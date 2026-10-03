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
