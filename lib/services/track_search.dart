import 'dart:math' as math;

import '../database/database.dart';
import 'chapter_playback.dart';
import 'chapters.dart';
import 'labels.dart';
import 'lyrics/lyrics_models.dart';
import 'lyrics/lyrics_text.dart';
import 'track_title.dart';

/// What a search compares against, computed once per [Track] object: the
/// folded title (see [foldForSearch]), the active chapters with folded
/// titles and the labels. Track objects are immutable and the track streams
/// only emit new ones when a track changed, so a search over a long
/// playlist decodes no chapter JSON and folds no title on later keystrokes.
class _SearchEntry {
  _SearchEntry(Track track)
    : title = foldForSearch(track.displayTitle),
      index = track.index.toString(),
      _chaptersJson = track.chaptersJson,
      _labelUids = track.labelUids;

  final String title;
  final String index;
  final String? _chaptersJson;
  final String? _labelUids;
  ChapterData? _data;
  List<(String, MediaChapter)>? _chapters;
  List<String>? _fileLabels;

  ChapterData get _chapterData => _data ??= ChapterData.decode(_chaptersJson);

  /// Whether a chapter may carry a label, without decoding the chapters
  /// of a file none of whose chapters does (most files).
  late final bool _hasChapterLabels =
      _chaptersJson != null &&
      _chaptersJson.contains('"chapterLabels"') &&
      _chapterData.chapterLabels.isNotEmpty;

  /// Active chapters in timeline order, each with its folded title.
  List<(String, MediaChapter)> get chapters =>
      _chapters ??= [
        for (final chapter in _chapterData.active)
          (foldForSearch(chapter.title), chapter),
      ];

  /// The labels of the file itself (uids, deleted labels included).
  List<String> get fileLabels => _fileLabels ??= decodeLabelUids(_labelUids);

  /// The labels of active chapter [chapterId].
  List<String> chapterLabels(String chapterId) =>
      _hasChapterLabels ? _chapterData.labelsOf(chapterId) : const [];

  /// Every label uid on the file or one of its active chapters.
  Iterable<String> get allLabels sync* {
    yield* fileLabels;
    if (!_hasChapterLabels) return;
    for (final chapter in _chapterData.active) {
      yield* _chapterData.labelsOf(chapter.id);
    }
  }

  /// The active chapters, in timeline order, that carry one of [uids], and
  /// those of [uids] they carry.
  (List<MediaChapter>, Set<String>) chaptersWithAnyLabel(Set<String> uids) {
    if (!_hasChapterLabels) return (const [], const {});
    final found = <MediaChapter>[];
    final carried = <String>{};
    for (final chapter in _chapterData.active) {
      final matching = _chapterData.labelsOf(chapter.id).where(uids.contains);
      if (matching.isEmpty) continue;
      found.add(chapter);
      carried.addAll(matching);
    }
    return (found, carried);
  }

  /// The active chapters, in timeline order, whose own labels satisfy
  /// [filters].
  List<MediaChapter> chaptersLabelled(SearchFilters filters) {
    if (!_hasChapterLabels) return const [];
    return [
      for (final chapter in _chapterData.active)
        if (labelsMatch(
          _chapterData.labelsOf(chapter.id),
          filters.labels,
          filters.labelMatch,
        ))
          chapter,
    ];
  }

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

  /// Long enough for the lyrics search (two letters), so offering it can
  /// find something.
  bool get canSearchLyrics => phrase.length >= 2;

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

/// Filters a search applies on top of its words: lyrics, and the owner's
/// labels.
class SearchFilters {
  const SearchFilters({
    this.lyrics = false,
    this.labelSearch = false,
    this.labels = const {},
    this.labelMatch = LabelMatch.all,
  });

  /// Also match lyric and transcript lines. Off whenever search opens.
  final bool lyrics;

  /// The Labels chip: labels can be chosen ([labels]) and the words also
  /// match label names. Off whenever search opens.
  final bool labelSearch;

  /// Only files and chapters that carry these labels (uids), the file's
  /// own labels and each chapter's apart. Empty: no label filter.
  final Set<String> labels;

  /// Whether an item needs every label of [labels] or any one of them.
  final LabelMatch labelMatch;

  bool get hasLabels => labels.isNotEmpty;

  SearchFilters copyWith({
    bool? lyrics,
    bool? labelSearch,
    Set<String>? labels,
    LabelMatch? labelMatch,
  }) => SearchFilters(
    lyrics: lyrics ?? this.lyrics,
    labelSearch: labelSearch ?? this.labelSearch,
    labels: labels ?? this.labels,
    labelMatch: labelMatch ?? this.labelMatch,
  );

  /// These filters with only the labels of [known] kept, so a label
  /// deleted while chosen stops filtering. Returns this when all are known.
  SearchFilters withLabelsIn(Set<String> known) {
    if (labels.every(known.contains)) return this;
    return copyWith(labels: labels.where(known.contains).toSet());
  }

  @override
  bool operator ==(Object other) =>
      other is SearchFilters &&
      other.lyrics == lyrics &&
      other.labelSearch == labelSearch &&
      other.labelMatch == labelMatch &&
      other.labels.length == labels.length &&
      other.labels.containsAll(labels);

  @override
  int get hashCode => Object.hash(
    lyrics,
    labelSearch,
    labelMatch,
    Object.hashAllUnordered(labels),
  );
}

/// Why a track is in the results.
enum SearchReason {
  /// Its title (or, for an empty search, nothing: every track is listed).
  title,

  /// Its track number.
  number,

  /// Only chapter titles.
  chapter,

  /// Only the name of a label the file or some chapters carry (the
  /// Labels chip is on).
  labelName,

  /// Only a lyric or transcript line (the Lyrics filter is on).
  lyrics,

  /// The file's own labels, for an empty search with label filters.
  label,
}

/// One track in the search results.
class SearchHit {
  const SearchHit({
    required this.track,
    required this.reason,
    this.chapters = const [],
    this.lyric,
    this.labels = const {},
    this.rank = 0,
  });

  final Track track;
  final SearchReason reason;

  /// For [SearchReason.labelName], the labels (uids) whose names match,
  /// carried by the file or by [chapters].
  final Set<String> labels;

  /// The active chapters whose titles match, in timeline order. Also set
  /// when the title matched too. With label filters, only chapters that
  /// carry the labels (when the file itself does not). For
  /// [SearchReason.labelName], the chapters that carry the matching labels
  /// (empty when the file does: it is found whole).
  final List<MediaChapter> chapters;

  /// The track's best matching lyric line, when lyrics are searched.
  final LyricsHit? lyric;

  /// Lower ranks list first: 0 exact title or number, 1 title starts with
  /// the query, 2 every word starts a title word (or the number starts the
  /// track number), 3 the words are somewhere in the title, 4–5 chapter
  /// titles likewise, 6 label names only, 7 lyrics only.
  final int rank;

  /// The first matching chapter: a tap plays from it.
  MediaChapter? get chapter => chapters.firstOrNull;

  /// Whether it is downloaded and not marked Always skip, so Play all
  /// plays it.
  bool get playable => track.status == 'complete' && !track.alwaysSkip;

  /// What Play all queues for it: a file found by its title, number or
  /// own labels whole, one found only by chapter titles or chapter labels
  /// just those chapters, and one found only by a lyric line the chapter
  /// holding that line (or the whole file without chapters). One found by
  /// a label name like one found by those labels.
  QueueEntry get queueEntry {
    switch (reason) {
      case SearchReason.title:
      case SearchReason.number:
      case SearchReason.label:
        return QueueEntry(track);
      case SearchReason.chapter:
        return QueueEntry(track, {for (final c in chapters) c.id});
      case SearchReason.labelName:
        return chapters.isEmpty
            ? QueueEntry(track)
            : QueueEntry(track, {for (final c in chapters) c.id});
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

/// [track] as a search hit for [query] and the label filters of
/// [filters], or null when it does not match. [lyric] is its best lyric
/// line, if lyrics are searched.
///
/// A file that carries the labels itself is found as by [query] alone. One
/// whose chapters carry them is found through those chapters only: an
/// empty search lists them, a title match keeps them (or those of them
/// whose titles match too), a chapter title match keeps the matching ones
/// that carry the labels, and a lyric line counts when its chapter does.
SearchHit? _hitFor(
  Track track,
  SearchQuery query,
  LyricsHit? lyric, [
  SearchFilters filters = const SearchFilters(),
  Set<String> namedLabels = const {},
]) {
  final hit = _textHitFor(track, query, lyric, namedLabels);
  if (hit == null || !filters.hasLabels) return hit;
  final entry = _entryFor(track);
  if (labelsMatch(entry.fileLabels, filters.labels, filters.labelMatch)) {
    return query.isEmpty
        ? SearchHit(track: track, reason: SearchReason.label)
        : hit;
  }
  final labelled = entry.chaptersLabelled(filters);
  if (labelled.isEmpty) return null;
  if (query.isEmpty) {
    return SearchHit(
      track: track,
      reason: SearchReason.chapter,
      chapters: labelled,
    );
  }
  final ids = {for (final chapter in labelled) chapter.id};
  final both = [
    for (final chapter in hit.chapters)
      if (ids.contains(chapter.id)) chapter,
  ];
  switch (hit.reason) {
    case SearchReason.lyrics:
      final chapter = lyricsHitTarget(track, lyric!).chapter;
      return chapter != null && ids.contains(chapter.id) ? hit : null;
    case SearchReason.labelName:
      if (hit.chapters.isNotEmpty && both.isEmpty) return null;
      return SearchHit(
        track: track,
        reason: SearchReason.labelName,
        chapters: hit.chapters.isEmpty ? labelled : both,
        labels: hit.labels,
        rank: hit.rank,
      );
    case SearchReason.chapter:
      if (both.isEmpty) return null;
      return SearchHit(
        track: track,
        reason: SearchReason.chapter,
        chapters: both,
        lyric: lyric,
        rank: hit.rank,
      );
    case SearchReason.title:
    case SearchReason.number:
    case SearchReason.label:
      return SearchHit(
        track: track,
        reason: SearchReason.chapter,
        chapters: both.isEmpty ? labelled : both,
        lyric: lyric,
        rank: hit.rank,
      );
  }
}

SearchHit? _textHitFor(
  Track track,
  SearchQuery query,
  LyricsHit? lyric, [
  Set<String> namedLabels = const {},
]) {
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
  if (rank == null && namedLabels.isNotEmpty) {
    // A label whose name matches: on the file finds it whole, otherwise
    // the chapters that carry one.
    final own = {...entry.fileLabels.where(namedLabels.contains)};
    if (own.isNotEmpty) {
      return SearchHit(
        track: track,
        reason: SearchReason.labelName,
        labels: own,
        rank: 6,
      );
    }
    final (labelled, carried) = entry.chaptersWithAnyLabel(namedLabels);
    if (labelled.isNotEmpty) {
      return SearchHit(
        track: track,
        reason: SearchReason.labelName,
        chapters: labelled,
        labels: carried,
        rank: 6,
      );
    }
  }
  if (rank == null && lyric != null) {
    reason = SearchReason.lyrics;
    rank = 7;
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
/// used, so callers need not search lyrics while the filter is off). With
/// [SearchFilters.labelSearch], also files and chapters that carry one of
/// [namedLabels], the labels whose names match [query] (see
/// [labelUidsNamed]). With label filters only what carries the labels is
/// found (see [_hitFor]); an empty query then lists everything that does.
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
  Set<String> namedLabels = const {},
  bool ranked = true,
  Map<int, int> playlistOrder = const {},
}) {
  final lyrics = <int, LyricsHit>{};
  if (filters.lyrics && !query.isEmpty) {
    for (final hit in lyricHits) {
      lyrics.putIfAbsent(hit.trackId, () => hit);
    }
  }
  final named =
      filters.labelSearch && !query.isEmpty ? namedLabels : const <String>{};
  final hits = <SearchHit>[
    for (final track in tracks)
      if (_hitFor(track, query, lyrics[track.id], filters, named)
          case final hit?)
        hit,
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

/// What "Label all" labels for [hits], downloaded or not: the same files
/// and chapters Play all would play ([SearchHit.queueEntry]): a file found
/// whole gets the label on the file, one found through chapters on those
/// chapters.
List<LabelledItem> searchLabelTargets(Iterable<SearchHit> hits) {
  final items = <LabelledItem>[];
  for (final hit in hits) {
    final ids = hit.queueEntry.chapterIds;
    if (ids == null) {
      items.add(LabelledItem(hit.track));
      continue;
    }
    for (final (_, chapter) in _entryFor(hit.track).chapters) {
      if (ids.contains(chapter.id)) items.add(LabelledItem(hit.track, chapter));
    }
  }
  return items;
}

/// Whether a result for [track] (or its [chapter]) passes the label
/// filters of [filters]: always without any; otherwise the file's own
/// labels, or [chapter]'s.
bool searchLabelsAllow(
  Track track,
  MediaChapter? chapter,
  SearchFilters filters,
) {
  if (!filters.hasLabels) return true;
  final entry = _entryFor(track);
  if (labelsMatch(entry.fileLabels, filters.labels, filters.labelMatch)) {
    return true;
  }
  return chapter != null &&
      labelsMatch(
        entry.chapterLabels(chapter.id),
        filters.labels,
        filters.labelMatch,
      );
}

/// The uids of those of [labels] whose names match [query] like a title
/// does (every word, any order, case and accents ignored).
Set<String> labelUidsNamed(Iterable<Label> labels, SearchQuery query) {
  if (query.isEmpty) return const {};
  return {
    for (final label in labels)
      if (matchesSearchText(label.name, query)) label.uid,
  };
}

/// The label uids [tracks] (the files or their active chapters) carry, so
/// a search offers only labels that can find something.
Set<String> labelUidsUsedBy(Iterable<Track> tracks) => {
  for (final track in tracks) ..._entryFor(track).allLabels,
};

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
