import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/recognition/silence_detector.dart';

import '../helpers/ffmpeg_audio_window_decoder.dart';

Int16List synthetic() {
  // 10 s: tone, 0.5 s gap, tone, 0.1 s gap (too short), tone, 2 s trailing
  // quiet tail with a faint hum below the threshold.
  const rate = 16000;
  final out = Int16List(10 * rate);
  final random = Random(7);
  void tone(double from, double to) {
    for (var i = (from * rate).round(); i < (to * rate).round(); i++) {
      out[i] = (8000 * sin(2 * pi * 440 * i / rate)).round();
    }
  }

  tone(0, 3);
  tone(3.5, 6);
  tone(6.1, 8);
  for (var i = 8 * rate; i < out.length; i++) {
    out[i] = random.nextInt(200) - 100;
  }
  return out;
}

void main() {
  test('uses the -40 dB threshold on the 16-bit scale', () {
    expect(const SilenceDetector().threshold, 327);
  });

  test('reports runs from first quiet to first loud sample, and a tail', () {
    final silences = const SilenceDetector().detect(synthetic());
    expect(silences.length, 2);
    expect(silences[0].$1, closeTo(3.0, 0.002));
    expect(silences[0].$2, closeTo(3.5, 0.002));
    expect(silences[1].$1, closeTo(8.0, 0.002));
    expect(silences[1].$2, closeTo(10.0, 0.0001));
    final shifted = const SilenceDetector().detect(
      synthetic(),
      offset: const Duration(seconds: 100),
    );
    expect(shifted.first.$1, closeTo(103.0, 0.002));
  });

  test(
    'agrees with FFmpeg silencedetect on synthetic audio',
    () async {
      final samples = synthetic();
      final ours = const SilenceDetector().detect(samples);
      final reference = await ffmpegSilences(samples);
      expect(ours.length, reference.length);
      for (var i = 0; i < ours.length; i++) {
        expect(ours[i].$1, closeTo(reference[i].$1, 0.002));
        expect(ours[i].$2, closeTo(reference[i].$2, 0.002));
      }
    },
    skip: FfmpegAudioWindowDecoder.available ? null : 'ffmpeg not installed',
  );
}
