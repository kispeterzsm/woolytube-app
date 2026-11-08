/// YouTube captions as lyrics or a transcript: choosing a caption track
/// from yt-dlp's info and fetching it as json3.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lyrics_models.dart';
import 'lyrics_text.dart';

/// One caption track to fetch.
class CaptionChoice {
  /// The caption language key, e.g. `en`, `en-nP7-2PuUl7o` or `en-orig`.
  final String key;
  final String url;

  /// Speech-to-text (`<lang>-orig`) rather than written by the uploader.
  final bool automatic;

  const CaptionChoice({
    required this.key,
    required this.url,
    required this.automatic,
  });

  /// The base language ("en" for "en-nP7-2PuUl7o" or "en-orig").
  String get lang => captionBaseLang(key);

  @override
  String toString() => 'CaptionChoice($key${automatic ? ', automatic' : ''})';
}

/// "en" for "en", "en-US", "en-orig" or "en-nP7-2PuUl7o".
String captionBaseLang(String key) => key.split('-').first.toLowerCase();

final _cjk = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]',
  unicode: true,
);
final _hangul = RegExp(r'\p{Script=Hangul}', unicode: true);

/// The json3 URL of a format list, skipping HLS playlists.
String? _json3Url(Object? formats) {
  if (formats is! List) return null;
  for (final format in formats) {
    if (format is! Map) continue;
    if (format['ext'] != 'json3') continue;
    final protocol = format['protocol'];
    if (protocol is String && protocol.startsWith('m3u8')) continue;
    final url = format['url'];
    if (url is String && url.isNotEmpty) return url;
  }
  return null;
}

/// Chooses a caption track from yt-dlp's info (`subtitles`,
/// `automatic_captions`, `language`, `title`). Never a machine translation.
///
/// [mode] lyrics: only a manual track in the song's language (the video's
/// `language`, else by the title's script: English, or Japanese/Chinese/
/// Korean for such titles); a translation would be useless for search.
/// [mode] transcript: a manual track (video language, then English, then
/// any), else the original speech-to-text track (`<lang>-orig`).
/// [onlyLang] restricts the choice to one base language.
CaptionChoice? pickCaption(
  Map<String, dynamic> info, {
  required LyricsMode mode,
  String? onlyLang,
}) {
  final subtitles = info['subtitles'];
  final automatic = info['automatic_captions'];
  final language = info['language'];
  final videoLang =
      language is String && language.isNotEmpty
          ? captionBaseLang(language)
          : null;

  final manual = <CaptionChoice>[];
  if (subtitles is Map) {
    for (final entry in subtitles.entries) {
      final key = '${entry.key}';
      if (key == 'live_chat') continue;
      final url = _json3Url(entry.value);
      if (url == null) continue;
      manual.add(CaptionChoice(key: key, url: url, automatic: false));
    }
  }
  if (onlyLang != null) {
    manual.removeWhere((c) => c.lang != captionBaseLang(onlyLang));
  }

  if (mode == LyricsMode.lyrics) {
    final title = info['title'] is String ? info['title'] as String : '';
    // The video's language comes from its speech-to-text track, which
    // often guesses wrong for music: the title's script comes next.
    final byScript = <String>{
      if (_hangul.hasMatch(title)) 'ko',
      if (_cjk.hasMatch(title)) ...['ja', 'zh'],
      if (!_cjk.hasMatch(title) && !_hangul.hasMatch(title)) 'en',
    };
    final tiers = [
      {
        if (videoLang != null) videoLang,
        if (onlyLang != null) captionBaseLang(onlyLang),
      },
      byScript,
    ];
    for (final wanted in tiers) {
      for (final choice in manual) {
        if (wanted.contains(choice.lang)) return choice;
      }
    }
    return null;
  }

  int rank(CaptionChoice c) =>
      c.lang == videoLang
          ? 0
          : c.lang == 'en'
          ? 1
          : 2;
  manual.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    // A plain key ("en") before a named variant ("en-nP7-2PuUl7o").
    return byRank != 0 ? byRank : a.key.length.compareTo(b.key.length);
  });
  if (manual.isNotEmpty) return manual.first;

  if (automatic is Map) {
    final keys =
        automatic.keys
            .map((k) => '$k')
            .where((k) => k.endsWith('-orig'))
            .where(
              (k) =>
                  onlyLang == null ||
                  captionBaseLang(k) == captionBaseLang(onlyLang),
            )
            .toList()
          ..sort((a, b) {
            final aMatch = captionBaseLang(a) == videoLang ? 0 : 1;
            final bMatch = captionBaseLang(b) == videoLang ? 0 : 1;
            return aMatch.compareTo(bMatch);
          });
    for (final key in keys) {
      final url = _json3Url(automatic[key]);
      if (url != null) {
        return CaptionChoice(key: key, url: url, automatic: true);
      }
    }
  }
  return null;
}

/// Downloads caption tracks. The URLs come from yt-dlp and expire after a
/// few hours.
class CaptionsClient {
  CaptionsClient({
    HttpClient? http,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _http =
           http ??
           (HttpClient()..connectionTimeout = const Duration(seconds: 15)),
       _ownsHttp = http == null;

  final HttpClient _http;
  final bool _ownsHttp;
  final Duration requestTimeout;

  /// The lines of a json3 caption track; empty when it has none.
  Future<List<LyricsLineDraft>> fetch(String url) async {
    final uri = Uri.parse(url);
    final request = await _http.getUrl(uri).timeout(requestTimeout);
    final response = await request.close().timeout(requestTimeout);
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    if (body.trim().isEmpty) return const [];
    return parseJson3Captions(body);
  }

  void close() {
    if (_ownsHttp) _http.close(force: true);
  }
}
