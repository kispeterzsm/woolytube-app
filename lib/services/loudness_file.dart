/// `.woolytube_info/loudness.json`: the loudness measurements of a
/// playlist's files ("Even out volume" and plane mode), so a reinstall or
/// another phone does not have to measure every song again.
///
/// Measurements are keyed by video id with the file's size, not by the
/// database's track id or the file's modification time: a reinstall gives
/// tracks new ids, and copying the folders to a PC and back usually changes
/// the time. A measurement is only taken back for a file of exactly that
/// size, and never replaces one the app already has.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import '../database/database.dart';
import 'info_files.dart';
import 'library_layout.dart';
import 'metadata_service.dart';

/// Format version of the file. A file of a newer version is read where it
/// can be but never overwritten.
const loudnessFileVersion = 1;

/// One file's measurement as the loudness file stores it.
class LoudnessFileEntry {
  const LoudnessFileEntry({
    required this.videoId,
    required this.fileName,
    required this.size,
    required this.measuredAt,
    this.integratedLufs,
    this.cabinLufs,
    this.peakDb,
  });

  final String videoId;

  /// The media file's name when it was measured; tells two files of one
  /// video apart.
  final String? fileName;
  final int size;
  final double? integratedLufs;
  final double? cabinLufs;
  final double? peakDb;
  final DateTime measuredAt;

  Map<String, dynamic> toJson({required bool withVideoId}) => {
    if (withVideoId) 'videoId': videoId,
    if (fileName != null) 'file': fileName,
    'size': size,
    if (integratedLufs != null) 'integrated': integratedLufs,
    if (cabinLufs != null) 'cabin': cabinLufs,
    if (peakDb != null) 'peak': peakDb,
    'measuredAt': measuredAt.toUtc().toIso8601String(),
  };

  /// Reads the entry stored under [key]; null when it is unusable.
  static LoudnessFileEntry? fromJson(String key, Object? json) {
    if (json is! Map) return null;
    final size = json['size'];
    if (size is! num || size <= 0) return null;
    double? number(String name) {
      final value = json[name];
      return value is num && value.isFinite ? value.toDouble() : null;
    }

    final videoId = json['videoId'];
    final file = json['file'];
    return LoudnessFileEntry(
      videoId: videoId is String && videoId.isNotEmpty ? videoId : key,
      fileName: file is String && file.isNotEmpty ? file : null,
      size: size.toInt(),
      integratedLufs: number('integrated'),
      cabinLufs: number('cabin'),
      peakDb: number('peak'),
      measuredAt:
          DateTime.tryParse('${json['measuredAt']}')?.toLocal() ??
          DateTime.now(),
    );
  }

  static LoudnessFileEntry fromMeasurement(
    String videoId,
    LoudnessMeasurement row,
  ) => LoudnessFileEntry(
    videoId: videoId,
    fileName: p.basename(row.filePath),
    size: row.fileSize,
    integratedLufs: row.integratedLufs,
    cabinLufs: row.cabinLufs,
    peakDb: row.peakDb,
    measuredAt: row.measuredAt,
  );
}

/// The file's JSON for [entries]. Each is stored under its video id; a
/// second file of the same video under `<videoId>/<file name>`.
Map<String, dynamic> loudnessFileJson(List<LoudnessFileEntry> entries) {
  final sorted = [...entries]..sort((a, b) {
    final byId = a.videoId.compareTo(b.videoId);
    return byId != 0 ? byId : (a.fileName ?? '').compareTo(b.fileName ?? '');
  });
  final files = <String, dynamic>{};
  for (final entry in sorted) {
    var key = entry.videoId;
    if (files.containsKey(key)) key = '$key/${entry.fileName ?? entry.size}';
    var n = 2;
    final base = key;
    while (files.containsKey(key)) {
      key = '$base#${n++}';
    }
    files[key] = entry.toJson(withVideoId: key != entry.videoId);
  }
  return {'app': 'WoolyTube', 'version': loudnessFileVersion, 'files': files};
}

/// The entries of a loudness file's [json]. Broken entries are skipped.
List<LoudnessFileEntry> loudnessEntriesFromJson(Object? json) {
  if (json is! Map) return const [];
  final files = json['files'];
  if (files is! Map) return const [];
  return [
    for (final MapEntry(:key, :value) in files.entries)
      if (LoudnessFileEntry.fromJson('$key', value) case final entry?) entry,
  ];
}

int _versionOf(Map<String, dynamic> json) =>
    (json['version'] as num?)?.toInt() ?? 1;

/// The entries stored in [playlistPath]'s loudness file.
Future<List<LoudnessFileEntry>> readLoudnessFile(String playlistPath) async =>
    loudnessEntriesFromJson(
      await readInfoJson(LibraryLayout.loudnessJsonPath(playlistPath)),
    );

/// Writes the loudness file of [playlist] from the measurements in [db].
///
/// Entries already in the file for songs of the playlist that have no
/// measurement here yet are kept (a reinstall that has not taken them back
/// yet must not drop them); entries of songs no longer in the playlist go.
/// Unchanged content is not rewritten, a file a newer app wrote is kept,
/// and nothing is written into a playlist folder that is gone. Returns
/// whether it wrote.
Future<bool> writeLoudnessFile(
  AppDatabase db,
  Playlist playlist, {
  List<Track>? tracks,
  Map<int, LoudnessMeasurement>? measurements,
}) async {
  final folder = playlist.outputPath;
  if (!await Directory(folder).exists()) return false;
  final path = LibraryLayout.loudnessJsonPath(folder);
  final existing = await readInfoJson(path);
  if (existing != null && _versionOf(existing) > loudnessFileVersion) {
    return false;
  }
  final songs = tracks ?? await db.getTracksForPlaylist(playlist.id);
  final rows = measurements ?? await db.getLoudnessMeasurements();
  final entries = <LoudnessFileEntry>[];
  final measuredVideos = <String>{};
  for (final track in songs) {
    final row = rows[track.id];
    if (row == null) continue;
    entries.add(LoudnessFileEntry.fromMeasurement(track.videoId, row));
    measuredVideos.add(track.videoId);
  }
  final videos = {for (final track in songs) track.videoId};
  for (final entry in loudnessEntriesFromJson(existing)) {
    if (videos.contains(entry.videoId) &&
        !measuredVideos.contains(entry.videoId)) {
      entries.add(entry);
    }
  }
  if (entries.isEmpty && existing == null) return false;
  return writeInfoFile(path, jsonEncode(loudnessFileJson(entries)));
}

/// Takes the measurements in [playlist]'s loudness file back for its songs
/// that have none: only for a file of exactly the stored size, and never
/// replacing a measurement the app has. The file's current modification
/// time is stored with it, since copying usually changes it. Returns how
/// many were taken back.
Future<int> seedLoudnessFromFolder(AppDatabase db, Playlist playlist) async {
  final entries = await readLoudnessFile(playlist.outputPath);
  if (entries.isEmpty) return 0;
  final byVideo = <String, List<LoudnessFileEntry>>{};
  for (final entry in entries) {
    byVideo.putIfAbsent(entry.videoId, () => []).add(entry);
  }
  final measured = await db.getLoudnessMeasurements();
  var seeded = 0;
  for (final track in await db.getTracksForPlaylist(playlist.id)) {
    final candidates = byVideo[track.videoId];
    final stored = track.filePath;
    if (candidates == null ||
        stored == null ||
        measured.containsKey(track.id)) {
      continue;
    }
    final path = MetadataService.resolveStoredFilePath(stored);
    if (path == null) continue;
    final FileStat stat;
    try {
      stat = await File(path).stat();
    } catch (_) {
      continue;
    }
    if (stat.type != FileSystemEntityType.file) continue;
    final name = p.basename(path);
    final sameSize = candidates.where((e) => e.size == stat.size).toList();
    if (sameSize.isEmpty) continue;
    final entry = sameSize.firstWhere(
      (e) => e.fileName == name,
      orElse: () => sameSize.first,
    );
    try {
      if (await db.seedLoudnessMeasurement(
        LoudnessMeasurementsCompanion.insert(
          trackId: Value(track.id),
          filePath: path,
          fileSize: stat.size,
          fileModifiedMs: stat.modified.millisecondsSinceEpoch,
          integratedLufs: Value(entry.integratedLufs),
          cabinLufs: Value(entry.cabinLufs),
          peakDb: Value(entry.peakDb),
          measuredAt: entry.measuredAt,
        ),
      )) {
        seeded++;
      }
    } catch (_) {
      // The track was deleted meanwhile.
    }
  }
  return seeded;
}
