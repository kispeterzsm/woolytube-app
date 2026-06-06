import 'dart:io';
import 'package:drift/drift.dart';
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'metadata_service.dart';

class SyncResult {
  final int added;
  final int markedUnavailable;
  final int markedAvailable;
  final int removed;
  final List<Track> replacementConflicts;

  const SyncResult({
    this.added = 0,
    this.markedUnavailable = 0,
    this.markedAvailable = 0,
    this.removed = 0,
    this.replacementConflicts = const [],
  });

  bool get hasChanges =>
      added + markedUnavailable + markedAvailable + removed > 0;

  bool get hasConflicts => replacementConflicts.isNotEmpty;
}

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
      final videoId = entry['id'] as String? ?? '';
      if (videoId.isEmpty) continue;

      final playlistIndex = entry['playlist_index'] as int? ?? (i + 1);
      final reason = _detectUnavailability(entry);

      tracks.add(TracksCompanion.insert(
        playlistId: playlistId,
        index: playlistIndex,
        videoId: videoId,
        title: entry['title'] as String? ?? 'Unknown',
        thumbnailUrl: Value(entry['thumbnail'] as String?),
        durationSeconds: Value(entry['duration'] as int?),
        status: Value(reason != null ? 'unavailable' : 'pending'),
        unavailableReason: Value(reason),
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

  /// Full reconciliation: detect new, unavailable, removed, and re-available tracks.
  Future<SyncResult> syncPlaylist(Playlist playlist) async {
    final info = await _ytdlp.getPlaylistInfo(playlist.url);
    final freshEntries = info['entries'] as List<dynamic>? ?? [];
    final existingTracks = await _db.getTracksForPlaylist(playlist.id);

    final existingByVideoId = <String, Track>{};
    for (final t in existingTracks) {
      existingByVideoId[t.videoId] = t;
    }

    final freshByVideoId = <String, Map<String, dynamic>>{};
    for (var i = 0; i < freshEntries.length; i++) {
      final entry = freshEntries[i] as Map<String, dynamic>;
      final vid = entry['id'] as String? ?? '';
      if (vid.isNotEmpty) freshByVideoId[vid] = entry;
    }

    int added = 0, markedUnavailable = 0, markedAvailable = 0, removed = 0;
    final replacementConflicts = <Track>[];

    // Helper: check if track has a valid file on disk
    bool hasFileOnDisk(Track t) =>
        t.filePath != null && File(t.filePath!).existsSync();

    // Process existing tracks against fresh data
    for (final track in existingTracks) {
      final freshEntry = freshByVideoId[track.videoId];

      if (freshEntry == null) {
        // Video removed from playlist entirely
        if (hasFileOnDisk(track)) {
          // File on disk — keep playable, just note removal
          if (track.unavailableReason != 'removed') {
            await _db.updateTrackOnlineStatus(track.id, 'removed');
            removed++;
          }
        } else if (track.status != 'unavailable' ||
            track.unavailableReason != 'removed') {
          await _db.updateTrackUnavailable(track.id, 'removed');
          removed++;
        }
        continue;
      }

      final reason = _detectUnavailability(freshEntry);
      final freshIndex = freshEntry['playlist_index'] as int? ?? track.index;

      if (reason != null) {
        // Video is unavailable online
        if (hasFileOnDisk(track)) {
          // File on disk — keep playable, just update online status
          if (track.unavailableReason != reason) {
            await _db.updateTrackOnlineStatus(track.id, reason);
          }
          // Don't change index for tracks with files
        } else if (track.status != 'unavailable') {
          await _db.updateTrackUnavailable(track.id, reason,
              newIndex: freshIndex);
          markedUnavailable++;
        }
      } else if (track.unavailableReason != null) {
        // Video is available again (was previously flagged)
        if (hasFileOnDisk(track)) {
          if (track.isLocalReplacement) {
            // Local replacement exists — user needs to decide
            replacementConflicts.add(track);
          }
          // Clear the unavailable reason since video is back
          await _db.updateTrackOnlineStatus(track.id, null);
        } else if (track.status == 'unavailable') {
          await _db.updateTrackAvailable(
            track.id,
            title: freshEntry['title'] as String? ?? 'Unknown',
            thumbnailUrl: freshEntry['thumbnail'] as String?,
            durationSeconds: freshEntry['duration'] as int?,
            newIndex: freshIndex,
          );
        } else {
          // Status is pending/error, reason was set informationally
          await _db.updateTrackOnlineStatus(track.id, null);
        }
        markedAvailable++;
      } else if (freshIndex != track.index && track.status != 'complete') {
        // Index changed and track not yet downloaded — safe to update
        await _db.updateTrackIndex(track.id, freshIndex);
      }
    }

    // Add genuinely new tracks
    final newTracks = <TracksCompanion>[];
    for (var i = 0; i < freshEntries.length; i++) {
      final entry = freshEntries[i] as Map<String, dynamic>;
      final vid = entry['id'] as String? ?? '';
      if (vid.isEmpty || existingByVideoId.containsKey(vid)) continue;

      final reason = _detectUnavailability(entry);
      final playlistIndex = entry['playlist_index'] as int? ?? (i + 1);
      newTracks.add(TracksCompanion.insert(
        playlistId: playlist.id,
        index: playlistIndex,
        videoId: vid,
        title: entry['title'] as String? ?? 'Unknown',
        thumbnailUrl: Value(entry['thumbnail'] as String?),
        durationSeconds: Value(entry['duration'] as int?),
        status: Value(reason != null ? 'unavailable' : 'pending'),
        unavailableReason: Value(reason),
      ));
      added++;
    }

    if (newTracks.isNotEmpty) {
      await _db.insertTracks(newTracks);
    }

    await _writeMetadata(playlist.id);
    return SyncResult(
      added: added,
      markedUnavailable: markedUnavailable,
      markedAvailable: markedAvailable,
      removed: removed,
      replacementConflicts: replacementConflicts,
    );
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

  /// Returns the unavailability reason, or null if the video is available.
  String? _detectUnavailability(Map<String, dynamic> entry) {
    final availability = entry['availability'] as String? ?? '';
    if (availability == 'private') return 'private';
    if (availability == 'needs_auth') return 'needs_auth';
    if (availability == 'premium_only') return 'premium_only';
    if (availability == 'unavailable') return 'unavailable';

    final title = entry['title'] as String? ?? '';
    if (title == '[Private video]') return 'private';
    if (title == '[Deleted video]') return 'deleted';
    if (title == '[Unavailable]') return 'unavailable';

    return null;
  }

  String _sanitizeFolderName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  }
}
