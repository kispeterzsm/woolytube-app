import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/lyrics/captions.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';

import '../../helpers/fake_http_client.dart';

List<Map<String, Object?>> formats(String url, {bool hls = false}) => [
  {'ext': 'vtt', 'url': '$url&fmt=vtt'},
  {'ext': 'json3', 'url': '$url&fmt=json3', if (hls) 'protocol': 'm3u8_native'},
];

void main() {
  group('pickCaption', () {
    test('transcripts prefer manual captions in the video language', () {
      final info = {
        'language': 'en-US',
        'subtitles': {
          'de': formats('https://x/de'),
          'en-nP7-2PuUl7o': formats('https://x/en-named'),
          'en': formats('https://x/en'),
          'live_chat': formats('https://x/chat'),
        },
        'automatic_captions': {'en-orig': formats('https://x/asr')},
      };
      final choice = pickCaption(info, mode: LyricsMode.transcript)!;
      expect(choice.key, 'en');
      expect(choice.url, 'https://x/en&fmt=json3');
      expect(choice.automatic, isFalse);
      expect(choice.lang, 'en');
    });

    test('transcripts fall back to the original speech-to-text track', () {
      final info = {
        'language': 'hu',
        'subtitles': <String, Object?>{},
        'automatic_captions': {
          'en': formats('https://x/translated'),
          'en-orig': formats('https://x/en-orig'),
          'hu-orig': formats('https://x/hu-orig'),
        },
      };
      final choice = pickCaption(info, mode: LyricsMode.transcript)!;
      expect(choice.key, 'hu-orig');
      expect(choice.automatic, isTrue);
      expect(choice.lang, 'hu');
    });

    test('HLS-only tracks are skipped', () {
      final info = {
        'subtitles': {'en': formats('https://x/en', hls: true)},
      };
      expect(pickCaption(info, mode: LyricsMode.transcript), isNull);
    });

    test('lyrics take only manual captions in the song language', () {
      // An English song with a Japanese translation track.
      expect(
        pickCaption({
          'title': 'Avicii - The Days',
          'subtitles': {'ja': formats('https://x/ja')},
          'automatic_captions': {'en-orig': formats('https://x/asr')},
        }, mode: LyricsMode.lyrics),
        isNull,
      );
      expect(
        pickCaption({
          'title': 'Hey Brother',
          'subtitles': {'en-nP7-2PuUl7o': formats('https://x/en')},
        }, mode: LyricsMode.lyrics)?.key,
        'en-nP7-2PuUl7o',
      );
      expect(
        pickCaption({
          'title': 'Szép napok',
          'language': 'hu',
          'subtitles': {
            'en': formats('https://x/en'),
            'hu': formats('https://x/hu'),
          },
        }, mode: LyricsMode.lyrics)?.key,
        'hu',
      );
      expect(
        pickCaption({
          'title': '夜に駆ける',
          'subtitles': {'ja': formats('https://x/ja')},
        }, mode: LyricsMode.lyrics)?.key,
        'ja',
      );
    });

    test('onlyLang narrows the choice', () {
      final info = {
        'subtitles': {
          'en': formats('https://x/en'),
          'de': formats('https://x/de'),
        },
      };
      expect(
        pickCaption(info, mode: LyricsMode.transcript, onlyLang: 'de')?.key,
        'de',
      );
    });
  });

  test('CaptionsClient fetches and parses json3', () async {
    final json3 =
        await File('test/fixtures/lyrics/manual_music.en.json3').readAsString();
    final http = FakeHttpClient((_) => FakeHttpResponse(200, json3));
    final lines = await CaptionsClient(
      http: http,
    ).fetch('https://www.youtube.com/api/timedtext?v=x&fmt=json3');
    expect(lines, isNotEmpty);
    expect(lines.every((l) => l.startMs != null), isTrue);
    expect(http.requests.single.uri.queryParameters['fmt'], 'json3');

    final empty = FakeHttpClient((_) => const FakeHttpResponse(200, ''));
    expect(await CaptionsClient(http: empty).fetch('https://x'), isEmpty);

    final failing = FakeHttpClient((_) => const FakeHttpResponse(429, ''));
    await expectLater(
      CaptionsClient(http: failing).fetch('https://x'),
      throwsA(isA<HttpException>()),
    );
  });
}
