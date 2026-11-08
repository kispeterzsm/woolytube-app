import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/lyrics/lrclib_client.dart';

import '../../helpers/fake_http_client.dart';
import '../../helpers/lyrics_fakes.dart';

void main() {
  late List<Duration> sleeps;
  late DateTime now;

  LrclibClient clientFor(FakeHttpClient http) => LrclibClient(
    http: http,
    userAgent: lyricsUserAgent('1.2.3'),
    sleep: (duration) async {
      sleeps.add(duration);
      now = now.add(duration);
    },
    clock: () => now,
  );

  setUp(() {
    sleeps = [];
    now = DateTime(2026, 11, 8);
  });

  test('get sends the fields and parses the record', () async {
    final http = FakeHttpClient(
      (request) => FakeHttpResponse.json(lrclibRecord()),
    );
    final record = await clientFor(http).get(
      artist: 'Europe',
      track: 'The Final Countdown',
      durationSeconds: 295.6,
    );
    final request = http.requests.single;
    expect(request.uri.path, '/api/get');
    expect(request.uri.queryParameters, {
      'artist_name': 'Europe',
      'track_name': 'The Final Countdown',
      'duration': '296',
    });
    expect(
      request.headers['user-agent'],
      'WoolyTube/1.2.3 (https://github.com/kispeterzsm/WoolyTube)',
    );
    expect(record!.id, 1);
    expect(record.artistName, 'Europe');
    expect(record.duration, 296);
    expect(record.isSynced, isTrue);
    expect(record.hasLyrics, isTrue);
  });

  test('a 404 is no record', () async {
    final http = FakeHttpClient(
      (_) => FakeHttpResponse.json({
        'message': 'Failed to find specified track',
        'name': 'TrackNotFound',
        'statusCode': 404,
      }, statusCode: 404),
    );
    expect(await clientFor(http).get(artist: 'a', track: 'b'), isNull);
    expect(await clientFor(http).getById(5), isNull);
  });

  test('search returns every record and skips broken ones', () async {
    final http = FakeHttpClient(
      (_) => FakeHttpResponse.json([
        lrclibRecord(id: 1),
        {'no': 'id'},
        lrclibRecord(id: 2, plain: null, synced: null),
      ]),
    );
    final records = await clientFor(
      http,
    ).search(trackName: 'Final Countdown', artistName: 'Europe');
    expect(records.map((r) => r.id), [1, 2]);
    expect(records.last.hasLyrics, isFalse);
    expect(http.requests.single.uri.queryParameters, {
      'track_name': 'Final Countdown',
      'artist_name': 'Europe',
    });
    await clientFor(http).searchQ('europe countdown');
    expect(http.requests.last.uri.queryParameters, {'q': 'europe countdown'});
  });

  test('requests are at least a second apart', () async {
    final http = FakeHttpClient((_) => FakeHttpResponse.json([]));
    final client = clientFor(http);
    await client.searchQ('a');
    await client.searchQ('b');
    await client.searchQ('c');
    expect(sleeps, [const Duration(seconds: 1), const Duration(seconds: 1)]);
    expect(client.requestCount, 3);
  });

  test('rate limits and server errors are waited out', () async {
    var calls = 0;
    final http = FakeHttpClient((_) {
      calls++;
      if (calls == 1) {
        return const FakeHttpResponse(
          429,
          'slow down',
          headers: {'retry-after': '7'},
        );
      }
      if (calls == 2) return const FakeHttpResponse(503, 'busy');
      return FakeHttpResponse.json([lrclibRecord()]);
    });
    final records = await clientFor(http).searchQ('europe');
    expect(records, hasLength(1));
    expect(sleeps, contains(const Duration(seconds: 7)));
    expect(sleeps, contains(const Duration(seconds: 10)));
  });

  test('gives up after the retries with a transient error', () async {
    final http = FakeHttpClient((_) => const FakeHttpResponse(500, 'down'));
    await expectLater(
      clientFor(http).searchQ('x'),
      throwsA(
        isA<LrclibException>()
            .having((e) => e.transient, 'transient', isTrue)
            .having((e) => e.statusCode, 'statusCode', 500),
      ),
    );
    expect(http.requests, hasLength(3));
  });

  test('network errors are retried, a bad request is not', () async {
    var calls = 0;
    final flaky = FakeHttpClient((_) {
      if (++calls == 1) throw const SocketException('offline');
      return FakeHttpResponse.json([]);
    });
    expect(await clientFor(flaky).searchQ('x'), isEmpty);
    expect(flaky.requests, hasLength(2));

    final bad = FakeHttpClient((_) => const FakeHttpResponse(400, 'no'));
    await expectLater(
      clientFor(bad).searchQ('x'),
      throwsA(
        isA<LrclibException>().having((e) => e.transient, 'transient', false),
      ),
    );
    expect(bad.requests, hasLength(1));
  });

  test('plainText falls back to the synced text without times', () {
    final record = LrclibRecord.fromJson(lrclibRecord(plain: null))!;
    expect(record.plainText, "We're leaving together\nBut still it's farewell");
    final candidate = record.toCandidate();
    expect(candidate.synced, isTrue);
    expect(candidate.title, 'The Final Countdown');
    expect(candidate.durationSeconds, 296);
  });
}
