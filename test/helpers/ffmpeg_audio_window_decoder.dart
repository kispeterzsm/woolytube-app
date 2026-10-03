import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:woolytube/services/recognition/audio_window_decoder.dart';

/// Test-only decoder that shells out to FFmpeg on the development machine,
/// standing in for the Android MediaCodec implementation.
class FfmpegAudioWindowDecoder implements AudioWindowDecoder {
  const FfmpegAudioWindowDecoder();

  static bool get available =>
      Process.runSync('which', ['ffmpeg']).exitCode == 0 &&
      Process.runSync('which', ['ffprobe']).exitCode == 0;

  @override
  Future<Int16List> decode(
    String path, {
    required Duration start,
    required Duration duration,
  }) async {
    final result = await Process.run(
      'ffmpeg',
      [
        '-v',
        'error',
        '-ss',
        (start.inMilliseconds / 1000).toString(),
        '-i',
        path,
        '-t',
        (duration.inMilliseconds / 1000).toString(),
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-c:a',
        'pcm_s16le',
        '-f',
        's16le',
        'pipe:1',
      ],
      stdoutEncoding: null,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw StateError('ffmpeg failed: ${result.stderr}');
    }
    final bytes = Uint8List.fromList(result.stdout as List<int>);
    return Int16List.view(bytes.buffer, 0, bytes.length ~/ 2);
  }

  @override
  Future<Duration?> probeDuration(String path) async {
    final result = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'json',
      path,
    ]);
    if (result.exitCode != 0) return null;
    final seconds = double.tryParse(
      (jsonDecode(result.stdout as String)['format']?['duration'] ?? '')
          .toString(),
    );
    return seconds == null
        ? null
        : Duration(microseconds: (seconds * 1000000).round());
  }
}

/// Runs FFmpeg's silencedetect over raw 16 kHz mono PCM and returns the
/// intervals it reports, for comparing against the Dart detector.
Future<List<(double, double)>> ffmpegSilences(Int16List samples) async {
  final process = await Process.start('ffmpeg', [
    '-hide_banner',
    '-nostats',
    '-f',
    's16le',
    '-ar',
    '16000',
    '-ac',
    '1',
    '-i',
    'pipe:0',
    '-af',
    'silencedetect=noise=-40dB:duration=0.2',
    '-f',
    'null',
    '-',
  ]);
  process.stdin.add(
    samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes),
  );
  await process.stdin.close();
  final stderr = await process.stderr.transform(utf8.decoder).join();
  await process.exitCode;
  final result = <(double, double)>[];
  double? start;
  for (final line in stderr.split('\n')) {
    final s = RegExp(r'silence_start: ([0-9.]+)').firstMatch(line);
    if (s != null) start = double.parse(s[1]!);
    final e = RegExp(r'silence_end: ([0-9.]+)').firstMatch(line);
    if (e != null && start != null) {
      result.add((start, double.parse(e[1]!)));
      start = null;
    }
  }
  return result;
}
