import 'dart:math' as math;

import '../database/database.dart';
import 'chapters.dart';
import 'lyrics/lyrics_models.dart';

/// What a search compares against, computed once per [Track] object: the
/// lower-case title and the active chapters with lower-case titles. Track
/// objects are immutable and the track streams only emit new ones when a
/// track changed, so a search over a long playlist decodes no chapter JSON
/// and lower-cases no title on later keystrokes.
class _SearchEntry {
  _SearchEntry(Track track)
    : title = track.title.toLowerCase(),
      index = track.index.toString(),
      _chaptersJson = track.chaptersJson;

  final String title;
  final String index;
  final String? _chaptersJson;
  List<(String, MediaChapter)>? _chapters;

  /// Active chapters in timeline order, each with its lower-case title.
  List<(String, MediaChapter)> get chapters =>
      _chapters ??= [
        for (final chapter in ChapterData.decode(_chaptersJson).active)
          (chapter.title.toLowerCase(), chapter),
      ];

  MediaChapter? chapterMatching(String normalized) {
    if (_chaptersJson == null) return null;
    for (final (title, chapter) in chapters) {
      if (title.contains(normalized)) return chapter;
    }
    return null;
  }
}

final _entries = Expando<_SearchEntry>('trackSearch');

_SearchEntry _entryFor(Track track) => _entries[track] ??= _SearchEntry(track);

/// [query] in the form the search compares: trimmed and lower case.
String normalizeTrackSearchQuery(String query) => query.trim().toLowerCase();

bool matchesTrackSearch(Track track, String query) =>
    matchesNormalizedTrackSearch(track, normalizeTrackSearchQuery(query));

/// [matchesTrackSearch] for a query already passed through
/// [normalizeTrackSearchQuery], for filtering long lists.
bool matchesNormalizedTrackSearch(Track track, String normalized) {
  final entry = _entryFor(track);
  return entry.title.contains(normalized) ||
      entry.index.contains(normalized) ||
      '#${entry.index}'.contains(normalized) ||
      (normalized.isNotEmpty && entry.chapterMatching(normalized) != null);
}

/// Select the first matching active chapter in timeline order. Empty searches
/// leave normal file playback unchanged.
MediaChapter? matchingChapterForSearch(Track track, String query) {
  final normalized = normalizeTrackSearchQuery(query);
  if (normalized.isEmpty) return null;
  return _entryFor(track).chapterMatching(normalized);
}

/// Where a lyrics search hit plays from.
class LyricsHitTarget {
  /// The chapter to play: the hit's own, or for a whole-file doc the
  /// active chapter holding the line. Null plays the file.
  final MediaChapter? chapter;

  /// File time to start at: 2 s before the line, so it is heard whole.
  /// Null for lyrics without times (the track or chapter starts).
  final Duration? startAt;

  const LyricsHitTarget({this.chapter, this.startAt});
}

/// How far before a matched line playback starts.
const lyricsLeadIn = Duration(seconds: 2);

/// The chapter and start time for playing [hit] of [track].
LyricsHitTarget lyricsHitTarget(Track track, LyricsHit hit) {
  final position = hit.positionMs;
  final chapters =
      track.chaptersJson == null
          ? const <MediaChapter>[]
          : [for (final (_, chapter) in _entryFor(track).chapters) chapter];
  MediaChapter? chapter;
  if (hit.chapterId != null) {
    chapter = chapters.where((c) => c.id == hit.chapterId).firstOrNull;
  }
  if (chapter == null && position != null) {
    chapter =
        chapters
            .where((c) => c.startMs <= position && position < c.endMs)
            .firstOrNull;
  }
  return LyricsHitTarget(
    chapter: chapter,
    startAt:
        position == null
            ? null
            : Duration(
              milliseconds: math.max(0, position - lyricsLeadIn.inMilliseconds),
            ),
  );
}

/// A file time as `m:ss` or `h:mm:ss`.
String formatLyricsTime(int ms) {
  final duration = Duration(milliseconds: ms);
  final h = duration.inHours;
  final m = duration.inMinutes % 60;
  final s = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}
