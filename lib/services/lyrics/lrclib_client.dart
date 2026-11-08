/// LRCLIB (https://lrclib.net), the open lyrics database. Plain Dart (no
/// Flutter), so tool/lyrics_eval.dart can run it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lyrics_models.dart';

/// The LRCLIB docs ask for a User-Agent naming the app, its version and
/// its homepage.
String lyricsUserAgent(String? appVersion) =>
    'WoolyTube${appVersion == null ? '' : '/$appVersion'} '
    '(https://github.com/kispeterzsm/WoolyTube)';

/// One LRCLIB record.
class LrclibRecord {
  final int id;
  final String trackName;
  final String artistName;
  final String? albumName;
  final double? duration;
  final bool instrumental;
  final String? plainLyrics;
  final String? syncedLyrics;

  const LrclibRecord({
    required this.id,
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.duration,
    this.instrumental = false,
    this.plainLyrics,
    this.syncedLyrics,
  });

  static LrclibRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! num) return null;
    String? text(String key) {
      final value = json[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    return LrclibRecord(
      id: id.toInt(),
      trackName: text('trackName') ?? text('name') ?? '',
      artistName: text('artistName') ?? '',
      albumName: text('albumName'),
      duration: (json['duration'] as num?)?.toDouble(),
      instrumental: json['instrumental'] == true,
      plainLyrics: text('plainLyrics'),
      syncedLyrics: text('syncedLyrics'),
    );
  }

  bool get isSynced => syncedLyrics != null;

  /// Whether there is any lyric text. Some records have neither plain nor
  /// synced lyrics without being marked instrumental.
  bool get hasLyrics =>
      !instrumental && (plainLyrics != null || syncedLyrics != null);

  /// The plain text, or the synced text without its time stamps.
  String get plainText =>
      plainLyrics ??
      (syncedLyrics ?? '')
          .split('\n')
          .map((line) => line.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim())
          .where((line) => line.isNotEmpty)
          .join('\n');

  LyricsCandidate toCandidate() => LyricsCandidate(
    id: id,
    artist: artistName,
    title: trackName,
    album: albumName,
    durationSeconds: duration,
    synced: isSynced,
    instrumental: instrumental,
    plainPreview: plainText,
  );

  @override
  String toString() =>
      'LrclibRecord($id, $artistName - $trackName, ${duration}s'
      '${instrumental ? ', instrumental' : ''}${isSynced ? ', synced' : ''})';
}

/// A failed LRCLIB request. [transient] ones (rate limit, server error,
/// network) are worth trying again later.
class LrclibException implements Exception {
  final String message;
  final int? statusCode;
  final bool transient;

  const LrclibException(this.message, {this.statusCode, this.transient = true});

  @override
  String toString() => 'LrclibException: $message';
}

/// Talks to the LRCLIB API politely: at most one request per
/// [minInterval], and rate limits or server errors are waited out a few
/// times before giving up.
class LrclibClient {
  LrclibClient({
    HttpClient? http,
    String? userAgent,
    this.baseUrl = 'https://lrclib.net',
    this.minInterval = const Duration(seconds: 1),
    this.requestTimeout = const Duration(seconds: 20),
    this.retryDelays = const [Duration(seconds: 3), Duration(seconds: 10)],
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
  }) : _http =
           http ??
           (HttpClient()..connectionTimeout = const Duration(seconds: 15)),
       _ownsHttp = http == null,
       _userAgent = userAgent ?? lyricsUserAgent(null),
       _sleep = sleep ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now;

  final HttpClient _http;
  final bool _ownsHttp;
  final String _userAgent;
  final String baseUrl;
  final Duration minInterval;
  final Duration requestTimeout;

  /// Waits before each retry of a rate-limited or failed request.
  final List<Duration> retryDelays;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;
  DateTime? _lastRequest;
  Future<void> _queue = Future<void>.value();

  /// Requests sent so far (for tests and the eval tool).
  int requestCount = 0;

  /// Exact lookup; null when LRCLIB has no such record. [durationSeconds]
  /// must be within about 2 s of the record's.
  Future<LrclibRecord?> get({
    required String artist,
    required String track,
    String? album,
    num? durationSeconds,
    bool Function()? stop,
  }) async {
    final json = await _request('/api/get', {
      'artist_name': artist,
      'track_name': track,
      if (album != null) 'album_name': album,
      if (durationSeconds != null) 'duration': '${durationSeconds.round()}',
    }, stop);
    return LrclibRecord.fromJson(json);
  }

  /// One record by id; null when it is gone.
  Future<LrclibRecord?> getById(int id, {bool Function()? stop}) async =>
      LrclibRecord.fromJson(await _request('/api/get/$id', const {}, stop));

  /// Search by fields, or by free text [q] (title, artist and album; not
  /// the lyric text). Up to 20 records.
  Future<List<LrclibRecord>> search({
    String? trackName,
    String? artistName,
    String? q,
    bool Function()? stop,
  }) async {
    final json = await _request('/api/search', {
      if (q != null) 'q': q,
      if (trackName != null) 'track_name': trackName,
      if (artistName != null) 'artist_name': artistName,
    }, stop);
    if (json is! List) return const [];
    return [
      for (final item in json)
        if (LrclibRecord.fromJson(item) case final record?) record,
    ];
  }

  /// Free-text search, see [search].
  Future<List<LrclibRecord>> searchQ(String q, {bool Function()? stop}) =>
      search(q: q, stop: stop);

  /// Runs requests one after another, spaced by [minInterval]. When [stop]
  /// says so (cancelled, out of time), throws instead of sending or waiting
  /// out a rate limit.
  Future<Object?> _request(
    String path,
    Map<String, String> query, [
    bool Function()? stop,
  ]) {
    final result = _queue.then((_) => _send(path, query, stop));
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Object?> _send(
    String path,
    Map<String, String> query,
    bool Function()? stop,
  ) async {
    final base = Uri.parse(baseUrl);
    final uri = base.replace(
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
    for (var attempt = 0; ; attempt++) {
      _checkStop(stop, path);
      await _pace();
      int? status;
      Duration? retryAfter;
      try {
        requestCount++;
        final request = await _http.getUrl(uri).timeout(requestTimeout);
        request.headers
          ..set(HttpHeaders.userAgentHeader, _userAgent)
          ..set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close().timeout(requestTimeout);
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(requestTimeout);
        status = response.statusCode;
        if (status == HttpStatus.notFound) return null;
        if (status >= 200 && status < 300) {
          return body.isEmpty ? null : jsonDecode(body);
        }
        final header = response.headers.value(HttpHeaders.retryAfterHeader);
        final seconds = int.tryParse(header ?? '');
        if (seconds != null) retryAfter = Duration(seconds: seconds);
        if (status != HttpStatus.tooManyRequests && status < 500) {
          throw LrclibException(
            'HTTP $status for $path',
            statusCode: status,
            transient: false,
          );
        }
      } on LrclibException {
        rethrow;
      } on FormatException catch (e) {
        throw LrclibException('Bad answer for $path: $e', transient: true);
      } on Exception catch (e) {
        if (attempt >= retryDelays.length) {
          throw LrclibException('$path failed: $e');
        }
        await _wait(retryDelays[attempt], stop, path);
        continue;
      }
      if (attempt >= retryDelays.length) {
        throw LrclibException('HTTP $status for $path', statusCode: status);
      }
      var wait = retryDelays[attempt];
      if (retryAfter != null && retryAfter > wait) {
        wait =
            retryAfter > const Duration(seconds: 60)
                ? const Duration(seconds: 60)
                : retryAfter;
      }
      await _wait(wait, stop, path);
    }
  }

  static void _checkStop(bool Function()? stop, String path) {
    if (stop?.call() ?? false) {
      throw LrclibException('Stopped before $path', transient: true);
    }
  }

  /// Sleeps [duration], in steps of a second while [stop] can end it.
  Future<void> _wait(
    Duration duration,
    bool Function()? stop,
    String path,
  ) async {
    if (stop == null) return _sleep(duration);
    var left = duration;
    while (left > Duration.zero) {
      _checkStop(stop, path);
      final step =
          left > const Duration(seconds: 1) ? const Duration(seconds: 1) : left;
      await _sleep(step);
      left -= step;
    }
    _checkStop(stop, path);
  }

  Future<void> _pace() async {
    final last = _lastRequest;
    if (last != null) {
      final since = _clock().difference(last);
      if (since < minInterval) await _sleep(minInterval - since);
    }
    _lastRequest = _clock();
  }

  void close() {
    if (_ownsHttp) _http.close(force: true);
  }
}
