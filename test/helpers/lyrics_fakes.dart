import 'package:woolytube/services/lyrics/lrclib_client.dart';
import 'package:woolytube/services/lyrics/lyrics_matcher.dart';

import 'fake_http_client.dart';

/// An LRCLIB record as the API returns it.
Map<String, Object?> lrclibRecord({
  int id = 1,
  String track = 'The Final Countdown',
  String artist = 'Europe',
  double duration = 296,
  bool instrumental = false,
  String? plain = "We're leaving together\nBut still it's farewell",
  String? synced =
      "[01:27.77] We're leaving together\n[01:31.17] But still it's farewell",
}) => {
  'id': id,
  'name': track,
  'trackName': track,
  'artistName': artist,
  'albumName': 'a',
  'duration': duration,
  'instrumental': instrumental,
  'plainLyrics': plain,
  'syncedLyrics': synced,
};

/// A fake LRCLIB: `get` answers from [exact] (keyed "artist|track"),
/// searches from [searches] (keyed by the query string).
class FakeLrclib {
  final exact = <String, Map<String, Object?>>{};
  final searches = <String, List<Map<String, Object?>>>{};
  late final http = FakeHttpClient(_answer);

  FakeHttpResponse _answer(FakeHttpRequest request) {
    final query = request.uri.queryParameters;
    if (request.uri.path == '/api/get') {
      final record = exact['${query['artist_name']}|${query['track_name']}'];
      return record == null
          ? FakeHttpResponse.json({'statusCode': 404}, statusCode: 404)
          : FakeHttpResponse.json(record);
    }
    final key = [
      for (final name in ['q', 'track_name', 'artist_name'])
        if (query[name] != null) '$name=${query[name]}',
    ].join('&');
    return FakeHttpResponse.json(searches[key] ?? const []);
  }

  List<String> get paths => [
    for (final r in http.requests)
      r.uri.path == '/api/get'
          ? 'get'
          : r.uri.queryParameters.entries
              .map((e) => '${e.key}=${e.value}')
              .join('&'),
  ];

  LyricsMatcher matcher() => LyricsMatcher(
    LrclibClient(http: http, sleep: (_) async {}, retryDelays: const []),
  );
}

/// The parts of an innertube `next` answer the client reads.
Map<String, Object?> nextAnswer({
  String? browseId,
  bool unselectable = false,
}) => {
  'contents': {
    'singleColumnMusicWatchNextResultsRenderer': {
      'tabbedRenderer': {
        'watchNextTabbedResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'title': 'Up next',
                'endpoint': {
                  'browseEndpoint': {'browseId': 'MPUP_x'},
                },
              },
            },
            if (browseId != null)
              {
                'tabRenderer': {
                  'title': 'Lyrics',
                  'endpoint': {
                    'browseEndpoint': {'browseId': browseId},
                  },
                  if (unselectable) 'unselectable': true,
                },
              },
          ],
        },
      },
    },
  },
};

Map<String, Object?> browseAnswer(String text, {String? footer}) => {
  'contents': {
    'sectionListRenderer': {
      'contents': [
        {
          'musicDescriptionShelfRenderer': {
            'description': {
              'runs': [
                {'text': text},
              ],
            },
            if (footer != null)
              'footer': {
                'runs': [
                  {'text': footer},
                ],
              },
          },
        },
      ],
    },
  },
};
