import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'app_settings_service.dart';
import 'library_gate.dart';
import 'log_service.dart';
import 'media_thumbnail_service.dart';
import 'metadata_service.dart';
import 'notification_service.dart';
import 'sponsorblock_service.dart';

class DownloadProgress {
  final int playlistId;
  final int currentTrackIndex;
  final int totalTracks;
  final double trackProgress;
  final String status; // idle | downloading | complete | error
  final String? error;

  const DownloadProgress({
    required this.playlistId,
    required this.currentTrackIndex,
    required this.totalTracks,
    required this.trackProgress,
    required this.status,
    this.error,
  });

  static const idle = DownloadProgress(
    playlistId: 0,
    currentTrackIndex: 0,
    totalTracks: 0,
    trackProgress: 0,
    status: 'idle',
  );
}

typedef LockDirectoryProvider = Future<String> Function();

/// Mutual exclusion between the foreground app and the hourly background
/// worker. Both run in the same process but in separate Flutter engines, so a
/// file in the app's documents directory is the shared state.
///
/// The file records its owner. A holder of the same kind may take the lock
/// over, because only one foreground service and one scheduled worker can
/// exist at a time; a lock left behind by a killed engine must not block the
/// other side forever.
class DownloadLock {
  DownloadLock({LockDirectoryProvider? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const foregroundOwner = 'foreground';
  static const backgroundOwner = 'background';
  static const fileName = 'download.lock';

  /// The foreground refreshes its lock before every track, so a much older
  /// lock belongs to a process that no longer exists.
  static const foregroundStaleAfter = Duration(hours: 1);

  /// WorkManager destroys the background engine after ten minutes, so a
  /// background lock cannot be live for longer than that.
  static const backgroundStaleAfter = Duration(minutes: 10);

  static Future<String> _defaultDirectory() async =>
      (await getApplicationDocumentsDirectory()).path;

  final LockDirectoryProvider _directoryProvider;

  Future<File> _file() async =>
      File(p.join(await _directoryProvider(), fileName));

  /// Takes the lock for [owner]. Returns false while a live holder of another
  /// kind has it.
  Future<bool> acquire(String owner) async {
    final file = await _file();
    if (await isHeldByOther(owner, file: file)) return false;
    file.writeAsStringSync('$owner ${DateTime.now().toIso8601String()}');
    return true;
  }

  /// Whether a live lock of a kind other than [owner] exists.
  Future<bool> isHeldByOther(String owner, {File? file}) async {
    final lockFile = file ?? await _file();
    if (!lockFile.existsSync()) return false;
    final String holder;
    final DateTime modified;
    try {
      holder = lockFile.readAsStringSync().split(' ').first.trim();
      modified = lockFile.lastModifiedSync();
    } on FileSystemException {
      // The other engine released it between the checks.
      return false;
    }
    if (holder == owner) return false;
    final staleAfter =
        holder == backgroundOwner ? backgroundStaleAfter : foregroundStaleAfter;
    return DateTime.now().difference(modified) < staleAfter;
  }

  /// Re-stamps the lock so a long foreground download is not mistaken for an
  /// abandoned one.
  Future<void> refresh(String owner) async {
    final file = await _file();
    try {
      file.writeAsStringSync('$owner ${DateTime.now().toIso8601String()}');
    } on FileSystemException {
      // Losing a refresh only shortens the stale window.
    }
  }

  /// Removes the lock. With [owner], only a lock that still names [owner] is
  /// removed, so one side can never drop the other side's live lock.
  Future<void> release([String? owner]) async {
    final file = await _file();
    if (!file.existsSync()) return;
    if (owner != null) {
      try {
        final holder = file.readAsStringSync().split(' ').first.trim();
        if (holder != owner) return;
      } on FileSystemException {
        return;
      }
    }
    file.deleteSync();
  }
}

enum _TrackDownloadResult { downloaded, reused, failed, cancelled }

/// Words in a yt-dlp error that mean the video itself can no longer be
/// fetched, as opposed to a network hiccup or a yt-dlp bug.
const _permanentErrorPatterns = [
  'video unavailable',
  'this video is not available',
  'this video has been removed',
  'private video',
  'video is private',
  'members-only',
  'members only',
  'premium',
  'confirm your age',
  'age-restricted',
  'account associated with this video has been terminated',
  'copyright',
];

bool isPermanentDownloadError(String message) {
  final lower = message.toLowerCase();
  return _permanentErrorPatterns.any(lower.contains);
}

class DownloadService {
  static const lockHeldMessage =
      'A scheduled update is running in the background. '
      'Try again in a few minutes.';

  /// Longest title part of a downloaded file name, in bytes. File names are
  /// limited to 255 bytes and non-Latin titles take 2-4 bytes per letter.
  static const titleByteLimit = 150;

  final AppDatabase _db;
  final YtDlpService _ytdlp;
  final LogService _log;
  final MetadataService _metadata;
  final DownloadNotificationService? _notifications;
  final SponsorBlockService? _sponsorBlock;
  final AppSettingsService _settings;
  final LibraryGate _gate;
  final MediaThumbnailService _thumbnails;

  final _progressController = StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  StreamSubscription? _ytdlpProgressSub;
  bool _isDownloading = false;
  bool _cancelRequested = false;
  bool _reportingStarted = false;
  int? _activeTrackId;
  bool _activeTrackIsReplacement = false;
  Playlist? _activePlaylist;
  String? _lastFailure;
  bool get isDownloading => _isDownloading;

  /// The track whose file is being downloaded right now, if any.
  int? get activeTrackId => _activeTrackId;

  /// Mutual exclusion shared with every other operation that changes files.
  LibraryGate get gate => _gate;

  DownloadService(
    this._db,
    this._ytdlp,
    this._log,
    this._metadata, [
    this._notifications,
    this._sponsorBlock,
    AppSettingsService? settings,
    DownloadLock? lock,
    String lockOwner = DownloadLock.foregroundOwner,
    LibraryGate? gate,
    MediaThumbnailService? thumbnails,
  ]) : _settings = settings ?? AppSettingsService(),
       _gate =
           gate ?? LibraryGate(lock: lock ?? DownloadLock(), owner: lockOwner),
       _thumbnails = thumbnails ?? const MediaThumbnailService();

  /// yt-dlp reads `%` in `-o` as the start of a format field, so a literal
  /// path component such as `100% Hits` must be doubled.
  static String escapeOutputTemplateLiteral(String literal) =>
      literal.replaceAll('%', '%%');

  void _emit(DownloadProgress progress) {
    if (!_progressController.isClosed) _progressController.add(progress);
  }

  /// Downloads every pending or failed track of [playlist], and replaces the
  /// files of tracks whose replacement was requested (a mode switch, or the
  /// original of a local replacement). An existing file is only replaced
  /// after its successor is completely on disk.
  ///
  /// Pass [sourceChecked] false when the playlist could not be read from
  /// YouTube first: the run then does not count as an update, so the next
  /// scheduled check still happens on time.
  Future<void> downloadPlaylist(
    Playlist playlist, {
    bool sourceChecked = true,
  }) async {
    if (_isDownloading) return;
    _isDownloading = true;
    _cancelRequested = false;
    _activePlaylist = playlist;
    var entered = false;
    var totalTracks = 0;
    var downloadedCount = 0;
    var reusedCount = 0;
    var failedCount = 0;

    try {
      final busy = await _gate.tryEnter('download');
      if (busy != null) {
        _log.warn('Playlist download skipped: $busy');
        _emit(
          DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: 0,
            totalTracks: 0,
            trackProgress: 0,
            status: 'error',
            error: busy,
          ),
        );
        return;
      }
      entered = true;

      // Settings such as the folder may have changed since the caller read
      // the row (for example a mode switch).
      playlist = await _db.getPlaylist(playlist.id);
      _activePlaylist = playlist;

      // A manual or scheduled update is an explicit download trigger. Repair
      // anything a previous process left behind before selecting work.
      await _metadata.discardStaging(playlist.outputPath);
      var recovered = await _metadata.recoverInterruptedPlaylist(playlist);
      recovered += await _metadata.adoptStrayFiles(playlist);
      if (recovered > 0) {
        _log.info('Recovered $recovered interrupted download files/states');
        await _writeMetadataForPlaylist(playlist.id);
      }

      final pendingTracks = await _db.getPendingTracks(playlist.id);
      final replaceTracks = await _db.getReplacementRequests(playlist.id);
      final work = [
        for (final track in pendingTracks) (track: track, replace: false),
        for (final track in replaceTracks) (track: track, replace: true),
      ]..sort((a, b) => a.track.index.compareTo(b.track.index));
      totalTracks = await _db.getTotalTrackCount(playlist.id);

      _log.info(
        'Updating "${playlist.name}": ${pendingTracks.length} of '
        '$totalTracks tracks to download'
        '${replaceTracks.isEmpty ? '' : ', ${replaceTracks.length} to replace'}',
      );

      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return;
      }

      if (work.isEmpty) {
        // A successful check with no pending work still starts the next
        // auto-update interval. Without this, an unchanged playlist remains
        // overdue and gets checked on every background-worker run.
        if (sourceChecked) await _markPlaylistUpdated(playlist);
        await _backfillMissingSponsorBlockSegments(playlist);
        await _writeMetadataForPlaylist(playlist.id);
        _emit(
          DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: totalTracks,
            totalTracks: totalTracks,
            trackProgress: 100,
            status: 'complete',
          ),
        );
        return;
      }

      final doneSoFar = (totalTracks - work.length).clamp(0, totalTracks);
      var currentTrackNum = doneSoFar + 1;

      await _startDownloadReporting(
        playlist: playlist,
        currentTrackIndex: () => currentTrackNum,
        totalTracks: totalTracks,
      );

      for (var i = 0; i < work.length; i++) {
        if (_cancelRequested) break;
        final item = work[i];
        final trackNum = doneSoFar + i + 1;
        currentTrackNum = trackNum;
        await _gate.refresh();

        final result = await _downloadTrackFile(
          playlist: playlist,
          track: item.track,
          totalTracks: totalTracks,
          progressTrackIndex: trackNum,
          progressTotalTracks: totalTracks,
          trackLabel: '[$trackNum/$totalTracks] ${item.track.title}',
          reuseExistingFile: !item.replace,
          replaceExisting: item.replace,
        );
        switch (result) {
          case _TrackDownloadResult.downloaded:
            downloadedCount++;
          case _TrackDownloadResult.reused:
            reusedCount++;
          case _TrackDownloadResult.failed:
            failedCount++;
          case _TrackDownloadResult.cancelled:
            break;
        }
      }

      if (_cancelRequested) {
        _log.info('Playlist download stopped');
        await _writeMetadataForPlaylist(playlist.id);
        _emit(DownloadProgress.idle);
        return;
      }

      // A run in which every attempt failed has not updated anything; leave
      // the playlist overdue so the next worker run retries it.
      final failedEntirely =
          downloadedCount + reusedCount == 0 && failedCount > 0;
      if (failedEntirely) {
        _log.warn(
          'All $failedCount downloads failed; '
          'not stamping "${playlist.name}" as updated',
        );
      } else if (sourceChecked) {
        await _markPlaylistUpdated(playlist);
      }

      await _backfillMissingSponsorBlockSegments(playlist);
      await _writeMetadataForPlaylist(playlist.id);
      await _cleanupFolder(playlist);

      // Only now is the playlist really finished; emitting earlier left the
      // UI claiming completion while the backfill still ran for minutes.
      _emit(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: totalTracks,
          totalTracks: totalTracks,
          trackProgress: 100,
          status: 'complete',
        ),
      );

      if (downloadedCount > 0) {
        await _notifications?.showDownloadComplete(
          playlist.name,
          downloadedCount: downloadedCount,
          notificationId: playlist.id,
        );
      }
    } catch (e) {
      if (_cancelRequested) {
        _log.info('Playlist download stopped');
        await _writeMetadataForPlaylist(playlist.id);
        _emit(DownloadProgress.idle);
        return;
      }
      _log.error('Playlist download failed: $e');
      await _writeMetadataForPlaylist(playlist.id);
      _emit(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: 0,
          totalTracks: totalTracks,
          trackProgress: 0,
          status: 'error',
          error: e.toString(),
        ),
      );
    } finally {
      await _finishRun(entered: entered);
    }
  }

  /// Downloads one track now: a retry of a failed track, or a fresh copy of
  /// a downloaded one. A downloaded file is replaced only once the new copy
  /// is complete; if the download fails the old file stays as it was.
  ///
  /// Returns true when a new file was saved, false when the owner stopped
  /// it (nothing changed then). Throws with the reason when it failed.
  Future<bool> downloadTrack(Playlist playlist, Track track) async {
    // A caller must never report success for a download that never ran.
    if (_isDownloading) {
      throw StateError('A download is already in progress.');
    }
    _isDownloading = true;
    _cancelRequested = false;
    _activePlaylist = playlist;
    _lastFailure = null;
    var entered = false;
    const progressTrackIndex = 1;
    const progressTotalTracks = 1;

    try {
      final busy = await _gate.tryEnter('download');
      if (busy != null) {
        _log.warn('Track download skipped: $busy');
        throw StateError(busy);
      }
      entered = true;

      playlist = await _db.getPlaylist(playlist.id);
      _activePlaylist = playlist;
      final fresh = await _db.getTrack(track.id);
      if (fresh == null) throw StateError('The track no longer exists.');
      final totalTracks = await _db.getTotalTrackCount(playlist.id);
      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return false;
      }

      await _startDownloadReporting(
        playlist: playlist,
        currentTrackIndex: () => progressTrackIndex,
        totalTracks: progressTotalTracks,
      );
      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return false;
      }

      final replace =
          fresh.status == 'complete' &&
          fresh.filePath != null &&
          await File(fresh.filePath!).exists();
      _log.info(
        '${replace ? 'Redownloading' : 'Downloading'} "${fresh.title}" '
        'from "${playlist.name}"',
      );

      final result = await _downloadTrackFile(
        playlist: playlist,
        track: fresh,
        totalTracks: totalTracks,
        progressTrackIndex: progressTrackIndex,
        progressTotalTracks: progressTotalTracks,
        trackLabel: '[${fresh.index}/$totalTracks] ${fresh.title}',
        reuseExistingFile: false,
        replaceExisting: replace,
      );

      if (result != _TrackDownloadResult.downloaded) {
        if (_cancelRequested) {
          await _writeMetadataForPlaylist(playlist.id);
          _emit(DownloadProgress.idle);
          return false;
        }
        // The caller shows this failure, so carry the recorded reason.
        final failed = await _db.getTrack(track.id);
        throw StateError(
          _lastFailure ?? failed?.lastError ?? 'Download failed',
        );
      }

      await _markPlaylistUpdated(playlist);
      await _writeMetadataForPlaylist(playlist.id);
      await _cleanupFolder(playlist);

      _emit(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: progressTrackIndex,
          totalTracks: progressTotalTracks,
          trackProgress: 100,
          status: 'complete',
        ),
      );

      await _notifications?.showDownloadComplete(
        fresh.title,
        notificationId: playlist.id,
      );
      return true;
    } catch (e) {
      if (_cancelRequested) {
        await _writeMetadataForPlaylist(playlist.id);
        _emit(DownloadProgress.idle);
        return false;
      }
      // A single-track download is always user-initiated and its caller
      // reports the failure, so do not also raise the global error event.
      _emit(DownloadProgress.idle);
      rethrow;
    } finally {
      await _finishRun(entered: entered);
    }
  }

  Future<void> _finishRun({required bool entered}) async {
    _isDownloading = false;
    _activeTrackId = null;
    _activeTrackIsReplacement = false;
    _activePlaylist = null;
    _ytdlpProgressSub?.cancel();
    _ytdlpProgressSub = null;
    if (_reportingStarted) {
      _reportingStarted = false;
      try {
        await _ytdlp.stopDownloadService();
      } catch (e) {
        _log.warn('Failed to stop download foreground service: $e');
      }
    }
    if (entered) {
      try {
        await _gate.exit();
      } catch (e) {
        _log.warn('Failed to release download lock: $e');
      }
    }
  }

  Future<void> _startDownloadReporting({
    required Playlist playlist,
    required int Function() currentTrackIndex,
    required int totalTracks,
  }) async {
    _reportingStarted = true;
    try {
      await _ytdlp.startDownloadService(playlist.name);
    } catch (e) {
      _log.warn('Failed to start download foreground service: $e');
    }

    _ytdlpProgressSub = _ytdlp.progressStream.listen((event) {
      final progress = (event['progress'] as num?)?.toDouble() ?? 0;
      final status = event['status'] as String? ?? 'downloading';

      if (status == 'downloading' || status == 'starting') {
        final currentTrack = currentTrackIndex();
        _emit(
          DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: currentTrack,
            totalTracks: totalTracks,
            trackProgress: progress,
            status: 'downloading',
          ),
        );
        _ytdlp.updateDownloadServiceProgress(
          playlistName: playlist.name,
          currentTrack: currentTrack,
          totalTracks: totalTracks,
          progress: progress.round(),
        );
      }
    });
  }

  Future<_TrackDownloadResult> _downloadTrackFile({
    required Playlist playlist,
    required Track track,
    required int totalTracks,
    required int progressTrackIndex,
    required int progressTotalTracks,
    required String trackLabel,
    required bool reuseExistingFile,
    required bool replaceExisting,
  }) async {
    final indexStr = MetadataService.paddedIndex(track.index, totalTracks);

    if (reuseExistingFile) {
      final existingFile = await _metadata.findAdoptableMediaFile(
        playlist,
        track,
      );
      if (existingFile != null) {
        // A local file that was briefly missing stays a local file: its
        // timeline is not the YouTube video's.
        await _db.updateTrackStatus(
          track.id,
          'complete',
          filePath: existingFile,
        );
        await _metadata.captureChapterMetadata(track, playlist.outputPath);
        if (!track.isLocalReplacement) {
          await _sponsorBlock?.refreshTrackSegments(
            track.copyWith(filePath: Value(existingFile), status: 'complete'),
          );
        }
        _log.info(
          '$trackLabel Found existing file: ${p.basename(existingFile)}',
        );
        _emit(
          DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: progressTrackIndex,
            totalTracks: progressTotalTracks,
            trackProgress: 100,
            status: 'downloading',
          ),
        );
        return _TrackDownloadResult.reused;
      }
    }

    if (track.videoId.startsWith(forcedInsertVideoIdPrefix)) {
      // A local-only entry has nothing on YouTube to download.
      const errorMsg = 'This entry is a local file and has no YouTube source';
      if (replaceExisting) {
        await _db.setTrackReplaceRequested(track.id, false);
      } else {
        await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
      }
      _lastFailure = errorMsg;
      return _TrackDownloadResult.failed;
    }

    _emit(
      DownloadProgress(
        playlistId: playlist.id,
        currentTrackIndex: progressTrackIndex,
        totalTracks: progressTotalTracks,
        trackProgress: 0,
        status: 'downloading',
      ),
    );

    _activeTrackId = track.id;
    _activeTrackIsReplacement = replaceExisting;
    if (!replaceExisting) {
      await _db.updateTrackStatus(track.id, 'downloading');
    }

    final Directory staging;
    try {
      staging = await _metadata.prepareStagingDir(
        playlist.outputPath,
        track.id,
      );
    } catch (e) {
      _activeTrackId = null;
      _activeTrackIsReplacement = false;
      return _recordFailure(
        track: track,
        playlist: playlist,
        replaceExisting: replaceExisting,
        trackLabel: trackLabel,
        errorMsg:
            'Could not prepare the download folder: ${_cleanErrorMessage(e)}',
      );
    }
    final outputTemplate =
        '${escapeOutputTemplateLiteral(staging.path)}/'
        '${indexStr}_%(title).${titleByteLimit}B.%(ext)s';
    final videoUrl = 'https://www.youtube.com/watch?v=${track.videoId}';

    try {
      String? failure;
      try {
        await _downloadWithRetry(
          url: videoUrl,
          outputPath: staging.path,
          audioOnly: playlist.audioOnly,
          embedThumbnail: playlist.includeThumbnails,
          metadataAlbum: playlist.name,
          outputTemplate: outputTemplate,
          trackLabel: trackLabel,
        );
      } catch (e) {
        failure = _cleanErrorMessage(e);
      }

      if (_cancelRequested) {
        if (!replaceExisting) {
          await _db.resetInterruptedTrack(track.id, onlyIfDownloading: true);
        }
        _log.info('$trackLabel Interrupted; nothing was changed');
        return _TrackDownloadResult.cancelled;
      }

      final staged = MetadataService.findStagedMedia(staging);
      if (failure != null) {
        // yt-dlp reports a failed post-processing step (thumbnail or
        // metadata embedding) as an error although the media is complete.
        // Keep such a file rather than throw away a good copy.
        if (staged != null && _isPostProcessingError(failure)) {
          _log.warn('$trackLabel Saved, but post-processing failed: $failure');
        } else {
          return await _recordFailure(
            track: track,
            playlist: playlist,
            replaceExisting: replaceExisting,
            trackLabel: trackLabel,
            errorMsg: failure,
          );
        }
      }

      if (staged == null) {
        // yt-dlp reported success but left no playable file (for example a
        // failed merge). Recording a made-up path would present a track that
        // cannot be played and would never be retried.
        return await _recordFailure(
          track: track,
          playlist: playlist,
          replaceExisting: replaceExisting,
          trackLabel: trackLabel,
          errorMsg: 'Downloaded file not found',
        );
      }

      final updatedTrack = await _metadata.publishDownload(
        playlist: playlist,
        trackId: track.id,
        stagingDir: staging,
        stagedMedia: staged,
        thumbnails: _thumbnails,
        embeddedThumbnailExpected: playlist.includeThumbnails,
      );
      if (updatedTrack == null) {
        _lastFailure = 'The track was removed during the download';
        return _TrackDownloadResult.failed;
      }
      await _sponsorBlock?.refreshTrackSegments(updatedTrack);
      _log.info('$trackLabel Downloaded: ${track.title}');

      _emit(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: progressTrackIndex,
          totalTracks: progressTotalTracks,
          trackProgress: 100,
          status: 'downloading',
        ),
      );
      return _TrackDownloadResult.downloaded;
    } catch (e) {
      // Unexpected failure while publishing; the previous file, if any, was
      // not touched before the new one was in place.
      final errorMsg = _cleanErrorMessage(e);
      _log.error('$trackLabel Could not save "${track.title}": $errorMsg');
      _lastFailure = errorMsg;
      if (!replaceExisting) {
        await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
      }
      return _TrackDownloadResult.failed;
    } finally {
      await _metadata.discardStagingDir(staging);
      if (_activeTrackId == track.id) {
        _activeTrackId = null;
        _activeTrackIsReplacement = false;
      }
    }
  }

  Future<_TrackDownloadResult> _recordFailure({
    required Track track,
    required Playlist playlist,
    required bool replaceExisting,
    required String trackLabel,
    required String errorMsg,
  }) async {
    _lastFailure = errorMsg;
    if (!replaceExisting) {
      await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
      _log.error('$trackLabel Failed "${track.title}": $errorMsg');
      return _TrackDownloadResult.failed;
    }
    // The existing copy is still in place and keeps playing.
    _log.error(
      '$trackLabel Could not download a new copy of "${track.title}"; '
      'kept the existing file: $errorMsg',
    );
    if (track.replaceRequested && isPermanentDownloadError(errorMsg)) {
      // YouTube no longer serves it: keep what we have for good.
      await _metadata.adoptKeptFile(playlist, track.id);
      await _db.setTrackReplaceRequested(track.id, false);
    }
    return _TrackDownloadResult.failed;
  }

  /// Only a failed embedding step leaves a complete, playable file. A failed
  /// audio conversion can leave a truncated one, so it is not accepted.
  static bool _isPostProcessingError(String message) {
    final lower = message.toLowerCase();
    return lower.contains('postprocessing') &&
        (lower.contains('thumbnail') ||
            lower.contains('embed') ||
            lower.contains('metadata'));
  }

  /// Stops this service's native yt-dlp process. A track that had no file
  /// returns to the queue; a track that was being replaced keeps its file.
  Future<void> cancelActiveDownloads() async {
    if (!_isDownloading) return;
    _cancelRequested = true;

    try {
      await _ytdlp.cancelDownloads();
    } catch (e) {
      _log.warn('Failed to cancel native download: $e');
    }

    final trackId = _activeTrackId;
    if (trackId != null && !_activeTrackIsReplacement) {
      await _db.resetInterruptedTrack(trackId, onlyIfDownloading: true);
    }

    final playlist = _activePlaylist;
    if (playlist != null) {
      try {
        await _writeMetadataForPlaylist(playlist.id);
      } catch (e) {
        _log.warn('Interrupted download cleanup failed: $e');
      }
    }
  }

  /// Stamps only `lastUpdated`. A full row replace from the [Playlist]
  /// snapshot handed to this run would silently undo settings the user
  /// changed while the download was in progress.
  Future<void> _markPlaylistUpdated(Playlist playlist) =>
      _db.markPlaylistUpdated(playlist.id, DateTime.now());

  Future<void> _cleanupFolder(Playlist playlist) async {
    try {
      final cleaned = await _metadata.cleanupPlaylist(playlist);
      if (cleaned > 0) _log.info('Cleaned up $cleaned leftover files');
    } catch (e) {
      _log.warn('Cleanup failed: $e');
    }
  }

  static const _transientErrorPatterns = [
    'no address associated with hostname',
    'unable to download webpage',
    'http error 5',
    'http error 429',
    'too many requests',
    'connection reset',
    'connection refused',
    'connection closed',
    'timed out',
    'timeout',
    'rate limited',
    'temporary failure in name resolution',
    'network is unreachable',
  ];

  static bool _isTransientError(String message) {
    final lower = message.toLowerCase();
    return _transientErrorPatterns.any(lower.contains);
  }

  static bool _isExtrasError(String message) {
    final lower = message.toLowerCase();
    return (lower.contains('postprocessing:') ||
            lower.contains('preprocessing:')) &&
        !lower.contains('audio conversion');
  }

  static bool _isSubtitleError(String message) =>
      message.toLowerCase().contains('subtitles');

  Future<void> _downloadWithRetry({
    required String url,
    required String outputPath,
    required bool audioOnly,
    required bool embedThumbnail,
    required String metadataAlbum,
    required String outputTemplate,
    required String trackLabel,
  }) async {
    var downloadSubtitles =
        !audioOnly && await _settings.getDownloadSubtitles();
    final subtitleLanguages =
        downloadSubtitles ? await _settings.getSubtitleLanguages() : 'en';
    const backoffs = [Duration(seconds: 5), Duration(seconds: 15)];
    var attempt = 0;
    var withExtras = true;
    while (true) {
      if (_cancelRequested) return;
      try {
        await _ytdlp.download(
          url: url,
          outputPath: outputPath,
          audioOnly: audioOnly,
          embedThumbnail: embedThumbnail && withExtras,
          writeThumbnail: withExtras,
          embedMetadata: withExtras,
          metadataAlbum: metadataAlbum,
          downloadSubtitles: downloadSubtitles,
          subtitleLanguages: subtitleLanguages,
          outputTemplate: outputTemplate,
        );
        return;
      } catch (e) {
        final cleaned = _cleanErrorMessage(e);
        if (downloadSubtitles && _isSubtitleError(cleaned)) {
          // Subtitles are an extra. Never let them cost the media itself.
          _log.warn(
            '$trackLabel: subtitles failed, retrying without: $cleaned',
          );
          downloadSubtitles = false;
          continue;
        }
        if (withExtras && _isExtrasError(cleaned)) {
          // Cover art, tags and the kept thumbnail are extras too. yt-dlp
          // reports their failure with the same bare "Conversion failed!"
          // as a failed merge, so try once more without them: the media
          // already in staging is reused, and a real merge failure fails
          // again.
          _log.warn(
            '$trackLabel: post-processing failed, retrying without '
            'cover/tags: $cleaned',
          );
          withExtras = false;
          continue;
        }
        if (attempt >= backoffs.length || !_isTransientError(cleaned)) {
          rethrow;
        }
        final delay = backoffs[attempt];
        attempt++;
        _log.warn(
          '$trackLabel: transient error (attempt $attempt), retrying in ${delay.inSeconds}s: $cleaned',
        );
        await Future.delayed(delay);
        if (_cancelRequested) return;
      }
    }
  }

  static const _sponsorBlockMissingRetryInterval = Duration(days: 7);
  static const _sponsorBlockBackfillConcurrency = 4;

  /// Fetches segments for completed YouTube downloads that have none stored.
  /// Local replacements are skipped: their timeline is not the YouTube
  /// video's, and remote segments would cut the wrong parts of the audio.
  Future<void> _backfillMissingSponsorBlockSegments(Playlist playlist) async {
    final sponsorBlock = _sponsorBlock;
    if (sponsorBlock == null || !playlist.sponsorBlockEnabled) return;

    final now = DateTime.now();
    final candidates =
        (await _db.getTracksForPlaylist(playlist.id))
            .where(
              (track) =>
                  track.status == 'complete' &&
                  track.filePath != null &&
                  track.unavailableReason == null &&
                  !track.isLocalReplacement &&
                  _shouldRetryMissingSponsorBlock(track, now),
            )
            .toList();
    if (candidates.isEmpty) return;

    var refreshed = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < candidates.length && !_cancelRequested) {
        final track = candidates[next++];
        try {
          final existingSegments = await _db.getSegmentsForTrack(track.id);
          final hasRemoteState = existingSegments.any(
            (segment) =>
                segment.source == 'sponsorblock' ||
                segment.source == 'override' ||
                segment.source == 'hidden',
          );
          if (hasRemoteState) continue;

          final segments = await sponsorBlock.fetchSegments(
            track.videoId,
            track.id,
          );
          await _db.replaceRemoteSponsorBlockSegments(track.id, segments);
          await _db.updateTrackSponsorBlockCheckedAt(track.id, now);
          refreshed++;
        } catch (e) {
          _log.warn('SponsorBlock backfill failed for ${track.videoId}: $e');
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < _sponsorBlockBackfillConcurrency; i++) worker(),
    ]);

    if (refreshed > 0) {
      _log.info('SponsorBlock: backfilled $refreshed tracks');
    }
  }

  bool _shouldRetryMissingSponsorBlock(Track track, DateTime now) {
    final checkedAt = track.sponsorBlockCheckedAt;
    return checkedAt == null ||
        now.difference(checkedAt) >= _sponsorBlockMissingRetryInterval;
  }

  Future<void> _writeMetadataForPlaylist(int playlistId) async {
    try {
      final pl = await _db.getPlaylist(playlistId);
      final tracks = await _db.getTracksForPlaylist(playlistId);
      await _metadata.writeMetadata(pl, tracks);
    } catch (e) {
      _log.warn('Failed to write metadata: $e');
    }
  }

  void dispose() {
    _ytdlpProgressSub?.cancel();
    _progressController.close();
  }

  static final _ansiPattern = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final _ytPrefixPattern = RegExp(
    r'^\s*(?:ERROR:\s*)?(?:\[[^\]]+\]\s*[^:]*:\s*)?',
  );

  static String _cleanErrorMessage(Object e) {
    String raw;
    if (e is PlatformException) {
      raw = e.message ?? e.details?.toString() ?? e.toString();
    } else {
      raw = e.toString();
    }
    var cleaned = raw.replaceAll(_ansiPattern, '').trim();
    // yt-dlp prints warnings before the error; keep the error lines.
    final errorLines = [
      for (final line in cleaned.split('\n'))
        if (line.trimLeft().startsWith('ERROR:')) line.trim(),
    ];
    if (errorLines.isNotEmpty) cleaned = errorLines.join('\n');
    // Strip a leading "ERROR: [youtube] xxxx: " prefix once.
    cleaned = cleaned.replaceFirst(_ytPrefixPattern, '').trim();
    if (cleaned.isEmpty) cleaned = raw.trim();
    if (cleaned.length > 500) {
      cleaned = '${cleaned.substring(0, 500)}...';
    }
    return cleaned;
  }
}
