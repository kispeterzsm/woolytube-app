import 'dart:math' as math;

import '../chapters.dart';
import 'shazam_client.dart';

/// One recognized sample window of a scanned file.
class RecognitionSample {
  final int sampleStartMs;
  final int sampleDurationMs;
  final ShazamResult result;

  const RecognitionSample({
    required this.sampleStartMs,
    required this.sampleDurationMs,
    required this.result,
  });
}

/// A quiet stretch of the file, in seconds.
typedef QuietInterval = (double start, double end);

/// A draft chapter with the evidence behind it, mirroring the PC prototype's
/// report so the review screen can show why a boundary was chosen.
class ChapterProposal {
  final String id;
  final String title;
  final int startMs;
  final int endMs;
  final String? trackKey;
  final String? referenceId;
  final int sampleCount;
  final int referenceSampleCount;
  final int? referenceStartMs;
  final int? referenceSpreadMs;

  /// 'file-start', 'reference-offset', 'quiet-transition', 'sample-bracket'
  /// or 'manual' (the user set the start in the chapter editor).
  final String boundaryMethod;
  final (int, int)? selectedQuietIntervalMs;
  final (int, int)? nearestSilenceMs;
  final int? distanceFromSilenceEndMs;
  final bool consistentReference;
  final List<String> notes;
  final int firstSampleMs;
  final int lastSampleMs;

  /// The user renamed or merged this proposal on the review page. Applied,
  /// it counts as their own work, which later scans never replace.
  final bool edited;

  const ChapterProposal({
    required this.id,
    required this.title,
    required this.startMs,
    required this.endMs,
    required this.trackKey,
    required this.referenceId,
    required this.sampleCount,
    required this.referenceSampleCount,
    required this.referenceStartMs,
    required this.referenceSpreadMs,
    required this.boundaryMethod,
    required this.selectedQuietIntervalMs,
    required this.nearestSilenceMs,
    required this.distanceFromSilenceEndMs,
    required this.consistentReference,
    required this.notes,
    required this.firstSampleMs,
    required this.lastSampleMs,
    this.edited = false,
  });

  /// A chapter the user added in the chapter editor (no detections).
  factory ChapterProposal.manual({
    required String id,
    required String title,
    required int startMs,
    required int endMs,
  }) => ChapterProposal(
    id: id,
    title: title,
    startMs: startMs,
    endMs: endMs,
    trackKey: null,
    referenceId: null,
    sampleCount: 0,
    referenceSampleCount: 0,
    referenceStartMs: null,
    referenceSpreadMs: null,
    boundaryMethod: manualBoundary,
    selectedQuietIntervalMs: null,
    nearestSilenceMs: null,
    distanceFromSilenceEndMs: null,
    consistentReference: false,
    notes: const [],
    firstSampleMs: startMs,
    lastSampleMs: endMs,
    edited: true,
  );

  static const manualBoundary = 'manual';

  bool get recognized => trackKey != null;

  /// Added by the user rather than found by the scan.
  bool get addedByUser =>
      boundaryMethod == manualBoundary && trackKey == null && sampleCount == 0;

  ChapterProposal copyWith({
    String? title,
    int? startMs,
    int? endMs,
    String? boundaryMethod,
    List<String>? notes,
    bool? edited,
  }) => ChapterProposal(
    id: id,
    title: title ?? this.title,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    trackKey: trackKey,
    referenceId: referenceId,
    sampleCount: sampleCount,
    referenceSampleCount: referenceSampleCount,
    referenceStartMs: referenceStartMs,
    referenceSpreadMs: referenceSpreadMs,
    boundaryMethod: boundaryMethod ?? this.boundaryMethod,
    selectedQuietIntervalMs: selectedQuietIntervalMs,
    nearestSilenceMs: nearestSilenceMs,
    distanceFromSilenceEndMs: distanceFromSilenceEndMs,
    consistentReference: consistentReference,
    notes: notes ?? this.notes,
    firstSampleMs: firstSampleMs,
    lastSampleMs: lastSampleMs,
    edited: edited ?? this.edited,
  );

  /// This proposal with a title the user typed: it counts as edited, and the
  /// notes that doubted the recognised name no longer apply.
  ChapterProposal renamed(String title) => copyWith(
    title: title,
    edited: true,
    notes: notes.where((note) => !_nameNotes.contains(note)).toList(),
  );

  /// This proposal as the chapter editor left it. A new title counts as a
  /// rename; a moved start was set by the user, so the notes doubting the
  /// old start no longer apply. Any change marks it edited.
  ChapterProposal adjusted({
    required String title,
    required int startMs,
    required int endMs,
  }) {
    final trimmed = title.trim();
    if (trimmed == this.title &&
        startMs == this.startMs &&
        endMs == this.endMs) {
      return this;
    }
    var next = trimmed == this.title ? this : renamed(trimmed);
    if (startMs != this.startMs) {
      next = next.copyWith(
        boundaryMethod: manualBoundary,
        notes: next.notes.where(_nameNotes.contains).toList(),
      );
    }
    return next.copyWith(startMs: startMs, endMs: endMs, edited: true);
  }

  /// The chapter this proposal becomes when applied. Review reasons keep the
  /// prefixes the chapter service uses to clear them on rename or retiming.
  MediaChapter toChapter() => MediaChapter(
    id: id,
    title: title,
    startMs: startMs,
    endMs: endMs,
    origin: ChapterOrigin.auto,
    manuallyEdited: edited,
    reviewReasons: reviewReasons,
  );

  List<String> get reviewReasons => [
    for (final note in notes)
      if (_nameNotes.contains(note)) 'Name: $note' else 'Timing: $note',
  ];

  static const _nameNotes = {unrecognizedNote, singleDetectionNote};

  static const unrecognizedNote =
      'Unrecognized audio; retain this range for review.';
  static const singleDetectionNote =
      'Only one sampled detection; verify the identity.';
  static const provisionalBoundaryNote =
      'Reference offset cannot locate this occurrence; boundary is provisional.';
  static const disagreeingStartsNote =
      'Reference start estimates disagree by more than two seconds.';
  static const noSilenceNote =
      'No silence ending within three seconds of the reference start.';
  static const multipleGapsNote =
      'Multiple quiet gaps between detections; review the selected boundary.';

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'startMs': startMs,
    'endMs': endMs,
    'trackKey': trackKey,
    'referenceId': referenceId,
    'sampleCount': sampleCount,
    'referenceSampleCount': referenceSampleCount,
    'referenceStartMs': referenceStartMs,
    'referenceSpreadMs': referenceSpreadMs,
    'boundaryMethod': boundaryMethod,
    'selectedQuietIntervalMs':
        selectedQuietIntervalMs == null
            ? null
            : [selectedQuietIntervalMs!.$1, selectedQuietIntervalMs!.$2],
    'nearestSilenceMs':
        nearestSilenceMs == null
            ? null
            : [nearestSilenceMs!.$1, nearestSilenceMs!.$2],
    'distanceFromSilenceEndMs': distanceFromSilenceEndMs,
    'consistentReference': consistentReference,
    'notes': notes,
    'firstSampleMs': firstSampleMs,
    'lastSampleMs': lastSampleMs,
    'edited': edited,
  };

  static (int, int)? _pair(Object? value) =>
      value is List && value.length == 2
          ? ((value[0] as num).toInt(), (value[1] as num).toInt())
          : null;

  factory ChapterProposal.fromJson(Map<String, dynamic> json) =>
      ChapterProposal(
        id: json['id'] as String,
        title: json['title'] as String,
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        trackKey: json['trackKey'] as String?,
        referenceId: json['referenceId'] as String?,
        sampleCount: json['sampleCount'] as int,
        referenceSampleCount: json['referenceSampleCount'] as int,
        referenceStartMs: json['referenceStartMs'] as int?,
        referenceSpreadMs: json['referenceSpreadMs'] as int?,
        boundaryMethod: json['boundaryMethod'] as String,
        selectedQuietIntervalMs: _pair(json['selectedQuietIntervalMs']),
        nearestSilenceMs: _pair(json['nearestSilenceMs']),
        distanceFromSilenceEndMs: json['distanceFromSilenceEndMs'] as int?,
        consistentReference: json['consistentReference'] == true,
        notes: (json['notes'] as List? ?? const []).cast<String>(),
        firstSampleMs: json['firstSampleMs'] as int,
        lastSampleMs: json['lastSampleMs'] as int,
        edited: json['edited'] == true,
      );
}

/// Turns sampled recognitions plus quiet intervals into draft chapters.
///
/// This is a direct port of the PC prototype's estimator: consecutive samples
/// with the same catalog key form a song; its start comes from the reference
/// offsets when they agree with the sample order, and is snapped to a quiet
/// transition inside the change bracket when one exists. Anything uncertain
/// is kept as a note instead of being hidden.
class ChapterEstimator {
  /// Quiet intervals closer than this are treated as one gap.
  static const mergeGapSeconds = 3.0;

  /// Only gaps at least this long can carry a boundary.
  static const minimumGapSeconds = 0.4;

  static List<QuietInterval> mergeQuietIntervals(Iterable<QuietInterval> raw) {
    final merged = <QuietInterval>[];
    for (final (start, end) in raw) {
      if (merged.isNotEmpty && start - merged.last.$2 < mergeGapSeconds) {
        merged[merged.length - 1] = (merged.last.$1, end);
      } else {
        merged.add((start, end));
      }
    }
    return merged;
  }

  static List<ChapterProposal> estimate({
    required String runName,
    required int durationMs,
    required List<RecognitionSample> samples,
    required Iterable<QuietInterval> quietIntervals,
  }) {
    final rows = [...samples]
      ..sort((a, b) => a.sampleStartMs.compareTo(b.sampleStartMs));
    final silences = mergeQuietIntervals(quietIntervals);
    final chapters = <ChapterProposal>[];

    var index = 0;
    while (index < rows.length) {
      final key = rows[index].result.trackKey;
      final group = <RecognitionSample>[];
      while (index < rows.length && rows[index].result.trackKey == key) {
        group.add(rows[index++]);
      }
      final first = group.first.result;

      // Reference recordings can differ between samples; estimate the start
      // from the one that explains the most samples.
      final estimatesById = <String, List<double>>{};
      for (final row in group) {
        for (final offset in row.result.offsets) {
          estimatesById
              .putIfAbsent(offset.referenceId, () => [])
              .add(row.sampleStartMs - offset.offsetSeconds * 1000);
        }
      }
      String? referenceId;
      for (final entry in estimatesById.entries) {
        if (referenceId == null ||
            entry.value.length > estimatesById[referenceId]!.length) {
          referenceId = entry.key;
        }
      }
      final estimates =
          referenceId == null ? <double>[] : estimatesById[referenceId]!;
      final estimate = estimates.isEmpty ? null : _median(estimates);
      final spread =
          estimates.isEmpty
              ? null
              : estimates.reduce(math.max) - estimates.reduce(math.min);

      final previousSample = chapters.isEmpty ? 0 : chapters.last.lastSampleMs;
      final latestStart =
          group.first.sampleStartMs + group.first.sampleDurationMs;
      final plausible =
          estimate != null &&
          previousSample <= estimate &&
          estimate <= latestStart;
      final consistent = estimates.length >= 2 && spread! <= 2000 && plausible;

      int start;
      if (chapters.isEmpty) {
        start = 0;
      } else if (plausible) {
        start = pythonRound(estimate);
      } else {
        start = pythonRound((previousSample + latestStart) / 2);
      }

      final candidates = [
        for (final s in silences)
          if (previousSample < s.$2 * 1000 &&
              s.$2 * 1000 <= latestStart &&
              s.$2 - s.$1 >= minimumGapSeconds)
            s,
      ];
      var boundaryMethod =
          chapters.isEmpty
              ? 'file-start'
              : plausible
              ? 'reference-offset'
              : 'sample-bracket';
      QuietInterval? selected;
      if (chapters.isNotEmpty && candidates.isNotEmpty) {
        final QuietInterval chosen =
            plausible
                ? _minBy(candidates, (s) => (s.$2 * 1000 - estimate).abs())
                : _maxBy(candidates, (s) => s.$2 - s.$1);
        selected = chosen;
        start = pythonRound(chosen.$2 * 1000 - 100);
        boundaryMethod = 'quiet-transition';
      }
      final anchor =
          (estimate == null || estimate == 0) ? start.toDouble() : estimate;
      final nearest =
          silences.isEmpty
              ? null
              : _minBy(silences, (s) => (s.$2 * 1000 - anchor).abs());
      int? silenceDistance;
      if (nearest != null && estimate != null) {
        silenceDistance = pythonRound((nearest.$2 * 1000 - estimate).abs());
      }

      final notes = <String>[
        if (key == null) ChapterProposal.unrecognizedNote,
        if (group.length < 2) ChapterProposal.singleDetectionNote,
        if (estimate == null || (chapters.isNotEmpty && !plausible))
          ChapterProposal.provisionalBoundaryNote,
        if (spread != null && spread > 2000)
          ChapterProposal.disagreeingStartsNote,
        if (silenceDistance != null && silenceDistance > 3000)
          ChapterProposal.noSilenceNote,
        if (candidates.length > 1) ChapterProposal.multipleGapsNote,
      ];

      chapters.add(
        ChapterProposal(
          id: 'recognition-$runName-$start',
          title:
              key != null
                  ? '${first.artist} — ${first.title}'
                  : 'Unrecognized section',
          startMs: start,
          endMs: durationMs,
          trackKey: key,
          referenceId: referenceId,
          sampleCount: group.length,
          referenceSampleCount: estimates.length,
          referenceStartMs: estimate == null ? null : pythonRound(estimate),
          referenceSpreadMs: spread == null ? null : pythonRound(spread),
          boundaryMethod: boundaryMethod,
          selectedQuietIntervalMs: selected == null ? null : _toMs(selected),
          nearestSilenceMs: nearest == null ? null : _toMs(nearest),
          distanceFromSilenceEndMs: silenceDistance,
          consistentReference: consistent,
          notes: notes,
          firstSampleMs: group.first.sampleStartMs,
          lastSampleMs: group.last.sampleStartMs,
        ),
      );
    }
    final kept = _withIncreasingStarts(chapters, durationMs);
    for (var i = 0; i + 1 < kept.length; i++) {
      kept[i] = kept[i].copyWith(endMs: kept[i + 1].startMs);
    }
    return kept;
  }

  /// Two neighbouring groups can snap to the same quiet gap, or the later
  /// one to an earlier gap, which would give an empty or backwards chapter
  /// and two proposals with the same ID. Of such a pair the one with less
  /// evidence is dropped (the earlier one on a tie), so every proposal has a
  /// positive length and a unique start, and therefore a unique ID. The
  /// first proposal always starts the file and is never dropped.
  static List<ChapterProposal> _withIncreasingStarts(
    List<ChapterProposal> chapters,
    int durationMs,
  ) {
    int strength(ChapterProposal c) =>
        (c.recognized ? 1 << 20 : 0) + c.sampleCount;
    final kept = <ChapterProposal>[];
    for (final chapter in chapters) {
      if (kept.isEmpty) {
        kept.add(chapter);
        continue;
      }
      if (chapter.startMs >= durationMs) continue;
      var dropped = false;
      while (kept.isNotEmpty && chapter.startMs <= kept.last.startMs) {
        if (kept.length == 1 || strength(kept.last) > strength(chapter)) {
          dropped = true;
          break;
        }
        kept.removeLast();
      }
      if (!dropped) kept.add(chapter);
    }
    return kept;
  }

  static (int, int) _toMs(QuietInterval s) => (
    pythonRound(s.$1 * 1000),
    pythonRound(s.$2 * 1000),
  );

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static T _minBy<T>(List<T> items, double Function(T) key) {
    var best = items.first;
    var bestKey = key(best);
    for (final item in items.skip(1)) {
      final k = key(item);
      if (k < bestKey) {
        best = item;
        bestKey = k;
      }
    }
    return best;
  }

  static T _maxBy<T>(List<T> items, double Function(T) key) {
    var best = items.first;
    var bestKey = key(best);
    for (final item in items.skip(1)) {
      final k = key(item);
      if (k > bestKey) {
        best = item;
        bestKey = k;
      }
    }
    return best;
  }
}

/// Python's round(): halves go to the even neighbour.
int pythonRound(double value) {
  final floor = value.floorToDouble();
  final diff = value - floor;
  if (diff > 0.5) return floor.toInt() + 1;
  if (diff < 0.5) return floor.toInt();
  return floor.toInt().isEven ? floor.toInt() : floor.toInt() + 1;
}
