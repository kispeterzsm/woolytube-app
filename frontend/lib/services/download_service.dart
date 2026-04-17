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

  final _progressController =
      StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  StreamSubscription? _ytdlpProgressSub;
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  DownloadService(this._db, this._ytdlp, this._log, this._metadata,
      [this._notifications]);

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

    _log.info('Updating "${playlist.name}": ${pendingTracks.length} of $totalTracks tracks to download');

    if (pendingTracks.isEmpty) {
      _isDownloading = false;
      _progressController.add(DownloadProgress(
        playlistId: playlist.id,
        currentTrackIndex: totalTracks,
        totalTracks: totalTracks,
        trackProgress: 100,
        status: 'complete',
      ));
      return;
    }

    final downloadedSoFar = totalTracks - pendingTracks.length;
    var currentTrackNum = downloadedSoFar + 1;

    _ytdlpProgressSub = _ytdlp.progressStream.listen((event) {
      final progress = (event['progress'] as num?)?.toDouble() ?? 0;
      final status = event['status'] as String? ?? 'downloading';

      if (status == 'downloading' || status == 'starting') {
        _progressController.add(DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: currentTrackNum,
          totalTracks: totalTracks,
          trackProgress: progress,
          status: 'downloading',
        ));
        _notifications?.showDownloadProgress(
          playlistName: playlist.name,
          currentTrack: currentTrackNum,
          totalTracks: totalTracks,
          progressPercent: progress.round(),
        );
      }
    });

    try {
      for (var i = 0; i < pendingTracks.length; i++) {
        final track = pendingTracks[i];
        final trackNum = downloadedSoFar + i + 1;
        currentTrackNum = trackNum;

        final indexStr = MetadataService.paddedIndex(track.index, totalTracks);

        // Check if a file already exists on disk for this track
        final existingFile = MetadataService.resolveMediaFile(
            playlist.outputPath, '${indexStr}_');
        if (existingFile != null) {
          await _db.updateTrackStatus(track.id, 'complete',
              filePath: existingFile, isLocalReplacement: true);
          _log.info(
              '[$trackNum/$totalTracks] Found existing file: ${existingFile.split('/').last}');
          _progressController.add(DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: trackNum,
            totalTracks: totalTracks,
            trackProgress: 100,
            status: 'downloading',
          ));
          continue;
        }

        _progressController.add(DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: currentTrackNum,
          totalTracks: totalTracks,
          trackProgress: 0,
          status: 'downloading',
        ));

        await _db.updateTrackStatus(track.id, 'downloading');

        final outputTemplate =
            '${playlist.outputPath}/${indexStr}_%(title)s.%(ext)s';

        try {
          final videoUrl =
              'https://www.youtube.com/watch?v=${track.videoId}';

          await _ytdlp.download(
            url: videoUrl,
            outputPath: playlist.outputPath,
            audioOnly: playlist.audioOnly,
            embedThumbnail: playlist.includeThumbnails,
            outputTemplate: outputTemplate,
          );

          // Resolve actual file path (yt-dlp adds extension)
          final actualPath = MetadataService.resolveMediaFile(
              playlist.outputPath, '${indexStr}_');
          await _db.updateTrackStatus(track.id, 'complete',
              filePath: actualPath ??
                  '${playlist.outputPath}/${indexStr}_${track.title}');
          _log.info('[$trackNum/$totalTracks] Downloaded: ${track.title}');

          _progressController.add(DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: trackNum,
            totalTracks: totalTracks,
            trackProgress: 100,
            status: 'downloading',
          ));
        } catch (e) {
          final errorMsg = _cleanErrorMessage(e);
          await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
          _log.error(
              '[$trackNum/$totalTracks] Failed "${track.title}": $errorMsg');
        }
      }

      _progressController.add(DownloadProgress(
        playlistId: playlist.id,
        currentTrackIndex: totalTracks,
        totalTracks: totalTracks,
        trackProgress: 100,
        status: 'complete',
      ));

      await _db.updatePlaylist(PlaylistsCompanion(
        id: Value(playlist.id),
        url: Value(playlist.url),
        name: Value(playlist.name),
        thumbnailUrl: Value(playlist.thumbnailUrl),
        thumbnailPath: Value(playlist.thumbnailPath),
        audioOnly: Value(playlist.audioOnly),
        autoUpdate: Value(playlist.autoUpdate),
        updateFrequencyHours: Value(playlist.updateFrequencyHours),
        includeThumbnails: Value(playlist.includeThumbnails),
        lastUpdated: Value(DateTime.now()),
        createdAt: Value(playlist.createdAt),
        outputPath: Value(playlist.outputPath),
      ));

      await _writeMetadataForPlaylist(playlist.id);

      // Cleanup .part files and orphaned thumbnails
      try {
        final cleaned =
            await MetadataService.cleanupPlaylistFolder(playlist.outputPath);
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
      await _notifications?.cancel();
      _progressController.add(DownloadProgress(
        playlistId: playlist.id,
        currentTrackIndex: 0,
        totalTracks: totalTracks,
        trackProgress: 0,
        status: 'error',
        error: e.toString(),
      ));
    } finally {
      _isDownloading = false;
      _ytdlpProgressSub?.cancel();
      _ytdlpProgressSub = null;
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
  static final _ytPrefixPattern =
      RegExp(r'^\s*(?:ERROR:\s*)?(?:\[[^\]]+\]\s*[^:]*:\s*)?');

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
