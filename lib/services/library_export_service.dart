import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/database.dart';
import 'app_settings_service.dart';
import 'folder_write_errors.dart';
import 'library_layout.dart';
import 'log_service.dart';
import 'metadata_service.dart';
import 'settings_mirror.dart';
import 'sidecar_mirror.dart';
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

  /// Where a settings file this install did not write is put aside before
  /// the settings are written (for example one copied from another phone
  /// over a library that was already in use). Restore settings brings it
  /// back until it was restored once.
  static const previousSettingsFileName = 'woolytube_settings.previous.json';

  /// The database copies older versions made, named by their time.
  static final databaseCopyPattern = RegExp(r'^woolytube-\d{8}-\d{4}\.sqlite$');

  /// The problem listed for a playlist sharing its folder with another.
  static String sharedFolderProblem(String playlistName) =>
      '$playlistName: shares its folder with another playlist; its files '
      'are saved once the app gives it its own folder at the next start';

  static String get backupDir =>
      p.join(LibraryLayout.audioBasePath, backupDirName);

  Future<LibraryExportResult>? _running;

  /// Exports everything. Covers may be downloaded only when [allowNetwork].
  /// The settings file is left alone without [writeSettings] (a copied
  /// library waiting to be restored brought its own). A failing playlist is
  /// listed in the result and the rest still export.
  ///
  /// The metadata, playlist and settings files are compared with the disk,
  /// not with what this run last wrote, so a file changed on disk since is
  /// written again. Each write is reported to [FolderWriteErrors], so an
  /// earlier failure of the mirrors shows as saved again. Two playlists
  /// sharing one folder are left alone (their metadata files would
  /// overwrite each other) and listed as a problem.
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
    final shared = LibraryLayout.sharedFolders(
      playlists.map((pl) => pl.outputPath),
    );
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
        if (shared.contains(LibraryLayout.folderKey(playlist.outputPath))) {
          // Covers wait too: finding one rewrites the metadata file.
          problems.add(sharedFolderProblem(playlist.name));
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
        final errorKey = SidecarMirror.metadataErrorKey(playlist.id);
        try {
          await _metadata.writeMetadataFor(playlist.id, verify: true);
          FolderWriteErrors.succeeded(errorKey);
        } catch (e) {
          FolderWriteErrors.failed(
            errorKey,
            'Metadata file of "${playlist.name}"',
            e,
          );
          rethrow;
        }

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
        settingsFile = await writeSettingsFile(verify: true);
        FolderWriteErrors.succeeded(SettingsMirror.errorKey);
      } catch (e) {
        problems.add('Settings: $e');
        _log.warn('settings export failed: $e');
        FolderWriteErrors.failed(SettingsMirror.errorKey, 'Settings file', e);
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
  /// [folder] (or its `.woolytube_backup`). In the library's backup folder
  /// a settings file put aside as [previousSettingsFileName] comes first
  /// while it waits to be restored ([copiedSettingsWaiting]). Returns how
  /// many settings were applied, or null when no settings file exists.
  Future<int?> restoreSettings({String? folder}) async {
    final main = p.join(backupDir, settingsFileName);
    final previous = p.join(backupDir, previousSettingsFileName);
    final candidates = [
      if (folder != null) ...[
        p.join(folder, backupDirName, settingsFileName),
        p.join(folder, settingsFileName),
      ],
      if (await copiedSettingsWaiting()) ...[previous, main] else main,
    ];
    for (final path in candidates) {
      final file = File(path);
      if (!await file.exists()) continue;
      final content = await file.readAsString();
      final values = settingsFromFile(jsonDecode(content));
      if (values == null) continue;
      final applied = await _settings.importSettings(values);
      try {
        await _settings.setRestoredSettingsFileHash(contentHash(content));
      } catch (_) {
        // Only decides which file a later restore offers first.
      }
      return applied;
    }
    return null;
  }

  /// Whether a settings file that came from elsewhere was put aside as
  /// [previousSettingsFileName] and not restored yet, while the settings
  /// file is this install's own (or gone). Restore settings then restores
  /// the one put aside.
  Future<bool> copiedSettingsWaiting() async {
    try {
      final previous = File(p.join(backupDir, previousSettingsFileName));
      if (!await previous.exists()) return false;
      final restored = await _settings.getRestoredSettingsFileHash();
      if (contentHash(await previous.readAsString()) == restored) return false;
      final main = File(p.join(backupDir, settingsFileName));
      if (!await main.exists()) return true;
      return contentHash(await main.readAsString()) ==
          await _settings.getSettingsFileHash();
    } catch (_) {
      return false;
    }
  }

  /// The keys around the settings in a settings file.
  static const _settingsFileEnvelope = {'app', 'version', 'sections'};

  /// The settings in a decoded settings file, by key, or null when it is not
  /// one. Reads every version: version 2 lists them by section (and also
  /// flat, for older app versions), version 1 only flat under `settings`,
  /// and a hand-made file may list them at the top.
  static Map<String, Object?>? settingsFromFile(Object? decoded) {
    if (decoded is! Map) return null;
    final Map<String, Object?> values;
    if (decoded['settings'] case final Map settings) {
      values = Map<String, Object?>.from(settings);
    } else {
      values = Map<String, Object?>.from(decoded)
        ..removeWhere((key, _) => _settingsFileEnvelope.contains(key));
    }
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

  /// When this run last wrote the settings file. Some phones report an
  /// older modified time for a rewritten file, so this is preferred when
  /// it is later.
  DateTime? _settingsWrittenAt;

  /// The settings file write in progress, if any.
  Future<String>? _settingsWrite;

  /// Writes the owner's settings to `.woolytube_backup/woolytube_settings.json`
  /// and returns its path. A file whose content would not change is left
  /// alone. Writes run one after another (the settings mirror and a library
  /// export may ask at the same time).
  ///
  /// A settings file there that this install did not write (its hash is not
  /// the one remembered in [AppSettingsService.settingsFileHashKey]) and
  /// that holds settings this phone does not have the same is never
  /// written over: it came from elsewhere, for example copied from another
  /// phone. It is put aside as [previousSettingsFileName] first, and
  /// Restore settings offers it.
  ///
  /// With [verify] the file is compared with the disk even when this run
  /// already wrote the same content, so a file changed on disk since is
  /// written again (by the same rules).
  Future<String> writeSettingsFile({bool verify = false}) {
    final previous = _settingsWrite;
    final next =
        previous == null
            ? _writeSettingsFileNow(verify)
            : previous.then(
              (_) => _writeSettingsFileNow(verify),
              onError: (Object _) => _writeSettingsFileNow(verify),
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
      final modified = await file.lastModified();
      final written = _settingsWrittenAt;
      final savedAt =
          written != null && written.isAfter(modified) ? written : modified;
      final upToDate =
          await file.readAsString() == await _settingsFileContent();
      return (savedAt: savedAt, upToDate: upToDate);
    } catch (_) {
      return (savedAt: null, upToDate: false);
    }
  }

  Future<String> _writeSettingsFileNow(bool verify) async {
    final content = await _settingsFileContent();
    final hash = contentHash(content);
    final target = p.join(backupDir, settingsFileName);
    final file = File(target);
    if (!verify && _settingsFileHash == hash && await file.exists()) {
      return target;
    }
    final exists = await file.exists();
    String? onDisk;
    if (exists) {
      try {
        onDisk = await file.readAsString();
      } catch (_) {
        // Unreadable: put aside below rather than lost.
      }
    }
    if (onDisk == content) {
      await _rememberSettingsFile(hash);
      return target;
    }
    await _prepareBackupDir();
    if (exists && !await _mayReplaceSettingsFile(onDisk)) {
      await file.rename(p.join(backupDir, previousSettingsFileName));
      _log.info(
        'The settings file in the library folder was not written by this '
        'install; kept it as $previousSettingsFileName',
      );
    }
    final tmp = File('$target.partial');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(target);
    _settingsWrittenAt = DateTime.now();
    await _rememberSettingsFile(hash);
    return target;
  }

  Future<void> _rememberSettingsFile(int hash) async {
    _settingsFileHash = hash;
    try {
      if (await _settings.getSettingsFileHash() != hash) {
        await _settings.setSettingsFileHash(hash);
      }
    } catch (_) {
      // Without it the next run compares the settings themselves.
    }
  }

  /// Whether the settings file content [onDisk] may be written over: this
  /// install wrote it, or every setting in it that a restore would bring
  /// back is set the same on this phone (nothing would be lost, for example
  /// a file of an older version of the app on this same phone).
  ///
  /// Keys a restore skips are not compared: older versions also wrote app
  /// bookkeeping (the last yt-dlp update, whether the plane mode tips were
  /// shown), which a restore never applies.
  Future<bool> _mayReplaceSettingsFile(String? onDisk) async {
    if (onDisk == null) return false;
    try {
      if (contentHash(onDisk) == await _settings.getSettingsFileHash()) {
        return true;
      }
      final values = settingsFromFile(jsonDecode(onDisk));
      if (values == null) return false;
      final current = await _settings.exportSettings();
      for (final setting in AppSettingsService.backedUpSettings) {
        final value = setting.accept(values[setting.key]);
        // Missing or not a value this setting takes: a restore skips it.
        if (value == null) continue;
        if (current[setting.key] != value) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
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
