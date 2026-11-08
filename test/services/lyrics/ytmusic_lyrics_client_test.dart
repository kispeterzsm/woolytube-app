import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/lyrics/ytmusic_lyrics_client.dart';

import '../../helpers/fake_http_client.dart';
import '../../helpers/lyrics_fakes.dart';

void main() {
  test('reads the lyrics tab, then its page', () async {
    final http = FakeHttpClient((request) {
      if (request.uri.path.endsWith('/next')) {
        return FakeHttpResponse.json(nextAnswer(browseId: 'MPLYt_abc'));
      }
      return FakeHttpResponse.json(
        browseAnswer(
          "We're leaving together\r\nBut still it's farewell",
          footer: 'Source: LyricFind',
        ),
      );
    });
    final lyrics = await YtMusicLyricsClient(http: http).lyricsFor('vid');
    expect(lyrics!.browseId, 'MPLYt_abc');
    expect(lyrics.text, "We're leaving together\nBut still it's farewell");
    expect(lyrics.source, 'Source: LyricFind');

    final next = http.requests.first;
    expect(next.method, 'POST');
    expect(next.uri.host, 'music.youtube.com');
    final body = next.json as Map;
    expect(body['videoId'], 'vid');
    expect(body['context']['client']['clientName'], 'WEB_REMIX');
    expect((http.requests.last.json as Map)['browseId'], 'MPLYt_abc');
  });

  test(
    'a greyed out or missing tab means no lyrics, without a browse',
    () async {
      for (final answer in [
        nextAnswer(browseId: 'MPLYt_abc', unselectable: true),
        nextAnswer(),
      ]) {
        final http = FakeHttpClient((_) => FakeHttpResponse.json(answer));
        expect(await YtMusicLyricsClient(http: http).lyricsFor('vid'), isNull);
        expect(http.requests, hasLength(1));
      }
    },
  );

  test('"Lyrics not available" is no lyrics', () {
    expect(
      parseLyricsBrowse({
        'contents': {
          'messageRenderer': {
            'text': {
              'runs': [
                {'text': 'Lyrics not available'},
              ],
            },
          },
        },
      }, 'MPLYt_abc'),
      isNull,
    );
  });

  test('HTTP errors are thrown', () async {
    final http = FakeHttpClient((_) => const FakeHttpResponse(403, 'no'));
    await expectLater(
      YtMusicLyricsClient(http: http).lyricsFor('vid'),
      throwsA(anything),
    );
  });
}
