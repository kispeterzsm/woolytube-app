/// `.woolytube_info/<safeId>.lyrics.json`: every lyrics doc of a track with
/// its lines, kept next to the info files so a reinstall can restore them
/// without fetching again.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../library_layout.dart';
import 'lyrics_models.dart';

const _fileVersion = 1;

/// The file's JSON for [docs] (their track ids are not stored).
Map<String, dynamic> lyricsFileJson(
  String videoId,
  List<LyricsDocDraft> docs,
) => {
  'version': _fileVersion,
  'videoId': videoId,
  'docs': [
    for (final doc in docs)
      {
        if (doc.chapterId != null) 'chapterId': doc.chapterId,
        if (doc.offsetMs != 0) 'offsetMs': doc.offsetMs,
        'kind': doc.kind.dbValue,
        'status': doc.status,
        if (doc.source != null) 'source': doc.source,
        if (doc.sourceRef != null) 'sourceRef': doc.sourceRef,
        if (doc.matchedArtist != null) 'matchedArtist': doc.matchedArtist,
        if (doc.matchedTitle != null) 'matchedTitle': doc.matchedTitle,
        if (doc.timeScale != 1.0) 'timeScale': doc.timeScale,
        if (doc.synced) 'synced': true,
        if (doc.pinned) 'pinned': true,
        // Already added to the line times below.
        if (doc.shiftMs != 0) 'shiftMs': doc.shiftMs,
        if (doc.timingOff) 'timingOff': true,
        if (doc.lang != null) 'lang': doc.lang,
        'checkedAt': doc.checkedAt.toUtc().toIso8601String(),
        if (doc.attempts != 0) 'attempts': doc.attempts,
        // [startMs, text], or [text] for an untimed line.
        'lines': [
          for (final line in doc.lines)
            line.startMs == null ? [line.text] : [line.startMs, line.text],
        ],
      },
  ],
};

/// Reads the docs in a lyrics file's [json] for track [trackId]. Broken
/// entries are skipped.
List<LyricsDocDraft> lyricsDocsFromJson(Object? json, int trackId) {
  if (json is! Map) return const [];
  final docs = json['docs'];
  if (docs is! List) return const [];
  final result = <LyricsDocDraft>[];
  for (final doc in docs) {
    if (doc is! Map) continue;
    final kind = LyricsMode.fromDb(doc['kind'] as String?);
    final status = doc['status'];
    final checkedAt = DateTime.tryParse('${doc['checkedAt']}');
    if (kind == null || status is! String || checkedAt == null) continue;
    final lines = <LyricsLineDraft>[];
    final rawLines = doc['lines'];
    if (rawLines is List) {
      for (final line in rawLines) {
        if (line is! List || line.isEmpty) continue;
        final text = line.last;
        if (text is! String) continue;
        final start = line.length > 1 ? line.first : null;
        lines.add(
          LyricsLineDraft(text, startMs: start is num ? start.toInt() : null),
        );
      }
    }
    String? text(String key) => doc[key] is String ? doc[key] as String : null;
    result.add(
      LyricsDocDraft(
        trackId: trackId,
        chapterId: text('chapterId'),
        offsetMs: (doc['offsetMs'] as num?)?.toInt() ?? 0,
        kind: kind,
        status: status,
        source: text('source'),
        sourceRef: text('sourceRef'),
        matchedArtist: text('matchedArtist'),
        matchedTitle: text('matchedTitle'),
        timeScale: (doc['timeScale'] as num?)?.toDouble() ?? 1.0,
        synced: doc['synced'] == true,
        pinned: doc['pinned'] == true,
        shiftMs: (doc['shiftMs'] as num?)?.toInt() ?? 0,
        timingOff: doc['timingOff'] == true,
        lang: text('lang'),
        checkedAt: checkedAt.toLocal(),
        attempts: (doc['attempts'] as num?)?.toInt() ?? 0,
        lines: lines,
      ),
    );
  }
  return result;
}

/// Writes (or, for no [docs], deletes) the lyrics file of [videoId] in the
/// playlist folder [playlistPath]. Written to a temporary file first.
Future<void> writeLyricsFile(
  String playlistPath,
  String videoId,
  List<LyricsDocDraft> docs,
) async {
  final target = File(LibraryLayout.lyricsJsonPath(playlistPath, videoId));
  if (docs.isEmpty) {
    await deleteLyricsFile(playlistPath, videoId);
    return;
  }
  final dir = Directory(LibraryLayout.infoDir(playlistPath));
  await dir.create(recursive: true);
  final noMedia = File(p.join(dir.path, '.nomedia'));
  if (!await noMedia.exists()) await noMedia.create();
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString(jsonEncode(lyricsFileJson(videoId, docs)));
  await tmp.rename(target.path);
}

/// The docs stored for [videoId], for track [trackId]; empty when there is
/// no readable file.
Future<List<LyricsDocDraft>> readLyricsFile(
  String playlistPath,
  String videoId,
  int trackId,
) async {
  final file = File(LibraryLayout.lyricsJsonPath(playlistPath, videoId));
  try {
    if (!await file.exists()) return const [];
    return lyricsDocsFromJson(jsonDecode(await file.readAsString()), trackId);
  } catch (_) {
    return const [];
  }
}

Future<void> deleteLyricsFile(String playlistPath, String videoId) async {
  final file = File(LibraryLayout.lyricsJsonPath(playlistPath, videoId));
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // A leftover file is harmless; the next write replaces it.
  }
}
