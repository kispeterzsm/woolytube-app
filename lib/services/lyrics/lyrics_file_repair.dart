/// Finding and repairing lyrics files (`.woolytube_info/<id>.lyrics.json`)
/// that are missing or differ from the database.
///
/// The lyrics service writes a track's file each time its lyrics change,
/// and a failed write is only noted. Nothing wrote the file again until
/// the lyrics changed once more, so a reinstall could lose them. "Check
/// backup" compares every file with what the database holds, and the
/// app's start looks for missing files, which costs one file check per
/// track with lyrics.
library;

import 'dart:convert';
import 'dart:io';

import '../../database/database.dart';
import '../folder_write_errors.dart';
import '../info_files.dart';
import '../library_layout.dart';
import '../track_title.dart';
import 'lyrics_files.dart';
import 'lyrics_models.dart';
import 'lyrics_service.dart' show draftFromDoc;

/// What [checkLyricsFiles] found in one playlist folder.
class LyricsFilesCheck {
  /// Tracks with lyrics or transcripts in the database.
  int tracks = 0;

  /// Their files that do not exist.
  int missing = 0;

  /// Their files that hold something else than the database.
  int outdated = 0;

  /// Files a newer app wrote, left alone.
  int newer = 0;

  /// Files written by a repair.
  int written = 0;

  /// One line per file a repair could not write.
  final failures = <String>[];

  void add(LyricsFilesCheck other) {
    tracks += other.tracks;
    missing += other.missing;
    outdated += other.outdated;
    newer += other.newer;
    written += other.written;
    failures.addAll(other.failures);
  }
}

/// Compares the lyrics files of [playlist]'s tracks with the database and,
/// with [repair], writes the missing and differing ones.
///
/// Without [compareContent] only missing files are looked for: one file
/// check per track, cheap enough for every app start.
///
/// Only files of tracks with lyrics are looked at: a file is never
/// deleted, and a file a newer app wrote is never replaced. A video listed
/// twice in the playlist shares one file; when it matches either entry's
/// lyrics it is left as it is. Nothing is written when the playlist folder
/// is gone. [tracks] are the playlist's tracks when the caller has them.
Future<LyricsFilesCheck> checkLyricsFiles(
  AppDatabase db,
  Playlist playlist, {
  List<Track>? tracks,
  bool compareContent = true,
  bool repair = false,
}) async {
  final result = LyricsFilesCheck();
  final folder = playlist.outputPath;
  if (!await Directory(folder).exists()) return result;
  final docsByTrack = <int, List<LyricsDoc>>{};
  for (final doc in await db.lyricsDocsForPlaylist(playlist.id)) {
    docsByTrack.putIfAbsent(doc.trackId, () => []).add(doc);
  }
  if (docsByTrack.isEmpty) return result;
  final byVideo = <String, List<Track>>{};
  for (final track in tracks ?? await db.getTracksForPlaylist(playlist.id)) {
    if (track.playlistId != playlist.id) continue;
    if (!docsByTrack.containsKey(track.id)) continue;
    byVideo.putIfAbsent(track.videoId, () => []).add(track);
  }
  final lines =
      compareContent
          ? await db.lyricsLinesForDocs([
            for (final docs in docsByTrack.values)
              for (final doc in docs) doc.id,
          ])
          : const <int, List<LyricsLine>>{};

  for (final entry in byVideo.entries) {
    final videoId = entry.key;
    final entries = entry.value;
    result.tracks += entries.length;
    final path = LibraryLayout.lyricsJsonPath(folder, videoId);
    final file = File(path);
    String? onDisk;
    try {
      if (await file.exists()) {
        if (!compareContent) continue;
        onDisk = await file.readAsString();
      }
    } catch (_) {
      onDisk = null;
    }
    if (onDisk != null) {
      final expected = [
        for (final track in entries)
          encodeLyricsFile(
            videoId,
            _drafts(docsByTrack[track.id]!, (doc) => lines[doc.id]),
          ),
      ];
      if (expected.contains(onDisk)) continue;
      if (_isNewer(onDisk)) {
        result.newer++;
        continue;
      }
      // A video listed twice: which entry's lyrics it should hold is
      // unknown, so it is left as it is.
      if (entries.length > 1) continue;
      result.outdated++;
    } else {
      result.missing++;
    }
    if (!repair) continue;
    final track = entries.first;
    try {
      if (await _rewrite(db, track, folder)) result.written++;
      FolderWriteErrors.succeeded(lyricsFileErrorKey(track.id));
    } catch (e) {
      result.failures.add('${track.displayTitle}: $e');
      FolderWriteErrors.failed(
        lyricsFileErrorKey(track.id),
        'Lyrics file of "${track.displayTitle}"',
        e,
      );
    }
  }
  return result;
}

/// Writes [track]'s lyrics file from the database as it is now (it may
/// have changed since the check read it). Returns whether it wrote.
Future<bool> _rewrite(AppDatabase db, Track track, String folder) async {
  final docs = await db.lyricsDocsForTrack(track.id);
  // Its lyrics were removed meanwhile; the lyrics service saw to the file.
  if (docs.isEmpty) return false;
  final lines = await db.lyricsLinesForDocs(docs.map((doc) => doc.id));
  return writeInfoFile(
    LibraryLayout.lyricsJsonPath(folder, track.videoId),
    encodeLyricsFile(track.videoId, _drafts(docs, (doc) => lines[doc.id])),
  );
}

/// [docs] in the order the lyrics service writes them (see
/// `AppDatabase.lyricsDocsForTrack`), as drafts.
List<LyricsDocDraft> _drafts(
  List<LyricsDoc> docs,
  List<LyricsLine>? Function(LyricsDoc doc) linesOf,
) {
  final sorted = [...docs]..sort((a, b) {
    final byChapter = (a.chapterId != null ? 1 : 0).compareTo(
      b.chapterId != null ? 1 : 0,
    );
    if (byChapter != 0) return byChapter;
    final byOffset = a.offsetMs.compareTo(b.offsetMs);
    return byOffset != 0 ? byOffset : a.id.compareTo(b.id);
  });
  return [
    for (final doc in sorted) draftFromDoc(doc, linesOf(doc) ?? const []),
  ];
}

bool _isNewer(String content) {
  try {
    final json = jsonDecode(content);
    if (json is! Map) return false;
    final version = json['version'];
    return version is num && version > lyricsFileVersion;
  } catch (_) {
    return false;
  }
}
