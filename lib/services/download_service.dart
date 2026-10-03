import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'app_settings_service.dart';
import 'log_service.dart';
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
    try {
      holder = lockFile.readAsStringSync().split(' ').first.trim();
    } on FileSystemException {
      return false;
    }
    if (holder == owner) return false;
    final staleAfter =
        holder == backgroundOwner ? backgroundStaleAfter : foregroundStaleAfter;
    final age = DateTime.now().difference(lockFile.lastModifiedSync());
    return age < staleAfter;
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

  Future<void> release() async {
    final file = await _file();
    if (file.existsSync()) file.deleteSync();
  }
}

enum _TrackDownloadResult { downloaded, reused, failed, cancelled }

class DownloadService {
  static const lockHeldMessage =
      'A scheduled update is running in the background. '
      'Try again in a few minutes.';

  final AppDatabase _db;
  final YtDlpService _ytdlp;
  final LogService _log;
  final MetadataService _metadata;
  final DownloadNotificationService? _notifications;
  final SponsorBlockService? _sponsorBlock;
  final AppSettingsService _settings;
  final DownloadLock _lock;

  final _progressController = StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  StreamSubscription? _ytdlpProgressSub;
  bool _isDownloading = false;
  bool _cancelRequested = false;
  bool _reportingStarted = false;
  int? _activeTrackId;
  Playlist? _activePlaylist;
  bool get isDownloading => _isDownloading;

  DownloadService(
    this._db,
    this._ytdlp,
    this._log,
    this._metadata, [
    this._notifications,
    this._sponsorBlock,
    AppSettingsService? settings,
    DownloadLock? lock,
  ]) : _settings = settings ?? AppSettingsService(),
       _lock = lock ?? DownloadLock();

  /// yt-dlp reads `%` in `-o` as the start of a format field, so a literal
  /// path component such as `100% Hits` must be doubled.
  static String escapeOutputTemplateLiteral(String literal) =>
      literal.replaceAll('%', '%%');

  void _emit(DownloadProgress progress) {
    if (!_progressController.isClosed) _progressController.add(progress);
  }

  Future<void> downloadPlaylist(Playlist playlist) async {
    if (_isDownloading) return;
    _isDownloading = true;
    _cancelRequested = false;
    _activePlaylist = playlist;
    var lockAcquired = false;
    var totalTracks = 0;
    var downloadedCount = 0;
    var reusedCount = 0;
    var failedCount = 0;

    try {
      lockAcquired = await _lock.acquire(DownloadLock.foregroundOwner);
      if (!lockAcquired) {
        _log.warn('Playlist download skipped: $lockHeldMessage');
        _emit(
          DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: 0,
            totalTracks: 0,
            trackProgress: 0,
            status: 'error',
            error: lockHeldMessage,
          ),
        );
        return;
      }

      // A manual or scheduled update is an explicit download trigger. Repair
      // anything a previous process left behind before selecting pending work.
      final recovered = await _metadata.recoverInterruptedPlaylist(playlist);
      if (recovered > 0) {
        _log.info('Recovered $recovered interrupted download files/states');
        await _writeMetadataForPlaylist(playlist.id);
      }

      final pendingTracks = await _db.getPendingTracks(playlist.id);
      totalTracks = await _db.getTotalTrackCount(playlist.id);

      _log.info(
        'Updating "${playlist.name}": ${pendingTracks.length} of $totalTracks tracks to download',
      );

      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return;
      }

      if (pendingTracks.isEmpty) {
        // A successful check with no pending work still starts the next
        // auto-update interval. Without this, an unchanged playlist remains
        // overdue and gets checked on every background-worker run.
        await _markPlaylistUpdated(playlist);
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

      final downloadedSoFar = totalTracks - pendingTracks.length;
      var currentTrackNum = downloadedSoFar + 1;

      await _startDownloadReporting(
        playlist: playlist,
        currentTrackIndex: () => currentTrackNum,
        totalTracks: totalTracks,
      );

      for (var i = 0; i < pendingTracks.length; i++) {
        if (_cancelRequested) break;
        final track = pendingTracks[i];
        final trackNum = downloadedSoFar + i + 1;
        currentTrackNum = trackNum;
        await _lock.refresh(DownloadLock.foregroundOwner);

        final result = await _downloadTrackFile(
          playlist: playlist,
          track: track,
          totalTracks: totalTracks,
          progressTrackIndex: trackNum,
          progressTotalTracks: totalTracks,
          trackLabel: '[$trackNum/$totalTracks] ${track.title}',
          reuseExistingFile: true,
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
          'All $failedCount pending downloads failed; '
          'not stamping "${playlist.name}" as updated',
        );
      } else {
        await _markPlaylistUpdated(playlist);
      }

      await _backfillMissingSponsorBlockSegments(playlist);
      await _writeMetadataForPlaylist(playlist.id);

      // Cleanup .part files and orphaned thumbnails
      try {
        final cleaned = await MetadataService.cleanupPlaylistFolder(
          playlist.outputPath,
        );
        if (cleaned > 0) _log.info('Cleaned up $cleaned leftover files');
      } catch (e) {
        _log.warn('Cleanup failed: $e');
      }

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
      try {
        await MetadataService.cleanupPlaylistFolder(playlist.outputPath);
      } catch (_) {}
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
      await _finishRun(lockAcquired: lockAcquired);
    }
  }

  Future<void> downloadTrack(Playlist playlist, Track track) async {
    if (_isDownloading) return;
    _isDownloading = true;
    _cancelRequested = false;
    _activePlaylist = playlist;
    var lockAcquired = false;
    var totalTracks = 0;
    const progressTrackIndex = 1;
    const progressTotalTracks = 1;

    try {
      lockAcquired = await _lock.acquire(DownloadLock.foregroundOwner);
      if (!lockAcquired) {
        _log.warn('Track download skipped: $lockHeldMessage');
        throw StateError(lockHeldMessage);
      }

      totalTracks = await _db.getTotalTrackCount(playlist.id);
      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return;
      }

      await _startDownloadReporting(
        playlist: playlist,
        currentTrackIndex: () => progressTrackIndex,
        totalTracks: progressTotalTracks,
      );
      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return;
      }

      _log.info('Downloading "${track.title}" from "${playlist.name}"');
      await _db.resetTrackForRedownload(track.id);

      final result = await _downloadTrackFile(
        playlist: playlist,
        track: track,
        totalTracks: totalTracks,
        progressTrackIndex: progressTrackIndex,
        progressTotalTracks: progressTotalTracks,
        trackLabel: '[${track.index}/$totalTracks] ${track.title}',
        reuseExistingFile: false,
      );

      if (result != _TrackDownloadResult.downloaded) {
        if (_cancelRequested) {
          await _writeMetadataForPlaylist(playlist.id);
          _emit(DownloadProgress.idle);
          return;
        }
        throw StateError('Download failed');
      }

      await _markPlaylistUpdated(playlist);
      await _writeMetadataForPlaylist(playlist.id);

      try {
        final cleaned = await MetadataService.cleanupPlaylistFolder(
          playlist.outputPath,
        );
        if (cleaned > 0) _log.info('Cleaned up $cleaned leftover files');
      } catch (e) {
        _log.warn('Cleanup failed: $e');
      }

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
        track.title,
        notificationId: playlist.id,
      );
    } catch (e) {
      if (_cancelRequested) {
        await _db.resetInterruptedTrack(track.id);
        await _writeMetadataForPlaylist(playlist.id);
        _emit(DownloadProgress.idle);
        return;
      }
      _emit(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: 0,
          totalTracks: progressTotalTracks,
          trackProgress: 0,
          status: 'error',
          error: e.toString(),
        ),
      );
      rethrow;
    } finally {
      await _finishRun(lockAcquired: lockAcquired);
    }
  }

  Future<void> _finishRun({required bool lockAcquired}) async {
    _isDownloading = false;
    _activeTrackId = null;
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
    if (lockAcquired) {
      try {
        await _lock.release();
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
  }) async {
    final indexStr = MetadataService.paddedIndex(track.index, totalTracks);

    if (reuseExistingFile) {
      final existingFile = MetadataService.resolveMediaFile(
        playlist.outputPath,
        '${indexStr}_',
      );
      if (existingFile != null) {
        await _db.updateTrackStatus(
          track.id,
          'complete',
          filePath: existingFile,
          isLocalReplacement: false,
        );
        await _metadata.captureChapterMetadata(
          track.copyWith(isLocalReplacement: false),
          playlist.outputPath,
        );
        await _sponsorBlock?.refreshTrackSegments(
          track.copyWith(
            filePath: Value(existingFile),
            status: 'complete',
            isLocalReplacement: false,
          ),
        );
        _log.info(
          '$trackLabel Found existing file: ${existingFile.split('/').last}',
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
    await _db.updateTrackStatus(track.id, 'downloading');

    final outputTemplate =
        '${escapeOutputTemplateLiteral(playlist.outputPath)}/'
        '${indexStr}_%(title)s.%(ext)s';
    final videoUrl = 'https://www.youtube.com/watch?v=${track.videoId}';

    try {
      await _downloadWithRetry(
        url: videoUrl,
        outputPath: playlist.outputPath,
        audioOnly: playlist.audioOnly,
        embedThumbnail: playlist.includeThumbnails,
        outputTemplate: outputTemplate,
        trackLabel: trackLabel,
      );

      if (_cancelRequested) {
        await _db.resetInterruptedTrack(track.id);
        return _TrackDownloadResult.cancelled;
      }

      final actualPath = MetadataService.resolveMediaFile(
        playlist.outputPath,
        '${indexStr}_',
      );
      if (actualPath == null) {
        // yt-dlp reported success but left no playable file (for example a
        // failed merge). Recording a made-up path would present a track that
        // cannot be played and would never be retried.
        const errorMsg = 'Downloaded file not found';
        await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
        _log.error('$trackLabel Failed "${track.title}": $errorMsg');
        return _TrackDownloadResult.failed;
      }
      await _db.updateTrackStatus(track.id, 'complete', filePath: actualPath);
      final updatedTrack = (await _db.getTracksForPlaylist(
        playlist.id,
      )).firstWhere((t) => t.id == track.id, orElse: () => track);
      await _metadata.captureChapterMetadata(updatedTrack, playlist.outputPath);
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
      if (_cancelRequested) {
        await _db.resetInterruptedTrack(track.id);
        _log.info('$trackLabel Interrupted; returned to pending');
        return _TrackDownloadResult.cancelled;
      }
      final errorMsg = _cleanErrorMessage(e);
      await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
      _log.error('$trackLabel Failed "${track.title}": $errorMsg');
      return _TrackDownloadResult.failed;
    } finally {
      if (_activeTrackId == track.id) _activeTrackId = null;
    }
  }

  /// Stops this service's native yt-dlp process and makes its current track
  /// eligible for a future manual or scheduled update. It does not resume it.
  Future<void> cancelActiveDownloads() async {
    if (!_isDownloading) return;
    _cancelRequested = true;

    try {
      await _ytdlp.cancelDownloads();
    } catch (e) {
      _log.warn('Failed to cancel native download: $e');
    }

    final trackId = _activeTrackId;
    if (trackId != null) {
      await _db.resetInterruptedTrack(trackId);
    }

    final playlist = _activePlaylist;
    if (playlist != null) {
      try {
        await MetadataService.cleanupPlaylistFolder(playlist.outputPath);
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

  static const _transientErrorPatterns = [
    'no address associated with hostname',
    'unable to download webpage',
    'http error 5',
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

  Future<void> _downloadWithRetry({
    required String url,
    required String outputPath,
    required bool audioOnly,
    required bool embedThumbnail,
    required String outputTemplate,
    required String trackLabel,
  }) async {
    final downloadSubtitles =
        !audioOnly && await _settings.getDownloadSubtitles();
    final subtitleLanguages =
        downloadSubtitles ? await _settings.getSubtitleLanguages() : 'en';
    const backoffs = [Duration(seconds: 5), Duration(seconds: 15)];
    var attempt = 0;
    while (true) {
      if (_cancelRequested) return;
      try {
        await _ytdlp.download(
          url: url,
          outputPath: outputPath,
          audioOnly: audioOnly,
          embedThumbnail: embedThumbnail,
          downloadSubtitles: downloadSubtitles,
          subtitleLanguages: subtitleLanguages,
          outputTemplate: outputTemplate,
        );
        return;
      } catch (e) {
        final cleaned = _cleanErrorMessage(e);
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
    // Strip a leading "ERROR: [youtube] xxxx: " prefix once.
    cleaned = cleaned.replaceFirst(_ytPrefixPattern, '').trim();
    if (cleaned.isEmpty) cleaned = raw.trim();
    if (cleaned.length > 500) {
      cleaned = '${cleaned.substring(0, 500)}...';
    }
    return cleaned;
  }
}
