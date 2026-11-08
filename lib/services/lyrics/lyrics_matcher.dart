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
class LyricsMatcher {
  LyricsMatcher(this.client);

  final LrclibClient client;

  /// Looks up [query]. [durationSeconds] is the file's (or chapter's)
  /// length; [chapter] marks a chapter of a longer file.
  Future<LyricsMatch> match(
    SongQuery query, {
    double? durationSeconds,
    bool chapter = false,
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
          () => client.search(trackName: track, artistName: artistName, q: q),
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
    var anyResults = false;
    final answers = <String, List<LrclibRecord>>{};
    for (final step in steps) {
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
        return LyricsMatch(
          status: LyricsStatus.found,
          record: best.record,
          step: step.name,
          timeScale: synced ? best.timeScale : 1.0,
          synced: synced,
        );
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
    return instrumental ??
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
    double? delta;
    double? ratio;
    if (duration != null && recordDuration != null && recordDuration > 0) {
      delta = (duration - recordDuration).abs();
      ratio = duration / recordDuration;
    }
    var timingFits = false;
    var timeScale = 1.0;
    if (delta != null && delta <= durationToleranceSeconds) {
      timingFits = true;
    } else if (query.nightcore &&
        ratio != null &&
        ratio >= nightcoreMinRatio &&
        ratio <= nightcoreMaxRatio) {
      timingFits = true;
      timeScale = ratio;
    } else if (chapter) {
      // Chapters are often shortened versions; the start still lines up.
      timingFits = true;
    }
    return _Fit(
      record,
      titleSim,
      artistSim,
      delta,
      ratio,
      timingFits,
      timeScale,
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
    if (delta != null && delta <= durationToleranceSeconds) return true;
    final ratio = fit.ratio;
    return query.nightcore &&
        ratio != null &&
        ratio >= nightcoreMinRatio &&
        ratio <= nightcoreMaxRatio;
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
