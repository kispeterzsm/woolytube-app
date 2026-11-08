/// Lyrics from YouTube Music (innertube WEB_REMIX, no login). Only official
/// uploads have them, as plain text.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Lyrics YouTube Music shows for a video.
class YtMusicLyrics {
  /// The lyrics page id (`MPLYt_…`).
  final String browseId;
  final String text;

  /// "Source: LyricFind" and the like.
  final String? source;

  const YtMusicLyrics({
    required this.browseId,
    required this.text,
    this.source,
  });
}

class YtMusicLyricsClient {
  YtMusicLyricsClient({
    HttpClient? http,
    this.requestTimeout = const Duration(seconds: 20),
    this.clientVersion = '1.20241106.01.00',
  }) : _http =
           http ??
           (HttpClient()..connectionTimeout = const Duration(seconds: 15)),
       _ownsHttp = http == null;

  final HttpClient _http;
  final bool _ownsHttp;
  final Duration requestTimeout;
  final String clientVersion;

  static const _host = 'music.youtube.com';
  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0 Safari/537.36';

  /// The lyrics of [videoId]; null when YouTube Music has none.
  Future<YtMusicLyrics?> lyricsFor(String videoId) async {
    final next = await _post('/youtubei/v1/next', {
      'videoId': videoId,
      'isAudioOnly': true,
    });
    final browseId = lyricsBrowseId(next);
    if (browseId == null) return null;
    final browse = await _post('/youtubei/v1/browse', {'browseId': browseId});
    return parseLyricsBrowse(browse, browseId);
  }

  Future<Object?> _post(String path, Map<String, Object?> body) async {
    final uri = Uri.https(_host, path, {'prettyPrint': 'false'});
    final request = await _http.postUrl(uri).timeout(requestTimeout);
    request.headers
      ..set(HttpHeaders.userAgentHeader, _userAgent)
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set('Origin', 'https://$_host')
      ..set(HttpHeaders.refererHeader, 'https://$_host/');
    request.add(
      utf8.encode(
        jsonEncode({
          ...body,
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': clientVersion,
              'hl': 'en',
              'gl': 'US',
            },
          },
        }),
      ),
    );
    final response = await request.close().timeout(requestTimeout);
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return jsonDecode(text);
  }

  void close() {
    if (_ownsHttp) _http.close(force: true);
  }
}

/// The lyrics tab's `MPLYt_…` id in a `next` answer; null when the tab is
/// missing or greyed out (`unselectable`).
String? lyricsBrowseId(Object? next) {
  for (final tab in _findAll(next, 'tabRenderer')) {
    if (tab is! Map) continue;
    final endpoint = tab['endpoint'];
    final browse = endpoint is Map ? endpoint['browseEndpoint'] : null;
    final id = browse is Map ? browse['browseId'] : null;
    if (id is String && id.startsWith('MPLYt')) {
      return tab['unselectable'] == true ? null : id;
    }
  }
  return null;
}

/// The lyrics in a `browse` answer for the lyrics page; null for "Lyrics
/// not available".
YtMusicLyrics? parseLyricsBrowse(Object? browse, String browseId) {
  for (final shelf in _findAll(browse, 'musicDescriptionShelfRenderer')) {
    if (shelf is! Map) continue;
    final text = _runs(shelf['description']).replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) continue;
    final footer = _runs(shelf['footer']).trim();
    return YtMusicLyrics(
      browseId: browseId,
      text: text,
      source: footer.isEmpty ? null : footer,
    );
  }
  return null;
}

String _runs(Object? textObject) {
  if (textObject is! Map) return '';
  final runs = textObject['runs'];
  if (runs is! List) return '${textObject['simpleText'] ?? ''}';
  return runs.map((run) => run is Map ? '${run['text'] ?? ''}' : '').join();
}

/// Every value stored under [key] anywhere in [json].
Iterable<Object?> _findAll(Object? json, String key) sync* {
  if (json is Map) {
    for (final entry in json.entries) {
      if (entry.key == key) yield entry.value;
      yield* _findAll(entry.value, key);
    }
  } else if (json is List) {
    for (final item in json) {
      yield* _findAll(item, key);
    }
  }
}
