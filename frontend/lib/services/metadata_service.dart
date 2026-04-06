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
  final String? fileName;

  DiscoveredTrack({
    required this.index,
    required this.videoId,
    required this.title,
    this.thumbnailUrl,
    this.durationSeconds,
    required this.status,
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
      String status = 'pending';

      if (dt.fileName != null) {
        final fullPath = p.join(discovered.folderPath, dt.fileName!);
        if (await File(fullPath).exists()) {
          filePath = fullPath;
          status = 'complete';
        }
      }

      tracks.add(TracksCompanion.insert(
        playlistId: playlistId,
        index: dt.index,
        videoId: dt.videoId,
        title: dt.title,
        thumbnailUrl: Value(dt.thumbnailUrl),
        durationSeconds: Value(dt.durationSeconds),
        status: Value(status),
        filePath: Value(filePath),
        downloadedAt: Value(
            status == 'complete' ? DateTime.now() : null),
      ));
    }

    if (tracks.isNotEmpty) {
      await _db.insertTracks(tracks);
    }
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
