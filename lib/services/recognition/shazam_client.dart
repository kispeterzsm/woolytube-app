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
  const ShazamHttpException(this.statusCode, this.body);
  @override
  String toString() => 'Shazam returned HTTP $statusCode';
}

/// Anything that can turn a fingerprint into a recognition result.
abstract interface class ShazamRecognizer {
  Future<ShazamResult> recognize(ShazamSignature signature);
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
  }) : _http = httpClient ?? (HttpClient()..connectionTimeout = timeout),
       _random = random ?? Random(),
       _timeout = timeout;

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

  Future<void> _queue = Future.value();
  DateTime? _lastRequest;

  Uri requestUri() {
    final device = _devices[_random.nextInt(_devices.length)];
    return Uri.parse(
      'https://amp.shazam.com/discovery/v5/$language/$endpointCountry/$device'
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
  /// surfaces as an exception so the caller can stop and resume later from
  /// its cache instead of hammering the endpoint.
  @override
  Future<ShazamResult> recognize(ShazamSignature signature) {
    final completer = Completer<ShazamResult>();
    _queue = _queue.then((_) async {
      try {
        final last = _lastRequest;
        if (last != null) {
          final wait = minimumInterval - DateTime.now().difference(last);
          if (wait > Duration.zero) await Future<void>.delayed(wait);
        }
        _lastRequest = DateTime.now();
        completer.complete(await _send(signature));
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<ShazamResult> _send(ShazamSignature signature) async {
    final request = await _http.postUrl(requestUri()).timeout(_timeout);
    headers().forEach(request.headers.set);
    request.add(utf8.encode(jsonEncode(requestBody(signature))));
    final response = await request.close().timeout(_timeout);
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw ShazamHttpException(response.statusCode, body);
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
