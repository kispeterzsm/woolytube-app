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
  }) {
    final limit = threshold;
    final minimumSamples =
        (minimumDuration.inMicroseconds * sampleRate / 1000000).round();
    final base = offset.inMicroseconds / 1000000;
    final result = <QuietInterval>[];
    int? runStart;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final quiet = s < limit && s > -limit;
      if (quiet) {
        runStart ??= i;
      } else if (runStart != null) {
        if (i - runStart >= minimumSamples) {
          result.add((base + runStart / sampleRate, base + i / sampleRate));
        }
        runStart = null;
      }
    }
    if (runStart != null && samples.length - runStart >= minimumSamples) {
      result.add((
        base + runStart / sampleRate,
        base + samples.length / sampleRate,
      ));
    }
    return result;
  }
}
