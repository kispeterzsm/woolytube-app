import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'log_service.dart';
import 'metadata_service.dart';

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

  final _progressController =
      StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  StreamSubscription? _ytdlpProgressSub;
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  DownloadService(this._db, this._ytdlp, this._log, this._metadata);

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

    _ytdlpProgressSub = _ytdlp.progressStream.listen((event) {
      final progress = (event['progress'] as num?)?.toDouble() ?? 0;
      final status = event['status'] as String? ?? 'downloading';

      if (status == 'downloading' || status == 'starting') {
        _progressController.add(DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: downloadedSoFar + 1,
          totalTracks: totalTracks,
          trackProgress: progress,
          status: 'downloading',
        ));
      }
    });

    try {
      for (var i = 0; i < pendingTracks.length; i++) {
        final track = pendingTracks[i];
        final trackNum = downloadedSoFar + i + 1;

        _progressController.add(DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: trackNum,
          totalTracks: totalTracks,
          trackProgress: 0,
          status: 'downloading',
        ));

        await _db.updateTrackStatus(track.id, 'downloading');

        final indexStr = track.index.toString().padLeft(3, '0');
        final outputTemplate =
            '${playlist.outputPath}/$indexStr - %(title)s.%(ext)s';

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
          final actualPath = _resolveDownloadedFile(
              playlist.outputPath, '$indexStr - ${track.title}');
          await _db.updateTrackStatus(track.id, 'complete',
              filePath: actualPath ??
                  '${playlist.outputPath}/$indexStr - ${track.title}');
          _log.info('[$trackNum/$totalTracks] Downloaded: ${track.title}');

          _progressController.add(DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: trackNum,
            totalTracks: totalTracks,
            trackProgress: 100,
            status: 'downloading',
          ));
        } catch (e) {
          await _db.updateTrackStatus(track.id, 'error');
          _log.error('[$trackNum/$totalTracks] Failed "${track.title}": $e');
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
    } catch (e) {
      _log.error('Playlist download failed: $e');
      await _writeMetadataForPlaylist(playlist.id);
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

  /// Find the actual downloaded file (with extension) matching a base name
  String? _resolveDownloadedFile(String dirPath, String baseName) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;
    for (final entity in dir.listSync()) {
      if (entity is File &&
          p.basenameWithoutExtension(entity.path) == baseName) {
        return entity.path;
      }
    }
    return null;
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
}
