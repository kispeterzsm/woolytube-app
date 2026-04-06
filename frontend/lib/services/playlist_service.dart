import 'dart:io';
import 'package:drift/drift.dart';
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'metadata_service.dart';

class PlaylistService {
  final AppDatabase _db;
  final YtDlpService _ytdlp;
  final MetadataService _metadata;

  PlaylistService(this._db, this._ytdlp, this._metadata);

  Stream<List<Playlist>> watchAllPlaylists() => _db.watchAllPlaylists();

  Future<Playlist> getPlaylist(int id) => _db.getPlaylist(id);

  Future<Map<String, dynamic>> fetchPlaylistInfo(String url) async {
    return await _ytdlp.getPlaylistInfo(url);
  }

  Future<int> addPlaylist({
    required String url,
    required String name,
    String? thumbnailUrl,
    bool audioOnly = false,
    bool autoUpdate = true,
    int updateFrequencyHours = 24,
    bool includeThumbnails = true,
  }) async {
    final basePath = audioOnly
        ? '/storage/emulated/0/Music/WoolyTube'
        : '/storage/emulated/0/Movies/WoolyTube';
    final sanitizedName = _sanitizeFolderName(name);
    final outputPath = '$basePath/$sanitizedName';

    await Directory(outputPath).create(recursive: true);

    final playlistId = await _db.insertPlaylist(PlaylistsCompanion.insert(
      url: url,
      name: name,
      thumbnailUrl: Value(thumbnailUrl),
      audioOnly: Value(audioOnly),
      autoUpdate: Value(autoUpdate),
      updateFrequencyHours: Value(updateFrequencyHours),
      includeThumbnails: Value(includeThumbnails),
      createdAt: DateTime.now(),
      outputPath: outputPath,
    ));

    return playlistId;
  }

  Future<void> populateTracksFromInfo(
      int playlistId, Map<String, dynamic> playlistInfo) async {
    final entries = playlistInfo['entries'] as List<dynamic>? ?? [];
    final tracks = <TracksCompanion>[];

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i] as Map<String, dynamic>;
      tracks.add(TracksCompanion.insert(
        playlistId: playlistId,
        index: i + 1,
        videoId: entry['id'] as String? ?? '',
        title: entry['title'] as String? ?? 'Unknown',
        thumbnailUrl: Value(entry['thumbnail'] as String?),
        durationSeconds: Value(entry['duration'] as int?),
      ));
    }

    if (tracks.isNotEmpty) {
      await _db.insertTracks(tracks);
    }

    await _writeMetadata(playlistId);
  }

  Future<void> updatePlaylistSettings({
    required int id,
    String? name,
    bool? audioOnly,
    bool? autoUpdate,
    int? updateFrequencyHours,
    bool? includeThumbnails,
  }) async {
    final playlist = await _db.getPlaylist(id);

    String outputPath = playlist.outputPath;
    if (audioOnly != null && audioOnly != playlist.audioOnly) {
      final basePath = audioOnly
          ? '/storage/emulated/0/Music/WoolyTube'
          : '/storage/emulated/0/Movies/WoolyTube';
      final folderName = _sanitizeFolderName(name ?? playlist.name);
      outputPath = '$basePath/$folderName';
      await Directory(outputPath).create(recursive: true);
    }

    await _db.updatePlaylist(PlaylistsCompanion(
      id: Value(id),
      url: Value(playlist.url),
      name: Value(name ?? playlist.name),
      thumbnailUrl: Value(playlist.thumbnailUrl),
      thumbnailPath: Value(playlist.thumbnailPath),
      audioOnly: Value(audioOnly ?? playlist.audioOnly),
      autoUpdate: Value(autoUpdate ?? playlist.autoUpdate),
      updateFrequencyHours:
          Value(updateFrequencyHours ?? playlist.updateFrequencyHours),
      includeThumbnails:
          Value(includeThumbnails ?? playlist.includeThumbnails),
      lastUpdated: Value(playlist.lastUpdated),
      createdAt: Value(playlist.createdAt),
      outputPath: Value(outputPath),
    ));

    await _writeMetadata(id);
  }

  Future<void> deletePlaylist(int id) async {
    await _db.deletePlaylist(id);
  }

  Future<List<Track>> getPendingTracks(int playlistId) =>
      _db.getPendingTracks(playlistId);

  Future<List<Track>> getTracksForPlaylist(int playlistId) =>
      _db.getTracksForPlaylist(playlistId);

  Stream<List<Track>> watchTracksForPlaylist(int playlistId) =>
      _db.watchTracksForPlaylist(playlistId);

  Future<int> getDownloadedCount(int playlistId) =>
      _db.getDownloadedTrackCount(playlistId);

  Future<int> getTotalCount(int playlistId) =>
      _db.getTotalTrackCount(playlistId);

  Future<void> _writeMetadata(int playlistId) async {
    try {
      final playlist = await _db.getPlaylist(playlistId);
      final tracks = await _db.getTracksForPlaylist(playlistId);
      await _metadata.writeMetadata(playlist, tracks);
    } catch (_) {
      // Non-critical — don't block playlist operations
    }
  }

  String _sanitizeFolderName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  }
}
