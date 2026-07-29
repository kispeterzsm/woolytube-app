import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../database/database.dart';
import 'ytdlp_service.dart';
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

enum _TrackDownloadResult { downloaded, reused, failed, cancelled }

class DownloadService {
  final AppDatabase _db;
  final YtDlpService _ytdlp;
  final LogService _log;
  final MetadataService _metadata;
  final DownloadNotificationService? _notifications;
  final SponsorBlockService? _sponsorBlock;

  final _progressController = StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  StreamSubscription? _ytdlpProgressSub;
  bool _isDownloading = false;
  bool _cancelRequested = false;
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
  ]);

  static Future<bool> acquireLock() async {
    final dir = await getApplicationDocumentsDirectory();
    final lockFile = File('${dir.path}/download.lock');
    if (lockFile.existsSync()) {
      final modified = lockFile.lastModifiedSync();
      if (DateTime.now().difference(modified).inHours < 1) return false;
    }
    lockFile.writeAsStringSync(DateTime.now().toIso8601String());
    return true;
  }

  static Future<void> releaseLock() async {
    final dir = await getApplicationDocumentsDirectory();
    final lockFile = File('${dir.path}/download.lock');
    if (lockFile.existsSync()) lockFile.deleteSync();
  }

  Future<void> downloadPlaylist(Playlist playlist) async {
    if (_isDownloading) return;
    _isDownloading = true;
    _cancelRequested = false;
    _activePlaylist = playlist;
    var totalTracks = 0;
    var downloadedCount = 0;

    try {
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
        _progressController.add(DownloadProgress.idle);
        return;
      }

      if (pendingTracks.isEmpty) {
        // A successful check with no pending work still starts the next
        // auto-update interval. Without this, an unchanged playlist remains
        // overdue and gets checked on every background-worker run.
        await _markPlaylistUpdated(playlist);
        await _backfillMissingSponsorBlockSegments(playlist);
        await _writeMetadataForPlaylist(playlist.id);
        _progressController.add(
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

        final result = await _downloadTrackFile(
          playlist: playlist,
          track: track,
          totalTracks: totalTracks,
          progressTrackIndex: trackNum,
          progressTotalTracks: totalTracks,
          trackLabel: '[$trackNum/$totalTracks] ${track.title}',
          reuseExistingFile: true,
        );
        if (result == _TrackDownloadResult.downloaded) downloadedCount++;
      }

      if (_cancelRequested) {
        _log.info('Playlist download stopped');
        await _writeMetadataForPlaylist(playlist.id);
        _progressController.add(DownloadProgress.idle);
        return;
      }

      _progressController.add(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: totalTracks,
          totalTracks: totalTracks,
          trackProgress: 100,
          status: 'complete',
        ),
      );

      await _markPlaylistUpdated(playlist);

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

      if (downloadedCount > 0) {
        await _notifications?.showDownloadComplete(
          playlist.name,
          downloadedCount: downloadedCount,
        );
      }
    } catch (e) {
      if (_cancelRequested) {
        _log.info('Playlist download stopped');
        await _writeMetadataForPlaylist(playlist.id);
        _progressController.add(DownloadProgress.idle);
        return;
      }
      _log.error('Playlist download failed: $e');
      await _writeMetadataForPlaylist(playlist.id);
      try {
        await MetadataService.cleanupPlaylistFolder(playlist.outputPath);
      } catch (_) {}
      _progressController.add(
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
      _isDownloading = false;
      _activeTrackId = null;
      _activePlaylist = null;
      _ytdlpProgressSub?.cancel();
      _ytdlpProgressSub = null;
      try {
        await _ytdlp.stopDownloadService();
      } catch (e) {
        _log.warn('Failed to stop download foreground service: $e');
      }
    }
  }

  Future<void> downloadTrack(Playlist playlist, Track track) async {
    if (_isDownloading) return;
    _isDownloading = true;
    _cancelRequested = false;
    _activePlaylist = playlist;
    var totalTracks = 0;
    const progressTrackIndex = 1;
    const progressTotalTracks = 1;

    try {
      totalTracks = await _db.getTotalTrackCount(playlist.id);
      if (_cancelRequested) {
        _progressController.add(DownloadProgress.idle);
        return;
      }

      await _startDownloadReporting(
        playlist: playlist,
        currentTrackIndex: () => progressTrackIndex,
        totalTracks: progressTotalTracks,
      );
      if (_cancelRequested) {
        _progressController.add(DownloadProgress.idle);
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
          _progressController.add(DownloadProgress.idle);
          return;
        }
        throw StateError('Download failed');
      }

      _progressController.add(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: progressTrackIndex,
          totalTracks: progressTotalTracks,
          trackProgress: 100,
          status: 'complete',
        ),
      );

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

      await _notifications?.showDownloadComplete(track.title);
    } catch (e) {
      if (_cancelRequested) {
        await _db.resetInterruptedTrack(track.id);
        await _writeMetadataForPlaylist(playlist.id);
        _progressController.add(DownloadProgress.idle);
        return;
      }
      _progressController.add(
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
      _isDownloading = false;
      _activeTrackId = null;
      _activePlaylist = null;
      _ytdlpProgressSub?.cancel();
      _ytdlpProgressSub = null;
      try {
        await _ytdlp.stopDownloadService();
      } catch (e) {
        _log.warn('Failed to stop download foreground service: $e');
      }
    }
  }

  Future<void> _startDownloadReporting({
    required Playlist playlist,
    required int Function() currentTrackIndex,
    required int totalTracks,
  }) async {
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
        _progressController.add(
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
        _progressController.add(
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

    _progressController.add(
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
        '${playlist.outputPath}/${indexStr}_%(title)s.%(ext)s';
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
      await _db.updateTrackStatus(
        track.id,
        'complete',
        filePath:
            actualPath ?? '${playlist.outputPath}/${indexStr}_${track.title}',
      );
      final updatedTrack = (await _db.getTracksForPlaylist(
        playlist.id,
      )).firstWhere((t) => t.id == track.id, orElse: () => track);
      await _sponsorBlock?.refreshTrackSegments(updatedTrack);
      _log.info('$trackLabel Downloaded: ${track.title}');

      _progressController.add(
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

  Future<void> _markPlaylistUpdated(Playlist playlist) async {
    await _db.updatePlaylist(
      PlaylistsCompanion(
        id: Value(playlist.id),
        url: Value(playlist.url),
        name: Value(playlist.name),
        thumbnailUrl: Value(playlist.thumbnailUrl),
        thumbnailPath: Value(playlist.thumbnailPath),
        audioOnly: Value(playlist.audioOnly),
        autoUpdate: Value(playlist.autoUpdate),
        updateFrequencyHours: Value(playlist.updateFrequencyHours),
        includeThumbnails: Value(playlist.includeThumbnails),
        sponsorBlockEnabled: Value(playlist.sponsorBlockEnabled),
        sponsorBlockCategories: Value(playlist.sponsorBlockCategories),
        sponsorBlockCategoryActions: Value(
          playlist.sponsorBlockCategoryActions,
        ),
        lastUpdated: Value(DateTime.now()),
        createdAt: Value(playlist.createdAt),
        outputPath: Value(playlist.outputPath),
      ),
    );
  }

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

  Future<void> _backfillMissingSponsorBlockSegments(Playlist playlist) async {
    if (_sponsorBlock == null || !playlist.sponsorBlockEnabled) return;

    final now = DateTime.now();
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    var refreshed = 0;
    var repaired = 0;
    for (final track in tracks) {
      if (track.status != 'complete' ||
          track.filePath == null ||
          track.unavailableReason != null) {
        continue;
      }

      final existingSegments = await _db.getSegmentsForTrack(track.id);
      final hasRemoteState = existingSegments.any(
        (segment) =>
            segment.source == 'sponsorblock' ||
            segment.source == 'override' ||
            segment.source == 'hidden',
      );
      if (hasRemoteState) continue;
      if (!_shouldRetryMissingSponsorBlock(track, now)) continue;

      try {
        final segments = await _sponsorBlock.fetchSegments(
          track.videoId,
          track.id,
        );

        if (track.isLocalReplacement && segments.isNotEmpty) {
          await _db.updateTrackLocalReplacement(track.id, false);
          repaired++;
        }
        await _db.replaceRemoteSponsorBlockSegments(track.id, segments);
        await _db.updateTrackSponsorBlockCheckedAt(track.id, now);
        refreshed++;
      } catch (e) {
        _log.warn('SponsorBlock backfill failed for ${track.videoId}: $e');
      }
    }

    if (refreshed > 0) {
      final repairText =
          repaired > 0 ? ', repaired $repaired reused downloads' : '';
      _log.info('SponsorBlock: backfilled $refreshed tracks$repairText');
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
