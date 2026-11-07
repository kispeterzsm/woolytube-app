import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/recognition/shazam_client.dart';
import 'package:woolytube/services/recognition/shazam_signature.dart';

void main() {
  test('parses a cached tagging response', () {
    final result = ShazamResult.fromJson({
      'matches': [
        {'id': '446816601', 'offset': 29.60943164, 'timeskew': 0.0007},
        {'id': 'x', 'offset': 'bad'},
      ],
      'track': {
        'key': '229461461',
        'title': 'Come and Get Your Love',
        'subtitle': 'Redbone',
      },
    });
    expect(result.recognized, isTrue);
    expect(result.trackKey, '229461461');
    expect(result.artist, 'Redbone');
    expect(result.offsets.single.referenceId, '446816601');
    expect(result.offsets.single.offsetSeconds, closeTo(29.609, 0.001));
    expect(ShazamResult.fromJson({'matches': []}).recognized, isFalse);
  });

  test('builds the request the way the reference client does', () {
    final client = ShazamClient();
    addTearDown(client.close);
    final uri = client.requestUri();
    expect(uri.host, 'amp.shazam.com');
    expect(uri.pathSegments.take(4), ['discovery', 'v5', 'en-US', 'GB']);
    expect(uri.pathSegments[6], 'tag');
    expect(uri.pathSegments[7], matches(RegExp(r'^[0-9A-F-]{36}$')));
    expect(uri.queryParameters['shazamapiversion'], 'v3');
    const signature = ShazamSignature(numberSamples: 192000, bands: {});
    final body = client.requestBody(signature, timestampMs: 5);
    expect(body['timestamp'], 5);
    expect((body['signature'] as Map)['samplems'], 12000);
    expect(
      (body['signature'] as Map)['uri'],
      startsWith(ShazamSignature.dataUriPrefix),
    );
    expect(client.headers()['X-Shazam-AppVersion'], '14.1.0');
  });

  group('Retry-After', () {
    final now = DateTime.utc(2026, 11, 7, 12);

    test('reads delay-seconds', () {
      expect(parseRetryAfter('120'), const Duration(seconds: 120));
      expect(parseRetryAfter(' 7 '), const Duration(seconds: 7));
      expect(parseRetryAfter('0'), Duration.zero);
    });

    test('reads an HTTP-date relative to now', () {
      expect(
        parseRetryAfter('Sat, 07 Nov 2026 12:01:30 GMT', now: now),
        const Duration(seconds: 90),
      );
      // Already past: no wait.
      expect(
        parseRetryAfter('Sat, 07 Nov 2026 11:00:00 GMT', now: now),
        Duration.zero,
      );
    });

    test('caps long waits at ten minutes', () {
      expect(parseRetryAfter('86400'), maxShazamRetryAfter);
      expect(
        parseRetryAfter('Sun, 08 Nov 2026 12:00:00 GMT', now: now),
        const Duration(minutes: 10),
      );
    });

    test('ignores missing or unreadable values', () {
      expect(parseRetryAfter(null), isNull);
      expect(parseRetryAfter(''), isNull);
      expect(parseRetryAfter('-5'), isNull);
      expect(parseRetryAfter('soon'), isNull);
    });
  });

  test('classifies failures', () {
    ShazamFailureKind kind(Object e) => classifyShazamFailure(e);
    const wait = Duration(seconds: 5);
    expect(
      kind(const ShazamHttpException(429, '')),
      ShazamFailureKind.rateLimited,
    );
    expect(
      kind(const ShazamHttpException(503, '', retryAfter: wait)),
      ShazamFailureKind.rateLimited,
    );
    expect(
      kind(const ShazamHttpException(503, '')),
      ShazamFailureKind.transient,
    );
    expect(
      kind(const ShazamHttpException(500, '')),
      ShazamFailureKind.transient,
    );
    expect(
      kind(const ShazamHttpException(408, '')),
      ShazamFailureKind.transient,
    );
    expect(
      kind(const ShazamHttpException(404, '')),
      ShazamFailureKind.permanent,
    );
    expect(
      kind(const ShazamHttpException(400, '')),
      ShazamFailureKind.permanent,
    );
    expect(kind(TimeoutException('slow')), ShazamFailureKind.transient);
    expect(kind(const SocketException('offline')), ShazamFailureKind.transient);
    expect(kind(const HandshakeException('tls')), ShazamFailureKind.transient);
    expect(kind(const HttpException('closed')), ShazamFailureKind.transient);
    expect(
      kind(const FormatException('bad json')),
      ShazamFailureKind.permanent,
    );
    expect(const ShazamHttpException(429, '').isRateLimited, isTrue);
    expect(const ShazamHttpException(503, '').isRateLimited, isFalse);
    expect(const ShazamHttpException(503, '').isTransient, isTrue);
    expect(const ShazamHttpException(429, '').isTransient, isFalse);
  });

  group('ShazamPacer', () {
    test('spaces requests by the interval', () async {
      var clock = DateTime.utc(2026);
      final waits = <Duration>[];
      final pacer = ShazamPacer(
        minimumInterval: const Duration(seconds: 4),
        clock: () => clock,
        delay: (d) async {
          waits.add(d);
          clock = clock.add(d);
        },
      );
      await pacer.waitTurn();
      expect(waits, isEmpty);
      clock = clock.add(const Duration(seconds: 1));
      await pacer.waitTurn();
      expect(waits, [const Duration(seconds: 3)]);
      clock = clock.add(const Duration(seconds: 10));
      await pacer.waitTurn();
      expect(waits.length, 1);
    });

    test('slows down after rate limits, between 8 and 20 s', () {
      final pacer = ShazamPacer(minimumInterval: const Duration(seconds: 4));
      expect(pacer.interval, const Duration(seconds: 4));
      final seen = <Duration>[];
      for (var i = 0; i < 5; i++) {
        pacer.slowDown();
        seen.add(pacer.interval);
      }
      expect(seen, const [
        Duration(seconds: 8),
        Duration(seconds: 12),
        Duration(seconds: 18),
        Duration(seconds: 20),
        Duration(seconds: 20),
      ]);
    });

    test('a cancelled wait ends at once and leaves the slot free', () async {
      var clock = DateTime.utc(2026);
      final pending = <Completer<void>>[];
      final pacer = ShazamPacer(
        minimumInterval: const Duration(seconds: 20),
        clock: () => clock,
        delay: (d) => (pending..add(Completer<void>())).last.future,
      );
      await pacer.waitTurn();
      final cancel = Completer<void>();
      final turn = pacer.waitTurn(cancelled: cancel.future);
      await Future<void>.delayed(Duration.zero);
      expect(pending.length, 1);
      cancel.complete();
      await expectLater(turn, throwsA(isA<ShazamLookupCancelled>()));
      expect(pending.single.isCompleted, isFalse);
      // The cancelled turn claimed nothing: 20 s after the first request
      // the next one may go out without waiting.
      clock = clock.add(const Duration(seconds: 20));
      await pacer.waitTurn();
      expect(pending.length, 1);
    });

    test('never goes below the configured minimum', () {
      final pacer = ShazamPacer(minimumInterval: const Duration(seconds: 30));
      pacer.slowDown();
      expect(pacer.interval, const Duration(seconds: 30));
    });
  });

  test('a 429 carries Retry-After and slows the client down', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    var request = 0;
    server.listen((req) async {
      paths.add(req.uri.path);
      await req.drain<void>();
      final res = req.response;
      switch (request++) {
        case 0:
          res.statusCode = 429;
          res.headers.set(HttpHeaders.retryAfterHeader, '12');
        case 1:
          res.statusCode = 429;
        default:
          res.statusCode = 200;
          res.write(
            jsonEncode({
              'track': {'key': '1', 'title': 'Song', 'subtitle': 'Artist'},
              'matches': [
                {'id': 'r', 'offset': 3.5},
              ],
            }),
          );
      }
      await res.close();
    });

    final waits = <Duration>[];
    final clock = DateTime.utc(2026, 11, 7, 12);
    final client = ShazamClient(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      clock: () => clock,
      delay: (d) async => waits.add(d),
    );
    addTearDown(client.close);
    const signature = ShazamSignature(numberSamples: 192000, bands: {});

    await expectLater(
      client.recognize(signature),
      throwsA(
        isA<ShazamHttpException>()
            .having((e) => e.statusCode, 'status', 429)
            .having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 12),
            )
            .having((e) => e.isRateLimited, 'rateLimited', isTrue),
      ),
    );
    expect(client.currentInterval, const Duration(seconds: 8));

    await expectLater(
      client.recognize(signature),
      throwsA(
        isA<ShazamHttpException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          isNull,
        ),
      ),
    );
    expect(client.currentInterval, const Duration(seconds: 12));

    final result = await client.recognize(signature);
    expect(result.title, 'Song');
    expect(client.currentInterval, const Duration(seconds: 12));
    // The clock stands still, so each request waited the full interval
    // that was in force when it was sent.
    expect(waits, const [Duration(seconds: 8), Duration(seconds: 12)]);
    expect(paths.length, 3);
    expect(paths.first, startsWith('/discovery/v5/en-US/GB/'));
  });

  test('cancel during the slowed-down pace sends no request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((req) async {
      requests++;
      await req.drain<void>();
      req.response.statusCode = 429;
      await req.response.close();
    });
    final paced = Completer<void>();
    final client = ShazamClient(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      clock: () => DateTime.utc(2026, 11, 7, 12),
      delay: (_) {
        if (!paced.isCompleted) paced.complete();
        return Completer<void>().future;
      },
    );
    addTearDown(client.close);
    const signature = ShazamSignature(numberSamples: 192000, bands: {});

    await expectLater(
      client.recognize(signature),
      throwsA(isA<ShazamHttpException>()),
    );
    expect(client.currentInterval, const Duration(seconds: 8));
    final cancel = Completer<void>();
    final lookup = client.recognize(signature, cancelled: cancel.future);
    await paced.future;
    cancel.complete();
    await expectLater(lookup, throwsA(isA<ShazamLookupCancelled>()));
    expect(requests, 1);
  });

  test('cancel ends a request in flight at once', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final arrived = Completer<void>();
    server.listen((req) async {
      await req.drain<void>();
      // Never answers.
      arrived.complete();
    });
    final client = ShazamClient(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(client.close);
    const signature = ShazamSignature(numberSamples: 192000, bands: {});

    final cancel = Completer<void>();
    final lookup = client.recognize(signature, cancelled: cancel.future);
    await arrived.future;
    final stopwatch = Stopwatch()..start();
    cancel.complete();
    await expectLater(lookup, throwsA(isA<ShazamLookupCancelled>()));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));

    // The cancel signal firing again later never hurts a finished lookup.
    final lateCancel = Completer<void>();
    final server2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server2.close(force: true));
    server2.listen((req) async {
      await req.drain<void>();
      req.response.write(jsonEncode({}));
      await req.response.close();
    });
    final client2 = ShazamClient(
      endpoint: Uri.parse('http://127.0.0.1:${server2.port}'),
    );
    addTearDown(client2.close);
    final result = await client2.recognize(
      signature,
      cancelled: lateCancel.future,
    );
    expect(result.recognized, isFalse);
    lateCancel.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test(
    'live: fixture fingerprints are recognized as the cached songs',
    () async {
      final client = ShazamClient(minimumInterval: const Duration(seconds: 5));
      addTearDown(client.close);
      final expectations = {
        'nightcore-30s': 'Angel with a Shotgun',
        'guardians-1258s': "Ain't No Mountain High Enough",
      };
      for (final entry in expectations.entries) {
        final pcm =
            File(
              'test/fixtures/recognition/${entry.key}.pcm',
            ).readAsBytesSync();
        final samples = Int16List.view(
          pcm.buffer,
          pcm.offsetInBytes,
          pcm.length ~/ 2,
        );
        final result = await client.recognize(
          ShazamSignatureGenerator.fromSamples(samples),
        );
        // ignore: avoid_print
        print(
          '${entry.key}: ${result.artist} - ${result.title} offsets=${result.offsets.map((o) => o.offsetSeconds.toStringAsFixed(1)).toList()}',
        );
        expect(result.title, contains(entry.value));
        expect(result.offsets, isNotEmpty);
      }
    },
    skip:
        Platform.environment['RECOGNITION_LIVE'] != '1'
            ? 'Set RECOGNITION_LIVE=1 to contact the Shazam endpoint'
            : null,
  );
}
