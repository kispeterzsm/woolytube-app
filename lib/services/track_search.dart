import 'dart:math' as math;

import '../database/database.dart';
import 'chapter_playback.dart';
import 'chapters.dart';
import 'lyrics/lyrics_models.dart';
import 'lyrics/lyrics_text.dart';
import 'track_title.dart';

/// What a search compares against, computed once per [Track] object: the
/// folded title (see [foldForSearch]) and the active chapters with folded
/// titles. Track objects are immutable and the track streams only emit new
/// ones when a track changed, so a search over a long playlist decodes no
/// chapter JSON and folds no title on later keystrokes.
class _SearchEntry {
  _SearchEntry(Track track)
    : title = foldForSearch(track.displayTitle),
      index = track.index.toString(),
      _chaptersJson = track.chaptersJson;

  final String title;
  final String index;
  final String? _chaptersJson;
  List<(String, MediaChapter)>? _chapters;

  /// Active chapters in timeline order, each with its folded title.
  List<(String, MediaChapter)> get chapters =>
      _chapters ??= [
        for (final chapter in ChapterData.decode(_chaptersJson).active)
          (foldForSearch(chapter.title), chapter),
      ];

  /// The active chapters whose titles match [query], in timeline order,
  /// and the best rank among them.
  (List<MediaChapter>, int?) chaptersMatching(SearchQuery query) {
    if (_chaptersJson == null || query.isEmpty) return (const [], null);
    List<MediaChapter>? found;
    int? best;
    for (final (title, chapter) in chapters) {
      final rank = _textRank(title, query);
      if (rank == null) continue;
      (found ??= []).add(chapter);
      if (best == null || rank < best) best = rank;
    }
    return (found ?? const [], best);
  }
}

final _entries = Expando<_SearchEntry>('trackSearch');

_SearchEntry _entryFor(Track track) => _entries[track] ??= _SearchEntry(track);

/// A search as typed, in the form the search compares: folded like lyrics
/// (lower case, no accents or punctuation, see [foldForSearch]) and split
/// into words. Every word must match, in any order.
class SearchQuery {
  factory SearchQuery(String raw) {
    final typed = tokenizeFolded(foldForSearch(raw));
    final words = <String>[];
    for (final word in typed) {
      if (!words.contains(word)) words.add(word);
    }
    return SearchQuery._(raw, words, typed.join(' '));
  }

  SearchQuery._(this.raw, this.words, this.phrase) : folded = words.join(' ');

  static final empty = SearchQuery('');

  final String raw;

  /// Distinct folded words, in typed order.
  final List<String> words;

  /// [words] joined by single spaces.
  final String folded;

  /// Every folded word as typed, repeats kept, joined by single spaces. The
  /// lyrics search scores the words as a phrase, so it gets this.
  final String phrase;

  bool get isEmpty => words.isEmpty;

  /// The digits when the query is just a track number (`12` or `#12`).
  String? get number =>
      words.length == 1 && _digits.hasMatch(words.single) ? words.single : null;

  static final _digits = RegExp(r'^\d+$');

  @override
  bool operator ==(Object other) =>
      other is SearchQuery && other.phrase == phrase;

  @override
  int get hashCode => phrase.hashCode;
}

/// Filters a search applies on top of its words. Only lyrics so far; label
/// and playlist filters belong here too.
class SearchFilters {
  const SearchFilters({this.lyrics = false});

  /// Also match lyric and transcript lines. Off whenever search opens.
  final bool lyrics;

  SearchFilters copyWith({bool? lyrics}) =>
      SearchFilters(lyrics: lyrics ?? this.lyrics);

  @override
  bool operator ==(Object other) =>
      other is SearchFilters && other.lyrics == lyrics;

  @override
  int get hashCode => lyrics.hashCode;
}

/// Why a track is in the results.
enum SearchReason {
  /// Its title (or, for an empty search, nothing: every track is listed).
  title,

  /// Its track number.
  number,

  /// Only chapter titles.
  chapter,

  /// Only a lyric or transcript line (the Lyrics filter is on).
  lyrics,
}

/// One track in the search results.
class SearchHit {
  const SearchHit({
    required this.track,
    required this.reason,
    this.chapters = const [],
    this.lyric,
    this.rank = 0,
  });

  final Track track;
  final SearchReason reason;

  /// The active chapters whose titles match, in timeline order. Also set
  /// when the title matched too.
  final List<MediaChapter> chapters;

  /// The track's best matching lyric line, when lyrics are searched.
  final LyricsHit? lyric;

  /// Lower ranks list first: 0 exact title or number, 1 title starts with
  /// the query, 2 every word starts a title word (or the number starts the
  /// track number), 3 the words are somewhere in the title, 4–5 chapter
  /// titles likewise, 6 lyrics only.
  final int rank;

  /// The first matching chapter: a tap plays from it.
  MediaChapter? get chapter => chapters.firstOrNull;

  /// Whether it is downloaded and not marked Always skip, so Play all
  /// plays it.
  bool get playable => track.status == 'complete' && !track.alwaysSkip;

  /// What Play all queues for it: a file found by its title or number
  /// whole, one found only by chapter titles just those chapters, and one
  /// found only by a lyric line the chapter holding that line (or the
  /// whole file without chapters).
  QueueEntry get queueEntry {
    switch (reason) {
      case SearchReason.title:
      case SearchReason.number:
        return QueueEntry(track);
      case SearchReason.chapter:
        return QueueEntry(track, {for (final c in chapters) c.id});
      case SearchReason.lyrics:
        final chapter = lyricsHitTarget(track, lyric!).chapter;
        return QueueEntry(track, chapter == null ? null : {chapter.id});
    }
  }
}

/// How well folded [text] matches [query] (see [SearchHit.rank], 0–3), or
/// null when a word is missing.
int? _textRank(String text, SearchQuery query) {
  for (final word in query.words) {
    if (!text.contains(word)) return null;
  }
  if (text == query.folded) return 0;
  if (text.startsWith(query.folded)) return 1;
  if (query.words.every((w) => text.startsWith(w) || text.contains(' $w'))) {
    return 2;
  }
  return 3;
}

/// Whether every word of [query] is in [text] (folded), in any order.
bool matchesSearchText(String text, SearchQuery query) =>
    query.isEmpty || _textRank(foldForSearch(text), query) != null;

/// [track] as a search hit for [query], or null when it does not match.
/// [lyric] is its best lyric line, if lyrics are searched.
SearchHit? _hitFor(Track track, SearchQuery query, LyricsHit? lyric) {
  if (query.isEmpty) return SearchHit(track: track, reason: SearchReason.title);
  final entry = _entryFor(track);
  var reason = SearchReason.title;
  var rank = _textRank(entry.title, query);
  final number = query.number;
  if (number != null) {
    // A number finds that track, then those whose number starts with it
    // (1 → 1, 10–19, 100…), never 21 or 31.
    final indexRank =
        entry.index == number
            ? 0
            : entry.index.startsWith(number)
            ? 2
            : null;
    if (indexRank != null && (rank == null || indexRank < rank)) {
      reason = SearchReason.number;
      rank = indexRank;
    }
  }
  final (chapters, chapterRank) = entry.chaptersMatching(query);
  if (rank == null && chapterRank != null) {
    reason = SearchReason.chapter;
    rank = chapterRank <= 2 ? 4 : 5;
  }
  if (rank == null && lyric != null) {
    reason = SearchReason.lyrics;
    rank = 6;
  }
  if (rank == null) return null;
  return SearchHit(
    track: track,
    reason: reason,
    chapters: chapters,
    lyric: lyric,
    rank: rank,
  );
}

/// Searches [tracks] for [query]: titles, track numbers and chapter titles,
/// and with [SearchFilters.lyrics] also [lyricHits] (only then are they
/// used, so callers need not search lyrics while the filter is off).
///
/// With [ranked], better matches come first (see [SearchHit.rank]), then
/// by [playlistOrder] (playlist id → position on the home screen), track
/// number and the order of [tracks]; otherwise [tracks]' order is kept. An
/// empty query lists every track.
List<SearchHit> searchLibrary(
  List<Track> tracks,
  SearchQuery query, {
  SearchFilters filters = const SearchFilters(),
  List<LyricsHit> lyricHits = const [],
  bool ranked = true,
  Map<int, int> playlistOrder = const {},
}) {
  final lyrics = <int, LyricsHit>{};
  if (filters.lyrics && !query.isEmpty) {
    for (final hit in lyricHits) {
      lyrics.putIfAbsent(hit.trackId, () => hit);
    }
  }
  final hits = <SearchHit>[
    for (final track in tracks)
      if (_hitFor(track, query, lyrics[track.id]) case final hit?) hit,
  ];
  if (!ranked || query.isEmpty && playlistOrder.isEmpty) return hits;
  final position = {for (var i = 0; i < hits.length; i++) hits[i]: i};
  int order(SearchHit hit) => playlistOrder[hit.track.playlistId] ?? 1 << 30;
  hits.sort((a, b) {
    var c = a.rank.compareTo(b.rank);
    if (c == 0) c = order(a).compareTo(order(b));
    if (c == 0 && a.track.playlistId == b.track.playlistId) {
      c = a.track.index.compareTo(b.track.index);
    }
    return c != 0 ? c : position[a]!.compareTo(position[b]!);
  });
  return hits;
}

/// What Play all queues for [hits]: one entry per file, in order.
List<QueueEntry> searchQueueEntries(Iterable<SearchHit> hits) => [
  for (final hit in hits)
    if (hit.playable) hit.queueEntry,
];

/// Where the words of [query] are in raw [text], merged and in order, for
/// highlighting.
List<LyricsHighlight> searchHighlights(String text, SearchQuery query) {
  if (query.isEmpty) return const [];
  final folded = foldWithOffsets(text);
  final ranges = <(int, int)>[];
  for (final word in query.words) {
    var from = 0;
    while (true) {
      final at = folded.text.indexOf(word, from);
      if (at < 0) break;
      ranges.add(folded.rawRange(at, at + word.length));
      from = at + word.length;
    }
  }
  if (ranges.isEmpty) return const [];
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <LyricsHighlight>[];
  var (start, end) = ranges.first;
  for (final (s, e) in ranges.skip(1)) {
    if (s <= end) {
      if (e > end) end = e;
    } else {
      merged.add(LyricsHighlight(start, end));
      (start, end) = (s, e);
    }
  }
  merged.add(LyricsHighlight(start, end));
  return merged;
}

/// Whether [track]'s title, number or an active chapter title matches.
bool matchesTrackSearch(Track track, String query) =>
    _hitFor(track, SearchQuery(query), null) != null;

/// Select the first matching active chapter in timeline order. Empty searches
/// leave normal file playback unchanged.
MediaChapter? matchingChapterForSearch(Track track, String query) =>
    _entryFor(track).chaptersMatching(SearchQuery(query)).$1.firstOrNull;

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
