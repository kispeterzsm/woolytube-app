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

    final pendingTracks = await _db.getPendingTracks(playlist.id);
    final totalTracks = await _db.getTotalTrackCount(playlist.id);

    _log.info(
      'Updating "${playlist.name}": ${pendingTracks.length} of $totalTracks tracks to download',
    );

    if (pendingTracks.isEmpty) {
      _isDownloading = false;
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

    try {
      for (var i = 0; i < pendingTracks.length; i++) {
        final track = pendingTracks[i];
        final trackNum = downloadedSoFar + i + 1;
        currentTrackNum = trackNum;

        await _downloadTrackFile(
          playlist: playlist,
          track: track,
          totalTracks: totalTracks,
          progressTrackIndex: trackNum,
          progressTotalTracks: totalTracks,
          trackLabel: '[$trackNum/$totalTracks] ${track.title}',
          reuseExistingFile: true,
        );
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

      await _notifications?.showDownloadComplete(playlist.name);
    } catch (e) {
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

    final totalTracks = await _db.getTotalTrackCount(playlist.id);
    const progressTrackIndex = 1;
    const progressTotalTracks = 1;

    await _startDownloadReporting(
      playlist: playlist,
      currentTrackIndex: () => progressTrackIndex,
      totalTracks: progressTotalTracks,
    );

    try {
      _log.info('Downloading "${track.title}" from "${playlist.name}"');
      await _db.resetTrackForRedownload(track.id);

      final succeeded = await _downloadTrackFile(
        playlist: playlist,
        track: track,
        totalTracks: totalTracks,
        progressTrackIndex: progressTrackIndex,
        progressTotalTracks: progressTotalTracks,
        trackLabel: '[${track.index}/$totalTracks] ${track.title}',
        reuseExistingFile: false,
      );

      if (!succeeded) {
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

  Future<bool> _downloadTrackFile({
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
          isLocalReplacement: true,
        );
        await _sponsorBlock?.refreshTrackSegments(
          track.copyWith(
            filePath: Value(existingFile),
            status: 'complete',
            isLocalReplacement: true,
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
        return true;
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
      return true;
    } catch (e) {
      final errorMsg = _cleanErrorMessage(e);
      await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
      _log.error('$trackLabel Failed "${track.title}": $errorMsg');
      return false;
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
      }
    }
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
