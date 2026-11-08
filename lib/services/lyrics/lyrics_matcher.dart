/// Finds a song's lyrics on LRCLIB: the lookup order, the acceptance rule
/// and the nightcore time scale. Plain Dart (no Flutter), so
/// tool/lyrics_eval.dart can run it.
library;

import 'lrclib_client.dart';
import 'lyrics_models.dart';
import 'lyrics_text.dart';
import 'title_parser.dart';

/// Title similarity needed to accept a record.
const minTitleSimilarity = 0.75;

/// Title similarity needed for a chapter that names no artist (nothing
/// else confirms the match).
const minChapterTitleSimilarity = 0.85;

/// Artist similarity needed when the artist is known.
const minArtistSimilarity = 0.6;

/// A whole file within this many seconds of a record has the same timing.
const durationToleranceSeconds = 4.0;

/// A nightcore file is this fraction of the original's length.
const nightcoreMinRatio = 0.70;
const nightcoreMaxRatio = 0.93;

/// The last synced line must start at least this long before the file (or
/// chapter) ends.
const syncedEndMarginMs = 1000;

/// A record's last line may start this much after its stated length (the
/// length is rounded) before the length counts as wrong.
const claimedDurationSlackMs = 1000;

/// When a record's synced lines start and end (unscaled), or null when it
/// has no timed lines.
({int firstMs, int lastMs})? syncedSpanOf(LrclibRecord record) {
  final synced = record.syncedLyrics;
  if (synced == null) return null;
  int? first;
  int? last;
  for (final line in parseLrc(synced)) {
    final start = line.startMs;
    if (start == null) continue;
    if (first == null || start < first) first = start;
    if (last == null || start > last) last = start;
  }
  return first == null ? null : (firstMs: first, lastMs: last!);
}

/// Whether a record states a length its own lines fit in. A record whose
/// lines run past its stated length is mislabelled (another recording's
/// lines under this one's length), so that length says nothing.
bool claimedDurationTrustworthy(double? claimedSeconds, int? lastLineMs) =>
    claimedSeconds != null &&
    claimedSeconds > 0 &&
    (lastLineMs == null ||
        lastLineMs <= claimedSeconds * 1000 + claimedDurationSlackMs);

/// Whether synced lines whose last one starts at [lastLineMs] (doc time,
/// already scaled) fit a file of [durationMs].
bool syncedLinesFit(int lastLineMs, int durationMs) =>
    lastLineMs <= durationMs - syncedEndMarginMs;

/// How a record's synced lines fit a file or chapter.
class SyncedTiming {
  /// Whether the times can be used.
  final bool fits;

  /// Line times are multiplied by this (nightcore: local / original).
  final double timeScale;

  /// The record's stated length is wrong for its own lines.
  final bool mislabelled;

  const SyncedTiming(
    this.fits, {
    this.timeScale = 1.0,
    this.mislabelled = false,
  });

  static const none = SyncedTiming(false);
}

/// Whether [record]'s synced times fit a file (or [chapter]) of
/// [localSeconds], checked against its real line times, not only its
/// stated length:
///
/// * a whole file must be as long as the record (±4 s), or a nightcore
///   speed-up of it when [nightcore]; then the last line, scaled, must
///   start before the file ends;
/// * a chapter is often a shortened version (a TV size), whose lines are
///   cut at its end: the first line must start inside it;
/// * a record whose lines run past its stated length never fits.
SyncedTiming syncedTimingFor(
  LrclibRecord record, {
  required double? localSeconds,
  bool nightcore = false,
  bool chapter = false,
}) {
  final span = syncedSpanOf(record);
  if (span == null || localSeconds == null || localSeconds <= 0) {
    return SyncedTiming.none;
  }
  final claimed = record.duration;
  if (!claimedDurationTrustworthy(claimed, span.lastMs)) {
    return const SyncedTiming(false, mislabelled: true);
  }
  final localMs = (localSeconds * 1000).round();
  final ratio = localSeconds / claimed!;
  var scale = 1.0;
  if ((localSeconds - claimed).abs() <= durationToleranceSeconds) {
    scale = 1.0;
  } else if (nightcore &&
      ratio >= nightcoreMinRatio &&
      ratio <= nightcoreMaxRatio) {
    scale = ratio;
  } else if (!chapter) {
    return SyncedTiming.none;
  }
  if (chapter) {
    final first = (span.firstMs * scale).round();
    return SyncedTiming(first <= localMs - syncedEndMarginMs, timeScale: scale);
  }
  final last = (span.lastMs * scale).round();
  return SyncedTiming(syncedLinesFit(last, localMs), timeScale: scale);
}

/// [record] as a picker result, with whether its synced times fit a file
/// (or [chapter]) of [localSeconds].
LyricsCandidate lyricsCandidateFor(
  LrclibRecord record, {
  double? localSeconds,
  bool nightcore = false,
  bool chapter = false,
}) {
  final span = syncedSpanOf(record);
  return LyricsCandidate(
    id: record.id,
    artist: record.artistName,
    title: record.trackName,
    album: record.albumName,
    durationSeconds: record.duration,
    synced: record.isSynced,
    instrumental: record.instrumental,
    plainPreview: record.plainText,
    lastLineSeconds: span == null ? null : span.lastMs / 1000,
    localSeconds: localSeconds,
    timingFits:
        span == null || localSeconds == null || record.instrumental
            ? null
            : syncedTimingFor(
              record,
              localSeconds: localSeconds,
              nightcore: nightcore,
              chapter: chapter,
            ).fits,
  );
}

/// [candidates] with the records of one song (same title and artist)
/// reordered among themselves: synced times that fit first, then plain
/// ones, then times that do not fit. Other songs keep their places.
List<LyricsCandidate> sortCandidatesByFit(List<LyricsCandidate> candidates) {
  String key(LyricsCandidate c) =>
      '${foldForSearch(c.artist)}|${foldForSearch(c.title)}';
  int rank(LyricsCandidate c) => switch (c.timingFits) {
    true => 0,
    null => 1,
    false => 2,
  };
  final groups = <String, List<int>>{};
  for (final (i, c) in candidates.indexed) {
    groups.putIfAbsent(key(c), () => []).add(i);
  }
  final result = [...candidates];
  for (final positions in groups.values) {
    if (positions.length < 2) continue;
    final members = [for (final i in positions) candidates[i]];
    // A stable sort: equal ranks keep LRCLIB's order.
    final order = [for (var i = 0; i < members.length; i++) i]..sort((a, b) {
      final byRank = rank(members[a]).compareTo(rank(members[b]));
      return byRank != 0 ? byRank : a.compareTo(b);
    });
    for (var j = 0; j < positions.length; j++) {
      result[positions[j]] = members[order[j]];
    }
  }
  return result;
}

/// What a lookup decided.
class LyricsMatch {
  /// One of [LyricsStatus]: found, instrumental or none.
  final String status;
  final LrclibRecord? record;

  /// The lookup step that found it ('get', 'search', 'swapped', 'alt',
  /// 'q', 'title').
  final String? step;

  /// Line times are multiplied by this (nightcore: local / original).
  final double timeScale;

  /// Whether the stored lines carry times. False for plain lyrics and for
  /// synced lyrics whose timing does not fit the file.
  final bool synced;

  /// Why nothing was accepted (for logs and the eval tool).
  final String? reason;

  const LyricsMatch({
    required this.status,
    this.record,
    this.step,
    this.timeScale = 1.0,
    this.synced = false,
    this.reason,
  });

  const LyricsMatch.none(String this.reason)
    : status = LyricsStatus.none,
      record = null,
      step = null,
      timeScale = 1.0,
      synced = false;

  bool get found => status == LyricsStatus.found;

  /// The lines to store: timed and scaled when [synced], plain otherwise.
  List<LyricsLineDraft> get lines {
    final record = this.record;
    if (record == null || !found) return const [];
    return lyricsLinesFor(record, synced: synced, timeScale: timeScale);
  }

  @override
  String toString() =>
      found
          ? 'found ${record!.artistName} - ${record!.trackName} via $step'
              '${synced ? ' synced' : ' plain'}'
              '${timeScale == 1.0 ? '' : ' x${timeScale.toStringAsFixed(3)}'}'
          : '$status${reason == null ? '' : ' ($reason)'}';
}

/// The lines of [record]: its synced lyrics with times multiplied by
/// [timeScale], or its plain lyrics.
List<LyricsLineDraft> lyricsLinesFor(
  LrclibRecord record, {
  required bool synced,
  double timeScale = 1.0,
}) {
  final syncedLyrics = record.syncedLyrics;
  if (synced && syncedLyrics != null) {
    final lines = parseLrc(syncedLyrics);
    if (lines.isNotEmpty) {
      return [
        for (final line in lines)
          LyricsLineDraft(
            line.text,
            startMs:
                timeScale == 1.0
                    ? line.startMs
                    : (line.startMs! * timeScale).round(),
          ),
      ];
    }
  }
  return parsePlainLyrics(record.plainLyrics ?? record.plainText);
}

/// How one record fits a query.
class _Fit {
  final LrclibRecord record;
  final double titleSim;
  final double? artistSim;
  final double? delta;
  final double? ratio;
  final bool timingFits;
  final double timeScale;

  _Fit(
    this.record,
    this.titleSim,
    this.artistSim,
    this.delta,
    this.ratio,
    this.timingFits,
    this.timeScale,
  );
}

/// One lookup: a request and the (artist, title) its results are judged
/// against.
class _Step {
  final String name;
  final String? artist;
  final String title;

  /// The request's kind and parameters; equal keys send one request.
  final String request;
  final Future<List<LrclibRecord>> Function() run;

  _Step(this.name, this.artist, this.title, this.request, this.run);
}

/// Looks songs up on LRCLIB. Stops at the first accepted record:
///
/// 1. `get(A, T, duration)`, not for nightcore or chapters;
/// 2. `search(track_name: T, artist_name: A)`;
/// 3. the same swapped when the title had two parts;
/// 4. other readings of the title;
/// 5. `q = "A T"` (with the context word for chapters);
/// 6. `track_name: T` alone (a known artist must still match).
///
/// A record is accepted when it has lyrics, its title is similar enough
/// and: the artist matches when one is known; otherwise the duration fits
/// (±4 s, or the nightcore window). Chapters are never gated on duration.
/// A record whose lines run past its stated length has no known duration.
///
/// Times are kept only when [syncedTimingFor] says they fit. When the best
/// record's synced times do not fit, later steps may still find a record
/// of the same song whose times do; otherwise it is stored plain.
class LyricsMatcher {
  LyricsMatcher(this.client);

  final LrclibClient client;

  /// Looks up [query]. [durationSeconds] is the file's (or chapter's)
  /// length; [chapter] marks a chapter of a longer file.
  Future<LyricsMatch> match(
    SongQuery query, {
    double? durationSeconds,
    bool chapter = false,
    bool Function()? stop,
  }) async {
    final artist = query.artist;
    final title = query.title;
    final steps = <_Step>[];
    void search(
      String name,
      String? judgeArtist,
      String judgeTitle, {
      String? track,
      String? artistName,
      String? q,
    }) {
      steps.add(
        _Step(
          name,
          judgeArtist,
          judgeTitle,
          'search|$track|$artistName|$q',
          () => client.search(
            trackName: track,
            artistName: artistName,
            q: q,
            stop: stop,
          ),
        ),
      );
    }

    if (artist != null &&
        !query.nightcore &&
        !chapter &&
        durationSeconds != null) {
      steps.add(
        _Step('get', artist, title, 'get|$artist|$title', () async {
          final record = await client.get(
            artist: artist,
            track: title,
            durationSeconds: durationSeconds,
            stop: stop,
          );
          return record == null ? const <LrclibRecord>[] : [record];
        }),
      );
    }
    if (artist != null) {
      search('search', artist, title, track: title, artistName: artist);
      if (query.swappable) {
        search('swapped', title, artist, track: artist, artistName: title);
      }
    }
    for (final (altArtist, altTitle) in query.alternatives.take(2)) {
      search(
        'alt',
        altArtist,
        altTitle,
        track: altTitle,
        artistName: altArtist,
      );
    }
    final q = [
      if (artist == null && query.contextWord != null) query.contextWord!,
      if (artist != null) artist,
      title,
    ].join(' ');
    search('q', artist, title, q: q);
    // The title alone finds records filed under another spelling of the
    // artist ("Yun*chi"); a known artist must still match.
    search('title', artist, title, track: title);
    if (query.alternatives.firstOrNull case (final altArtist, final altTitle)) {
      search('title', altArtist, altTitle, track: altTitle);
    }

    LyricsMatch? instrumental;
    // Synced lyrics whose times do not fit: kept as plain unless a later
    // step finds a record of the same song whose times fit.
    LyricsMatch? untimed;
    var anyResults = false;
    final answers = <String, List<LrclibRecord>>{};
    for (final step in steps) {
      if (stop?.call() ?? false) {
        throw const LrclibException('Stopped', transient: true);
      }
      final records = answers[step.request] ??= await step.run();
      if (records.isNotEmpty) anyResults = true;
      final fits = [
        for (final record in records)
          _fit(record, step, query, durationSeconds, chapter),
      ];
      final accepted = fits.where((f) => _accepted(f, step, query, chapter));
      final withLyrics = accepted.where((f) => f.record.hasLyrics).toList();
      if (withLyrics.isNotEmpty) {
        withLyrics.sort(_preference);
        final best = withLyrics.first;
        final synced = best.record.isSynced && best.timingFits;
        final match = LyricsMatch(
          status: LyricsStatus.found,
          record: best.record,
          step: step.name,
          timeScale: synced ? best.timeScale : 1.0,
          synced: synced,
        );
        if (synced) return match;
        if (!best.record.isSynced) return untimed ?? match;
        untimed ??= match;
        continue;
      }
      final instrumentalFit =
          accepted.where((f) => f.record.instrumental).firstOrNull;
      if (instrumentalFit != null) {
        instrumental ??= LyricsMatch(
          status: LyricsStatus.instrumental,
          record: instrumentalFit.record,
          step: step.name,
        );
        // An exact match says so with authority.
        if (step.name == 'get') return instrumental;
      }
    }
    return untimed ??
        instrumental ??
        LyricsMatch.none(anyResults ? 'no result fits' : 'no results');
  }

  _Fit _fit(
    LrclibRecord record,
    _Step step,
    SongQuery query,
    double? duration,
    bool chapter,
  ) {
    final titleSim = textSimilarity(record.trackName, step.title);
    final artistSim =
        step.artist == null
            ? null
            : artistSimilarity(record.artistName, step.artist!);
    final recordDuration = record.duration;
    // A record whose lines run past its stated length has no known length.
    final trustworthy = claimedDurationTrustworthy(
      recordDuration,
      syncedSpanOf(record)?.lastMs,
    );
    double? delta;
    double? ratio;
    if (duration != null && trustworthy) {
      delta = (duration - recordDuration!).abs();
      ratio = duration / recordDuration;
    }
    final timing = syncedTimingFor(
      record,
      localSeconds: duration,
      nightcore: query.nightcore,
      chapter: chapter,
    );
    return _Fit(
      record,
      titleSim,
      artistSim,
      delta,
      ratio,
      timing.fits,
      timing.fits ? timing.timeScale : 1.0,
    );
  }

  bool _accepted(_Fit fit, _Step step, SongQuery query, bool chapter) {
    if (!fit.record.hasLyrics && !fit.record.instrumental) return false;
    if (fit.titleSim < minTitleSimilarity) return false;
    if (step.artist != null) {
      return (fit.artistSim ?? 0) >= minArtistSimilarity;
    }
    if (chapter) return fit.titleSim >= minChapterTitleSimilarity;
    final delta = fit.delta;
    final ratio = fit.ratio;
    final sped =
        ratio != null &&
        ratio >= nightcoreMinRatio &&
        ratio <= nightcoreMaxRatio;
    if (query.nightcore) {
      // A sped-up upload is shorter than its original: a record of the
      // same length is another song with that title. With no artist the
      // title alone must match closely.
      return sped && fit.titleSim >= minChapterTitleSimilarity;
    }
    return delta != null && delta <= durationToleranceSeconds;
  }

  /// Synced with fitting timing first, then synced, then closest length,
  /// then the most similar.
  static int _preference(_Fit a, _Fit b) {
    int rank(_Fit f) =>
        f.record.isSynced && f.timingFits
            ? 0
            : f.record.isSynced
            ? 1
            : 2;
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    final byDelta = (a.delta ?? double.infinity).compareTo(
      b.delta ?? double.infinity,
    );
    if (byDelta != 0) return byDelta;
    return (b.titleSim + (b.artistSim ?? 0)).compareTo(
      a.titleSim + (a.artistSim ?? 0),
    );
  }
}
