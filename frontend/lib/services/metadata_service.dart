import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';

class DiscoveredTrack {
  final int index;
  final String videoId;
  final String title;
  final String? thumbnailUrl;
  final int? durationSeconds;
  final String status;
  final String? unavailableReason;
  final bool isLocalReplacement;
  final String? fileName;

  DiscoveredTrack({
    required this.index,
    required this.videoId,
    required this.title,
    this.thumbnailUrl,
    this.durationSeconds,
    required this.status,
    this.unavailableReason,
    this.isLocalReplacement = false,
    this.fileName,
  });
}

class DiscoveredPlaylist {
  final String folderPath;
  final String url;
  final String name;
  final String? thumbnailUrl;
  final bool audioOnly;
  final bool autoUpdate;
  final int updateFrequencyHours;
  final bool includeThumbnails;
  final DateTime? lastUpdated;
  final DateTime createdAt;
  final List<DiscoveredTrack> tracks;

  DiscoveredPlaylist({
    required this.folderPath,
    required this.url,
    required this.name,
    this.thumbnailUrl,
    required this.audioOnly,
    required this.autoUpdate,
    required this.updateFrequencyHours,
    required this.includeThumbnails,
    this.lastUpdated,
    required this.createdAt,
    required this.tracks,
  });
}

const _metaFileName = 'woolytube_meta.json';

class MetadataService {
  final AppDatabase _db;

  MetadataService(this._db);

  /// Writes playlist metadata as JSON sidecar file in the playlist folder.
  Future<void> writeMetadata(Playlist playlist, List<Track> tracks) async {
    final dir = Directory(playlist.outputPath);
    if (!await dir.exists()) return;

    final data = {
      'version': 1,
      'playlist': {
        'url': playlist.url,
        'name': playlist.name,
        'thumbnailUrl': playlist.thumbnailUrl,
        'audioOnly': playlist.audioOnly,
        'autoUpdate': playlist.autoUpdate,
        'updateFrequencyHours': playlist.updateFrequencyHours,
        'includeThumbnails': playlist.includeThumbnails,
        'lastUpdated': playlist.lastUpdated?.toUtc().toIso8601String(),
        'createdAt': playlist.createdAt.toUtc().toIso8601String(),
      },
      'tracks': tracks.map((t) => {
        'index': t.index,
        'videoId': t.videoId,
        'title': t.title,
        'thumbnailUrl': t.thumbnailUrl,
        'durationSeconds': t.durationSeconds,
        'status': t.status,
        'unavailableReason': t.unavailableReason,
        'isLocalReplacement': t.isLocalReplacement,
        'fileName': t.filePath != null ? p.basename(t.filePath!) : null,
      }).toList(),
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    final targetFile = File(p.join(playlist.outputPath, _metaFileName));
    final tmpFile = File('${targetFile.path}.tmp');

    await tmpFile.writeAsString(jsonStr);
    await tmpFile.rename(targetFile.path);
  }

  /// Scans public WoolyTube folders for playlist metadata files.
  Future<List<DiscoveredPlaylist>> scanForPlaylists() async {
    final discovered = <DiscoveredPlaylist>[];
    final scanDirs = [
      '/storage/emulated/0/Music/WoolyTube',
      '/storage/emulated/0/Movies/WoolyTube',
    ];

    for (final scanPath in scanDirs) {
      final dir = Directory(scanPath);
      if (!await dir.exists()) continue;

      await for (final entity in dir.list()) {
        if (entity is! Directory) continue;
        final metaFile = File(p.join(entity.path, _metaFileName));
        if (!await metaFile.exists()) continue;

        try {
          final json = jsonDecode(await metaFile.readAsString())
              as Map<String, dynamic>;
          final parsed = _parseMetadata(entity.path, json);
          if (parsed != null) discovered.add(parsed);
        } catch (_) {
          // Skip malformed JSON
        }
      }
    }

    return discovered;
  }

  /// Returns only playlists not already in the database (matched by URL).
  Future<List<DiscoveredPlaylist>> findUnimportedPlaylists() async {
    final discovered = await scanForPlaylists();
    final result = <DiscoveredPlaylist>[];

    for (final dp in discovered) {
      final existing = await _db.getPlaylistByUrl(dp.url);
      if (existing == null) result.add(dp);
    }

    return result;
  }

  /// Reconciles database track statuses with actual files on disk.
  /// Fixes mismatches where files exist but DB says pending, or vice versa.
  Future<int> reconcilePlaylist(Playlist playlist) async {
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    final dir = Directory(playlist.outputPath);
    if (!await dir.exists()) return 0;

    int fixed = 0;
    for (final track in tracks) {
      final indexPrefix =
          '${track.index.toString().padLeft(3, '0')}_';
      final fileOnDisk = resolveMediaFile(playlist.outputPath, indexPrefix);

      if (fileOnDisk != null &&
          (track.status == 'pending' ||
              track.status == 'error' ||
              track.status == 'unavailable')) {
        // File exists but DB says not downloaded — fix it
        await _db.updateTrackStatus(track.id, 'complete',
            filePath: fileOnDisk);
        fixed++;
      } else if (fileOnDisk == null && track.status == 'complete') {
        // DB says downloaded but file is gone — mark for re-download
        await _db.updateTrackStatus(track.id, 'pending');
        fixed++;
      }
    }

    // Cleanup leftover .part files, .ytdl files, and orphaned thumbnails
    final cleaned = await cleanupPlaylistFolder(playlist.outputPath);
    fixed += cleaned;

    return fixed;
  }

  /// Deletes .part files, .ytdl files, and orphaned image files from the playlist folder.
  /// Returns the number of files deleted.
  static Future<int> cleanupPlaylistFolder(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;

    int deleted = 0;
    const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};
    final partPattern = RegExp(r'\.part(-Frag\d+)?$');

    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final fileName = p.basename(entity.path);
      final ext = p.extension(entity.path).toLowerCase();

      // Delete .part files (incomplete yt-dlp downloads)
      if (partPattern.hasMatch(fileName)) {
        await entity.delete();
        deleted++;
        continue;
      }

      // Delete .ytdl files (yt-dlp download state files)
      if (ext == '.ytdl') {
        await entity.delete();
        deleted++;
        continue;
      }

      // Delete .tmp files (metadata writing leftovers)
      if (fileName.endsWith('.tmp')) {
        await entity.delete();
        deleted++;
        continue;
      }

      // Delete orphaned image/thumbnail files (not the metadata JSON)
      if (imageExtensions.contains(ext) && fileName != _metaFileName) {
        await entity.delete();
        deleted++;
        continue;
      }
    }

    return deleted;
  }

  /// Find a media file in [dirPath] matching an index prefix (e.g. "001_").
  static String? resolveMediaFile(String dirPath, String indexPrefix) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    const mediaExtensions = {
      '.m4a', '.mp3', '.opus', '.ogg', '.flac', '.wav',
      '.mp4', '.mkv', '.webm', '.avi', '.mov',
    };

    for (final entity in dir.listSync()) {
      if (entity is File) {
        final fileName = p.basename(entity.path);
        final ext = p.extension(entity.path).toLowerCase();
        if (fileName.startsWith(indexPrefix) && mediaExtensions.contains(ext)) {
          return entity.path;
        }
      }
    }
    return null;
  }

  /// Imports a discovered playlist into the database.
  Future<void> importPlaylist(DiscoveredPlaylist discovered) async {
    final playlistId = await _db.insertPlaylist(PlaylistsCompanion.insert(
      url: discovered.url,
      name: discovered.name,
      thumbnailUrl: Value(discovered.thumbnailUrl),
      audioOnly: Value(discovered.audioOnly),
      autoUpdate: Value(discovered.autoUpdate),
      updateFrequencyHours: Value(discovered.updateFrequencyHours),
      includeThumbnails: Value(discovered.includeThumbnails),
      lastUpdated: Value(discovered.lastUpdated),
      createdAt: discovered.createdAt,
      outputPath: discovered.folderPath,
    ));

    final tracks = <TracksCompanion>[];
    for (final dt in discovered.tracks) {
      String? filePath;
      String status = dt.status;

      if (dt.fileName != null) {
        final fullPath = p.join(discovered.folderPath, dt.fileName!);
        if (await File(fullPath).exists()) {
          filePath = fullPath;
          status = 'complete';
        } else if (status == 'complete') {
          status = 'pending'; // File gone, re-download
        }
      }

      // Preserve unavailable status from metadata
      if (status != 'complete' && status != 'unavailable') {
        status = 'pending';
      }

      tracks.add(TracksCompanion.insert(
        playlistId: playlistId,
        index: dt.index,
        videoId: dt.videoId,
        title: dt.title,
        thumbnailUrl: Value(dt.thumbnailUrl),
        durationSeconds: Value(dt.durationSeconds),
        status: Value(status),
        unavailableReason: Value(dt.unavailableReason),
        isLocalReplacement: Value(dt.isLocalReplacement),
        filePath: Value(filePath),
        downloadedAt: Value(
            status == 'complete' ? DateTime.now() : null),
      ));
    }

    if (tracks.isNotEmpty) {
      await _db.insertTracks(tracks);
    }

    // Reconcile with actual files on disk (catches mismatches from stale JSON)
    final playlist = await _db.getPlaylist(playlistId);
    await reconcilePlaylist(playlist);
  }

  DiscoveredPlaylist? _parseMetadata(
      String folderPath, Map<String, dynamic> json) {
    final pl = json['playlist'] as Map<String, dynamic>?;
    if (pl == null) return null;

    final url = pl['url'] as String?;
    final name = pl['name'] as String?;
    if (url == null || name == null) return null;

    final tracksJson = json['tracks'] as List<dynamic>? ?? [];
    final tracks = tracksJson
        .map((t) {
          final m = t as Map<String, dynamic>;
          return DiscoveredTrack(
            index: m['index'] as int? ?? 0,
            videoId: m['videoId'] as String? ?? '',
            title: m['title'] as String? ?? 'Unknown',
            thumbnailUrl: m['thumbnailUrl'] as String?,
            durationSeconds: m['durationSeconds'] as int?,
            status: m['status'] as String? ?? 'pending',
            unavailableReason: m['unavailableReason'] as String?,
            isLocalReplacement: m['isLocalReplacement'] as bool? ?? false,
            fileName: m['fileName'] as String?,
          );
        })
        .toList();

    return DiscoveredPlaylist(
      folderPath: folderPath,
      url: url,
      name: name,
      thumbnailUrl: pl['thumbnailUrl'] as String?,
      audioOnly: pl['audioOnly'] as bool? ?? false,
      autoUpdate: pl['autoUpdate'] as bool? ?? true,
      updateFrequencyHours: pl['updateFrequencyHours'] as int? ?? 24,
      includeThumbnails: pl['includeThumbnails'] as bool? ?? true,
      lastUpdated: pl['lastUpdated'] != null
          ? DateTime.tryParse(pl['lastUpdated'] as String)
          : null,
      createdAt: pl['createdAt'] != null
          ? DateTime.tryParse(pl['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      tracks: tracks,
    );
  }
}
