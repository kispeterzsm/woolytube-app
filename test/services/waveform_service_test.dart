import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/recognition/audio_window_decoder.dart';
import 'package:woolytube/services/waveform_service.dart';

/// Makes 16 kHz audio from [level] (0..1 amplitude at a file time) for a
/// file [lengthMs] long, and records each decode request.
class FakeDecoder implements AudioWindowDecoder {
  FakeDecoder({required this.lengthMs, required this.level});

  final int lengthMs;
  final double Function(int ms) level;
  final requests = <(String, int, int)>[];
  Completer<void>? gate;
  bool fail = false;

  /// Leaves this many samples off the end of every window, like Android's
  /// MP3 decoder (512 short per 10 s).
  int shortBy = 0;

  @override
  Future<Int16List> decode(
    String path, {
    required Duration start,
    required Duration duration,
  }) async {
    requests.add((path, start.inMilliseconds, duration.inMilliseconds));
    final g = gate;
    if (g != null) await g.future;
    if (fail) throw StateError('decode failed');
    final from = start.inMilliseconds;
    final to = (from + duration.inMilliseconds).clamp(0, lengthMs);
    final count = to <= from ? 0 : max(0, (to - from) * 16 - shortBy);
    final out = Int16List(count);
    for (var i = 0; i < count; i++) {
      final ms = from + i ~/ 16;
      final amplitude = (level(ms) * 32767).round();
      out[i] = i.isEven ? amplitude : -amplitude;
    }
    return out;
  }

  @override
  Future<Duration?> probeDuration(String path) async =>
      Duration(milliseconds: lengthMs);
}

void main() {
  group('waveformBuckets', () {
    test('peak and RMS per 10 ms bucket', () {
      final samples = Int16List(400);
      for (var i = 0; i < 160; i++) {
        samples[i] = i.isEven ? 16384 : -16384;
      }
      samples[200] = -32768;
      final levels = waveformBuckets(samples);
      expect(levels.peaks.length, 3);
      expect(levels.peaks[0], closeTo(0.5, 1e-6));
      expect(levels.rms[0], closeTo(0.5, 1e-6));
      expect(levels.peaks[1], 1.0);
      expect(levels.rms[1], closeTo(1 / sqrt(160), 1e-6));
      expect(levels.peaks[2], 0);
    });

    test('empty input gives no buckets', () {
      final levels = waveformBuckets(Int16List(0));
      expect(levels.peaks, isEmpty);
      expect(levels.rms, isEmpty);
    });
  });

  group('quietestRunCenterMs', () {
    Float32List rmsOf(List<double> values) => Float32List.fromList(values);

    test('finds the centre of the quietest 200 ms run', () {
      final rms = rmsOf(List.filled(100, 0.8));
      for (var i = 60; i < 80; i++) {
        rms[i] = 0.01;
      }
      expect(quietestRunCenterMs(rms, startMs: 1000), 1000 + 600 + 100);
    });

    test('ties go to the run nearest the preferred point', () {
      final rms = rmsOf(List.filled(200, 0));
      expect(quietestRunCenterMs(rms, startMs: 0, preferMs: 1234), 1230);
      expect(quietestRunCenterMs(rms, startMs: 0, preferMs: -500), 100);
      expect(quietestRunCenterMs(rms, startMs: 0, preferMs: 99999), 1900);
    });

    test('a single quiet bucket does not beat a quiet run', () {
      final rms = rmsOf(List.filled(100, 0.5));
      rms[10] = 0;
      for (var i = 70; i < 90; i++) {
        rms[i] = 0.1;
      }
      expect(quietestRunCenterMs(rms, startMs: 0), 800);
    });

    test('runs over buckets without audio are skipped', () {
      final rms = rmsOf(List.filled(100, 0.5));
      for (var i = 40; i < 60; i++) {
        rms[i] = double.nan;
      }
      for (var i = 70; i < 90; i++) {
        rms[i] = 0.2;
      }
      expect(quietestRunCenterMs(rms, startMs: 0), 800);
      expect(
        quietestRunCenterMs(rmsOf(List.filled(30, double.nan)), startMs: 0),
        isNull,
      );
    });

    test('null when shorter than one run', () {
      expect(quietestRunCenterMs(rmsOf(List.filled(19, 0)), startMs: 0), null);
      expect(quietestRunCenterMs(Float32List(0), startMs: 0), isNull);
    });
  });

  group('WaveformService', () {
    test('loads a window across block borders', () async {
      final decoder = FakeDecoder(
        lengthMs: 60000,
        level: (ms) => ms < 10000 ? 0.25 : 0.75,
      );
      final service = WaveformService(decoder);
      final window = await service.load('a.mp3', 9500, 10500);
      expect(window.startMs, 9500);
      expect(window.bucketMs, 10);
      expect(window.peaks.length, 100);
      expect(window.endMs, 10500);
      expect(window.peakAt(9600), closeTo(0.25, 0.001));
      expect(window.peakAt(10200), closeTo(0.75, 0.001));
      expect(window.peakAt(9000), 0);
      expect(window.peakAt(20000), 0);
      expect(decoder.requests, [('a.mp3', 0, 10000), ('a.mp3', 10000, 10000)]);
    });

    test('aligns the start to a bucket and clamps before 0', () async {
      final decoder = FakeDecoder(lengthMs: 30000, level: (_) => 0.5);
      final service = WaveformService(decoder);
      final window = await service.load('a.mp3', -2000, 1005);
      expect(window.startMs, 0);
      expect(window.peaks.length, 101);
      final unaligned = await service.load('a.mp3', 1234, 1300);
      expect(unaligned.startMs, 1230);
      expect(unaligned.peaks.length, 7);
    });

    test('stops at the end of the file', () async {
      final decoder = FakeDecoder(lengthMs: 12000, level: (_) => 0.5);
      final service = WaveformService(decoder);
      final window = await service.load('a.mp3', 11000, 15000);
      expect(window.peaks.length, 100);
      expect(window.endMs, 12000);
      final past = await service.load('a.mp3', 13000, 14000);
      expect(past.peaks, isEmpty);
    });

    test('caches blocks and shares requests in flight', () async {
      final decoder = FakeDecoder(lengthMs: 60000, level: (_) => 0.5)
        ..gate = Completer<void>();
      final service = WaveformService(decoder);
      final first = service.load('a.mp3', 1000, 2000);
      final second = service.load('a.mp3', 3000, 9000);
      await pumpEventQueue();
      expect(decoder.requests, hasLength(1));
      decoder.gate!.complete();
      decoder.gate = null;
      await Future.wait([first, second]);
      await service.load('a.mp3', 0, 10000);
      expect(decoder.requests, hasLength(1));
      await service.load('b.mp3', 0, 10000);
      expect(decoder.requests, hasLength(2), reason: 'cached per file');
      service.forget('a.mp3');
      await service.load('a.mp3', 0, 10000);
      expect(decoder.requests, hasLength(3));
    });

    test('evicts the least recently used block', () async {
      final decoder = FakeDecoder(lengthMs: 10000000, level: (_) => 0.5);
      final service = WaveformService(decoder);
      const blockMs = WaveformService.blockMs;
      for (var b = 0; b < WaveformService.maxCachedBlocks; b++) {
        await service.load('a.mp3', b * blockMs, b * blockMs + 10);
      }
      // Touch block 0 so block 1 is the oldest.
      await service.load('a.mp3', 0, 10);
      await service.load('a.mp3', 999 * blockMs, 999 * blockMs + 10);
      final before = decoder.requests.length;
      await service.load('a.mp3', 0, 10);
      expect(decoder.requests.length, before);
      await service.load('a.mp3', blockMs, blockMs + 10);
      expect(decoder.requests.length, before + 1);
    });

    test('a failed decode throws and is retried next time', () async {
      final decoder = FakeDecoder(lengthMs: 60000, level: (_) => 0.5)
        ..fail = true;
      final service = WaveformService(decoder);
      await expectLater(service.load('a.mp3', 0, 1000), throwsStateError);
      expect(await service.quietestPoint('a.mp3', 5000), isNull);
      decoder.fail = false;
      final window = await service.load('a.mp3', 0, 1000);
      expect(window.peaks.length, 100);
    });

    test('quietestPoint finds a quiet gap near the centre', () async {
      // A short dip between two songs at 21.0–21.3 s.
      final decoder = FakeDecoder(
        lengthMs: 60000,
        level: (ms) => ms >= 21000 && ms < 21300 ? 0.001 : 0.6,
      );
      final service = WaveformService(decoder);
      final point = await service.quietestPoint('a.mp3', 20000);
      expect(point, isNotNull);
      expect(point!, inInclusiveRange(21100, 21200));
      expect(
        await service.quietestPoint('a.mp3', 30000, radiusMs: 3000),
        isNot(inInclusiveRange(21000, 21300)),
      );
    });

    test('a short decode leaves a gap, not silence', () async {
      final decoder = FakeDecoder(lengthMs: 60000, level: (_) => 0.5)
        ..shortBy = 512; // 32 ms
      final service = WaveformService(decoder);
      final window = await service.load('a.mp3', 9000, 11000);
      expect(window.peaks.length, 200);
      // 9.97–10.00 s had no audio.
      for (var ms = 9970; ms < 10000; ms += 10) {
        expect(window.peaks[(ms - 9000) ~/ 10].isNaN, isTrue, reason: '$ms');
        expect(window.peakAt(ms), 0);
      }
      expect(window.peakAt(9960), closeTo(0.5, 0.001));
      expect(window.peakAt(10000), closeTo(0.5, 0.001));
      // The quietest spot is not the gap.
      final quiet = FakeDecoder(
        lengthMs: 60000,
        // Only slightly quieter than the rest: a gap read as silence
        // would win.
        level: (ms) => ms >= 8000 && ms < 8300 ? 0.57 : 0.6,
      )..shortBy = 512;
      expect(
        await WaveformService(quiet).quietestPoint('a.mp3', 9000),
        inInclusiveRange(8100, 8200),
      );
    });

    test('quietestPoint is null past the end of the file', () async {
      final decoder = FakeDecoder(lengthMs: 5000, level: (_) => 0.5);
      final service = WaveformService(decoder);
      expect(await service.quietestPoint('a.mp3', 9000, radiusMs: 1000), null);
    });
  });
}
