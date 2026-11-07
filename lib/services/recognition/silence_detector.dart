import 'dart:math' as math;
import 'dart:typed_data';

import 'chapter_estimator.dart';

/// Finds quiet stretches in 16-bit PCM the way FFmpeg's `silencedetect`
/// filter does (`noise=-40dB:duration=0.2` by default): a run of samples
/// below the threshold that lasts at least the minimum duration, reported
/// from its first quiet sample to the first loud one after it.
class SilenceDetector {
  const SilenceDetector({
    this.sampleRate = 16000,
    this.noiseDb = -40,
    this.minimumDuration = const Duration(milliseconds: 200),
  });

  final int sampleRate;
  final double noiseDb;
  final Duration minimumDuration;

  /// Amplitude threshold on the 16-bit scale, truncated like FFmpeg's
  /// integer path.
  int get threshold => (math.pow(10, noiseDb / 20) * 32767).toInt();

  /// Quiet intervals in seconds, relative to the start of [samples] plus
  /// [offset]. A run still open at the end is closed at the end.
  List<QuietInterval> detect(
    Int16List samples, {
    Duration offset = Duration.zero,
  }) => (SilenceScan(this)..add(samples, offset: offset)).close();
}

/// Runs a [SilenceDetector] over consecutive chunks of one stretch of audio.
///
/// A quiet run that is still open at the end of a chunk carries over into
/// the next one, so splitting a stretch into chunks finds the same
/// intervals as one pass over the whole stretch, including gaps that
/// straddle a chunk edge.
class SilenceScan {
  SilenceScan(this.detector)
    : _limit = detector.threshold,
      _minimumSamples =
          (detector.minimumDuration.inMicroseconds *
                  detector.sampleRate /
                  1000000)
              .round();

  final SilenceDetector detector;
  final int _limit;
  final int _minimumSamples;
  final _result = <QuietInterval>[];

  /// Start of the open quiet run in seconds, and its length in samples.
  double? _runStart;
  int _runSamples = 0;
  double _end = 0;

  /// Adds the next chunk; [offset] is where its first sample lies.
  void add(Int16List samples, {required Duration offset}) {
    final rate = detector.sampleRate;
    final base = offset.inMicroseconds / 1000000;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      if (s < _limit && s > -_limit) {
        _runStart ??= base + i / rate;
        _runSamples++;
      } else if (_runStart != null) {
        if (_runSamples >= _minimumSamples) {
          _result.add((_runStart!, base + i / rate));
        }
        _runStart = null;
        _runSamples = 0;
      }
    }
    _end = base + samples.length / rate;
  }

  /// The intervals found; a run still open is closed at the end of the last
  /// chunk.
  List<QuietInterval> close() {
    if (_runStart != null && _runSamples >= _minimumSamples) {
      _result.add((_runStart!, _end));
    }
    _runStart = null;
    _runSamples = 0;
    return _result;
  }
}
