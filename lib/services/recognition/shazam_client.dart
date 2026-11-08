import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'shazam_signature.dart';

/// One catalog reference Shazam aligned the sample with.
class ShazamOffset {
  /// Catalog recording id; the same song can come back under several.
  final String referenceId;

  /// Seconds into the reference recording where the sample starts.
  final double offsetSeconds;

  const ShazamOffset(this.referenceId, this.offsetSeconds);
}

/// A tagging response reduced to what chapter estimation needs, plus the raw
/// body so a cached result can be reinterpreted later.
class ShazamResult {
  final String? trackKey;
  final String? title;
  final String? artist;
  final List<ShazamOffset> offsets;
  final Map<String, dynamic> raw;

  const ShazamResult({
    required this.trackKey,
    required this.title,
    required this.artist,
    required this.offsets,
    required this.raw,
  });

  bool get recognized => trackKey != null;

  factory ShazamResult.fromJson(Map<String, dynamic> json) {
    final track = json['track'];
    final matches = json['matches'];
    return ShazamResult(
      trackKey: track is Map ? track['key']?.toString() : null,
      title: track is Map ? track['title']?.toString() : null,
      artist: track is Map ? track['subtitle']?.toString() : null,
      offsets: [
        if (matches is List)
          for (final match in matches)
            if (match is Map && match['offset'] is num && match['id'] != null)
              ShazamOffset(
                match['id'].toString(),
                (match['offset'] as num).toDouble(),
              ),
      ],
      raw: json,
    );
  }
}

class ShazamHttpException implements Exception {
  final int statusCode;
  final String body;

  /// How long the endpoint asked us to wait, from its Retry-After header.
  final Duration? retryAfter;

  const ShazamHttpException(this.statusCode, this.body, {this.retryAfter});

  /// The endpoint is asking us to slow down rather than failing.
  bool get isRateLimited =>
      statusCode == 429 || (statusCode == 503 && retryAfter != null);

  /// A failure that is likely gone if the same request is sent again later.
  bool get isTransient => statusCode == 408 || statusCode >= 500;

  @override
  String toString() => 'Shazam returned HTTP $statusCode';
}

/// The longest Retry-After that is honoured; anything longer is clamped.
const maxShazamRetryAfter = Duration(minutes: 10);

/// Parses a Retry-After header value: either delay-seconds or an HTTP-date.
/// Returns null when it is missing or unreadable; a date in the past means
/// no wait. The result is capped at [maxShazamRetryAfter].
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  Duration wait;
  final seconds = int.tryParse(text);
  if (seconds != null) {
    if (seconds < 0) return null;
    wait = Duration(seconds: seconds);
  } else {
    final DateTime date;
    try {
      date = HttpDate.parse(text);
    } catch (_) {
      return null;
    }
    wait = date.difference((now ?? DateTime.now()).toUtc());
    if (wait.isNegative) wait = Duration.zero;
  }
  return wait > maxShazamRetryAfter ? maxShazamRetryAfter : wait;
}

/// The scan was cancelled while a lookup waited for its turn or was in
/// flight; no further request is sent for it.
class ShazamLookupCancelled implements Exception {
  const ShazamLookupCancelled();
  @override
  String toString() => 'Shazam lookup cancelled';
}

/// [work], unless [cancelled] completes first, in which case the result
/// fails with [ShazamLookupCancelled] at once.
Future<T> _unlessCancelled<T>(Future<T> work, Future<void>? cancelled) {
  if (cancelled == null) return work;
  return Future.any([
    work,
    cancelled.then<T>((_) => throw const ShazamLookupCancelled()),
  ]);
}

/// How a failed lookup should be handled.
enum ShazamFailureKind {
  /// The endpoint asked us to slow down: wait, then retry the same request.
  rateLimited,

  /// A network or server hiccup: retry a few times.
  transient,

  /// Retrying will not help.
  permanent,
}

ShazamFailureKind classifyShazamFailure(Object error) {
  if (error is ShazamHttpException) {
    if (error.isRateLimited) return ShazamFailureKind.rateLimited;
    if (error.isTransient) return ShazamFailureKind.transient;
    return ShazamFailureKind.permanent;
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is HandshakeException ||
      error is HttpException) {
    return ShazamFailureKind.transient;
  }
  return ShazamFailureKind.permanent;
}

/// Spaces requests at least [interval] apart. The interval starts at
/// [minimumInterval] and only grows: every rate-limit response slows the
/// pace for the rest of the pacer's lifetime.
class ShazamPacer {
  ShazamPacer({
    required this.minimumInterval,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : _interval = minimumInterval,
       _clock = clock ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;

  /// The slowed-down pace is at least this after the first rate limit.
  static const rateLimitedFloor = Duration(seconds: 8);

  /// Slowing down never goes past this (unless [minimumInterval] does).
  static const rateLimitedCeiling = Duration(seconds: 20);

  final Duration minimumInterval;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  Duration _interval;
  DateTime? _last;

  /// The current spacing between requests.
  Duration get interval => _interval;

  /// Waits until the next request may go out and claims that slot. Callers
  /// must serialise their calls. When [cancelled] completes first, the wait
  /// ends at once with [ShazamLookupCancelled] and the slot stays free.
  Future<void> waitTurn({Future<void>? cancelled}) async {
    final last = _last;
    if (last != null) {
      final wait = _interval - _clock().difference(last);
      if (wait > Duration.zero) {
        await _unlessCancelled(_delay(wait), cancelled);
      }
    }
    _last = _clock();
  }

  /// Raises the interval by half, to at least [rateLimitedFloor] and at
  /// most [rateLimitedCeiling], never below the current interval.
  void slowDown() {
    var next = _interval * 1.5;
    if (next < rateLimitedFloor) next = rateLimitedFloor;
    if (next > rateLimitedCeiling) next = rateLimitedCeiling;
    if (next > _interval) _interval = next;
  }
}

/// Anything that can turn a fingerprint into a recognition result.
abstract interface class ShazamRecognizer {
  /// When [cancelled] completes, a lookup that has not finished yet fails
  /// with [ShazamLookupCancelled] at once, and one that has not been sent
  /// yet is never sent.
  Future<ShazamResult> recognize(
    ShazamSignature signature, {
    Future<void>? cancelled,
  });
}

/// Sends locally generated fingerprints to Shazam's tagging endpoint, one at
/// a time and no faster than [minimumInterval], the way the PC prototype did.
/// Audio never leaves the device; only the signature does.
class ShazamClient implements ShazamRecognizer {
  ShazamClient({
    HttpClient? httpClient,
    Random? random,
    this.minimumInterval = const Duration(seconds: 4),
    this.language = 'en-US',
    this.endpointCountry = 'GB',
    Duration timeout = const Duration(seconds: 40),
    Uri? endpoint,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : _http = httpClient ?? (HttpClient()..connectionTimeout = timeout),
       _random = random ?? Random(),
       _timeout = timeout,
       _endpoint = endpoint ?? Uri.parse('https://amp.shazam.com'),
       _clock = clock ?? DateTime.now,
       _pacer = ShazamPacer(
         minimumInterval: minimumInterval,
         clock: clock,
         delay: delay,
       );

  static const _userAgents = [
    'Dalvik/2.1.0 (Linux; U; Android 6.0.1; SM-G920F Build/MMB29K)',
    'Dalvik/2.1.0 (Linux; U; Android 5.0; SM-G900F Build/LRX21T)',
    'Dalvik/2.1.0 (Linux; U; Android 5.1.1; SM-P905V Build/LMY47X)',
    'Dalvik/2.1.0 (Linux; U; Android 5.0.2; VS980 4G Build/LRX22G)',
  ];
  static const _devices = ['iphone', 'android', 'web'];

  final HttpClient _http;
  final Random _random;
  final Duration _timeout;
  final Duration minimumInterval;
  final String language;
  final String endpointCountry;

  /// Scheme and authority of the tagging endpoint; only tests change it.
  final Uri _endpoint;
  final DateTime Function() _clock;
  final ShazamPacer _pacer;

  Future<void> _queue = Future.value();

  /// The spacing between requests right now. It grows after every
  /// rate-limit response and stays raised for the client's lifetime.
  Duration get currentInterval => _pacer.interval;

  Uri requestUri() {
    final device = _devices[_random.nextInt(_devices.length)];
    return _endpoint.resolve(
      '/discovery/v5/$language/$endpointCountry/$device'
      '/-/tag/${_uuid()}/${_uuid()}'
      '?sync=true&webv3=true&sampling=true&connected=&shazamapiversion=v3'
      '&sharehub=true&hubv5minorversion=v5.1&hidelb=true&video=v3',
    );
  }

  Map<String, Object> requestBody(
    ShazamSignature signature, {
    int? timestampMs,
  }) {
    final now = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    return {
      'timezone': 'Europe/Paris',
      'signature': {'uri': signature.uri, 'samplems': signature.sampleMs},
      'timestamp': now,
      'context': <String, Object>{},
      'geolocation': <String, Object>{},
    };
  }

  Map<String, String> headers() => {
    'X-Shazam-Platform': 'IPHONE',
    'X-Shazam-AppVersion': '14.1.0',
    'Accept': '*/*',
    'Accept-Language': language,
    'Content-Type': 'application/json',
    'User-Agent': _userAgents[_random.nextInt(_userAgents.length)],
  };

  /// Recognizes [signature]. Requests are serialised and paced; a failure
  /// surfaces as an exception (see [classifyShazamFailure]) so the caller
  /// decides whether to wait and retry or stop and resume later from its
  /// cache. A rate-limit response also slows this client down for good.
  /// [cancelled] ends the pacing wait or the request in flight at once.
  @override
  Future<ShazamResult> recognize(
    ShazamSignature signature, {
    Future<void>? cancelled,
  }) {
    final completer = Completer<ShazamResult>();
    var stopped = false;
    cancelled?.then((_) => stopped = true);
    _queue = _queue.then((_) async {
      try {
        if (stopped) throw const ShazamLookupCancelled();
        await _pacer.waitTurn(cancelled: cancelled);
        if (stopped) throw const ShazamLookupCancelled();
        completer.complete(await _send(signature, cancelled));
      } catch (e, s) {
        if (e is ShazamHttpException && e.isRateLimited) _pacer.slowDown();
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<ShazamResult> _send(
    ShazamSignature signature,
    Future<void>? cancelled,
  ) async {
    final request = await _http.postUrl(requestUri()).timeout(_timeout);
    // Drops the connection if the scan is cancelled before the response
    // arrives; does nothing once it has.
    cancelled?.then((_) => request.abort(const ShazamLookupCancelled()));
    headers().forEach(request.headers.set);
    request.add(utf8.encode(jsonEncode(requestBody(signature))));
    final response = await _unlessCancelled(
      request.close().timeout(_timeout),
      cancelled,
    );
    final body = await _unlessCancelled(
      response.transform(utf8.decoder).join().timeout(_timeout),
      cancelled,
    );
    if (response.statusCode != 200) {
      throw ShazamHttpException(
        response.statusCode,
        body,
        retryAfter: parseRetryAfter(
          response.headers[HttpHeaders.retryAfterHeader]?.first,
          now: _clock(),
        ),
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Unexpected Shazam response');
    }
    return ShazamResult.fromJson(decoded);
  }

  void close() => _http.close(force: true);

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
            '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
            '${hex.substring(20)}'
        .toUpperCase();
  }
}
