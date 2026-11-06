import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';
import 'sponsorblock_categories.dart';
import 'chapters.dart';
import 'library_layout.dart';
import 'media_thumbnail_service.dart';

class DiscoveredTrack {
  final int index;
  final String videoId;
  final String title;
  final String? thumbnailUrl;
  final String? thumbnailFileName;
  final int? durationSeconds;
  final String status;
  final String? unavailableReason;
  final bool isLocalReplacement;
  final bool alwaysSkip;
  final String? chaptersJson;
  final bool? chaptersEnabled;
  final DateTime? sponsorBlockCheckedAt;
  final DateTime? downloadedAt;
  final bool replaceRequested;
  final String? fileName;
  final List<DiscoveredSponsorBlockSegment> sponsorBlockSegments;

  DiscoveredTrack({
    required this.index,
    required this.videoId,
    required this.title,
    this.thumbnailUrl,
    this.thumbnailFileName,
    this.durationSeconds,
    required this.status,
    this.unavailableReason,
    this.isLocalReplacement = false,
    this.alwaysSkip = false,
    this.chaptersJson,
    this.chaptersEnabled,
    this.sponsorBlockCheckedAt,
    this.downloadedAt,
    this.replaceRequested = false,
    this.fileName,
    this.sponsorBlockSegments = const [],
  });
}

class DiscoveredSponsorBlockSegment {
  final String source;
  final String? uuid;
  final String category;
  final String actionType;
  final int startMs;
  final int endMs;
  final int? votes;
  final bool? locked;
  final String? description;
  final DateTime? createdAt;

  const DiscoveredSponsorBlockSegment({
    required this.source,
    this.uuid,
    required this.category,
    this.actionType = 'skip',
    required this.startMs,
    required this.endMs,
    this.votes,
    this.locked,
    this.description,
    this.createdAt,
  });
}

class DiscoveredPlaylist {
  final String folderPath;
  final String url;
  final String name;
  final String? thumbnailUrl;
  final String? thumbnailFileName;
  final bool audioOnly;
  final bool playChapters;
  final bool autoUpdate;
  final int updateFrequencyHours;
  final bool includeThumbnails;
  final bool sponsorBlockEnabled;
  final String sponsorBlockCategories;
  final String sponsorBlockCategoryActions;
  final DateTime? lastUpdated;
  final DateTime createdAt;
  final List<DiscoveredTrack> tracks;

  DiscoveredPlaylist({
    required this.folderPath,
    required this.url,
    required this.name,
    this.thumbnailUrl,
    this.thumbnailFileName,
    required this.audioOnly,
    this.playChapters = true,
    required this.autoUpdate,
    required this.updateFrequencyHours,
    required this.includeThumbnails,
    required this.sponsorBlockEnabled,
    required this.sponsorBlockCategories,
    this.sponsorBlockCategoryActions = defaultSponsorBlockCategoryActionsJson,
    this.lastUpdated,
    required this.createdAt,
    required this.tracks,
  });
}

const _metaFileName = 'woolytube_meta.json';

/// Thrown when a playlist is added or imported that is already in the
/// library (same folder, or same YouTube playlist in the same mode).
class PlaylistExistsException implements Exception {
  final String message;

  const PlaylistExistsException(this.message);

  @override
  String toString() => message;
}

/// Index prefix yt-dlp output files and sidecars share, e.g. `00012_`.
final _indexPrefixPattern = RegExp(r'^(\d+)_');

class _CandidateFile {
  final int index;
  final String path;
  _CandidateFile({required this.index, required this.path});
}

/// Keys of yt-dlp's info.json that only describe how to download the video.
/// They are large and useless once the file exists.
const _downloadOnlyInfoKeys = {
  'formats',
  'requested_formats',
  'requested_downloads',
  'requested_subtitles',
  'automatic_captions',
  'subtitles',
  'thumbnails',
  'heatmap',
  'http_headers',
  'fragments',
  'url',
  'manifest_url',
  '_format_sort_fields',
  '_has_drm',
  '_version',
};

class MetadataService {
  final AppDatabase _db;

  MetadataService(this._db);

  static String get metaFileName => _metaFileName;

  /// Repairs a playlist only when it contains transient download state.
  /// Normal pending-file reuse remains the download service's responsibility,
  /// including its SponsorBlock refresh path. Call only while holding the
  /// library gate.
  Future<int> recoverInterruptedPlaylist(Playlist playlist) async {
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    if (!tracks.any((track) => track.status == 'downloading')) return 0;
    return repairPlaylist(playlist);
  }

  /// Repairs every playlist after an interrupted app process and rewrites any
  /// sidecar whose database/filesystem state changed. This never starts a
  /// download; recovered tracks remain pending until a later update trigger.
  /// Call only while holding the library gate.
  Future<int> recoverInterruptedDownloads() async {
    var fixed = 0;
    for (final playlist in await _db.getAllPlaylists()) {
      await discardStaging(playlist.outputPath);
      final playlistFixed = await repairPlaylist(playlist);
      fixed += playlistFixed;
      if (playlistFixed > 0) {
        final tracks = await _db.getTracksForPlaylist(playlist.id);
        await writeMetadata(playlist, tracks);
      }
    }
    return fixed;
  }

  /// Consumes yt-dlp info files left in the playlist folder by older
  /// versions, without modifying the downloaded media.
  Future<void> captureChapterMetadata(Track track, String folder) async {
    final dir = Directory(folder);
    if (!await dir.exists() || track.isLocalReplacement) return;
    await for (final entity in dir.list()) {
      if (entity is! File || !_isInfoJsonForIndex(entity.path, track.index)) {
        continue;
      }
      await _consumeInfoJsonFile(track, entity, folder);
    }
  }

  static bool _isInfoJsonForIndex(String path, int index) {
    if (!path.endsWith('.info.json')) return false;
    final prefix = _indexPrefixPattern.firstMatch(p.basename(path));
    return prefix != null && int.tryParse(prefix[1]!) == index;
  }

  /// Applies the chapters of a matching info file and moves the file, trimmed,
  /// into the playlist's info folder.
  Future<void> _consumeInfoJsonFile(
    Track track,
    File infoFile,
    String folder,
  ) async {
    try {
      final info =
          jsonDecode(await infoFile.readAsString()) as Map<String, dynamic>;
      if (info['id'] != track.videoId) return;
      await _applyDownloadedChapters(track.id, info);
      await keepVideoInfo(folder, track.videoId, info);
      await infoFile.delete();
    } catch (_) {
      // A broken metadata sidecar must not fail a successful media download.
    }
  }

  /// Stores YouTube's chapters for a freshly downloaded copy of a track's own
  /// video. The owner's custom chapters are never dropped: they were made
  /// for this video's timeline (a local replacement had only disabled them).
  Future<void> _applyDownloadedChapters(
    int trackId,
    Map<String, dynamic> info, {
    bool wasLocal = false,
  }) async {
    final fresh = await _db.getTrack(trackId);
    if (fresh == null) return;
    final old = ChapterData.decode(fresh.chaptersJson);
    final data = ChapterData.fromVideoInfo(info);
    // Replacing a local file disables its chapters. Chapters still disabled
    // were made for this video before the replacement and fit again; ones
    // the owner made (and so enabled) while the local file played do not.
    final keepCustom = !wasLocal || !old.valid;
    await _db.writeTrackChapters(
      trackId,
      ChapterData(
        downloaded: data.downloaded,
        custom: keepCustom ? old.custom : null,
        shuffleChapters: old.shuffleChapters,
        checkedAt: data.checkedAt,
        durationMs: data.durationMs,
      ),
    );
  }

  /// Keeps yt-dlp's description of a video (uploader, upload date,
  /// description, tags, ...) without the download-only parts, because
  /// YouTube may delete the original.
  Future<void> keepVideoInfo(
    String folder,
    String videoId,
    Map<String, dynamic> info,
  ) async {
    try {
      final trimmed = {
        for (final entry in info.entries)
          if (!_downloadOnlyInfoKeys.contains(entry.key))
            entry.key: entry.value,
      };
      final dir = Directory(LibraryLayout.infoDir(folder));
      await dir.create(recursive: true);
      await _ensureNoMedia(dir.path);
      final target = File(LibraryLayout.infoJsonPath(folder, videoId));
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent(' ').convert(trimmed),
      );
      await tmp.rename(target.path);
    } catch (_) {
      // Extra information only; never fail a download over it.
    }
  }

  final _metadataWrites = <int, Future<void>>{};
  final _lastWritten = <String, String>{};
  var _metadataWriteCounter = 0;

  /// Writes playlist metadata as JSON sidecar file in the playlist folder,
  /// together with a `.m3u8` playlist other players can open.
  ///
  /// Writes for one playlist run strictly one after another. Download
  /// progress, sync and UI edits can all request a write at the same time and
  /// would otherwise race on the temp file or rename a half-written sidecar
  /// into place.
  Future<void> writeMetadata(Playlist playlist, List<Track> tracks) {
    final previous = _metadataWrites[playlist.id] ?? Future<void>.value();
    final current = previous
        .catchError((_) {})
        .then((_) => _writeMetadataNow(playlist, tracks));
    _metadataWrites[playlist.id] = current;
    return current.whenComplete(() {
      if (identical(_metadataWrites[playlist.id], current)) {
        _metadataWrites.remove(playlist.id);
      }
    });
  }

  /// Rewrites the sidecar and playlist file of [playlistId] from the
  /// database. Safe to call after any edit.
  Future<void> writeMetadataFor(int playlistId) async {
    final playlist = await _db.getPlaylist(playlistId);
    final tracks = await _db.getTracksForPlaylist(playlistId);
    await writeMetadata(playlist, tracks);
  }

  Future<void> _writeMetadataNow(Playlist playlist, List<Track> tracks) async {
    final dir = Directory(playlist.outputPath);
    if (!await dir.exists()) return;

    final segmentsByTrack = await _segmentsByTrack(tracks);
    final tracksJson = <Map<String, dynamic>>[];
    for (final t in tracks) {
      final segments = segmentsByTrack[t.id] ?? const <SponsorBlockSegment>[];
      tracksJson.add({
        'index': t.index,
        'videoId': t.videoId,
        'title': t.title,
        'thumbnailUrl': t.thumbnailUrl,
        'thumbnailFileName': _fileNameRelativeTo(
          playlist.outputPath,
          t.thumbnailPath,
        ),
        'durationSeconds': t.durationSeconds,
        'status': t.status,
        'unavailableReason': t.unavailableReason,
        'isLocalReplacement': t.isLocalReplacement,
        'alwaysSkip': t.alwaysSkip,
        'chapters': ChapterData.decode(t.chaptersJson).toJson(),
        'chaptersEnabled': t.chaptersEnabled,
        'sponsorBlockCheckedAt':
            t.sponsorBlockCheckedAt?.toUtc().toIso8601String(),
        'downloadedAt': t.downloadedAt?.toUtc().toIso8601String(),
        'replaceRequested': t.replaceRequested,
        'fileName': _fileNameRelativeTo(playlist.outputPath, t.filePath),
        'sponsorBlockSegments':
            segments
                .map(
                  (s) => {
                    'source': s.source,
                    'uuid': s.uuid,
                    'category': s.category,
                    'actionType': s.actionType,
                    'startMs': s.startMs,
                    'endMs': s.endMs,
                    'votes': s.votes,
                    'locked': s.locked,
                    'description': s.description,
                    'createdAt': s.createdAt.toUtc().toIso8601String(),
                  },
                )
                .toList(),
      });
    }

    final data = {
      'version': 2,
      'playlist': {
        'url': playlist.url,
        'name': playlist.name,
        'thumbnailUrl': playlist.thumbnailUrl,
        'thumbnailFileName': _fileNameRelativeTo(
          playlist.outputPath,
          playlist.thumbnailPath,
        ),
        'audioOnly': playlist.audioOnly,
        'playChapters': playlist.playChapters ?? true,
        'autoUpdate': playlist.autoUpdate,
        'updateFrequencyHours': playlist.updateFrequencyHours,
        'includeThumbnails': playlist.includeThumbnails,
        'sponsorBlockEnabled': playlist.sponsorBlockEnabled,
        'sponsorBlockCategories': playlist.sponsorBlockCategories,
        'sponsorBlockCategoryActions': playlist.sponsorBlockCategoryActions,
        'lastUpdated': playlist.lastUpdated?.toUtc().toIso8601String(),
        'createdAt': playlist.createdAt.toUtc().toIso8601String(),
      },
      'tracks': tracksJson,
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    await _writeIfChanged(p.join(playlist.outputPath, _metaFileName), jsonStr);
    await _writeIfChanged(
      playlistFilePath(playlist.outputPath),
      buildPlaylistFile(playlist, tracks),
    );
    await _writeLibraryReadme(p.dirname(playlist.outputPath));
  }

  Future<Map<int, List<SponsorBlockSegment>>> _segmentsByTrack(
    List<Track> tracks,
  ) async {
    if (tracks.isEmpty) return const {};
    final ids = tracks.map((t) => t.id).toList();
    final result = <int, List<SponsorBlockSegment>>{};
    // SQLite limits the number of bound variables per statement.
    for (var start = 0; start < ids.length; start += 500) {
      final chunk = ids.sublist(
        start,
        start + 500 > ids.length ? ids.length : start + 500,
      );
      final rows =
          await (_db.select(_db.sponsorBlockSegments)
                ..where((s) => s.trackId.isIn(chunk))
                ..orderBy([(s) => OrderingTerm.asc(s.startMs)]))
              .get();
      for (final row in rows) {
        result.putIfAbsent(row.trackId, () => []).add(row);
      }
    }
    return result;
  }

  /// Writes [content] to [path] atomically, skipping the write when this
  /// service already wrote the same content there.
  Future<void> _writeIfChanged(String path, String content) async {
    final target = File(path);
    if (_lastWritten[path] == content && await target.exists()) return;
    final tmpFile = File(
      '$path.tmp.'
      '${DateTime.now().microsecondsSinceEpoch}.${_metadataWriteCounter++}',
    );
    try {
      await tmpFile.writeAsString(content);
      await tmpFile.rename(target.path);
      _lastWritten[path] = content;
    } catch (_) {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {
        // The folder cleanup removes leftover temp files later.
      }
      rethrow;
    }
  }

  /// `<folder name>.m3u8` in the playlist folder. The folder name never
  /// changes after creation, so neither does this file's name.
  static String playlistFilePath(String folder) =>
      p.join(folder, '${p.basename(folder)}.m3u8');

  /// An extended M3U playlist of the downloaded tracks in the app's order,
  /// with the app's titles. Paths are relative so the folder can be copied
  /// anywhere. Tracks set to "Always skip" are left out, as in the app.
  static String buildPlaylistFile(Playlist playlist, List<Track> tracks) {
    final buffer =
        StringBuffer()
          ..writeln('#EXTM3U')
          ..writeln('#PLAYLIST:${_singleLine(playlist.name)}');
    final ordered = [...tracks]..sort((a, b) => a.index.compareTo(b.index));
    for (final track in ordered) {
      final path = track.filePath;
      if (track.status != 'complete' || path == null || track.alwaysSkip) {
        continue;
      }
      final relative = _fileNameRelativeTo(playlist.outputPath, path);
      if (relative == null) continue;
      buffer
        ..writeln(
          '#EXTINF:${track.durationSeconds ?? -1},${_singleLine(track.title)}',
        )
        ..writeln(relative.replaceAll(r'\', '/'));
    }
    return buffer.toString();
  }

  static String _singleLine(String text) =>
      text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

  /// [path] relative to [folder]: just the name for files inside it, a
  /// `../` path for files elsewhere (for example in the other format's
  /// folder while a mode switch is still downloading).
  static String? _fileNameRelativeTo(String folder, String? path) {
    if (path == null || path.isEmpty) return null;
    final normalizedFolder = p.normalize(p.absolute(folder));
    final normalizedPath = p.normalize(p.absolute(path));
    return p.relative(normalizedPath, from: normalizedFolder);
  }

  static const _readmeName = 'README - WoolyTube library.txt';
  static const _readmeText = '''
WoolyTube library
=================

Everything here plays without WoolyTube.

Each folder is one playlist:
  - Media files are named "<number>_<title>". The number is the track's
    position in the playlist, so sorting by name gives the playlist order.
  - "<folder>.m3u8" is a playlist file most music and video players can
    open. It lists the tracks in order with their full titles.
  - Files carry title, artist, album (= playlist name), track number
    (= position), date and the YouTube link as tags, plus cover art.
  - woolytube_meta.json holds everything WoolyTube knows about the
    playlist: order, titles, chapters, skip segments and settings.
    WoolyTube restores a playlist from it after a reinstall.
  - .woolytube_thumbnails holds the cover images, .woolytube_info the
    original YouTube descriptions (uploader, upload date, description) and
    .woolytube_replaced earlier files that were replaced.

Copy the whole WoolyTube folder (Music/WoolyTube for audio, Movies/WoolyTube
for video) to keep a complete backup.
''';

  Future<void> _writeLibraryReadme(String basePath) async {
    try {
      final file = File(p.join(basePath, _readmeName));
      if (await file.exists()) return;
      await file.writeAsString(_readmeText);
    } catch (_) {
      // Informational only.
    }
  }

  /// Scans public WoolyTube folders for playlist metadata files.
  Future<List<DiscoveredPlaylist>> scanForPlaylists() async {
    final discovered = <DiscoveredPlaylist>[];
    for (final scanPath in [
      LibraryLayout.audioBasePath,
      LibraryLayout.videoBasePath,
    ]) {
      discovered.addAll(await scanDirectory(scanPath, maxDepth: 1));
    }
    return discovered;
  }

  /// Finds playlist folders (folders with a `woolytube_meta.json`) at or
  /// below [rootPath], for restoring a copied backup from anywhere.
  Future<List<DiscoveredPlaylist>> scanDirectory(
    String rootPath, {
    int maxDepth = 3,
  }) async {
    final discovered = <DiscoveredPlaylist>[];
    Future<void> visit(Directory dir, int depth) async {
      final metaFile = File(p.join(dir.path, _metaFileName));
      if (await metaFile.exists()) {
        final parsed = await _readSidecar(dir.path, metaFile);
        if (parsed != null) {
          discovered.add(parsed);
          return;
        }
      }
      if (depth >= maxDepth) return;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final name = p.basename(entity.path);
          if (name.startsWith('.')) continue;
          await visit(entity, depth + 1);
        }
      } on FileSystemException {
        // Unreadable folder; skip it.
      }
    }

    final root = Directory(rootPath);
    if (await root.exists()) await visit(root, 0);
    return discovered;
  }

  Future<DiscoveredPlaylist?> _readSidecar(String folder, File metaFile) async {
    try {
      final json =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      return _parseMetadata(folder, json);
    } catch (_) {
      return null; // Malformed JSON
    }
  }

  /// Reads the sidecar of one folder, if it has a valid one.
  Future<DiscoveredPlaylist?> readFolder(String folder) {
    return _readSidecar(folder, File(p.join(folder, _metaFileName)));
  }

  /// Reads the sidecar a format switch set aside in [folder]
  /// (`woolytube_meta.json.superseded`), if any.
  Future<DiscoveredPlaylist?> readSupersededFolder(String folder) {
    return _readSidecar(
      folder,
      File(p.join(folder, '$_metaFileName.superseded')),
    );
  }

  /// Returns only playlists not already in the database. A folder counts as
  /// imported when a playlist uses it, or when a playlist of the same mode
  /// already has its URL.
  ///
  /// With [skipOtherModeCopies] (the startup banner), a folder of a playlist
  /// that is already in the library in the other mode is not offered: it is
  /// almost always what an older version left behind after a format switch.
  /// The Restore screen still lists it, for a copy kept on purpose.
  Future<List<DiscoveredPlaylist>> findUnimportedPlaylists({
    Set<String> excludeUrls = const {},
    List<DiscoveredPlaylist>? candidates,
    bool skipOtherModeCopies = false,
  }) async {
    final discovered = candidates ?? await scanForPlaylists();
    final existing = await _db.getAllPlaylists();
    final result = <DiscoveredPlaylist>[];
    final seenFolders = <String>{};

    for (final dp in discovered) {
      if (excludeUrls.contains(dp.url)) continue;
      final folder = _folderKey(dp.folderPath);
      if (!seenFolders.add(folder)) continue;
      final imported = existing.any(
        (pl) =>
            _folderKey(pl.outputPath) == folder ||
            (samePlaylistUrl(pl.url, dp.url) &&
                (pl.audioOnly == dp.audioOnly || skipOtherModeCopies)),
      );
      // One offer per playlist and mode, even if several folders hold it.
      final offered = result.any(
        (other) =>
            samePlaylistUrl(other.url, dp.url) &&
            other.audioOnly == dp.audioOnly,
      );
      if (!imported && !offered) result.add(dp);
    }

    return result;
  }

  /// Folder identity on Android's shared storage, which ignores case.
  static String _folderKey(String path) =>
      p.normalize(p.absolute(path)).toLowerCase();

  /// Whether two playlist URLs point at the same YouTube playlist.
  static bool samePlaylistUrl(String a, String b) {
    if (a == b) return true;
    String? listId(String url) =>
        Uri.tryParse(url.trim())?.queryParameters['list'];
    final aId = listId(a);
    return aId != null && aId.isNotEmpty && aId == listId(b);
  }

  /// Matches database tracks with the files in the playlist folder without
  /// deleting or renaming anything. Safe while a download runs: a track in
  /// the middle of a download is left alone.
  Future<int> reconcilePlaylist(Playlist playlist) =>
      _reconcile(playlist, recoverInterrupted: false, cleanup: false);

  /// Full repair: also resets tracks a killed process left 'downloading',
  /// renames files whose number no longer matches their track, and removes
  /// download leftovers. Call only while holding the library gate.
  Future<int> repairPlaylist(Playlist playlist) =>
      _reconcile(playlist, recoverInterrupted: true, cleanup: true);

  Future<int> _reconcile(
    Playlist playlist, {
    required bool recoverInterrupted,
    required bool cleanup,
  }) async {
    var tracks = await _db.getTracksForPlaylist(playlist.id);
    final dir = Directory(playlist.outputPath);
    var fixed = 0;
    if (!await dir.exists()) {
      if (!recoverInterrupted) return 0;
      for (final track in tracks.where((t) => t.status == 'downloading')) {
        await _db.resetInterruptedTrack(track.id);
        fixed++;
      }
      return fixed;
    }

    final mediaFiles = <_CandidateFile>[];
    final infoFilesByIndex = <int, List<File>>{};

    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final fileName = p.basename(entity.path);
      final ext = p.extension(entity.path).toLowerCase();

      if (fileName.endsWith('.info.json')) {
        final prefix = _indexPrefixPattern.firstMatch(fileName);
        final index = prefix == null ? null : int.tryParse(prefix[1]!);
        if (index != null) {
          infoFilesByIndex.putIfAbsent(index, () => []).add(entity);
        }
        continue;
      }
      if (isTransientFile(fileName) || !mediaExtensions.contains(ext)) continue;
      final match = _indexPrefixPattern.firstMatch(fileName);
      final index = match == null ? null : int.tryParse(match[1]!);
      if (index == null) continue;
      mediaFiles.add(_CandidateFile(index: index, path: entity.path));
    }

    for (final track in tracks) {
      if (track.isLocalReplacement) continue;
      for (final infoFile in infoFilesByIndex[track.index] ?? const <File>[]) {
        await _consumeInfoJsonFile(track, infoFile, playlist.outputPath);
      }
    }

    // When the folder lists no media at all although tracks point into it,
    // the storage is far more likely unreadable (no permission yet, storage
    // not mounted) than emptied. Never demote tracks on that evidence.
    final unreadable =
        mediaFiles.isEmpty &&
        tracks.any(
          (t) =>
              t.status == 'complete' &&
              t.filePath != null &&
              p.isWithin(playlist.outputPath, t.filePath!),
        );

    final claimed = <String>{
      for (final t in tracks)
        if (t.filePath != null && File(t.filePath!).existsSync())
          p.normalize(t.filePath!),
    };

    for (final track in tracks) {
      final ownPath = track.filePath;
      final hasOwnFile =
          ownPath != null && claimed.contains(p.normalize(ownPath));
      if (hasOwnFile) {
        if (track.status == 'pending' ||
            track.status == 'error' ||
            track.status == 'unavailable' ||
            (track.status == 'downloading' && recoverInterrupted)) {
          await _db.updateTrackStatus(track.id, 'complete', filePath: ownPath);
          fixed++;
        }
        continue;
      }
      if (track.status == 'downloading' && !recoverInterrupted) continue;

      final candidate = _pickCandidate(mediaFiles, track, claimed);
      if (candidate != null) {
        claimed.add(p.normalize(candidate));
        await _db.updateTrackStatus(track.id, 'complete', filePath: candidate);
        fixed++;
      } else if (track.status == 'downloading') {
        await _db.resetInterruptedTrack(track.id);
        fixed++;
      } else if (track.status == 'complete' && !unreadable) {
        await _db.updateTrackStatus(
          track.id,
          'pending',
          clearFilePath: true,
          clearDownloadedAt: true,
        );
        fixed++;
      }
    }

    if (cleanup && !unreadable) {
      tracks = await _db.getTracksForPlaylist(playlist.id);
      fixed += await _renameToTrackNumbers(playlist, tracks);
      tracks = await _db.getTracksForPlaylist(playlist.id);
      fixed += await _cleanupFolder(playlist, tracks);
    }

    return fixed;
  }

  /// The unclaimed media file whose number equals the track's index. When
  /// several match, only one whose name was made from the track's title is
  /// taken; otherwise nothing is guessed.
  static String? _pickCandidate(
    List<_CandidateFile> files,
    Track track,
    Set<String> claimed,
  ) {
    final matches = [
      for (final f in files)
        if (f.index == track.index && !claimed.contains(p.normalize(f.path)))
          f.path,
    ];
    if (matches.length == 1) return matches.single;
    if (matches.isEmpty) return null;
    final byTitle = matches.where((m) => titleMatchesFileName(track.title, m));
    return byTitle.length == 1 ? byTitle.single : null;
  }

  /// A media file in the playlist folder that a pending [track] may adopt
  /// instead of downloading again (for example after a crash between the
  /// download and the database update).
  Future<String?> findAdoptableMediaFile(Playlist playlist, Track track) async {
    final dir = Directory(playlist.outputPath);
    if (!await dir.exists()) return null;
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    final claimed = <String>{
      for (final t in tracks)
        if (t.id != track.id &&
            t.filePath != null &&
            File(t.filePath!).existsSync())
          p.normalize(t.filePath!),
    };
    final files = <_CandidateFile>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (isTransientFile(name) ||
          !mediaExtensions.contains(p.extension(name).toLowerCase())) {
        continue;
      }
      final match = _indexPrefixPattern.firstMatch(name);
      final index = match == null ? null : int.tryParse(match[1]!);
      if (index != null) {
        files.add(_CandidateFile(index: index, path: entity.path));
      }
    }
    return _pickCandidate(files, track, claimed);
  }

  /// Renames files whose number prefix no longer matches their track's index
  /// (after an interrupted force insert, a migration that moved a track, or
  /// an older, narrower prefix), so that sorting by name keeps giving the
  /// playlist order. A rename never replaces an existing file.
  Future<int> _renameToTrackNumbers(
    Playlist playlist,
    List<Track> tracks,
  ) async {
    var renamed = 0;
    final total = tracks.length;
    for (final track in tracks) {
      final path = track.filePath;
      if (path == null || !p.equals(p.dirname(path), playlist.outputPath)) {
        continue;
      }
      if (!await File(path).exists()) continue;
      final name = p.basename(path);
      final rest = name.replaceFirst(_indexPrefixPattern, '');
      final desired = '${paddedIndex(track.index, total)}_$rest';
      if (desired == name) continue;
      final target = p.join(playlist.outputPath, desired);
      if (await File(target).exists()) continue;
      try {
        await File(path).rename(target);
        await _db.updateTrackFields(track.id, filePath: target);
        renamed++;
      } catch (_) {
        // Best effort; the file keeps working under its current name.
      }
    }
    return renamed;
  }

  /// Media files WoolyTube downloads, imports or plays.
  static const mediaExtensions = {
    '.m4a',
    '.mp3',
    '.opus',
    '.ogg',
    '.flac',
    '.wav',
    '.mp4',
    '.mkv',
    '.webm',
    '.avi',
    '.mov',
  };

  static const _imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

  static final _partPattern = RegExp(r'\.part(-Frag\d+)?$');
  // yt-dlp per-format intermediates (`.f137.mp4`, `.f140.m4a`) and post-
  // processing temporaries (`.temp.mp4`) before the final merge/remux.
  static final _formatIntermediatePattern = RegExp(r'\.f\d+\.\w+$');
  static final _postProcessTempPattern = RegExp(r'\.temp\.\w+$');
  // Temp files of this service's atomic writes (sidecar, .m3u8).
  static final _atomicWriteTempPattern = RegExp(r'\.tmp\.\d+\.\d+$');

  /// Staged copies of a file the owner picked; the picked original stays
  /// where it was, so these can be removed.
  static const _copyStagingPrefixes = [
    '.woolytube-force-insert-',
    '.woolytube-local-replacement-',
  ];

  /// Files an older version's force insert parked under a temporary name.
  /// These are the only copy of a track and are never deleted.
  static const _parkedOriginalPrefix = '.woolytube-force-move-';

  /// True for files that yt-dlp or WoolyTube create while working and that
  /// never represent a finished track: partial downloads, download state,
  /// per-format intermediates, staging copies and metadata temp files. Such
  /// files are never matched to a track. Whether one may be deleted is
  /// decided separately, see [cleanupPlaylistFolder].
  static bool isTransientFile(String fileName) {
    if (_partPattern.hasMatch(fileName)) return true;
    if (p.extension(fileName).toLowerCase() == '.ytdl') return true;
    if (_formatIntermediatePattern.hasMatch(fileName)) return true;
    if (_postProcessTempPattern.hasMatch(fileName)) return true;
    if (fileName.startsWith('$_metaFileName.tmp')) return true;
    if (fileName.endsWith('.tmp')) return true;
    if (_atomicWriteTempPattern.hasMatch(fileName)) return true;
    if (fileName.startsWith(_parkedOriginalPrefix)) return true;
    return _copyStagingPrefixes.any(fileName.startsWith);
  }

  /// Removes download leftovers from a playlist folder and returns how many
  /// files were removed. Only files that can never be anyone's only copy
  /// are deleted:
  ///  - partial downloads (`.part`, `.ytdl`) and temp files;
  ///  - staged copies of files the owner picked;
  ///  - yt-dlp per-format streams (`.f137.mp4`) and post-processing temp files
  ///    (`.temp.mp4`), but only when the merged file they produced exists
  ///    and no track uses them. After a failed merge they are kept: they
  ///    may hold the only copy of a video that is gone from YouTube.
  ///
  /// Files listed in [keep] are never deleted. Images, files an older force
  /// insert parked under a temporary name and every other file are left
  /// alone.
  static Future<int> cleanupPlaylistFolder(
    String dirPath, {
    Set<String> keep = const {},
  }) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;

    final files = <File>[
      for (final entity in dir.listSync())
        if (entity is File) entity,
    ];
    final finalStems = <String>{
      for (final f in files)
        if (mediaExtensions.contains(p.extension(f.path).toLowerCase()) &&
            !isTransientFile(p.basename(f.path)))
          p.basenameWithoutExtension(f.path),
    };
    final kept = keep.map(p.normalize).toSet();

    var deleted = 0;
    for (final file in files) {
      final fileName = p.basename(file.path);
      if (kept.contains(p.normalize(file.path))) continue;
      if (fileName.startsWith(_parkedOriginalPrefix)) continue;
      if (!isTransientFile(fileName)) continue;

      if (_formatIntermediatePattern.hasMatch(fileName) ||
          _postProcessTempPattern.hasMatch(fileName)) {
        final stem = fileName
            .replaceFirst(_formatIntermediatePattern, '')
            .replaceFirst(_postProcessTempPattern, '');
        if (!finalStems.contains(stem)) continue;
      }
      try {
        await file.delete();
        deleted++;
      } catch (_) {
        // Best effort
      }
    }
    return deleted;
  }

  /// Removes download leftovers from [playlist]'s folder (see
  /// [cleanupPlaylistFolder]) and files away cover images older versions
  /// left beside the media. Call only while holding the library gate.
  Future<int> cleanupPlaylist(Playlist playlist) async {
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    return _cleanupFolder(playlist, tracks);
  }

  Future<int> _cleanupFolder(Playlist playlist, List<Track> tracks) async {
    final folder = playlist.outputPath;
    if (!await Directory(folder).exists()) return 0;
    var changed = await _adoptLooseThumbnails(playlist, tracks);
    final keep = <String>{
      for (final t in tracks) ...[
        if (t.filePath != null) t.filePath!,
        if (t.thumbnailPath != null) t.thumbnailPath!,
      ],
    };
    changed += await cleanupPlaylistFolder(folder, keep: keep);
    await discardStaging(folder);
    return changed;
  }

  /// Cover images yt-dlp left beside the media (named like the media file,
  /// `<index>_<title>.webp`) become the track's offline thumbnail when it has
  /// none yet, and are otherwise moved to `.woolytube_replaced/`. Images
  /// without an index prefix, such as a folder.jpg, are never touched.
  Future<int> _adoptLooseThumbnails(
    Playlist playlist,
    List<Track> tracks,
  ) async {
    final folder = playlist.outputPath;
    final byIndex = {for (final t in tracks) t.index: t};
    var changed = 0;
    for (final entity in Directory(folder).listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!_imageExtensions.contains(p.extension(name).toLowerCase())) continue;
      final match = _indexPrefixPattern.firstMatch(name);
      final index = match == null ? null : int.tryParse(match[1]!);
      if (index == null) continue;
      final track = byIndex[index];
      try {
        if (track != null &&
            existingThumbnailPath(track.thumbnailPath) == null) {
          final stem = LibraryLayout.trackThumbnailStem(
            folder,
            track.videoId,
            localFile: track.isLocalReplacement,
          );
          final target = '$stem${p.extension(name).toLowerCase()}';
          await Directory(p.dirname(target)).create(recursive: true);
          await _ensureNoMedia(p.dirname(target));
          await moveFile(entity.path, target);
          await _db.updateTrackThumbnailPath(track.id, target);
        } else if (track != null) {
          // The track already has a cover; keep this one out of the way.
          await moveAside(folder, entity.path);
        } else {
          continue;
        }
        changed++;
      } catch (_) {
        // Best effort
      }
    }
    return changed;
  }

  /// Zero-pads [index] to at least 5 digits, widening further if [totalTracks]
  /// needs more digits. Keeps every track in a playlist aligned to the same width.
  static String paddedIndex(int index, int totalTracks) {
    final needed = totalTracks.toString().length;
    final width = needed < 5 ? 5 : needed;
    return index.toString().padLeft(width, '0');
  }

  /// Returns the minimum digit width used for file prefixes in a playlist.
  static int paddingWidth(int totalTracks) {
    final needed = totalTracks.toString().length;
    return needed < 5 ? 5 : needed;
  }

  /// Replaces characters illegal on common filesystems with '_', matching
  /// yt-dlp's default sanitisation (non-restrict mode). Collapses whitespace.
  /// A trailing `.f<digits>` or `.temp` part is neutralised so the name can
  /// never look like a yt-dlp intermediate.
  static String sanitizeFilename(String name) {
    final replaced = name.replaceAll(
      RegExp(r'''[\/\\:*?"<>|\x00-\x1f]'''),
      '_',
    );
    var collapsed = replaced.replaceAll(RegExp(r'\s+'), ' ').trim();
    collapsed = collapsed.replaceFirstMapped(
      RegExp(r'\.(f\d+|temp|part)$', caseSensitive: false),
      (m) => '_${m[1]}',
    );
    return collapsed.isEmpty ? '_' : collapsed;
  }

  /// A file name whose title ends like a yt-dlp intermediate
  /// (`Formula.f1.m4a`, `Live.temp.mp4`) gets that last dot replaced, so the
  /// finished file can never be mistaken for a leftover.
  static String neutralizeTransientLookingName(String fileName) {
    if (!_formatIntermediatePattern.hasMatch(fileName) &&
        !_postProcessTempPattern.hasMatch(fileName)) {
      return fileName;
    }
    final ext = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    final fixed = stem.replaceFirstMapped(
      RegExp(r'\.(f\d+|temp)$'),
      (m) => '_${m[1]}',
    );
    return '$fixed$ext';
  }

  /// Find a media file in [dirPath] whose number prefix equals the number in
  /// [indexPrefix] (e.g. "001_" also matches "00001_"). Intermediate and
  /// staging files are never returned, even when their extension looks like
  /// media.
  static String? resolveMediaFile(String dirPath, String indexPrefix) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;
    final wanted = int.tryParse(indexPrefix.replaceAll('_', ''));
    if (wanted == null) return null;

    for (final entity in dir.listSync()) {
      if (entity is File) {
        final fileName = p.basename(entity.path);
        final ext = p.extension(entity.path).toLowerCase();
        final match = _indexPrefixPattern.firstMatch(fileName);
        if (match != null &&
            int.tryParse(match[1]!) == wanted &&
            mediaExtensions.contains(ext) &&
            !isTransientFile(fileName)) {
          return entity.path;
        }
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Staging: yt-dlp only ever writes into `.woolytube-staging/track-<id>/`.

  /// A fresh, empty working folder for one track's download.
  Future<Directory> prepareStagingDir(String folder, int trackId) async {
    final root = Directory(LibraryLayout.stagingRoot(folder));
    await root.create(recursive: true);
    await _ensureNoMedia(root.path);
    final dir = Directory(p.join(root.path, 'track-$trackId'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create();
    return dir;
  }

  Future<void> discardStagingDir(Directory dir) async {
    if (p.basename(p.dirname(dir.path)) != LibraryLayout.stagingDirName) {
      return;
    }
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Removed with the whole staging folder later.
    }
  }

  /// Deletes every working folder of [folder]'s downloads. Only call while
  /// holding the library gate, when no download can be running.
  Future<void> discardStaging(String folder) async {
    final root = Directory(LibraryLayout.stagingRoot(folder));
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Best effort
    }
  }

  /// The finished media file in a staging folder: the only non-intermediate
  /// media file, or the largest of the preferred kinds if yt-dlp left more.
  static File? findStagedMedia(Directory dir) {
    if (!dir.existsSync()) return null;
    // A staging folder only ever holds one download, so a name that merely
    // looks like an intermediate (a title ending in ".f1" or ".temp") is
    // still the finished file. Unfinished parts never count.
    final media = <File>[
      for (final entity in dir.listSync())
        if (entity is File &&
            mediaExtensions.contains(p.extension(entity.path).toLowerCase()) &&
            !_partPattern.hasMatch(p.basename(entity.path)))
          entity,
    ];
    if (media.isEmpty) return null;
    if (media.length == 1) return media.single;
    final finished = [
      for (final f in media)
        if (!isTransientFile(p.basename(f.path))) f,
    ];
    if (finished.isNotEmpty) {
      media
        ..clear()
        ..addAll(finished);
    }
    if (media.length == 1) return media.single;
    const preferred = ['.m4a', '.mp4', '.mkv'];
    media.sort((a, b) {
      final ap = preferred.indexOf(p.extension(a.path).toLowerCase());
      final bp = preferred.indexOf(p.extension(b.path).toLowerCase());
      final aRank = ap < 0 ? preferred.length : ap;
      final bRank = bp < 0 ? preferred.length : bp;
      if (aRank != bRank) return aRank.compareTo(bRank);
      return b.lengthSync().compareTo(a.lengthSync());
    });
    return media.first;
  }

  static File? _findStaged(Directory dir, bool Function(String name) test) {
    if (!dir.existsSync()) return null;
    for (final entity in dir.listSync()) {
      if (entity is File && test(p.basename(entity.path))) return entity;
    }
    return null;
  }

  /// Moves a finished download from its staging folder into the playlist
  /// folder and records it as the track's file, together with its cover and
  /// YouTube information.
  ///
  /// The previous file is replaced only now, after the new one is complete:
  /// a copy of the same video is superseded; a local replacement, or an
  /// unknown file that happens to have the target name, is moved to
  /// `.woolytube_replaced/` instead of being deleted; a file in another
  /// folder (before a mode switch) stays where it is.
  Future<Track?> publishDownload({
    required Playlist playlist,
    required int trackId,
    required Directory stagingDir,
    required File stagedMedia,
    required MediaThumbnailService thumbnails,
    required bool embeddedThumbnailExpected,
  }) async {
    final fresh = await _db.getTrack(trackId);
    if (fresh == null) return null;
    final folder = playlist.outputPath;
    await Directory(folder).create(recursive: true);
    final total = await _db.getTotalTrackCount(playlist.id);
    final rest = neutralizeTransientLookingName(
      p.basename(stagedMedia.path).replaceFirst(_indexPrefixPattern, ''),
    );
    var targetPath = p.join(folder, '${paddedIndex(fresh.index, total)}_$rest');

    final oldPath = fresh.filePath;
    final oldExists = oldPath != null && await File(oldPath).exists();
    final wasLocal = fresh.isLocalReplacement;
    var replacesOldInPlace = oldExists && await samePath(oldPath, targetPath);
    var oldMovedAside = false;
    if (await File(targetPath).exists() && !(replacesOldInPlace && !wasLocal)) {
      var usedByOther = false;
      for (final t in await _db.getTracksForPlaylist(playlist.id)) {
        if (t.id != trackId &&
            t.filePath != null &&
            await samePath(t.filePath!, targetPath)) {
          usedByOther = true;
        }
      }
      if (usedByOther) {
        // Another track's file has this name: never touch it, use another.
        targetPath = await uniquePath(targetPath);
        replacesOldInPlace = false;
      } else {
        await moveAside(folder, targetPath);
        oldMovedAside = replacesOldInPlace;
      }
    }
    await moveFile(stagedMedia.path, targetPath);

    final thumbnailPath = await _publishThumbnail(
      folder: folder,
      track: fresh,
      stagingDir: stagingDir,
      mediaPath: targetPath,
      thumbnails: thumbnails,
      embeddedThumbnailExpected: embeddedThumbnailExpected,
    );

    await _db.markTrackDownloaded(
      trackId,
      filePath: targetPath,
      thumbnailPath: thumbnailPath,
    );

    if (oldExists &&
        !replacesOldInPlace &&
        !oldMovedAside &&
        !await samePath(oldPath, targetPath)) {
      try {
        // Older versions could point two tracks at one file; never remove
        // a file another track still uses.
        var sharedWithOther = false;
        for (final t in await _db.getTracksForPlaylist(playlist.id)) {
          if (t.id != trackId &&
              t.filePath != null &&
              await samePath(t.filePath!, oldPath)) {
            sharedWithOther = true;
          }
        }
        if (sharedWithOther) {
          // Leave it to the track that also uses it.
        } else if (!p.equals(p.dirname(oldPath), folder)) {
          // A file in another folder (before a format switch) stays.
        } else if (wasLocal || !titleMatchesFileName(fresh.title, oldPath)) {
          // A local file, or a file that may not be a copy of this video
          // (it was matched only by its number): keep it.
          await moveAside(folder, oldPath);
        } else {
          // An older copy of the same video.
          await File(oldPath).delete();
        }
      } catch (_) {
        // The old file stays; nothing is lost.
      }
    }

    final infoFile = _findStaged(stagingDir, (n) => n.endsWith('.info.json'));
    if (infoFile != null) {
      try {
        final info =
            jsonDecode(await infoFile.readAsString()) as Map<String, dynamic>;
        if (info['id'] == fresh.videoId) {
          await _applyDownloadedChapters(trackId, info, wasLocal: wasLocal);
          await keepVideoInfo(folder, fresh.videoId, info);
        }
      } catch (_) {
        // Chapters and info are extras.
      }
    }
    if (wasLocal) {
      // Skip marks the owner made while the local file played were timed
      // to that file, not to the YouTube original.
      final since = fresh.downloadedAt;
      for (final segment in await _db.getSegmentsForTrack(trackId)) {
        if (segment.source == 'local' &&
            (since == null || !segment.createdAt.isBefore(since))) {
          await _db.deleteSegment(segment.id);
        }
      }
    }
    return _db.getTrack(trackId);
  }

  /// Whether two paths name the same file. Android's shared storage ignores
  /// case, so "00005_song.m4a" and "00005_Song.m4a" are one file there.
  static Future<bool> samePath(String a, String b) async {
    final na = p.normalize(p.absolute(a));
    final nb = p.normalize(p.absolute(b));
    if (p.equals(na, nb)) return true;
    if (na.toLowerCase() != nb.toLowerCase()) return false;
    try {
      return await FileSystemEntity.identical(na, nb);
    } catch (_) {
      return false;
    }
  }

  Future<String?> _publishThumbnail({
    required String folder,
    required Track track,
    required Directory stagingDir,
    required String mediaPath,
    required MediaThumbnailService thumbnails,
    required bool embeddedThumbnailExpected,
  }) async {
    final stem = LibraryLayout.trackThumbnailStem(folder, track.videoId);
    try {
      final staged = _findStaged(
        stagingDir,
        (n) => _imageExtensions.contains(p.extension(n).toLowerCase()),
      );
      if (staged != null) {
        await Directory(p.dirname(stem)).create(recursive: true);
        await _ensureNoMedia(p.dirname(stem));
        final target = '$stem${p.extension(staged.path).toLowerCase()}';
        for (final ext in _imageExtensions) {
          final stale = File('$stem$ext');
          if (stale.path != target && await stale.exists()) {
            await stale.delete();
          }
        }
        await moveFile(staged.path, target);
        return target;
      }
      if (embeddedThumbnailExpected) {
        await Directory(p.dirname(stem)).create(recursive: true);
        await _ensureNoMedia(p.dirname(stem));
        final extracted = await thumbnails.extractEmbeddedThumbnail(
          mediaPath: mediaPath,
          targetStem: stem,
        );
        if (extracted != null) return extracted;
      }
    } catch (_) {
      // Artwork is optional.
    }
    // Keep an earlier cover of this video, but not a local file's cover.
    final existing = existingThumbnailPath(track.thumbnailPath);
    if (existing != null && !track.isLocalReplacement) return existing;
    return null;
  }

  /// For a track whose file is still in another folder (a mode switch whose
  /// new download is impossible), moves that file into the playlist folder
  /// under the track's number so the playlist folder stays complete.
  Future<void> adoptKeptFile(Playlist playlist, int trackId) async {
    final track = await _db.getTrack(trackId);
    final path = track?.filePath;
    if (track == null || path == null || !await File(path).exists()) return;
    final folder = playlist.outputPath;
    if (p.equals(p.dirname(path), folder)) return;
    final total = await _db.getTotalTrackCount(playlist.id);
    final rest = p.basename(path).replaceFirst(_indexPrefixPattern, '');
    final target = await uniquePath(
      p.join(folder, '${paddedIndex(track.index, total)}_$rest'),
    );
    await Directory(folder).create(recursive: true);
    await moveFile(path, target);
    await _db.updateTrackFields(trackId, filePath: target);
    final thumb = existingThumbnailPath(track.thumbnailPath);
    if (thumb != null && !p.isWithin(folder, thumb)) {
      final stem = LibraryLayout.trackThumbnailStem(
        folder,
        track.videoId,
        localFile: track.isLocalReplacement,
      );
      final thumbTarget = '$stem${p.extension(thumb).toLowerCase()}';
      try {
        await Directory(p.dirname(stem)).create(recursive: true);
        await _ensureNoMedia(p.dirname(stem));
        await moveFile(thumb, thumbTarget);
        await _db.updateTrackThumbnailPath(trackId, thumbTarget);
      } catch (_) {
        // The cover stays where it is and still works.
      }
    }
  }

  /// Finishes a format switch the app could not complete: a downloaded
  /// track that YouTube can no longer provide (or a local file) and whose
  /// file is still in another folder is moved into the playlist folder.
  /// Call only while holding the library gate.
  Future<int> adoptStrayFiles(Playlist playlist) async {
    var adopted = 0;
    for (final track in await _db.getTracksForPlaylist(playlist.id)) {
      final path = track.filePath;
      if (track.status != 'complete' || track.replaceRequested) continue;
      if (path == null || p.equals(p.dirname(path), playlist.outputPath)) {
        continue;
      }
      final downloadable =
          !track.videoId.startsWith(forcedInsertVideoIdPrefix) &&
          !track.isLocalReplacement &&
          track.unavailableReason == null;
      if (!await File(path).exists()) continue;
      if (downloadable) {
        // Get the playlist's own format; this file keeps playing meanwhile.
        await _db.setTrackReplaceRequested(track.id, true);
      } else {
        await adoptKeptFile(playlist, track.id);
      }
      adopted++;
    }
    return adopted;
  }

  /// Moves [path] into the playlist's `.woolytube_replaced/` folder and
  /// returns the new path. Used instead of deleting a file the owner might
  /// still want.
  Future<String> moveAside(String folder, String path) async {
    final dir = Directory(LibraryLayout.replacedDir(folder));
    await dir.create(recursive: true);
    await _ensureNoMedia(dir.path);
    final target = await uniquePath(p.join(dir.path, p.basename(path)));
    await moveFile(path, target);
    return target;
  }

  /// [path], or `name (2).ext`, `name (3).ext`, ... if it exists.
  static Future<String> uniquePath(String path) async {
    if (!await File(path).exists() && !await Directory(path).exists()) {
      return path;
    }
    final dir = p.dirname(path);
    final stem = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    for (var i = 2; ; i++) {
      final candidate = p.join(dir, '$stem ($i)$ext');
      if (!await File(candidate).exists() &&
          !await Directory(candidate).exists()) {
        return candidate;
      }
    }
  }

  /// Renames [from] to [to], copying across file systems when needed.
  static Future<void> moveFile(String from, String to) async {
    try {
      await File(from).rename(to);
    } on FileSystemException {
      await File(from).copy(to);
      await File(from).delete();
    }
  }

  static Future<void> _ensureNoMedia(String dirPath) async {
    try {
      final marker = File(p.join(dirPath, '.nomedia'));
      if (!await marker.exists()) await marker.create(recursive: true);
    } catch (_) {
      // Only keeps gallery apps from listing covers.
    }
  }

  /// Imports a discovered playlist into the database.
  Future<int> importPlaylist(DiscoveredPlaylist discovered) async {
    // Never let two playlists own one folder or one playlist twice: they
    // would rename and relink each other's files.
    for (final existing in await _db.getAllPlaylists()) {
      if (_folderKey(existing.outputPath) ==
              _folderKey(discovered.folderPath) ||
          (samePlaylistUrl(existing.url, discovered.url) &&
              existing.audioOnly == discovered.audioOnly)) {
        throw PlaylistExistsException(
          '"${existing.name}" is already in your library.',
        );
      }
    }
    // Resolve files first so the database transaction below stays short.
    final rows =
        <
          ({
            DiscoveredTrack track,
            String? filePath,
            String? thumbnailPath,
            String status,
          })
        >[];
    for (final dt in discovered.tracks) {
      String? filePath;
      String? thumbnailPath;
      String status = dt.status;

      if (dt.fileName != null) {
        final fullPath = p.normalize(
          p.join(discovered.folderPath, dt.fileName!),
        );
        if (await File(fullPath).exists()) {
          filePath = fullPath;
          status = 'complete';
        } else if (status == 'complete') {
          status = 'pending'; // File gone, re-download
        }
      }

      thumbnailPath = await _resolveImportedImage(
        discovered.folderPath,
        dt.thumbnailFileName,
      );

      // Preserve unavailable status from metadata
      if (status != 'complete' && status != 'unavailable') {
        status = 'pending';
      }
      rows.add((
        track: dt,
        filePath: filePath,
        thumbnailPath: thumbnailPath,
        status: status,
      ));
    }

    // Sidecars from older versions can repeat an index, sometimes with two
    // entries pointing at one file (a track that adopted another's file).
    // The likely owner keeps the number, as in the database repair: the
    // entry whose file carries the number, then the one that got its file
    // first, then the one whose title matches the file name, then the
    // first listed. The others are appended.
    bool ownsNumber(int i) {
      final path = rows[i].filePath;
      if (path == null) return false;
      final match = _indexPrefixPattern.firstMatch(p.basename(path));
      return match != null && int.tryParse(match[1]!) == rows[i].track.index;
    }

    int compareOwnership(int a, int b) {
      final aOwns = ownsNumber(a), bOwns = ownsNumber(b);
      if (aOwns != bOwns) return aOwns ? -1 : 1;
      final aAt = rows[a].track.downloadedAt;
      final bAt = rows[b].track.downloadedAt;
      if (aAt != bAt) {
        if (aAt == null) return 1;
        if (bAt == null) return -1;
        final byTime = aAt.compareTo(bAt);
        if (byTime != 0) return byTime;
      }
      final aPath = rows[a].filePath, bPath = rows[b].filePath;
      final aTitle =
          aPath != null && titleMatchesFileName(rows[a].track.title, aPath);
      final bTitle =
          bPath != null && titleMatchesFileName(rows[b].track.title, bPath);
      if (aTitle != bTitle) return aTitle ? -1 : 1;
      return a.compareTo(b);
    }

    final holderOf = <int, int>{};
    for (var i = 0; i < rows.length; i++) {
      final index = rows[i].track.index;
      if (index <= 0) continue;
      final holder = holderOf[index];
      if (holder == null || compareOwnership(i, holder) < 0) {
        holderOf[index] = i;
      }
    }

    // One file never belongs to two tracks: the entry that keeps its number
    // keeps a shared file; any other entry downloads its own copy again.
    final filePaths = [for (final row in rows) row.filePath];
    final statuses = [for (final row in rows) row.status];
    bool isHolder(int i) => holderOf[rows[i].track.index] == i;
    final byOwnership = List<int>.generate(rows.length, (i) => i)..sort((a, b) {
      if (isHolder(a) != isHolder(b)) return isHolder(a) ? -1 : 1;
      return compareOwnership(a, b);
    });
    final claimedFiles = <String>{};
    for (final i in byOwnership) {
      final path = filePaths[i];
      if (path == null || claimedFiles.add(p.normalize(path))) continue;
      filePaths[i] = null;
      if (statuses[i] == 'complete') statuses[i] = 'pending';
    }
    var maxIndex = rows.fold<int>(
      0,
      (max, row) => row.track.index > max ? row.track.index : max,
    );
    final indices = <int>[];
    for (var i = 0; i < rows.length; i++) {
      final index = rows[i].track.index;
      indices.add(index > 0 && holderOf[index] == i ? index : ++maxIndex);
    }

    final playlistThumbnail = await _resolveImportedImage(
      discovered.folderPath,
      discovered.thumbnailFileName,
    );

    final playlistId = await _db.transaction(() async {
      final playlistId = await _db.insertPlaylist(
        PlaylistsCompanion.insert(
          url: discovered.url,
          name: discovered.name,
          thumbnailUrl: Value(discovered.thumbnailUrl),
          thumbnailPath: Value(playlistThumbnail),
          audioOnly: Value(discovered.audioOnly),
          playChapters: Value(discovered.playChapters),
          autoUpdate: Value(discovered.autoUpdate),
          updateFrequencyHours: Value(discovered.updateFrequencyHours),
          includeThumbnails: Value(discovered.includeThumbnails),
          sponsorBlockEnabled: Value(discovered.sponsorBlockEnabled),
          sponsorBlockCategories: Value(discovered.sponsorBlockCategories),
          sponsorBlockCategoryActions: Value(
            discovered.sponsorBlockCategoryActions,
          ),
          lastUpdated: Value(discovered.lastUpdated),
          createdAt: discovered.createdAt,
          outputPath: discovered.folderPath,
        ),
      );

      final tracks = <TracksCompanion>[];
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        final dt = row.track;
        final complete = statuses[i] == 'complete';
        tracks.add(
          TracksCompanion.insert(
            playlistId: playlistId,
            index: indices[i],
            videoId: dt.videoId,
            title: dt.title,
            thumbnailUrl: Value(dt.thumbnailUrl),
            thumbnailPath: Value(row.thumbnailPath),
            durationSeconds: Value(dt.durationSeconds),
            status: Value(statuses[i]),
            unavailableReason: Value(dt.unavailableReason),
            isLocalReplacement: Value(dt.isLocalReplacement),
            alwaysSkip: Value(dt.alwaysSkip),
            chaptersJson: Value(dt.chaptersJson),
            chaptersEnabled: Value(dt.chaptersEnabled),
            filePath: Value(filePaths[i]),
            downloadedAt: Value(
              complete ? (dt.downloadedAt ?? DateTime.now()) : null,
            ),
            sponsorBlockCheckedAt: Value(dt.sponsorBlockCheckedAt),
            replaceRequested: Value(complete && dt.replaceRequested),
          ),
        );
      }
      if (tracks.isNotEmpty) {
        await _db.insertTracks(tracks);
      }

      final importedTracks = await _db.getTracksForPlaylist(playlistId);
      final discoveredByVideoId = <String, DiscoveredTrack>{
        for (final dt in discovered.tracks) dt.videoId: dt,
      };
      for (final track in importedTracks) {
        final discoveredTrack = discoveredByVideoId[track.videoId];
        if (discoveredTrack == null) continue;
        final segments =
            discoveredTrack.sponsorBlockSegments
                .where((s) => s.endMs > s.startMs)
                .map(
                  (s) => SponsorBlockSegmentsCompanion.insert(
                    trackId: track.id,
                    videoId: track.videoId,
                    source: s.source,
                    uuid: Value(s.uuid),
                    category: s.category,
                    actionType: Value(s.actionType),
                    startMs: s.startMs,
                    endMs: s.endMs,
                    votes: Value(s.votes),
                    locked: Value(s.locked),
                    description: Value(s.description),
                    createdAt: s.createdAt ?? DateTime.now(),
                  ),
                )
                .toList();
        if (segments.isNotEmpty) {
          await _db.replaceSponsorBlockSegments(track.id, segments);
        }
      }
      return playlistId;
    });

    // Link files the sidecar did not name (it may be older than the folder).
    final playlist = await _db.getPlaylist(playlistId);
    await reconcilePlaylist(playlist);
    return playlistId;
  }

  /// An image named in a sidecar, resolved against the folder. Only images
  /// inside the folder or inside a WoolyTube library folder are accepted.
  Future<String?> _resolveImportedImage(String folder, String? name) async {
    if (name == null || name.isEmpty) return null;
    final normalizedFolder = p.normalize(p.absolute(folder));
    final candidate = p.normalize(p.absolute(p.join(folder, name)));
    final allowed =
        p.isWithin(normalizedFolder, candidate) ||
        p.isWithin(LibraryLayout.audioBasePath, candidate) ||
        p.isWithin(LibraryLayout.videoBasePath, candidate);
    if (!allowed || !await File(candidate).exists()) return null;
    return candidate;
  }

  DiscoveredPlaylist? _parseMetadata(
    String folderPath,
    Map<String, dynamic> json,
  ) {
    final pl = json['playlist'] as Map<String, dynamic>?;
    if (pl == null) return null;

    final url = pl['url'] as String?;
    final name = pl['name'] as String?;
    if (url == null || name == null) return null;

    DateTime? date(Object? value) =>
        value is String ? DateTime.tryParse(value) : null;

    final tracksJson = json['tracks'] as List<dynamic>? ?? [];
    final tracks = <DiscoveredTrack>[];
    for (final t in tracksJson) {
      if (t is! Map<String, dynamic>) continue;
      final m = t;
      tracks.add(
        DiscoveredTrack(
          index: m['index'] as int? ?? 0,
          videoId: m['videoId'] as String? ?? '',
          title: m['title'] as String? ?? 'Unknown',
          thumbnailUrl: m['thumbnailUrl'] as String?,
          thumbnailFileName: m['thumbnailFileName'] as String?,
          durationSeconds: m['durationSeconds'] as int?,
          status: m['status'] as String? ?? 'pending',
          unavailableReason: m['unavailableReason'] as String?,
          isLocalReplacement: m['isLocalReplacement'] as bool? ?? false,
          alwaysSkip: m['alwaysSkip'] as bool? ?? false,
          chaptersJson:
              m['chapters'] == null
                  ? null
                  : ChapterData.fromJson(m['chapters']).encode(),
          chaptersEnabled: m['chaptersEnabled'] as bool?,
          sponsorBlockCheckedAt: date(m['sponsorBlockCheckedAt']),
          downloadedAt: date(m['downloadedAt']),
          replaceRequested: m['replaceRequested'] as bool? ?? false,
          fileName: m['fileName'] as String?,
          sponsorBlockSegments: _parseSegments(
            m['sponsorBlockSegments'] as List<dynamic>?,
          ),
        ),
      );
    }

    return DiscoveredPlaylist(
      folderPath: folderPath,
      url: url,
      name: name,
      thumbnailUrl: pl['thumbnailUrl'] as String?,
      thumbnailFileName: pl['thumbnailFileName'] as String?,
      audioOnly: pl['audioOnly'] as bool? ?? false,
      playChapters: pl['playChapters'] != false,
      autoUpdate: pl['autoUpdate'] as bool? ?? true,
      updateFrequencyHours: pl['updateFrequencyHours'] as int? ?? 24,
      includeThumbnails: pl['includeThumbnails'] as bool? ?? true,
      sponsorBlockEnabled: pl['sponsorBlockEnabled'] as bool? ?? true,
      sponsorBlockCategories:
          pl['sponsorBlockCategories'] as String? ??
          '["sponsor","selfpromo","music_offtopic"]',
      sponsorBlockCategoryActions:
          pl['sponsorBlockCategoryActions'] as String? ??
          sponsorBlockCategoryActionsJsonFromLegacyJson(
            pl['sponsorBlockCategories'] as String? ??
                '["sponsor","selfpromo","music_offtopic"]',
          ),
      lastUpdated: date(pl['lastUpdated']),
      createdAt: date(pl['createdAt']) ?? DateTime.now(),
      tracks: tracks,
    );
  }

  List<DiscoveredSponsorBlockSegment> _parseSegments(List<dynamic>? raw) {
    if (raw == null) return const [];
    final result = <DiscoveredSponsorBlockSegment>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final source = item['source'] as String? ?? '';
      final category = item['category'] as String? ?? '';
      final startMs = item['startMs'] as int?;
      final endMs = item['endMs'] as int?;
      if (source.isEmpty ||
          category.isEmpty ||
          startMs == null ||
          endMs == null) {
        continue;
      }
      result.add(
        DiscoveredSponsorBlockSegment(
          source: source,
          uuid: item['uuid'] as String?,
          category: category,
          // Sidecars written before version 2 have no action; 'skip' was the
          // only action then.
          actionType: item['actionType'] as String? ?? 'skip',
          startMs: startMs,
          endMs: endMs,
          votes: item['votes'] as int?,
          locked: item['locked'] as bool?,
          description: item['description'] as String?,
          createdAt:
              item['createdAt'] is String
                  ? DateTime.tryParse(item['createdAt'] as String)
                  : null,
        ),
      );
    }
    return result;
  }
}
