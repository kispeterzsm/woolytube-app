import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/recognition/audio_window_decoder.dart';

/// Little-endian 16-bit PCM bytes for [samples], like the Kotlin decoder
/// writes them.
Uint8List _pcmBytes(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = 'com.woolytube/ytdlp';
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Uint8List reply;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMessageHandler(channel, (message) async {
      calls.add(codec.decodeMethodCall(message));
      // The engine delivers the reply in a buffer of its own, starting at
      // offset 0, laid out by StandardMethodCodec.
      final encoded = codec.encodeSuccessEnvelope(reply);
      final copy = Uint8List.fromList(
        encoded.buffer.asUint8List(
          encoded.offsetInBytes,
          encoded.lengthInBytes,
        ),
      );
      return ByteData.sublistView(copy);
    });
  });

  tearDown(() => messenger.setMockMessageHandler(channel, null));

  // Sizes that use each of the codec's size encodings: one byte (< 254),
  // marker plus two bytes (< 65536), and marker plus four bytes (a 12 s
  // window at 16 kHz is 384000 bytes). Each one puts the payload at an odd
  // offset.
  for (final count in [0, 5, 1000, 192000]) {
    test('decodes a $count-sample reply from the platform channel', () async {
      final samples = [
        for (var i = 0; i < count; i++) ((i * 7919) % 65536) - 32768,
      ];
      reply = _pcmBytes(samples);

      final pcm = await const PlatformAudioWindowDecoder().decode(
        '/music/mix.m4a',
        start: const Duration(seconds: 90),
        duration: const Duration(seconds: 12),
      );

      expect(pcm, samples);
      expect(calls.single.method, 'decodeAudioWindow');
      expect(calls.single.arguments, {
        'path': '/music/mix.m4a',
        'startMs': 90000,
        'durationMs': 12000,
      });
    });
  }

  test('drops a trailing odd byte', () async {
    reply = Uint8List.fromList([
      ..._pcmBytes([1, -2, 300]),
      0x7f,
    ]);
    final pcm = await const PlatformAudioWindowDecoder().decode(
      '/music/mix.m4a',
      start: Duration.zero,
      duration: const Duration(seconds: 1),
    );
    expect(pcm, [1, -2, 300]);
  });

  test('copies views at odd offsets and keeps aligned ones', () {
    final backing = Uint8List(9);
    backing.setRange(1, 7, _pcmBytes([258, -1, 7]));
    final odd = Uint8List.sublistView(backing, 1, 7);
    expect(PlatformAudioWindowDecoder.pcm16FromBytes(odd), [258, -1, 7]);

    final even = Uint8List.sublistView(_pcmBytes([0, 4, 5, 6]), 2, 7);
    final view = PlatformAudioWindowDecoder.pcm16FromBytes(even);
    expect(view, [4, 5]);
    // An aligned reply is used in place, without a copy.
    view[0] = 0x0102;
    expect(even.sublist(0, 2), [0x02, 0x01]);
  });
}
