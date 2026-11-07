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
    return pcm16FromBytes(bytes);
  }

  /// Little-endian 16-bit samples from a channel reply.
  ///
  /// StandardMethodCodec hands back byte arrays as views into the reply
  /// message, right after the type and size bytes, so the view usually
  /// starts at an odd offset where an Int16List view is not allowed. Such
  /// replies are copied into a buffer of their own first. A trailing odd
  /// byte is dropped.
  static Int16List pcm16FromBytes(Uint8List bytes) {
    final even = bytes.length - bytes.length % 2;
    if (bytes.offsetInBytes.isEven) {
      return bytes.buffer.asInt16List(bytes.offsetInBytes, even ~/ 2);
    }
    final copy = Uint8List(even)..setRange(0, even, bytes);
    return copy.buffer.asInt16List(0, even ~/ 2);
  }

  @override
  Future<Duration?> probeDuration(String path) async {
    final ms = await _channel.invokeMethod<int>('probeMediaDurationMs', {
      'path': path,
    });
    return ms == null || ms <= 0 ? null : Duration(milliseconds: ms);
  }
}
