import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../database/database.dart';
import 'lyrics_models.dart';
import 'lyrics_text.dart';

/// Finds lines of stored lyrics and transcripts from a half-remembered
/// query: FTS5 candidates with typo expansion, reranked in Dart.
class LyricsSearch {
  LyricsSearch(this._db);

  final AppDatabase _db;

  /// Results scoring below this are not shown.
  static const minScore = 0.65;

  /// How many FTS lines are reranked.
  static const candidateLimit = 150;

  /// Typo alternatives per unknown query word.
  static const maxAlternatives = 5;

  _Vocabulary? _vocabulary;
  Future<_Vocabulary>? _vocabularyLoad;
  int _vocabularyGeneration = 0;
  StreamSubscription<void>? _changes;

  /// The best line of each matching doc, best first, scoring at least
  /// 0.65. Only playlists with lyrics on; only [playlistId] when given.
  Future<List<LyricsHit>> search(
    String query, {
    int? playlistId,
    int limit = 50,
  }) async {
    final words = tokenizeFolded(foldForSearch(query));
    if (words.isEmpty || limit <= 0) return const [];
    final vocabulary = await _loadVocabulary();
    final match = _matchExpression(words, vocabulary);
    if (match == null) return const [];
    final candidates = await _db.lyricsFtsCandidates(
      match,
      limit: candidateLimit,
      playlistId: playlistId,
    );
    if (candidates.isEmpty) return const [];

    final lines = await _linesAround(candidates);
    final docs = {
      for (final doc in await _db.lyricsDocsByIds(
        candidates.map((c) => c.docId).toSet(),
      ))
        doc.id: doc,
    };

    final scorer = _Scorer(words);
    final bestPerDoc = <int, _Span>{};
    for (final candidate in candidates) {
      final docLines = lines[candidate.docId];
      if (docLines == null || !docs.containsKey(candidate.docId)) continue;
      final span = scorer.bestSpan(docLines, candidate);
      if (span == null) continue;
      final current = bestPerDoc[candidate.docId];
      if (current == null || span.betterThan(current)) {
        bestPerDoc[candidate.docId] = span;
      }
    }

    final ranked =
        bestPerDoc.values.where((span) => span.score >= minScore).toList()
          ..sort((a, b) => a.betterThan(b) ? -1 : (b.betterThan(a) ? 1 : 0));
    return [
      for (final span in ranked.take(limit)) _hitFor(span, docs[span.docId]!),
    ];
  }

  /// Forgets the cached vocabulary (it reloads on the next search).
  void invalidateVocabulary() {
    _vocabularyGeneration++;
    _vocabulary = null;
    _vocabularyLoad = null;
  }

  /// Stops watching the lyrics tables.
  void dispose() {
    unawaited(_changes?.cancel());
    _changes = null;
  }

  Future<_Vocabulary> _loadVocabulary() {
    // Any write to the lyrics tables (also from the background worker's
    // connection, via refreshIfChangedExternally) drops the cache.
    _changes ??= _db.watchLyricsChanges().listen((_) => invalidateVocabulary());
    final cached = _vocabulary;
    if (cached != null) return Future.value(cached);
    final generation = _vocabularyGeneration;
    return _vocabularyLoad ??= _db.lyricsVocabulary().then((terms) {
      final vocabulary = _Vocabulary(terms);
      if (generation == _vocabularyGeneration) {
        _vocabulary = vocabulary;
        _vocabularyLoad = null;
      }
      return vocabulary;
    });
  }

  /// Lines `lineNo - 1 … lineNo + 2` around each candidate, by doc and
  /// line number, in one query per 200 ranges.
  Future<Map<int, Map<int, _Line>>> _linesAround(
    List<LyricsFtsCandidate> candidates,
  ) async {
    final ranges = <int, List<(int, int)>>{};
    for (final c in candidates) {
      ranges.putIfAbsent(c.docId, () => []).add((c.lineNo - 1, c.lineNo + 2));
    }
    final merged = <(int, int, int)>[];
    for (final entry in ranges.entries) {
      final list = entry.value..sort((a, b) => a.$1.compareTo(b.$1));
      var (from, to) = list.first;
      for (final (start, end) in list.skip(1)) {
        if (start <= to + 1) {
          to = math.max(to, end);
        } else {
          merged.add((entry.key, from, to));
          (from, to) = (start, end);
        }
      }
      merged.add((entry.key, from, to));
    }

    final result = <int, Map<int, _Line>>{};
    const chunk = 200;
    for (var i = 0; i < merged.length; i += chunk) {
      final part = merged.sublist(i, math.min(merged.length, i + chunk));
      final rows =
          await _db
              .customSelect(
                'SELECT id, doc_id, line_no, start_ms, text FROM lyrics_lines '
                'WHERE ${List.filled(part.length, '(doc_id = ? AND line_no BETWEEN ? AND ?)').join(' OR ')}',
                variables: [
                  for (final (doc, from, to) in part) ...[
                    Variable<int>(doc),
                    Variable<int>(from),
                    Variable<int>(to),
                  ],
                ],
                readsFrom: {_db.lyricsLines},
              )
              .get();
      for (final row in rows) {
        final line = _Line(
          id: row.read<int>('id'),
          docId: row.read<int>('doc_id'),
          lineNo: row.read<int>('line_no'),
          startMs: row.readNullable<int>('start_ms'),
          text: row.read<String>('text'),
        );
        result.putIfAbsent(line.docId, () => {})[line.lineNo] = line;
      }
    }
    return result;
  }

  LyricsHit _hitFor(_Span span, LyricsDoc doc) {
    final first = span.lines.first;
    final text = StringBuffer();
    final highlights = <LyricsHighlight>[];
    for (var i = 0; i < span.lines.length; i++) {
      if (i > 0) text.write(' / ');
      final base = text.length;
      final line = span.lines[i];
      for (final t in span.highlighted[i]) {
        final token = line.tokens[t];
        highlights.add(LyricsHighlight(base + token.start, base + token.end));
      }
      text.write(line.text);
    }
    highlights.sort((a, b) => a.start.compareTo(b.start));
    return LyricsHit(
      trackId: doc.trackId,
      chapterId: doc.chapterId,
      docId: doc.id,
      lineId: first.id,
      lineNo: first.lineNo,
      lineText: text.toString(),
      highlightRanges: highlights,
      positionMs: first.startMs == null ? null : doc.offsetMs + first.startMs!,
      score: span.score,
      kind: LyricsMode.fromDb(doc.kind) ?? LyricsMode.lyrics,
    );
  }
}

/// The FTS5 query for folded query [words]: stop words dropped (unless
/// nothing would remain), unknown words joined by up to five vocabulary
/// words within edit distance 1 (≤ 5 letters) or 2, and the last word as a
/// prefix when it has 4+ letters. Null when there is nothing to match.
@visibleForTesting
String? buildLyricsMatchExpression(
  List<String> words,
  Map<String, int> vocabulary,
) => _matchExpression(words, _Vocabulary(vocabulary));

String? _matchExpression(List<String> words, _Vocabulary vocab) {
  if (words.isEmpty) return null;
  final kept = [
    for (var i = 0; i < words.length; i++)
      if (!isLyricsStopWord(words[i])) (i, words[i]),
  ];
  final use =
      kept.isEmpty
          ? [for (var i = 0; i < words.length; i++) (i, words[i])]
          : kept;
  final terms = <String>{};
  for (final (i, word) in use) {
    final last = i == words.length - 1;
    terms.add(last && word.length >= 4 ? '"$word"*' : '"$word"');
    if ((vocab.terms[word] ?? 0) > 0) continue;
    for (final alt in vocab.near(word, LyricsSearch.maxAlternatives)) {
      terms.add('"$alt"');
    }
  }
  return terms.isEmpty ? null : terms.join(' OR ');
}

/// The index vocabulary, bucketed by length for typo lookups.
class _Vocabulary {
  _Vocabulary(this.terms) {
    for (final entry in terms.entries) {
      if (entry.value <= 0 || isLyricsStopWord(entry.key)) continue;
      _byLength.putIfAbsent(entry.key.length, () => []).add(entry.key);
    }
  }

  final Map<String, int> terms;
  final _byLength = <int, List<String>>{};

  /// Up to [max] words within edit distance 1 (≤ 5 letters) or 2, most
  /// frequent first; never stop words. Words under 3 letters get none.
  List<String> near(String word, int max) {
    if (word.length < 3) return const [];
    final cap = word.length <= 5 ? 1 : 2;
    final found = <String>[];
    for (var len = word.length - cap; len <= word.length + cap; len++) {
      final bucket = _byLength[len];
      if (bucket == null) continue;
      for (final term in bucket) {
        if (term != word && boundedLevenshtein(word, term, cap) <= cap) {
          found.add(term);
        }
      }
    }
    found.sort((a, b) {
      final byCount = terms[b]!.compareTo(terms[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
    return found.length > max ? found.sublist(0, max) : found;
  }
}

/// Edit distance between [a] and [b], or `cap + 1` once it exceeds [cap].
int boundedLevenshtein(String a, String b, int cap) {
  if (a == b) return 0;
  if ((a.length - b.length).abs() > cap) return cap + 1;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (j) => j);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    var rowMin = i;
    final ca = a.codeUnitAt(i - 1);
    for (var j = 1; j <= b.length; j++) {
      final cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
      final value = math.min(
        math.min(previous[j] + 1, current[j - 1] + 1),
        previous[j - 1] + cost,
      );
      current[j] = value;
      if (value < rowMin) rowMin = value;
    }
    if (rowMin > cap) return cap + 1;
    final swap = previous;
    previous = current;
    current = swap;
  }
  return math.min(previous[b.length], cap + 1);
}

/// How well query word [query] matches line word [word]: 1 exact, 0.9 a
/// prefix (3+ letters), else 1 − distance / longer length; under 0.7 is 0.
double wordSimilarity(String query, String word) {
  if (query == word) return 1.0;
  if (query.length >= 3 && word.startsWith(query)) return 0.9;
  final longer = math.max(query.length, word.length);
  if (longer == 0) return 0;
  // sim >= 0.7 ⇔ distance <= 0.3 · longer.
  final cap = (longer * 3) ~/ 10;
  final distance = boundedLevenshtein(query, word, cap);
  if (distance > cap) return 0;
  final similarity = 1 - distance / longer;
  return similarity < 0.7 ? 0 : similarity;
}

/// One stored line with its words.
class _Line {
  _Line({
    required this.id,
    required this.docId,
    required this.lineNo,
    required this.startMs,
    required this.text,
  });

  final int id;
  final int docId;
  final int lineNo;
  final int? startMs;
  final String text;
  late final List<LyricsToken> tokens = tokenizeWithOffsets(text);
}

/// The best scoring run of 1–3 lines around one candidate.
class _Span {
  _Span({
    required this.docId,
    required this.lines,
    required this.score,
    required this.lineCoverage,
    required this.bm25,
    required this.highlighted,
  });

  final int docId;
  final List<_Line> lines;
  final double score;

  /// The share of the span's own words some query word matched.
  final double lineCoverage;
  final double bm25;

  /// Per line of [lines], the token indices to highlight.
  final List<Set<int>> highlighted;

  static const _epsilon = 1e-9;

  /// Higher score, then more of its own words matched, then lower bm25.
  bool betterThan(_Span other) {
    if ((score - other.score).abs() > _epsilon) return score > other.score;
    if ((lineCoverage - other.lineCoverage).abs() > _epsilon) {
      return lineCoverage > other.lineCoverage;
    }
    return bm25 < other.bm25;
  }
}

/// Scores spans against one query; word similarities are memoised.
class _Scorer {
  _Scorer(this.words)
    : weights = [for (final w in words) isLyricsStopWord(w) ? 0.3 : 1.0];

  final List<String> words;
  final List<double> weights;
  late final _memo = [for (final _ in words) <String, double>{}];

  double _similarity(int q, String word) =>
      _memo[q].putIfAbsent(word, () => wordSimilarity(words[q], word));

  _Span? bestSpan(Map<int, _Line> docLines, LyricsFtsCandidate candidate) {
    _Span? best;
    final last = candidate.lineNo + 2;
    for (var start = candidate.lineNo - 1; start <= last; start++) {
      final spanLines = <_Line>[];
      for (var end = start; end <= last && end < start + 3; end++) {
        final line = docLines[end];
        if (line == null) break;
        spanLines.add(line);
        final span = _score(candidate, List.of(spanLines));
        if (span != null && (best == null || span.betterThan(best))) {
          best = span;
        }
      }
    }
    return best;
  }

  _Span? _score(LyricsFtsCandidate candidate, List<_Line> lines) {
    // Words of the span with their line and token index.
    final spanWords = <(String, int, int)>[];
    for (var l = 0; l < lines.length; l++) {
      final tokens = lines[l].tokens;
      for (var t = 0; t < tokens.length; t++) {
        spanWords.add((tokens[t].folded, l, t));
      }
    }
    if (spanWords.isEmpty) return null;

    var total = 0.0;
    var weightSum = 0.0;
    final positions = <int>[];
    final highlighted = [for (final _ in lines) <int>{}];
    for (var q = 0; q < words.length; q++) {
      var best = 0.0;
      var at = -1;
      for (var j = 0; j < spanWords.length; j++) {
        final s = _similarity(q, spanWords[j].$1);
        if (s > best) {
          best = s;
          at = j;
        }
      }
      if (best < 0.7) best = 0;
      total += best * weights[q];
      weightSum += weights[q];
      if (best > 0) {
        positions.add(at);
        highlighted[spanWords[at].$2].add(spanWords[at].$3);
      }
    }
    var inOrder = 0;
    for (var i = 1; i < positions.length; i++) {
      if (positions[i] > positions[i - 1]) inOrder++;
    }
    final orderFraction = inOrder / math.max(1, positions.length - 1);
    final coverage = weightSum == 0 ? 0.0 : total / weightSum;
    final score =
        0.85 * coverage + 0.15 * orderFraction - 0.02 * (lines.length - 1);

    var covered = 0;
    for (final (word, _, _) in spanWords) {
      for (var q = 0; q < words.length; q++) {
        if (_similarity(q, word) > 0) {
          covered++;
          break;
        }
      }
    }
    return _Span(
      docId: candidate.docId,
      lines: lines,
      score: score,
      lineCoverage: covered / spanWords.length,
      bm25: candidate.bm25,
      highlighted: highlighted,
    );
  }
}
