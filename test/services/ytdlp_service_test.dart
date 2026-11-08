import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/ytdlp_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.woolytube/ytdlp');
  final calls = <MethodCall>[];
  String? playlistAnswer;

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getPlaylistInfo') return playlistAnswer;
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'native downloads receive subtitle options and exclude audio downloads',
    () async {
      final service = YtDlpService();
      for (final audioOnly in [false, true]) {
        await service.download(
          url: 'https://www.youtube.com/watch?v=test',
          outputPath: '/downloads',
          audioOnly: audioOnly,
          downloadSubtitles: true,
          subtitleLanguages: 'en,hu',
        );
        expect(calls.last.method, 'download');
        expect(calls.last.arguments['downloadSubtitles'], !audioOnly);
        expect(calls.last.arguments['subtitleLanguages'], 'en,hu');
      }
    },
  );

  test('the video quality cap is sent only for capped video', () async {
    final service = YtDlpService();
    Future<Map> send({int? maxHeight, bool audioOnly = false}) async {
      await service.download(
        url: 'https://www.youtube.com/watch?v=test',
        outputPath: '/downloads',
        audioOnly: audioOnly,
        maxHeight: maxHeight,
      );
      return calls.last.arguments as Map;
    }

    expect((await send(maxHeight: 720))['maxHeight'], 720);
    expect((await send()).containsKey('maxHeight'), isFalse);
    expect((await send(maxHeight: 0)).containsKey('maxHeight'), isFalse);
    expect(
      (await send(maxHeight: 720, audioOnly: true)).containsKey('maxHeight'),
      isFalse,
    );
  });

  test('large and small playlist answers decode the same', () async {
    final service = YtDlpService();
    Map<String, Object?> listing(int count) => {
      'title': 'Mix',
      'entries': [
        for (var i = 0; i < count; i++)
          {'id': 'video$i', 'title': 'Song number $i', 'duration': 180.0 + i},
      ],
    };

    playlistAnswer = jsonEncode(listing(2));
    final small = await service.getPlaylistInfo('https://example.com/list');
    expect(small['title'], 'Mix');
    expect((small['entries'] as List).length, 2);

    playlistAnswer = jsonEncode(listing(1500));
    expect(
      playlistAnswer!.length,
      greaterThanOrEqualTo(backgroundJsonDecodeThreshold),
    );
    final large = await service.getPlaylistInfo('https://example.com/list');
    final entries = large['entries'] as List;
    expect(entries.length, 1500);
    expect((entries.last as Map)['id'], 'video1499');
    expect((entries.last as Map)['duration'], 1679.0);
  });
}
