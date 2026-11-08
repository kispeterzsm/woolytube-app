import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'recognition/audio_window_decoder.dart';

/// Loudness of a stretch of a file, one value per [bucketMs].
class WaveformWindow {
  /// Time of the first bucket, on the file timeline.
  final int startMs;
  final int bucketMs;

  /// Peak level (0..1) of each bucket, NaN for a bucket the decoder gave
  /// no audio for (it is not silence). Shorter than asked for when the
  /// file ends inside the window.
  final Float32List peaks;

  const WaveformWindow({
    required this.startMs,
    required this.bucketMs,
    required this.peaks,
  });

  /// Time just after the last bucket.
  int get endMs => startMs + peaks.length * bucketMs;

  /// The peak level at [ms]; 0 outside the window or without audio there.
  double peakAt(int ms) {
    if (ms < startMs) return 0;
    final i = (ms - startMs) ~/ bucketMs;
    if (i >= peaks.length) return 0;
    final peak = peaks[i];
    return peak.isNaN ? 0 : peak;
  }
}

/// Peak and RMS level (0..1) per bucket of 16 kHz mono PCM.
({Float32List peaks, Float32List rms}) waveformBuckets(
  Int16List samples, {
  int sampleRate = WaveformService.sampleRate,
  int bucketMs = WaveformService.bucketMs,
}) {
  final perBucket = max(1, sampleRate * bucketMs ~/ 1000);
  final count = (samples.length + perBucket - 1) ~/ perBucket;
  final peaks = Float32List(count);
  final rms = Float32List(count);
  for (var b = 0; b < count; b++) {
    final from = b * perBucket;
    final to = min(from + perBucket, samples.length);
    var peak = 0;
    var sum = 0.0;
    for (var i = from; i < to; i++) {
      final s = samples[i];
      final a = s < 0 ? -s : s;
      if (a > peak) peak = a;
      sum += s * s;
    }
    peaks[b] = min(1.0, peak / 32768);
    rms[b] = min(1.0, sqrt(sum / (to - from)) / 32768);
  }
  return (peaks: peaks, rms: rms);
}

/// The centre (file time) of the quietest run of [runMs] in [rms], whose
/// first bucket is at [startMs]. "Quietest" is the lowest RMS over the run.
/// Ties go to the run closest to [preferMs]. Runs over a bucket without
/// audio (NaN) are skipped. Null when there is no such run.
int? quietestRunCenterMs(
  Float32List rms, {
  required int startMs,
  int bucketMs = WaveformService.bucketMs,
  int runMs = 200,
  int? preferMs,
}) {
  final run = max(1, runMs ~/ bucketMs);
  if (rms.length < run) return null;
  final half = run * bucketMs ~/ 2;
  final prefer = preferMs ?? startMs + rms.length * bucketMs ~/ 2;
  double energy(int i) => rms[i].isNaN ? 0 : rms[i] * rms[i];
  var sum = 0.0;
  var missing = 0;
  double? bestSum;
  var bestCenter = 0;
  for (var i = 0; i < rms.length; i++) {
    sum += energy(i);
    if (rms[i].isNaN) missing++;
    final first = i - run + 1;
    if (first > 0) {
      sum -= energy(first - 1);
      if (rms[first - 1].isNaN) missing--;
    }
    if (first < 0 || missing > 0) continue;
    final center = startMs + first * bucketMs + half;
    const epsilon = 1e-9;
    final best = bestSum;
    if (best == null ||
        sum < best - epsilon ||
        (sum <= best + epsilon &&
            (center - prefer).abs() < (bestCenter - prefer).abs())) {
      bestSum = max(0, sum);
      bestCenter = center;
    }
  }
  return bestSum == null ? null : bestCenter;
}

/// Loads waveforms for the chapter editor from short decoded stretches of
/// the file, cached in 10-second blocks.
class WaveformService {
  static const sampleRate = 16000;
  static const bucketMs = 10;
  static const blockMs = 10000;
  static const maxCachedBlocks = 60;

  final AudioWindowDecoder _decoder;
  final _blocks = <(String, int), Future<_Block>>{};

  WaveformService(AudioWindowDecoder decoder) : _decoder = decoder;

  /// Peak level per 10 ms bucket for [startMs, endMs). Throws when the file
  /// cannot be decoded.
  Future<WaveformWindow> load(String path, int startMs, int endMs) async {
    final (from, peaks, _) = await _levels(path, startMs, endMs);
    return WaveformWindow(startMs: from, bucketMs: bucketMs, peaks: peaks);
  }

  /// The centre of the quietest 200 ms within [centerMs] ± [radiusMs], or
  /// null when there is no audio there (or it cannot be decoded).
  Future<int?> quietestPoint(
    String path,
    int centerMs, {
    int radiusMs = 3000,
  }) async {
    try {
      final (from, _, rms) = await _levels(
        path,
        centerMs - radiusMs,
        centerMs + radiusMs,
      );
      return quietestRunCenterMs(rms, startMs: from, preferMs: centerMs);
    } catch (_) {
      return null;
    }
  }

  /// Drops everything cached for [path], e.g. after the file was replaced.
  void forget(String path) => _blocks.removeWhere((key, _) => key.$1 == path);

  Future<(int, Float32List, Float32List)> _levels(
    String path,
    int startMs,
    int endMs,
  ) async {
    final from = max(0, startMs) ~/ bucketMs * bucketMs;
    final to = max(from, endMs);
    final count = (to - from + bucketMs - 1) ~/ bucketMs;
    // NaN until a block fills it: a decode that came back short leaves a
    // gap, which must not look like silence.
    final peaks = Float32List(count)..fillRange(0, count, double.nan);
    final rms = Float32List(count)..fillRange(0, count, double.nan);
    if (count == 0) return (from, peaks, rms);
    final firstBlock = from ~/ blockMs;
    final lastBlock = (to - 1) ~/ blockMs;
    final blocks = await Future.wait([
      for (var b = firstBlock; b <= lastBlock; b++) _block(path, b),
    ]);
    var filled = 0;
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final blockStart = (firstBlock + i) * blockMs;
      final buckets = min(block.peaks.length, blockMs ~/ bucketMs);
      for (var j = 0; j < buckets; j++) {
        final index = (blockStart + j * bucketMs - from) ~/ bucketMs;
        if (index < 0) continue;
        if (index >= count) break;
        peaks[index] = block.peaks[j];
        rms[index] = block.rms[j];
        filled = index + 1;
      }
    }
    return (
      from,
      Float32List.sublistView(peaks, 0, filled),
      Float32List.sublistView(rms, 0, filled),
    );
  }

  Future<_Block> _block(String path, int index) {
    final key = (path, index);
    final cached = _blocks.remove(key);
    if (cached != null) {
      _blocks[key] = cached;
      return cached;
    }
    final future = _decode(path, index);
    _blocks[key] = future;
    while (_blocks.length > maxCachedBlocks) {
      _blocks.remove(_blocks.keys.first);
    }
    // A failed decode is not kept, so the next request tries again.
    future.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_blocks[key], future)) _blocks.remove(key);
      },
    );
    return future;
  }

  Future<_Block> _decode(String path, int index) async {
    final samples = await _decoder.decode(
      path,
      start: Duration(milliseconds: index * blockMs),
      duration: const Duration(milliseconds: blockMs),
    );
    const expected = blockMs * sampleRate ~/ 1000;
    const perBucket = bucketMs * sampleRate ~/ 1000;
    if ((samples.length - expected).abs() > perBucket) {
      // Expected for the last block of a file; elsewhere the decoder lost
      // audio, and the missing buckets are drawn as "no data".
      debugPrint(
        'Waveform block at ${index * blockMs} ms of $path: '
        '${samples.length} samples instead of $expected',
      );
    }
    final levels = waveformBuckets(samples);
    return _Block(levels.peaks, levels.rms);
  }
}

class _Block {
  final Float32List peaks;
  final Float32List rms;
  const _Block(this.peaks, this.rms);
}
