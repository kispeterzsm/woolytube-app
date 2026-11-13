import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/database.dart';
import 'folder_write_errors.dart';
import 'info_backfill_service.dart';
import 'library_export_service.dart';
import 'library_file.dart';
import 'library_gate.dart';
import 'library_layout.dart';
import 'library_mirror.dart';
import 'log_service.dart';
import 'loudness_file.dart';
import 'loudness_mirror.dart';
import 'lyrics/lyrics_file_repair.dart';
import 'media_thumbnail_service.dart';
import 'metadata_service.dart';
import 'sidecar_mirror.dart';

/// What "Check backup" found about one playlist folder.
class PlaylistBackupStatus {
  const PlaylistBackupStatus({
    required this.name,
    required this.folder,
    this.folderMissing = false,
    this.outsideLibrary = false,
    this.sharedFolder = false,
    this.metadataOutOfDate = false,
    this.newerMetadataVersion,
    this.tracks = 0,
    this.missingCovers = 0,
    this.missingPlaylistCover = false,
    this.missingLyricsFiles = 0,
    this.outdatedLyricsFiles = 0,
    this.infoFiles = 0,
    this.missingInfoFiles = 0,
    this.unavailableInfoFiles = 0,
  });

  final String name;
  final String folder;

  /// The playlist folder does not exist.
  final bool folderMissing;

  /// The folder is not in Music/WoolyTube or Movies/WoolyTube, so copying
  /// those two does not take it along.
  final bool outsideLibrary;

  /// Another playlist points at the same folder. Their metadata, lyrics
  /// and loudness files would overwrite each other, so they are neither
  /// compared nor written until the app gives each its own folder.
  final bool sharedFolder;

  /// `woolytube_meta.json` or the `.m3u8` is missing or differs from the
  /// database.
  final bool metadataOutOfDate;

  /// The format of a metadata file a newer app wrote, left alone.
  final int? newerMetadataVersion;

  /// Downloaded tracks.
  final int tracks;

  /// Downloaded tracks without a cover file.
  final int missingCovers;

  final bool missingPlaylistCover;

  /// Tracks with lyrics whose lyrics file is missing, or differs from the
  /// database.
  final int missingLyricsFiles;
  final int outdatedLyricsFiles;

  /// Downloaded YouTube tracks with their YouTube description
  /// (`.info.json`). Files the owner put in place of a video are not
  /// counted (see [keepsYouTubeInfo]).
  final int infoFiles;

  /// Downloaded YouTube tracks without it. Older downloads never kept one;
  /// it is fetched in the background ([InfoBackfillService]).
  final int missingInfoFiles;

  /// Of [missingInfoFiles], the ones YouTube no longer has (removed,
  /// private), which the background fetch gave up on.
  final int unavailableInfoFiles;

  /// Something here that "Fix" can write.
  bool get needsFix =>
      !folderMissing &&
      (metadataOutOfDate ||
          missingCovers > 0 ||
          missingPlaylistCover ||
          missingLyricsFiles > 0 ||
          outdatedLyricsFiles > 0);
}

/// What "Check backup" found. Nothing was written to find it.
class BackupReport {
  const BackupReport({
    required this.playlists,
    required this.settingsSavedAt,
    required this.settingsUpToDate,
    required this.settingsWaitForRestore,
    required this.libraryFiles,
    required this.writeErrors,
    required this.oldDatabaseCopies,
    required this.oldDatabaseCopyBytes,
    required this.lastUpdated,
    this.infoPausedUntil,
  });

  final List<PlaylistBackupStatus> playlists;

  /// YouTube asked the background fetch of YouTube info to slow down; it
  /// waits until then.
  final DateTime? infoPausedUntil;

  /// When the settings file was last written; null when there is none.
  final DateTime? settingsSavedAt;
  final bool settingsUpToDate;

  /// The settings file came with a copied library that is still to be
  /// restored, so it is left as it is.
  final bool settingsWaitForRestore;

  /// The library file in each library root.
  final List<LibraryFileState> libraryFiles;

  /// Files that could not be written since the app started.
  final List<FolderWriteError> writeErrors;

  /// Database copies older versions left in the backup folder.
  final int oldDatabaseCopies;
  final int oldDatabaseCopyBytes;

  /// The newest change to the app's files in the library folders.
  final DateTime? lastUpdated;

  int get tracks => playlists.fold(0, (sum, pl) => sum + pl.tracks);

  /// YouTube info: [infoSaved] of [infoTotal] tracks have it, and
  /// [infoUnavailable] of the rest can no longer be fetched.
  int get infoSaved => _sumOfFolders((pl) => pl.infoFiles);
  int get infoTotal =>
      _sumOfFolders((pl) => pl.infoFiles + pl.missingInfoFiles);
  int get infoUnavailable => _sumOfFolders((pl) => pl.unavailableInfoFiles);

  int _sumOfFolders(int Function(PlaylistBackupStatus pl) count) =>
      playlists.fold(0, (sum, pl) => sum + (pl.folderMissing ? 0 : count(pl)));

  List<String> get foldersOutsideLibrary => [
    for (final playlist in playlists)
      if (playlist.outsideLibrary) playlist.folder,
  ];

  bool get libraryFileUpToDate => libraryFiles.every((file) => file.upToDate);

  /// Something that "Fix" can write.
  bool get needsFix =>
      playlists.any((pl) => pl.needsFix) ||
      (!settingsUpToDate && !settingsWaitForRestore) ||
      !libraryFileUpToDate;

  /// One line per thing that is missing or out of date in the folders.
  List<String> get problems {
    String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
    return [
      for (final pl in playlists) ...[
        if (pl.folderMissing) '"${pl.name}": folder not found',
        if (!pl.folderMissing) ...[
          if (pl.sharedFolder)
            '"${pl.name}": shares its folder with another playlist',
          if (pl.metadataOutOfDate) '"${pl.name}": playlist files out of date',
          if (pl.missingCovers > 0)
            '"${pl.name}": ${count(pl.missingCovers, 'track')} without a cover',
          if (pl.missingPlaylistCover) '"${pl.name}": no playlist cover',
          if (pl.missingLyricsFiles > 0)
            '"${pl.name}": ${count(pl.missingLyricsFiles, 'lyrics file')} '
                'missing',
          if (pl.outdatedLyricsFiles > 0)
            '"${pl.name}": ${count(pl.outdatedLyricsFiles, 'lyrics file')} '
                'out of date',
        ],
      ],
      if (settingsSavedAt == null && !settingsWaitForRestore)
        'Settings file missing'
      else if (!settingsUpToDate && !settingsWaitForRestore)
        'Settings file out of date',
      for (final file in libraryFiles)
        if (!file.upToDate)
          'Library file ${file.savedAt == null ? 'missing' : 'out of date'} '
              'in ${_rootName(file.path)}',
    ];
  }

  /// `Music/WoolyTube` for a file in it.
  static String _rootName(String path) {
    final root = p.dirname(path);
    return '${p.basename(p.dirname(root))}/${p.basename(root)}';
  }
}

/// "Check backup": finds out whether the library folders hold everything
/// the app knows, without writing anything, and fills the gaps on "Fix".
///
/// The mirrors keep the folders up to date as the library changes; this
/// shows that they did, and catches what a failed write left behind.
class BackupCheckService {
  BackupCheckService(
    this._db,
    this._metadata,
    this._exporter,
    this._libraryFile,
    this._gate, {
    LogService? log,
    bool Function()? libraryWaitsForRestore,
    InfoBackfillStore? infoBackfill,
  }) : _log = log,
       _libraryWaitsForRestore = libraryWaitsForRestore ?? _never,
       _infoBackfill = infoBackfill;

  final AppDatabase _db;
  final MetadataService _metadata;
  final LibraryExportService _exporter;
  final LibraryFileService _libraryFile;
  final LibraryGate _gate;
  final LogService? _log;
  final bool Function() _libraryWaitsForRestore;
  final InfoBackfillStore? _infoBackfill;

  static bool _never() => false;

  /// Checks every playlist folder and the library's own files. Writes
  /// nothing.
  Future<BackupReport> check({
    void Function(LibraryExportProgress progress)? onProgress,
  }) async {
    final playlists = await _db.getAllPlaylists();
    final infoStore = _infoBackfill;
    final info =
        infoStore == null
            ? const InfoBackfillStatus()
            : await InfoBackfillStatus.read(infoStore);
    final shared = LibraryLayout.sharedFolders(
      playlists.map((pl) => pl.outputPath),
    );
    final statuses = <PlaylistBackupStatus>[];
    for (var i = 0; i < playlists.length; i++) {
      final playlist = playlists[i];
      onProgress?.call(
        LibraryExportProgress(
          done: i,
          total: playlists.length,
          current: playlist.name,
        ),
      );
      statuses.add(
        await _checkPlaylist(
          playlist,
          info,
          sharedFolder: shared.contains(
            LibraryLayout.folderKey(playlist.outputPath),
          ),
        ),
      );
    }
    onProgress?.call(
      LibraryExportProgress(
        done: playlists.length,
        total: playlists.length,
        current: 'Settings',
      ),
    );
    final settings = await _exporter.settingsFileState();
    final waits = await _settingsWaitForRestore();
    final libraryFiles = await _libraryFile.check();
    final copies = await _exporter.oldDatabaseCopies();
    return BackupReport(
      playlists: statuses,
      settingsSavedAt: settings.savedAt,
      settingsUpToDate: settings.upToDate,
      settingsWaitForRestore: waits,
      libraryFiles: libraryFiles,
      writeErrors: FolderWriteErrors.all,
      oldDatabaseCopies: copies.count,
      oldDatabaseCopyBytes: copies.bytes,
      lastUpdated: await lastUpdated(playlists: playlists),
      infoPausedUntil: info.pausedUntil,
    );
  }

  Future<PlaylistBackupStatus> _checkPlaylist(
    Playlist playlist,
    InfoBackfillStatus info, {
    required bool sharedFolder,
  }) async {
    final folder = playlist.outputPath;
    final outside =
        !p.isWithin(LibraryLayout.audioBasePath, folder) &&
        !p.isWithin(LibraryLayout.videoBasePath, folder);
    if (!await Directory(folder).exists()) {
      return PlaylistBackupStatus(
        name: playlist.name,
        folder: folder,
        folderMissing: true,
        outsideLibrary: outside,
      );
    }
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    var downloaded = 0;
    var missingCovers = 0;
    var infoFiles = 0;
    var missingInfo = 0;
    var unavailableInfo = 0;
    for (final track in tracks) {
      if (track.status != 'complete' || track.filePath == null) continue;
      downloaded++;
      if (!await thumbnailFileExists(track.thumbnailPath)) missingCovers++;
      if (!keepsYouTubeInfo(track)) continue;
      if (await File(
        LibraryLayout.infoJsonPath(folder, track.videoId),
      ).exists()) {
        infoFiles++;
      } else {
        missingInfo++;
        if (track.unavailableReason != null ||
            info.givenUp.contains(track.videoId)) {
          unavailableInfo++;
        }
      }
    }
    // A shared folder holds one playlist's files at best: comparing would
    // report the other as out of date on every check.
    final sidecar =
        sharedFolder ? null : await _metadata.checkMetadataOf(playlist);
    final lyrics =
        sharedFolder
            ? null
            : await checkLyricsFiles(_db, playlist, tracks: tracks);
    return PlaylistBackupStatus(
      name: playlist.name,
      folder: folder,
      outsideLibrary: outside,
      sharedFolder: sharedFolder,
      metadataOutOfDate:
          sidecar != null &&
          sidecar.newerVersionKept == null &&
          (sidecar.sidecarOutOfDate || sidecar.playlistFileOutOfDate),
      newerMetadataVersion: sidecar?.newerVersionKept,
      tracks: downloaded,
      missingCovers: missingCovers,
      missingPlaylistCover:
          downloaded > 0 && !await thumbnailFileExists(playlist.thumbnailPath),
      missingLyricsFiles: lyrics?.missing ?? 0,
      outdatedLyricsFiles: lyrics?.outdated ?? 0,
      infoFiles: infoFiles,
      missingInfoFiles: missingInfo,
      unavailableInfoFiles: unavailableInfo,
    );
  }

  /// Writes everything the folders lack: covers (downloaded only when
  /// [allowNetwork]), metadata and playlist files, the settings and library
  /// files, lyrics files and loudness files. No database copy is made.
  /// Files a newer app wrote, and a settings file waiting to be restored,
  /// are left alone; nothing is deleted.
  ///
  /// Files are compared with the disk, not with what this run last wrote,
  /// so one changed on disk since is written again. The metadata, lyrics
  /// and loudness files of playlists sharing one folder are left alone
  /// (they would overwrite each other) and listed as a problem.
  Future<LibraryExportResult> fix({
    bool allowNetwork = false,
    void Function(LibraryExportProgress progress)? onProgress,
  }) async {
    final waits = await _settingsWaitForRestore();
    final export = await _exporter.exportLibrary(
      allowNetwork: allowNetwork,
      writeSettings: !waits,
      onProgress: onProgress,
    );
    final problems = [...export.problems];
    try {
      await _libraryFile.write(verify: true);
      FolderWriteErrors.succeeded(LibraryMirror.errorKey);
    } catch (e) {
      problems.add('Library file: $e');
      FolderWriteErrors.failed(LibraryMirror.errorKey, 'Library file', e);
    }
    var lyricsWritten = 0;
    final playlists = await _db.getAllPlaylists();
    final shared = LibraryLayout.sharedFolders(
      playlists.map((pl) => pl.outputPath),
    );
    for (final playlist in playlists) {
      if (shared.contains(LibraryLayout.folderKey(playlist.outputPath))) {
        final problem = LibraryExportService.sharedFolderProblem(playlist.name);
        if (!problems.contains(problem)) problems.add(problem);
        continue;
      }
      if (_folderBusy) {
        problems.add(
          '${playlist.name}: lyrics and loudness files wait until the '
          '${_gate.activeOperation} finishes',
        );
        continue;
      }
      try {
        final lyrics = await checkLyricsFiles(_db, playlist, repair: true);
        lyricsWritten += lyrics.written;
        problems.addAll(lyrics.failures.map((f) => '${playlist.name}: $f'));
      } catch (e) {
        problems.add('${playlist.name}: lyrics files: $e');
      }
      try {
        await writeLoudnessFile(_db, playlist);
        FolderWriteErrors.succeeded(LoudnessMirror.errorKey(playlist.id));
      } catch (e) {
        problems.add('${playlist.name}: loudness file: $e');
        FolderWriteErrors.failed(
          LoudnessMirror.errorKey(playlist.id),
          'Loudness file of "${playlist.name}"',
          e,
        );
      }
    }
    _log?.info(
      'backup fix: ${export.playlists} playlists, ${export.newCovers} new '
      'covers, $lyricsWritten lyrics files, ${problems.length} problems',
    );
    return LibraryExportResult(
      playlists: export.playlists,
      tracks: export.tracks,
      trackCovers: export.trackCovers,
      playlistCovers: export.playlistCovers,
      newCovers: export.newCovers,
      settingsPath: export.settingsPath,
      problems: problems,
      foldersOutsideLibrary: export.foldersOutsideLibrary,
    );
  }

  /// Writes the lyrics files that are missing for tracks with lyrics, at
  /// the app's start. Only looks for missing files (one file check per
  /// track with lyrics); "Check backup" also compares their content.
  /// Returns how many it wrote.
  Future<int> repairMissingLyricsFiles() async {
    var written = 0;
    final playlists = await _db.getAllPlaylists();
    final shared = LibraryLayout.sharedFolders(
      playlists.map((pl) => pl.outputPath),
    );
    for (final playlist in playlists) {
      // Two playlists in one folder: the startup check separates them.
      if (shared.contains(LibraryLayout.folderKey(playlist.outputPath))) {
        continue;
      }
      if (_folderBusy) break;
      try {
        final result = await checkLyricsFiles(
          _db,
          playlist,
          compareContent: false,
          repair: true,
        );
        written += result.written;
        for (final failure in result.failures) {
          _log?.warn(
            'Could not save a lyrics file in "${playlist.name}": '
            '$failure',
          );
        }
      } catch (e) {
        _log?.warn(
          'Could not check the lyrics files of "${playlist.name}": '
          '$e',
        );
      }
    }
    if (written > 0) _log?.info('lyrics: wrote $written missing lyrics files');
    return written;
  }

  /// The newest change to the app's own files in the library folders: the
  /// playlists' metadata and playlist files, the settings file and the
  /// library files. Null when there are none.
  Future<DateTime?> lastUpdated({List<Playlist>? playlists}) async {
    final paths = [
      for (final playlist in playlists ?? await _db.getAllPlaylists()) ...[
        p.join(playlist.outputPath, MetadataService.metaFileName),
        MetadataService.playlistFilePath(playlist.outputPath),
      ],
      p.join(
        LibraryExportService.backupDir,
        LibraryExportService.settingsFileName,
      ),
      for (final root in LibraryFileService.roots)
        LibraryFileService.pathIn(root),
    ];
    DateTime? newest;
    for (final path in paths) {
      try {
        final stat = await File(path).stat();
        if (stat.type == FileSystemEntityType.notFound) continue;
        if (newest == null || stat.modified.isAfter(newest)) {
          newest = stat.modified;
        }
      } catch (_) {
        // Not counted.
      }
    }
    return newest;
  }

  bool get _folderBusy =>
      SidecarMirror.folderChangingOperations.contains(_gate.activeOperation);

  Future<bool> _settingsWaitForRestore() async {
    if (!_libraryWaitsForRestore()) return false;
    if ((await _db.getAllPlaylists()).isNotEmpty) return false;
    return _exporter.settingsFileExists();
  }
}
