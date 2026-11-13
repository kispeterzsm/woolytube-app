import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/database.dart';
import 'app_settings_service.dart';
import 'library_layout.dart';
import 'log_service.dart';
import 'metadata_service.dart';
import 'thumbnail_backfill_service.dart';

class LibraryExportProgress {
  const LibraryExportProgress({
    required this.done,
    required this.total,
    this.current,
  });

  /// Playlists finished so far, out of [total].
  final int done;
  final int total;

  /// What is being worked on: a playlist name, or the settings.
  final String? current;
}

class LibraryExportResult {
  const LibraryExportResult({
    required this.playlists,
    required this.tracks,
    required this.trackCovers,
    required this.playlistCovers,
    required this.newCovers,
    required this.settingsPath,
    required this.problems,
    this.foldersOutsideLibrary = const [],
  });

  /// Playlists whose folder is now complete and up to date.
  final int playlists;

  /// Downloaded tracks in those playlists.
  final int tracks;

  /// Tracks and playlists with a cover image in their folder.
  final int trackCovers;
  final int playlistCovers;

  /// Covers saved during this export.
  final int newCovers;

  /// The settings file, or null when it was not written.
  final String? settingsPath;

  /// One line per thing that could not be exported.
  final List<String> problems;

  /// Folders of playlists that live outside Music/WoolyTube and
  /// Movies/WoolyTube (restored from another folder). A backup must copy
  /// these as well.
  final List<String> foldersOutsideLibrary;
}

/// Makes the library folders a complete backup: every playlist folder gets
/// an up-to-date sidecar, `.m3u8` and offline covers, and the settings go
/// into `Music/WoolyTube/.woolytube_backup`. The mirrors keep all of this
/// up to date as the library changes; "Check backup" runs an export to
/// fill whatever they missed.
///
/// Older versions also put copies of the app's database there. Nothing
/// restores from them, so none are made any more, and the ones there are
/// left alone: they are the owner's files.
class LibraryExportService {
  LibraryExportService(
    this._db,
    this._metadata,
    this._thumbnails,
    this._settings,
    this._log,
  );

  final AppDatabase _db;
  final MetadataService _metadata;
  final ThumbnailBackfillService _thumbnails;
  final AppSettingsService _settings;
  final LogService _log;

  static const backupDirName = '.woolytube_backup';
  static const settingsFileName = 'woolytube_settings.json';

  /// The database copies older versions made, named by their time.
  static final databaseCopyPattern = RegExp(r'^woolytube-\d{8}-\d{4}\.sqlite$');

  static String get backupDir =>
      p.join(LibraryLayout.audioBasePath, backupDirName);

  Future<LibraryExportResult>? _running;

  /// Exports everything. Covers may be downloaded only when [allowNetwork].
  /// The settings file is left alone without [writeSettings] (a copied
  /// library waiting to be restored brought its own). A failing playlist is
  /// listed in the result and the rest still export.
  Future<LibraryExportResult> exportLibrary({
    bool allowNetwork = false,
    bool writeSettings = true,
    void Function(LibraryExportProgress progress)? onProgress,
  }) {
    return _running ??= _export(
      allowNetwork,
      writeSettings,
      onProgress,
    ).whenComplete(() => _running = null);
  }

  Future<LibraryExportResult> _export(
    bool allowNetwork,
    bool writeSettings,
    void Function(LibraryExportProgress progress)? onProgress,
  ) async {
    final playlists = await _db.getAllPlaylists();
    final problems = <String>[];
    var exported = 0;
    var tracks = 0;
    var trackCovers = 0;
    var playlistCovers = 0;
    var newCovers = 0;

    for (var i = 0; i < playlists.length; i++) {
      final playlist = playlists[i];
      onProgress?.call(
        LibraryExportProgress(
          done: i,
          total: playlists.length,
          current: playlist.name,
        ),
      );
      try {
        if (!await Directory(playlist.outputPath).exists()) {
          problems.add(
            '${playlist.name}: folder not found (${playlist.outputPath})',
          );
          continue;
        }
        newCovers += await _thumbnails.ensureTrackThumbnails(
          playlist,
          allowNetwork: allowNetwork,
        );
        final cover = await _thumbnails.ensurePlaylistCover(
          playlist,
          allowNetwork: allowNetwork,
        );
        if (cover != null) newCovers++;
        await _metadata.writeMetadataFor(playlist.id);

        final current = await _db.getPlaylist(playlist.id);
        if (await _exists(current.thumbnailPath)) playlistCovers++;
        for (final track in await _db.getTracksForPlaylist(playlist.id)) {
          if (track.status != 'complete' || track.filePath == null) continue;
          tracks++;
          if (await _exists(track.thumbnailPath)) trackCovers++;
        }
        exported++;
      } catch (e) {
        problems.add('${playlist.name}: $e');
        _log.warn('export of ${playlist.name} failed: $e');
      }
    }

    onProgress?.call(
      LibraryExportProgress(
        done: playlists.length,
        total: playlists.length,
        current: 'Settings',
      ),
    );
    String? settingsFile;
    if (writeSettings) {
      try {
        settingsFile = await writeSettingsFile();
      } catch (e) {
        problems.add('Settings: $e');
        _log.warn('settings export failed: $e');
      }
    }
    _log.info(
      'library export: $exported playlists, $tracks tracks, '
      '$newCovers new covers, ${problems.length} problems',
    );

    final outside = <String>[
      for (final playlist in playlists)
        if (!p.isWithin(LibraryLayout.audioBasePath, playlist.outputPath) &&
            !p.isWithin(LibraryLayout.videoBasePath, playlist.outputPath))
          playlist.outputPath,
    ];
    return LibraryExportResult(
      foldersOutsideLibrary: outside,
      playlists: exported,
      tracks: tracks,
      trackCovers: trackCovers,
      playlistCovers: playlistCovers,
      newCovers: newCovers,
      settingsPath: settingsFile,
      problems: problems,
    );
  }

  /// The database copies older versions left in the backup folder: how
  /// many, and their size in bytes. They are never deleted by the app.
  Future<({int count, int bytes})> oldDatabaseCopies() async {
    var count = 0;
    var bytes = 0;
    final dir = Directory(backupDir);
    try {
      if (!await dir.exists()) return (count: 0, bytes: 0);
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File ||
            !databaseCopyPattern.hasMatch(p.basename(entity.path))) {
          continue;
        }
        count++;
        bytes += await entity.length();
      }
    } catch (_) {
      // Only mentioned in the check.
    }
    return (count: count, bytes: bytes);
  }

  /// Restores the app settings saved in the library's backup folder, or in
  /// [folder] (or its `.woolytube_backup`). Returns how many settings were
  /// applied, or null when no settings file exists.
  Future<int?> restoreSettings({String? folder}) async {
    final candidates = [
      if (folder != null) ...[
        p.join(folder, backupDirName, settingsFileName),
        p.join(folder, settingsFileName),
      ],
      p.join(backupDir, settingsFileName),
    ];
    for (final path in candidates) {
      final file = File(path);
      if (!await file.exists()) continue;
      final values = settingsFromFile(jsonDecode(await file.readAsString()));
      if (values == null) continue;
      return _settings.importSettings(values);
    }
    return null;
  }

  /// The settings in a decoded settings file, by key, or null when it is not
  /// one. Reads every version: version 2 lists them by section (and also
  /// flat, for older app versions), version 1 only flat under `settings`,
  /// and a hand-made file may list them at the top.
  static Map<String, Object?>? settingsFromFile(Object? decoded) {
    if (decoded is! Map) return null;
    final flat = decoded['settings'] is Map ? decoded['settings'] : decoded;
    final values = Map<String, Object?>.from(flat as Map);
    final sections = decoded['sections'];
    if (sections is Map) {
      for (final section in sections.values) {
        if (section is Map) values.addAll(Map<String, Object?>.from(section));
      }
    }
    return values;
  }

  /// The settings file format [writeSettingsFile] writes.
  static const settingsFileVersion = 2;

  /// The hash of the settings file this run last wrote or found unchanged.
  int? _settingsFileHash;

  /// The settings file write in progress, if any.
  Future<String>? _settingsWrite;

  /// Writes the owner's settings to `.woolytube_backup/woolytube_settings.json`
  /// and returns its path. A file whose content would not change is left
  /// alone. Writes run one after another (the settings mirror and a library
  /// export may ask at the same time).
  Future<String> writeSettingsFile() {
    final previous = _settingsWrite;
    final next =
        previous == null
            ? _writeSettingsFileNow()
            : previous.then(
              (_) => _writeSettingsFileNow(),
              onError: (Object _) => _writeSettingsFileNow(),
            );
    _settingsWrite = next;
    next.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_settingsWrite, next)) _settingsWrite = null;
    });
    return next;
  }

  Future<String> _settingsFileContent() async {
    final sections = await _settings.exportSettingsBySection();
    return const JsonEncoder.withIndent('  ').convert({
      'app': 'WoolyTube',
      'version': settingsFileVersion,
      'sections': sections,
      // The same settings in one list, as app versions before version 2
      // of this file read them.
      'settings': {for (final section in sections.values) ...section},
    });
  }

  /// The settings file in the library's backup folder: when it was last
  /// written, and whether it holds the current settings. Writes nothing.
  Future<({DateTime? savedAt, bool upToDate})> settingsFileState() async {
    final file = File(p.join(backupDir, settingsFileName));
    try {
      if (!await file.exists()) return (savedAt: null, upToDate: false);
      final savedAt = await file.lastModified();
      final upToDate =
          await file.readAsString() == await _settingsFileContent();
      return (savedAt: savedAt, upToDate: upToDate);
    } catch (_) {
      return (savedAt: null, upToDate: false);
    }
  }

  Future<String> _writeSettingsFileNow() async {
    final content = await _settingsFileContent();
    final hash = contentHash(content);
    final target = p.join(backupDir, settingsFileName);
    final file = File(target);
    if (_settingsFileHash == hash && await file.exists()) return target;
    if (_settingsFileHash == null) {
      try {
        if (await file.exists() && await file.readAsString() == content) {
          _settingsFileHash = hash;
          return target;
        }
      } catch (_) {
        // Written again below.
      }
    }
    await _prepareBackupDir();
    final tmp = File('$target.partial');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(target);
    _settingsFileHash = hash;
    return target;
  }

  /// Whether a settings file exists in the library's backup folder.
  Future<bool> settingsFileExists() =>
      File(p.join(backupDir, settingsFileName)).exists();

  Future<Directory> _prepareBackupDir() async {
    final dir = Directory(backupDir);
    await dir.create(recursive: true);
    try {
      final marker = File(p.join(dir.path, '.nomedia'));
      if (!await marker.exists()) await marker.create();
    } catch (_) {
      // Only keeps media apps out of the backup folder.
    }
    return dir;
  }

  static Future<bool> _exists(String? path) async =>
      path != null && path.isNotEmpty && await File(path).exists();
}
