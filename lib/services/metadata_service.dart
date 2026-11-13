import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';
import 'sponsorblock_categories.dart';
import 'chapters.dart';
import 'label_service.dart';
import 'labels.dart';
import 'library_layout.dart';
import 'log_service.dart';
import 'loudness_file.dart';
import 'media_thumbnail_service.dart';
import 'subtitles.dart';
import 'track_title.dart';
import 'video_quality.dart';
import 'lyrics/lyrics_files.dart';
import 'lyrics/lyrics_service.dart' show syncLyricsChapterDocs;
import 'lyrics/lyrics_models.dart';

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

  /// The track's own video quality (see `Tracks.videoQuality`).
  final int? videoQuality;

  /// The cap its file was downloaded under (see `Tracks.downloadedMaxHeight`).
  final int? downloadedMaxHeight;

  /// Lyrics the user chose for the track or its chapters.
  final List<DiscoveredLyricsPin> lyricsPins;

  /// The uids of the labels the file carries (see `Tracks.labelUids`).
  /// Its chapters' labels are in [chaptersJson].
  final List<String> labelUids;

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
    this.videoQuality,
    this.downloadedMaxHeight,
    this.lyricsPins = const [],
    this.labelUids = const [],
  });
}

/// A lyrics choice the user made (`lyricsPins` in the sidecar): which
/// record a track or chapter uses, or that it has none.
class DiscoveredLyricsPin {
  final String? chapterId;
  final String status;
  final String? source;
  final String? sourceRef;
  final String? matchedArtist;
  final String? matchedTitle;

  /// The user's timing correction (see `LyricsDocDraft.shiftMs`).
  final int shiftMs;

  /// The user chose the lines without times.
  final bool timingOff;

  const DiscoveredLyricsPin({
    this.chapterId,
    required this.status,
    this.source,
    this.sourceRef,
    this.matchedArtist,
    this.matchedTitle,
    this.shiftMs = 0,
    this.timingOff = false,
  });

  static DiscoveredLyricsPin? fromJson(Object? json) {
    if (json is! Map) return null;
    String? text(String key) =>
        json[key] is String ? json[key] as String : null;
    final status = text('status');
    if (status == null) return null;
    return DiscoveredLyricsPin(
      chapterId: text('chapterId'),
      status: status,
      source: text('source'),
      sourceRef: text('sourceRef'),
      matchedArtist: text('matchedArtist'),
      matchedTitle: text('matchedTitle'),
      shiftMs: json['shiftMs'] is num ? (json['shiftMs'] as num).toInt() : 0,
      timingOff: json['timingOff'] == true,
    );
  }
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

  /// Highest video height to download; null = the best.
  final int? videoQuality;

  /// The app's own "Temporary" playlist (see `Playlists.isTemporary`).
  final bool isTemporary;

  /// `Playlists.lyricsMode`: 'lyrics', 'transcript' or null (off).
  final String? lyricsMode;

  /// `Playlists.downloadSubtitles`.
  final bool downloadSubtitles;

  /// `Playlists.subtitleLanguages`: tidied codes, or null (English).
  final String? subtitleLanguages;

  /// `Playlists.shuffleChapters`.
  final bool shuffleChapters;

  /// The names and colors of the labels the playlist's files and chapters
  /// carry.
  final List<PortableLabel> labels;

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
    this.videoQuality,
    this.isTemporary = false,
    this.lyricsMode,
    this.downloadSubtitles = false,
    this.subtitleLanguages,
    this.shuffleChapters = false,
    this.labels = const [],
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

/// [info] (yt-dlp's description of a video) as the content of its kept
/// `.info.json`: without the download-only parts, which are large and
/// useless once the file exists.
String encodeVideoInfo(Map<String, dynamic> info) {
  final trimmed = {
    for (final entry in info.entries)
      if (!_downloadOnlyInfoKeys.contains(entry.key)) entry.key: entry.value,
  };
  return const JsonEncoder.withIndent(' ').convert(trimmed);
}

class MetadataService {
  final AppDatabase _db;
  final LogService? _log;

  MetadataService(this._db, {LogService? log}) : _log = log;

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
  ///
  /// A playlist whose folder cannot be repaired (for example a permission
  /// problem) is reported through [onProblem] and the others still are.
  Future<int> recoverInterruptedDownloads({
    void Function(Playlist playlist, Object error)? onProblem,
  }) async {
    var fixed = 0;
    for (final playlist in await _db.getAllPlaylists()) {
      try {
        await discardStaging(playlist.outputPath);
        final playlistFixed = await repairPlaylist(playlist);
        fixed += playlistFixed;
        if (playlistFixed > 0) await writeMetadataFor(playlist.id);
      } catch (e) {
        onProblem?.call(playlist, e);
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
      await _healTitleFromInfo(track.id, info);
      await _applyDownloadedChapters(track.id, info);
      await keepVideoInfo(folder, track.videoId, info);
      await infoFile.delete();
    } catch (_) {
      // A broken metadata sidecar must not fail a successful media download.
    }
  }

  /// Replaces a stand-in title ("null", empty or the video id) with the
  /// real one from a downloaded video's metadata. A real title, even one
  /// the owner changed, is never touched.
  Future<void> _healTitleFromInfo(
    int trackId,
    Map<String, dynamic> info,
  ) async {
    final fresh = await _db.getTrack(trackId);
    final title = info['title'];
    if (fresh == null ||
        title is! String ||
        isMissingTitle(title) ||
        !isStandInTitle(fresh.title, fresh.videoId)) {
      return;
    }
    await _db.updateTrackFields(trackId, title: title.trim());
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
    final next = ChapterData(
      downloaded: data.downloaded,
      custom: keepCustom ? old.custom : null,
      shuffleChapters: old.shuffleChapters,
      checkedAt: data.checkedAt,
      durationMs: data.durationMs,
      // An undo step for dropped chapters no longer applies, and song
      // recognition results timed to a local file are stale.
      undoChapters: keepCustom ? old.undoChapters : null,
      undoFollowsDownloaded: keepCustom && old.undoFollowsDownloaded,
      // Skip marks go with the chapters they name (ids that no longer
      // exist are ignored).
      skippedChapterIds: keepCustom ? old.skippedChapterIds : const {},
      recognitionEpoch:
          wasLocal ? old.recognitionEpoch + 1 : old.recognitionEpoch,
      lastRecognitionRunId: old.lastRecognitionRunId,
      // Labels stay with the chapters still listed (YouTube's keep their
      // ids); the others' are dropped when written.
      chapterLabels: old.chapterLabels,
    );
    await _db.writeTrackChapters(trackId, next);
    await syncLyricsChapterDocs(_db, trackId, next, previous: old);
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
      final dir = Directory(LibraryLayout.infoDir(folder));
      await dir.create(recursive: true);
      await _ensureNoMedia(dir.path);
      final target = File(LibraryLayout.infoJsonPath(folder, videoId));
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(encodeVideoInfo(info));
      await tmp.rename(target.path);
    } catch (_) {
      // Extra information only; never fail a download over it.
    }
  }

  /// The tail of each playlist's chain of writes.
  final _metadataWrites = <int, Future<void>>{};

  /// A write per playlist that is queued but has not started yet. It reads
  /// the database when it starts, so later requests can simply join it.
  final _queuedWrites = <int, Future<void>>{};

  /// A hash of the content last written (or found) at each path, instead of
  /// the content itself: the sidecar of a big playlist is over a megabyte.
  final _writtenHashes = <String, int>{};

  /// The playlist revision (see [AppDatabase.playlistRevisions]) each
  /// playlist's files were last written from.
  final _writtenRevisions = <int, int>{};
  var _metadataWriteCounter = 0;

  /// Playlists whose next write compares with the disk (see
  /// [writeMetadataFor]).
  final _verifyNext = <int>{};

  /// Sidecars left alone because a newer app wrote them, already logged.
  final _newerSidecarsReported = <String>{};

  /// Playlists with at least this many tracks build their files on a
  /// worker isolate, so the UI never stalls on a big JSON document.
  static const isolateTrackThreshold = 40;

  /// The revision of [playlistId] its files were last written from, or
  /// null when this service has not written them yet.
  int? writtenRevision(int playlistId) => _writtenRevisions[playlistId];

  /// Writes playlist metadata as JSON sidecar file in the playlist folder,
  /// together with a `.m3u8` playlist other players can open.
  ///
  /// The files are always written from the database as it is when the write
  /// starts; [playlist] and [tracks] only name the playlist (they are kept
  /// for callers that already hold them).
  Future<void> writeMetadata(Playlist playlist, List<Track> tracks) =>
      writeMetadataFor(playlist.id);

  /// Rewrites the sidecar and playlist file of [playlistId] from the
  /// database. Safe to call after any edit; a playlist that no longer exists
  /// is ignored.
  ///
  /// Writes for one playlist run strictly one after another. Download
  /// progress, sync and UI edits can all request a write at the same time and
  /// would otherwise race on the temp file or rename a half-written sidecar
  /// into place. Requests that arrive while a write is waiting to start
  /// share it, since it reads the database only when it starts.
  ///
  /// Files this run already wrote with the same content are normally not
  /// read again. With [verify] they are compared with the disk, so a file
  /// changed on disk since (for example an older copy put back) is written
  /// again; "Check backup" compares with the disk too.
  Future<void> writeMetadataFor(int playlistId, {bool verify = false}) {
    // Read when the write starts, so a write already queued verifies too.
    if (verify) _verifyNext.add(playlistId);
    final queued = _queuedWrites[playlistId];
    if (queued != null) return queued;
    final previous = _metadataWrites[playlistId] ?? Future<void>.value();
    late final Future<void> current;
    current = previous.then<void>((_) {}, onError: (_) {}).then((_) {
      if (identical(_queuedWrites[playlistId], current)) {
        _queuedWrites.remove(playlistId);
      }
      return _writeMetadataNow(playlistId);
    });
    _queuedWrites[playlistId] = current;
    _metadataWrites[playlistId] = current;
    current.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_metadataWrites[playlistId], current)) {
        _metadataWrites.remove(playlistId);
      }
    });
    return current;
  }

  Future<void> _writeMetadataNow(int playlistId) async {
    final verify = _verifyNext.remove(playlistId);
    // Read the revision first: a change made while the files are built
    // leaves the recorded revision behind, so the mirror writes again.
    final revision = await _db.playlistRevision(playlistId);
    final playlist = await _db.getPlaylistOrNull(playlistId);
    if (playlist == null) return;
    final dir = Directory(playlist.outputPath);
    if (!await dir.exists()) return;

    final job = await _sidecarJob(playlist, compareWithDisk: verify);
    final result =
        job.tracks.length >= isolateTrackThreshold
            ? await Isolate.run(() => writeSidecarFiles(job))
            : await writeSidecarFiles(job);
    _writtenHashes.addAll(result.hashes);
    if (result.newerVersionKept case final version?) {
      // Said once per run: the mirror tries again after every change.
      if (_newerSidecarsReported.add(job.metaPath)) {
        _log?.warn(
          'Left the metadata file of "${playlist.name}" as it is: a newer '
          'app wrote it (format $version, this app knows $sidecarVersion). '
          'Update the app to keep that folder up to date.',
        );
      }
    }
    _writtenRevisions[playlistId] = revision;
    await _writeLibraryReadme(p.dirname(playlist.outputPath));
  }

  /// What writing the files of [playlist] now would change, without
  /// writing anything: the files on disk are compared with what the
  /// database holds. Null when the playlist folder is gone.
  Future<SidecarCheck?> checkMetadataOf(Playlist playlist) async {
    if (!await Directory(playlist.outputPath).exists()) return null;
    final job = await _sidecarJob(
      playlist,
      dryRun: true,
      compareWithDisk: true,
    );
    final result =
        job.tracks.length >= isolateTrackThreshold
            ? await Isolate.run(() => writeSidecarFiles(job))
            : await writeSidecarFiles(job);
    return (
      sidecarOutOfDate: result.changed.contains(job.metaPath),
      playlistFileOutOfDate: result.changed.contains(job.playlistFilePath),
      newerVersionKept: result.newerVersionKept,
    );
  }

  Future<SidecarJob> _sidecarJob(
    Playlist playlist, {
    bool dryRun = false,
    bool compareWithDisk = false,
  }) async {
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    final segmentsByTrack = await _segmentsByTrack(tracks);
    final lyricsPinsByTrack = <int, List<LyricsDoc>>{};
    for (final doc in await _db.lyricsDocsForPlaylist(playlist.id)) {
      if (!doc.pinned) continue;
      lyricsPinsByTrack.putIfAbsent(doc.trackId, () => []).add(doc);
    }
    final metaPath = p.join(playlist.outputPath, _metaFileName);
    final m3uPath = playlistFilePath(playlist.outputPath);
    return SidecarJob(
      playlist: playlist,
      tracks: tracks,
      segmentsByTrack: segmentsByTrack,
      lyricsPinsByTrack: lyricsPinsByTrack,
      labels: await _db.getLabels(),
      metaPath: metaPath,
      playlistFilePath: m3uPath,
      // A check (and a verifying write) compares with the files on disk,
      // not with what this run last wrote: they may have changed since.
      knownHashes:
          compareWithDisk
              ? const {}
              : {
                metaPath: _writtenHashes[metaPath],
                m3uPath: _writtenHashes[m3uPath],
              },
      tempSuffix:
          '${DateTime.now().microsecondsSinceEpoch}.${_metadataWriteCounter++}',
      dryRun: dryRun,
    );
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
          '#EXTINF:${track.durationSeconds ?? -1},'
          '${_singleLine(track.displayTitle)}',
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
  static String? fileNameRelativeTo(String folder, String? path) =>
      _fileNameRelativeTo(folder, path);

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
    playlist: order, titles, chapters, skip segments, labels and
    settings.
    WoolyTube restores a playlist from it after a reinstall.
  - .woolytube_thumbnails holds the cover images, .woolytube_info the
    original YouTube descriptions (uploader, upload date, description),
    lyrics, song recognition results and loudness measurements, and
    .woolytube_replaced earlier files that were replaced.

woolytube_library.json holds the home screen order, your labels and the
last song played, and .woolytube_backup/woolytube_settings.json the app settings.
WoolyTube keeps all of these files up to date as you use it.

Copy both WoolyTube folders (Music/WoolyTube for audio, Movies/WoolyTube
for video) to keep a complete backup. To move the library to another
phone, copy them there, install WoolyTube and tap "Import all".
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
  ///
  /// Folders in [skipFolders] (folder paths of playlists already in the
  /// library) are neither read nor searched.
  Future<List<DiscoveredPlaylist>> scanForPlaylists({
    Iterable<String> skipFolders = const [],
  }) async {
    final discovered = <DiscoveredPlaylist>[];
    for (final scanPath in [
      LibraryLayout.audioBasePath,
      LibraryLayout.videoBasePath,
    ]) {
      discovered.addAll(
        await scanDirectory(scanPath, maxDepth: 1, skipFolders: skipFolders),
      );
    }
    return discovered;
  }

  /// Finds playlist folders (folders with a `woolytube_meta.json`) at or
  /// below [rootPath], for restoring a copied backup from anywhere. Folders
  /// in [skipFolders] are neither read nor searched.
  Future<List<DiscoveredPlaylist>> scanDirectory(
    String rootPath, {
    int maxDepth = 3,
    Iterable<String> skipFolders = const [],
  }) async {
    final discovered = <DiscoveredPlaylist>[];
    final skip = {for (final folder in skipFolders) _folderKey(folder)};
    Future<void> visit(Directory dir, int depth) async {
      if (skip.isNotEmpty && skip.contains(_folderKey(dir.path))) return;
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

  /// Sidecars at least this big are read on a worker isolate.
  static const _isolateSidecarBytes = 64 * 1024;

  Future<DiscoveredPlaylist?> _readSidecar(String folder, File metaFile) async {
    try {
      final path = metaFile.path;
      if (await metaFile.length() >= _isolateSidecarBytes) {
        return await Isolate.run(() => _readSidecarFile(folder, path));
      }
      return await _readSidecarFile(folder, path);
    } catch (_) {
      return null; // Unreadable or malformed
    }
  }

  static Future<DiscoveredPlaylist?> _readSidecarFile(
    String folder,
    String path,
  ) async {
    try {
      final json =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
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
    final existing = await _db.getAllPlaylists();
    // A folder a playlist already uses is always "imported": do not even
    // read its (possibly large) sidecar.
    final discovered =
        candidates ??
        await scanForPlaylists(
          skipFolders: [for (final pl in existing) pl.outputPath],
        );
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
    // Every file in the folder, so whether a track's file exists is a set
    // lookup instead of a disk check per track.
    final listing = _FolderListing(playlist.outputPath);

    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      listing.add(entity.path);
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
        if (t.filePath != null && await listing.exists(t.filePath!))
          p.normalize(t.filePath!),
    };

    // Decide first, then write every change in one transaction: one stream
    // update for the open pages instead of one per track.
    final changes = <Future<void> Function()>[];
    for (final track in tracks) {
      final ownPath = track.filePath;
      final hasOwnFile =
          ownPath != null && claimed.contains(p.normalize(ownPath));
      // Relinking a file that was downloaded before keeps its history.
      final keepDownloadedAt = track.downloadedAt != null;
      if (hasOwnFile) {
        if (track.status == 'pending' ||
            track.status == 'error' ||
            track.status == 'unavailable' ||
            (track.status == 'downloading' && recoverInterrupted)) {
          changes.add(
            () => _db.updateTrackStatus(
              track.id,
              'complete',
              filePath: ownPath,
              keepDownloadedAt: keepDownloadedAt,
            ),
          );
        }
        continue;
      }
      if (track.status == 'downloading' && !recoverInterrupted) continue;

      final candidate = _pickCandidate(mediaFiles, track, claimed);
      if (candidate != null) {
        claimed.add(p.normalize(candidate));
        changes.add(
          () => _db.updateTrackStatus(
            track.id,
            'complete',
            filePath: candidate,
            keepDownloadedAt: keepDownloadedAt,
          ),
        );
      } else if (track.status == 'downloading') {
        changes.add(() => _db.resetInterruptedTrack(track.id));
      } else if (track.status == 'complete' && !unreadable) {
        changes.add(
          () => _db.updateTrackStatus(
            track.id,
            'pending',
            clearFilePath: true,
            clearDownloadedAt: true,
          ),
        );
      }
    }
    if (changes.isNotEmpty) {
      await _db.transaction(() async {
        for (final change in changes) {
          await change();
        }
      });
      fixed += changes.length;
    }

    if (cleanup && !unreadable) {
      tracks = await _db.getTracksForPlaylist(playlist.id);
      fixed += await _renameToTrackNumbers(playlist, tracks, listing: listing);
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
  ///
  /// Costs one folder listing. Only when a file with the track's number is
  /// there are the other tracks looked at: a listed candidate exists, so it
  /// is taken when no other track records it as its file.
  Future<String?> findAdoptableMediaFile(Playlist playlist, Track track) async {
    final dir = Directory(playlist.outputPath);
    if (!await dir.exists()) return null;
    final files = <_CandidateFile>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final match = _indexPrefixPattern.firstMatch(name);
      if (match == null || int.tryParse(match[1]!) != track.index) continue;
      if (isTransientFile(name) ||
          !mediaExtensions.contains(p.extension(name).toLowerCase())) {
        continue;
      }
      files.add(_CandidateFile(index: track.index, path: entity.path));
    }
    if (files.isEmpty) return null;
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    final claimed = <String>{
      for (final t in tracks)
        if (t.id != track.id && t.filePath != null) p.normalize(t.filePath!),
    };
    return _pickCandidate(files, track, claimed);
  }

  /// Renames files whose number prefix no longer matches their track's index
  /// (after an interrupted force insert, a migration that moved a track, or
  /// an older, narrower prefix), so that sorting by name keeps giving the
  /// playlist order. A rename never replaces an existing file.
  Future<int> _renameToTrackNumbers(
    Playlist playlist,
    List<Track> tracks, {
    required _FolderListing listing,
  }) async {
    final total = tracks.length;
    final moved = <int, String>{};
    for (final track in tracks) {
      final path = track.filePath;
      if (path == null || !p.equals(p.dirname(path), playlist.outputPath)) {
        continue;
      }
      if (!await listing.exists(path)) continue;
      final name = p.basename(path);
      final rest = name.replaceFirst(_indexPrefixPattern, '');
      final desired = '${paddedIndex(track.index, total)}_$rest';
      if (desired == name) continue;
      final target = p.join(playlist.outputPath, desired);
      if (listing.mayExist(target) && await File(target).exists()) continue;
      try {
        await File(path).rename(target);
        listing
          ..remove(path)
          ..add(target);
        moved[track.id] = target;
      } catch (_) {
        // Best effort; the file keeps working under its current name.
      }
    }
    // One transaction for all of them. A crash before it leaves files whose
    // recorded path is gone; their new names carry the track's number, so
    // the next repair links them again.
    await _db.updateTrackFilePaths(moved);
    return moved.length;
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
      await for (final entity in dir.list())
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
    final adopted = <int, String?>{};
    final images = <File>[
      await for (final entity in Directory(folder).list())
        if (entity is File &&
            _imageExtensions.contains(p.extension(entity.path).toLowerCase()))
          entity,
    ];
    for (final entity in images) {
      final name = p.basename(entity.path);
      final match = _indexPrefixPattern.firstMatch(name);
      final index = match == null ? null : int.tryParse(match[1]!);
      if (index == null) continue;
      final track = byIndex[index];
      try {
        if (track != null &&
            !adopted.containsKey(track.id) &&
            !await thumbnailFileExists(track.thumbnailPath)) {
          final stem = LibraryLayout.trackThumbnailStem(
            folder,
            track.videoId,
            localFile: track.isLocalReplacement,
          );
          final target = '$stem${p.extension(name).toLowerCase()}';
          await Directory(p.dirname(target)).create(recursive: true);
          await _ensureNoMedia(p.dirname(target));
          await moveFile(entity.path, target);
          noteThumbnailWritten(target);
          adopted[track.id] = target;
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
    await _db.updateTrackThumbnailPaths(adopted);
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

  /// Resolves a stored track path (which may lack its extension) to the
  /// file on disk: the exact path, the same basename with any extension, or
  /// the first media file sharing its index prefix (handles a title mismatch
  /// from yt-dlp). Intermediate and staging files are never returned.
  static String? resolveStoredFilePath(String storedPath) {
    if (File(storedPath).existsSync()) return storedPath;

    final dir = Directory(p.dirname(storedPath));
    final baseName = p.basename(storedPath);
    if (!dir.existsSync()) return null;

    final entries = dir.listSync();
    for (final entity in entries) {
      if (entity is File &&
          p.basenameWithoutExtension(entity.path) == baseName) {
        return entity.path;
      }
    }

    final indexPrefixMatch = RegExp(r'^\d+[_ -]').firstMatch(baseName);
    if (indexPrefixMatch != null) {
      final prefix = indexPrefixMatch.group(0)!;
      for (final entity in entries) {
        if (entity is File) {
          final fileName = p.basename(entity.path);
          final ext = p.extension(entity.path).toLowerCase();
          if (fileName.startsWith(prefix) &&
              mediaExtensions.contains(ext) &&
              !isTransientFile(fileName)) {
            return entity.path;
          }
        }
      }
    }
    return null;
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
    int? downloadedMaxHeight,
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
      downloadedMaxHeight: downloadedMaxHeight,
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
    var chaptersApplied = false;
    if (infoFile != null) {
      try {
        final info =
            jsonDecode(await infoFile.readAsString()) as Map<String, dynamic>;
        if (info['id'] == fresh.videoId) {
          await _healTitleFromInfo(trackId, info);
          await _applyDownloadedChapters(trackId, info, wasLocal: wasLocal);
          chaptersApplied = true;
          await keepVideoInfo(folder, fresh.videoId, info);
        }
      } catch (_) {
        // Chapters and info are extras.
      }
    }
    if (wasLocal && !chaptersApplied) {
      // Without YouTube's chapter list, still undo what the local file
      // changed: chapters made for it go, earlier ones fit again.
      final current = await _db.getTrack(trackId);
      if (current?.chaptersJson != null) {
        final old = ChapterData.decode(current!.chaptersJson);
        final next = ChapterData(
          downloaded: old.downloaded,
          custom: old.valid ? null : old.custom,
          shuffleChapters: old.shuffleChapters,
          checkedAt: old.checkedAt,
          durationMs: old.durationMs,
          undoChapters: old.valid ? null : old.undoChapters,
          undoFollowsDownloaded: !old.valid && old.undoFollowsDownloaded,
          recognitionEpoch: old.recognitionEpoch + 1,
          lastRecognitionRunId: old.lastRecognitionRunId,
          chapterLabels: old.chapterLabels,
        );
        await _db.writeTrackChapters(trackId, next);
        await syncLyricsChapterDocs(_db, trackId, next, previous: old);
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
            noteThumbnailRemoved(stale.path);
          }
        }
        await moveFile(staged.path, target);
        noteThumbnailWritten(target);
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
    final existing = track.thumbnailPath;
    if (!track.isLocalReplacement && await thumbnailFileExists(existing)) {
      return existing;
    }
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
    final thumb = track.thumbnailPath;
    if (thumb != null &&
        await thumbnailFileExists(thumb) &&
        !p.isWithin(folder, thumb)) {
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
        noteThumbnailRemoved(thumb);
        noteThumbnailWritten(thumbTarget);
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

    // The folder's labels first: a label already here under another uid
    // (made on each phone with the same name) is the same label.
    final labels = await importLabels(_db, discovered.labels);

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
          videoQuality: Value(discovered.videoQuality),
          isTemporary: Value(discovered.isTemporary),
          lyricsMode: Value(discovered.lyricsMode),
          downloadSubtitles: Value(discovered.downloadSubtitles),
          subtitleLanguages: Value(discovered.subtitleLanguages),
          shuffleChapters: Value(discovered.shuffleChapters),
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
            durationSeconds: Value(
              (dt.durationSeconds ?? 0) > 0 ? dt.durationSeconds : null,
            ),
            status: Value(statuses[i]),
            unavailableReason: Value(dt.unavailableReason),
            isLocalReplacement: Value(dt.isLocalReplacement),
            alwaysSkip: Value(dt.alwaysSkip),
            chaptersJson: Value(labels.applyToChapters(dt.chaptersJson)),
            chaptersEnabled: Value(dt.chaptersEnabled),
            filePath: Value(filePaths[i]),
            downloadedAt: Value(
              complete ? (dt.downloadedAt ?? DateTime.now()) : null,
            ),
            sponsorBlockCheckedAt: Value(dt.sponsorBlockCheckedAt),
            replaceRequested: Value(complete && dt.replaceRequested),
            videoQuality: Value(dt.videoQuality),
            downloadedMaxHeight: Value(
              complete ? dt.downloadedMaxHeight : null,
            ),
            // A uid whose label is unknown here is kept: a library file
            // copied later may still name it.
            labelUids: Value(encodeLabelUids(labels.apply(dt.labelUids))),
          ),
        );
      }
      if (tracks.isNotEmpty) {
        await _db.insertTracks(tracks);
      }

      // Segments go to the row made from the same sidecar entry (by the
      // index it was given): a video listed twice has its own segments in
      // each entry.
      final importedTracks = await _db.getTracksForPlaylist(playlistId);
      final entryByIndex = <int, DiscoveredTrack>{
        for (var i = 0; i < rows.length; i++) indices[i]: rows[i].track,
      };
      for (final track in importedTracks) {
        final discoveredTrack = entryByIndex[track.index];
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

    await _restoreLyrics(playlistId, discovered.folderPath, {
      for (var i = 0; i < rows.length; i++) indices[i]: rows[i].track,
    });

    // Link files the sidecar did not name (it may be older than the folder).
    final playlist = await _db.getPlaylist(playlistId);
    await reconcilePlaylist(playlist);

    // The loudness measured before, for files that are still the same.
    try {
      final seeded = await seedLoudnessFromFolder(
        _db,
        await _db.getPlaylist(playlistId),
      );
      if (seeded > 0) {
        _log?.info('import: took back $seeded loudness measurements');
      }
    } catch (e) {
      _log?.warn('import: could not read the loudness file: $e');
    }
    return playlistId;
  }

  /// Restores lyrics after an import: the docs kept in each track's
  /// `.lyrics.json`, then the user's choices from the sidecar. A choice
  /// whose text is missing is stored without lines; the lyrics service
  /// fetches it again by its source.
  Future<void> _restoreLyrics(
    int playlistId,
    String folder,
    Map<int, DiscoveredTrack> entryByIndex,
  ) async {
    try {
      final mode =
          LyricsMode.fromDb(
            (await _db.getPlaylistOrNull(playlistId))?.lyricsMode,
          ) ??
          LyricsMode.lyrics;
      for (final track in await _db.getTracksForPlaylist(playlistId)) {
        final active =
            ChapterData.decode(
              track.chaptersJson,
            ).active.map((c) => c.id).toSet();
        final docs = {
          for (final doc in await readLyricsFile(
            folder,
            track.videoId,
            track.id,
          ))
            if (doc.chapterId == null || active.contains(doc.chapterId))
              doc.chapterId: doc,
        };
        final pins = entryByIndex[track.index]?.lyricsPins ?? const [];
        for (final pin in pins) {
          if (pin.chapterId != null && !active.contains(pin.chapterId)) {
            continue;
          }
          final kept = docs[pin.chapterId];
          final sameChoice =
              kept != null &&
              kept.status == pin.status &&
              kept.source == pin.source &&
              kept.sourceRef == pin.sourceRef &&
              kept.timingOff == pin.timingOff;
          docs[pin.chapterId] = LyricsDocDraft(
            trackId: track.id,
            chapterId: pin.chapterId,
            offsetMs: kept?.offsetMs ?? 0,
            kind: kept?.kind ?? mode,
            status: pin.status,
            source: pin.source,
            sourceRef: pin.sourceRef,
            matchedArtist: pin.matchedArtist,
            matchedTitle: pin.matchedTitle,
            timeScale: sameChoice ? kept.timeScale : 1.0,
            synced: sameChoice && kept.synced,
            pinned: true,
            shiftMs: pin.shiftMs,
            timingOff: pin.timingOff,
            lang: sameChoice ? kept.lang : null,
            checkedAt: kept?.checkedAt ?? DateTime.now(),
            // The kept lines carry the file's shift; the sidecar's wins.
            lines:
                sameChoice
                    ? shiftLyricsLines(kept.lines, pin.shiftMs - kept.shiftMs)
                    : const [],
          );
        }
        for (final doc in docs.values) {
          await _db.replaceLyricsDoc(doc);
        }
      }
    } catch (_) {
      // Lyrics can always be fetched again; never fail an import over them.
    }
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

  /// A whole number from a sidecar, or null when missing or not a number.
  static int? _optionalInt(Object? value) =>
      value is num ? value.toInt() : null;

  static DiscoveredPlaylist? _parseMetadata(
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
      final videoId = m['videoId'] as String? ?? '';
      tracks.add(
        DiscoveredTrack(
          index: m['index'] as int? ?? 0,
          videoId: videoId,
          // Older versions could save the title "null".
          title: resolveTrackTitle(
            m['title'] is String ? m['title'] as String : null,
            videoId: videoId,
          ),
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
          videoQuality: _optionalInt(m['videoQuality']),
          downloadedMaxHeight: _optionalInt(m['downloadedMaxHeight']),
          lyricsPins: [
            if (m['lyricsPins'] case final List<dynamic> pins)
              for (final pin in pins)
                if (DiscoveredLyricsPin.fromJson(pin) case final parsed?)
                  parsed,
          ],
          labelUids: labelUidList(m['labels']),
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
      videoQuality: _optionalInt(pl['videoQuality']),
      isTemporary: pl['temporary'] == true || pl['url'] == temporaryPlaylistUrl,
      lyricsMode: LyricsMode.toDb(
        LyricsMode.fromDb(pl['lyricsMode'] is String ? pl['lyricsMode'] : null),
      ),
      downloadSubtitles: pl['downloadSubtitles'] == true,
      // A hand-edited list must not reach yt-dlp unchecked.
      subtitleLanguages: subtitleLanguagesOrNull(pl['subtitleLanguages']),
      shuffleChapters: pl['shuffleChapters'] == true,
      labels: PortableLabel.listFromJson(json['labels']),
    );
  }

  static List<DiscoveredSponsorBlockSegment> _parseSegments(
    List<dynamic>? raw,
  ) {
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

/// The files of one folder, listed once, so checking whether a track's file
/// is there costs a set lookup instead of a disk access.
class _FolderListing {
  _FolderListing(String folder) : _folder = p.normalize(folder);

  final String _folder;
  final _exact = <String>{};
  final _lower = <String>{};

  void add(String path) {
    final normalized = p.normalize(path);
    _exact.add(normalized);
    _lower.add(normalized.toLowerCase());
  }

  void remove(String path) {
    final normalized = p.normalize(path);
    _exact.remove(normalized);
    _lower.remove(normalized.toLowerCase());
  }

  bool _inFolder(String normalized) => p.dirname(normalized) == _folder;

  /// False only when [path] lies in the folder and was not listed (in any
  /// letter case).
  bool mayExist(String path) {
    final normalized = p.normalize(path);
    if (!_inFolder(normalized)) return true;
    return _lower.contains(normalized.toLowerCase());
  }

  /// Whether the file at [path] exists. Files in the folder are answered
  /// from the listing; only a name that differs from a listed one in letter
  /// case, or a file elsewhere, is checked on disk.
  Future<bool> exists(String path) async {
    final normalized = p.normalize(path);
    if (_inFolder(normalized)) {
      if (_exact.contains(normalized)) return true;
      if (!_lower.contains(normalized.toLowerCase())) return false;
    }
    return File(path).exists();
  }
}

/// Everything needed to write one playlist's sidecar and `.m3u8`, in a form
/// that can be sent to a worker isolate.
class SidecarJob {
  const SidecarJob({
    required this.playlist,
    required this.tracks,
    required this.segmentsByTrack,
    required this.metaPath,
    required this.playlistFilePath,
    required this.knownHashes,
    required this.tempSuffix,
    this.lyricsPinsByTrack = const {},
    this.labels = const [],
    this.dryRun = false,
  });

  final Playlist playlist;
  final List<Track> tracks;
  final Map<int, List<SponsorBlockSegment>> segmentsByTrack;

  /// The labels in use; the sidecar lists those its tracks carry.
  final List<Label> labels;

  /// Pinned lyrics docs per track (the user's choices).
  final Map<int, List<LyricsDoc>> lyricsPinsByTrack;
  final String metaPath;
  final String playlistFilePath;

  /// Hash of what was last written at each path, if known.
  final Map<String, int?> knownHashes;
  final String tempSuffix;

  /// Only find out which files would change; write nothing.
  final bool dryRun;
}

/// The sidecar format version this build writes. A sidecar with a higher
/// version was written by a newer app and is never overwritten.
const sidecarVersion = 2;

/// The top-level, playlist and track keys this build writes. Any other key
/// in a sidecar comes from a newer app and is kept when the file is
/// rewritten (see [keepUnknownSidecarKeys]). A key written only when set
/// must be listed too, or clearing it would bring the old value back.
const sidecarTopLevelKeys = {'version', 'playlist', 'tracks', 'labels'};
const sidecarPlaylistKeys = {
  'url',
  'name',
  'thumbnailUrl',
  'thumbnailFileName',
  'audioOnly',
  'playChapters',
  'autoUpdate',
  'updateFrequencyHours',
  'includeThumbnails',
  'sponsorBlockEnabled',
  'sponsorBlockCategories',
  'sponsorBlockCategoryActions',
  'lastUpdated',
  'createdAt',
  'videoQuality',
  'temporary',
  'lyricsMode',
  'downloadSubtitles',
  'subtitleLanguages',
  'shuffleChapters',
};
const sidecarTrackKeys = {
  'index',
  'videoId',
  'title',
  'thumbnailUrl',
  'thumbnailFileName',
  'durationSeconds',
  'status',
  'unavailableReason',
  'isLocalReplacement',
  'alwaysSkip',
  'chapters',
  'chaptersEnabled',
  'sponsorBlockCheckedAt',
  'downloadedAt',
  'replaceRequested',
  'fileName',
  'videoQuality',
  'downloadedMaxHeight',
  'sponsorBlockSegments',
  'lyricsPins',
  'labels',
};

/// The sidecar JSON of a playlist.
String buildSidecarJson(
  Playlist playlist,
  List<Track> tracks,
  Map<int, List<SponsorBlockSegment>> segmentsByTrack, {
  Map<int, List<LyricsDoc>> lyricsPinsByTrack = const {},
  List<Label> labels = const [],
}) => encodeSidecar(
  buildSidecarData(
    playlist,
    tracks,
    segmentsByTrack,
    lyricsPinsByTrack: lyricsPinsByTrack,
    labels: labels,
  ),
);

String encodeSidecar(Map<String, Object?> data) =>
    const JsonEncoder.withIndent('  ').convert(data);

/// The sidecar of a playlist, before it is encoded.
///
/// [labels] are the labels in use. The labels of each file (`labels`) and
/// of its chapters (`chapterLabels` in `chapters`) are written as stored,
/// and the top-level `labels` lists the name and color of those of them
/// that are in use, in the owner's order, so the folder alone tells what
/// they are. Each is left out when empty.
Map<String, Object?> buildSidecarData(
  Playlist playlist,
  List<Track> tracks,
  Map<int, List<SponsorBlockSegment>> segmentsByTrack, {
  Map<int, List<LyricsDoc>> lyricsPinsByTrack = const {},
  List<Label> labels = const [],
}) {
  String? relative(String? path) =>
      MetadataService.fileNameRelativeTo(playlist.outputPath, path);
  final tracksJson = <Map<String, Object?>>[];
  final usedLabels = <String>{};
  for (final t in tracks) {
    final segments = segmentsByTrack[t.id] ?? const <SponsorBlockSegment>[];
    final chapters = ChapterData.decode(t.chaptersJson);
    final fileLabels = decodeLabelUids(t.labelUids);
    usedLabels.addAll(fileLabels);
    for (final uids in chapters.keptChapterLabels.values) {
      usedLabels.addAll(uids);
    }
    tracksJson.add({
      'index': t.index,
      'videoId': t.videoId,
      // Never "null": a stand-in is the video id, which an import keeps
      // replaceable by the next real title.
      'title': resolveTrackTitle(t.title, videoId: t.videoId),
      'thumbnailUrl': t.thumbnailUrl,
      'thumbnailFileName': relative(t.thumbnailPath),
      'durationSeconds': t.durationSeconds,
      'status': t.status,
      'unavailableReason': t.unavailableReason,
      'isLocalReplacement': t.isLocalReplacement,
      'alwaysSkip': t.alwaysSkip,
      'chapters': chapters.toJson(),
      'chaptersEnabled': t.chaptersEnabled,
      'sponsorBlockCheckedAt':
          t.sponsorBlockCheckedAt?.toUtc().toIso8601String(),
      'downloadedAt': t.downloadedAt?.toUtc().toIso8601String(),
      'replaceRequested': t.replaceRequested,
      'fileName': relative(t.filePath),
      // Written only when set, so files without them stay unchanged.
      if (t.videoQuality != null) 'videoQuality': t.videoQuality,
      if (t.downloadedMaxHeight != null)
        'downloadedMaxHeight': t.downloadedMaxHeight,
      'sponsorBlockSegments': [
        for (final s in segments)
          {
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
      ],
      // Only the user's lyrics choices; the text is in `.woolytube_info`.
      if (lyricsPinsByTrack[t.id] case final pins? when pins.isNotEmpty)
        'lyricsPins': [
          for (final doc in pins)
            {
              'chapterId': doc.chapterId,
              'status': doc.status,
              'source': doc.source,
              'sourceRef': doc.sourceRef,
              'matchedArtist': doc.matchedArtist,
              'matchedTitle': doc.matchedTitle,
              if (doc.shiftMs != 0) 'shiftMs': doc.shiftMs,
              if (doc.timingOff) 'timingOff': true,
            },
        ],
      if (fileLabels.isNotEmpty) 'labels': fileLabels,
    });
  }
  final labelsJson = [
    for (final label in labels)
      if (label.deletedAt == null && usedLabels.contains(label.uid))
        PortableLabel.of(label).toJson(),
  ];

  return {
    'version': sidecarVersion,
    'playlist': <String, Object?>{
      'url': playlist.url,
      'name': playlist.name,
      'thumbnailUrl': playlist.thumbnailUrl,
      'thumbnailFileName': relative(playlist.thumbnailPath),
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
      if (playlist.videoQuality != null) 'videoQuality': playlist.videoQuality,
      if (playlist.isTemporary) 'temporary': true,
      if (playlist.lyricsMode != null) 'lyricsMode': playlist.lyricsMode,
      if (playlist.downloadSubtitles) 'downloadSubtitles': true,
      if (playlist.subtitleLanguages != null)
        'subtitleLanguages': playlist.subtitleLanguages,
      if (playlist.shuffleChapters) 'shuffleChapters': true,
    },
    'tracks': tracksJson,
    if (labelsJson.isNotEmpty) 'labels': labelsJson,
  };
}

/// Adds to [data], a sidecar this build is about to write, the keys of
/// [existing] (the sidecar it replaces) that this build does not know: a
/// newer app may have stored data there that an older one must not drop.
/// Tracks are matched by video id, and by position too when a video is
/// listed twice.
/// Returns [data].
Map<String, Object?> keepUnknownSidecarKeys(
  Map<String, Object?> data,
  Map<String, dynamic> existing,
) {
  void keep(
    Map<String, Object?> into,
    Map<dynamic, dynamic> from,
    Set<String> known,
  ) {
    for (final entry in from.entries) {
      final key = entry.key;
      if (key is! String || known.contains(key) || into.containsKey(key)) {
        continue;
      }
      into[key] = entry.value;
    }
  }

  keep(data, existing, sidecarTopLevelKeys);
  final playlist = data['playlist'];
  final oldPlaylist = existing['playlist'];
  if (playlist is Map<String, Object?> && oldPlaylist is Map) {
    keep(playlist, oldPlaylist, sidecarPlaylistKeys);
  }
  final tracks = data['tracks'];
  final oldTracks = existing['tracks'];
  if (tracks is List && oldTracks is List) {
    String keyOf(Map<dynamic, dynamic> track) =>
        track['videoId'] is String && (track['videoId'] as String).isNotEmpty
            ? 'v:${track['videoId']}'
            : 'i:${track['index']}';
    final oldByKey = <String, List<Map<dynamic, dynamic>>>{};
    for (final old in oldTracks) {
      if (old is! Map) continue;
      if (!old.keys.any((k) => k is String && !sidecarTrackKeys.contains(k))) {
        continue;
      }
      oldByKey.putIfAbsent(keyOf(old), () => []).add(old);
    }
    if (oldByKey.isNotEmpty) {
      for (final track in tracks) {
        if (track is! Map<String, Object?>) continue;
        final matches = oldByKey[keyOf(track)];
        if (matches == null || matches.isEmpty) continue;
        // A video listed twice: the entry at the same position first.
        final same = matches.indexWhere((m) => m['index'] == track['index']);
        keep(track, matches.removeAt(same < 0 ? 0 : same), sidecarTrackKeys);
      }
    }
  }
  return data;
}

/// The format version of a sidecar, or 0 when it has none.
int sidecarVersionOf(Map<String, dynamic> json) {
  final version = json['version'];
  return version is num ? version.toInt() : 0;
}

/// What [writeSidecarFiles] did.
typedef SidecarWriteResult =
    ({
      /// The hash of each file's current content. A sidecar left alone
      /// because a newer app wrote it has no hash.
      Map<String, int> hashes,

      /// The version of the sidecar left alone because a newer app wrote
      /// it, or null.
      int? newerVersionKept,

      /// The files whose content changed (or, for a dry run, would
      /// change).
      List<String> changed,
    });

/// What [MetadataService.checkMetadataOf] found.
typedef SidecarCheck =
    ({
      /// `woolytube_meta.json` is missing or differs from the database.
      bool sidecarOutOfDate,

      /// The `.m3u8` is missing or differs from the database.
      bool playlistFileOutOfDate,

      /// The format of a sidecar a newer app wrote, which is left alone.
      int? newerVersionKept,
    });

/// Builds and writes a playlist's sidecar and `.m3u8` (see [SidecarJob]).
/// A file whose content is unchanged is not rewritten; when its last hash
/// is not known, the file on disk is compared. Keys a newer app added to the
/// sidecar are kept, and a sidecar of a newer format version is not
/// overwritten at all. A [SidecarJob.dryRun] only reports which files
/// would change. Runs on any isolate.
Future<SidecarWriteResult> writeSidecarFiles(SidecarJob job) async {
  final data = buildSidecarData(
    job.playlist,
    job.tracks,
    job.segmentsByTrack,
    lyricsPinsByTrack: job.lyricsPinsByTrack,
    labels: job.labels,
  );
  final contents = {
    job.metaPath: encodeSidecar(data),
    job.playlistFilePath: MetadataService.buildPlaylistFile(
      job.playlist,
      job.tracks,
    ),
  };
  final hashes = <String, int>{};
  final changed = <String>[];
  int? newerVersionKept;
  for (final entry in contents.entries) {
    final path = entry.key;
    var content = entry.value;
    var hash = contentHash(content);
    final target = File(path);
    final known = job.knownHashes[path];
    var unchanged = false;
    if (known == hash) {
      unchanged = await target.exists();
    } else {
      // Not written by this process yet (for example after a restart), or
      // changed: compare with what is on disk instead of rewriting every
      // file, and keep what a newer app added to the sidecar.
      String? existing;
      try {
        if (await target.exists()) existing = await target.readAsString();
      } catch (_) {
        existing = null;
      }
      if (existing != null && path == job.metaPath) {
        Map<String, dynamic>? json;
        try {
          final decoded = jsonDecode(existing);
          if (decoded is Map<String, dynamic>) json = decoded;
        } catch (_) {
          // Unreadable: replaced by a good one.
        }
        if (json != null) {
          final version = sidecarVersionOf(json);
          if (version > sidecarVersion) {
            newerVersionKept = version;
            continue;
          }
          content = encodeSidecar(keepUnknownSidecarKeys(data, json));
          hash = contentHash(content);
        }
      }
      unchanged = existing == content;
    }
    if (!unchanged) changed.add(path);
    if (job.dryRun) continue;
    if (!unchanged) {
      final tmpFile = File('$path.tmp.${job.tempSuffix}');
      try {
        await tmpFile.writeAsString(content);
        await tmpFile.rename(path);
      } catch (_) {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {
          // The folder cleanup removes leftover temp files later.
        }
        rethrow;
      }
    }
    hashes[path] = hash;
  }
  return (hashes: hashes, newerVersionKept: newerVersionKept, changed: changed);
}

/// A content hash of [content]: two independent 30-bit hashes (FNV-1a and
/// a polynomial one) side by side, the same on every isolate and run.
int contentHash(String content) {
  var fnv = 0x811c9dc5;
  var poly = content.length & 0x3FFFFFFF;
  for (var i = 0; i < content.length; i++) {
    final unit = content.codeUnitAt(i);
    fnv = ((fnv ^ unit) * 0x01000193) & 0x3FFFFFFF;
    poly = (poly * 31 + unit) & 0x3FFFFFFF;
  }
  return (fnv << 30) | poly;
}
