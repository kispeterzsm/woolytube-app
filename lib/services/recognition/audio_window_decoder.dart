import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Decodes short stretches of a local media file to 16 kHz mono PCM so they
/// can be fingerprinted or checked for silence without reading the whole
/// file into memory.
abstract interface class AudioWindowDecoder {
  Future<Int16List> decode(
    String path, {
    required Duration start,
    required Duration duration,
  });

  Future<Duration?> probeDuration(String path);
}

/// Android implementation backed by MediaExtractor/MediaCodec in the
/// woolytube_ytdlp plugin.
class PlatformAudioWindowDecoder implements AudioWindowDecoder {
  const PlatformAudioWindowDecoder();

  static const _channel = MethodChannel('com.woolytube/ytdlp');

  @override
  Future<Int16List> decode(
    String path, {
    required Duration start,
    required Duration duration,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('decodeAudioWindow', {
      'path': path,
      'startMs': start.inMilliseconds,
      'durationMs': duration.inMilliseconds,
    });
    if (bytes == null) return Int16List(0);
    final even = bytes.length - bytes.length % 2;
    return Int16List.view(bytes.buffer, bytes.offsetInBytes, even ~/ 2);
  }

  @override
  Future<Duration?> probeDuration(String path) async {
    final ms = await _channel.invokeMethod<int>('probeMediaDurationMs', {
      'path': path,
    });
    return ms == null || ms <= 0 ? null : Duration(milliseconds: ms);
  }
}
