import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/recognition/shazam_signature.dart';

void main() {
  for (final name in ['nightcore-30s', 'guardians-1258s']) {
    test('matches the reference fingerprint for $name', () {
      final dir = 'test/fixtures/recognition';
      final pcm = File('$dir/$name.pcm').readAsBytesSync();
      final samples = Int16List.view(
        pcm.buffer,
        pcm.offsetInBytes,
        pcm.length ~/ 2,
      );
      final expected =
          jsonDecode(File('$dir/$name.signature.json').readAsStringSync())
              as Map<String, dynamic>;

      final stopwatch = Stopwatch()..start();
      final signature = ShazamSignatureGenerator.fromSamples(samples);
      stopwatch.stop();

      expect(signature.numberSamples, expected['numberSamples']);
      expect(signature.sampleMs, expected['samplems']);
      var total = 0;
      var matched = 0;
      for (final entry in (expected['peaks'] as Map<String, dynamic>).entries) {
        final reference =
            (entry.value as List)
                .map(
                  (p) => FrequencyPeak(p[0] as int, p[1] as int, p[2] as int),
                )
                .toSet();
        final actual =
            (signature.bands[int.parse(entry.key)] ?? const []).toSet();
        total += reference.length;
        matched += reference.intersection(actual).length;
        // Report per band to make a drift visible in the test output.
        // ignore: avoid_print
        print(
          '$name band ${entry.key}: ${reference.intersection(actual).length}/${reference.length} reference peaks reproduced, ${actual.length} produced',
        );
      }
      // ignore: avoid_print
      print(
        '$name: $matched/$total peaks identical, ${stopwatch.elapsedMilliseconds} ms',
      );
      expect(matched / total, greaterThanOrEqualTo(0.98));
      expect(signature.peakCount, closeTo(total, total * 0.02));
      if (matched == total && signature.peakCount == total) {
        expect(base64Encode(signature.encode()), expected['uriBase64']);
      }
    });
  }

  test('encodes the binary layout with a valid CRC and TLV blocks', () {
    const signature = ShazamSignature(
      numberSamples: 1280,
      bands: {
        0: [FrequencyPeak(3, 6000, 1000), FrequencyPeak(300, 6100, 1100)],
        2: [FrequencyPeak(10, 7000, 20000)],
      },
    );
    final bytes = signature.encode();
    final data = ByteData.sublistView(bytes);
    expect(data.getUint32(0, Endian.little), 0xcafe2580);
    expect(data.getUint32(4, Endian.little), crc32(bytes, 8));
    expect(data.getUint32(8, Endian.little), bytes.length - 48);
    expect(data.getUint32(12, Endian.little), 0x94119c00);
    expect(data.getUint32(28, Endian.little), 3 << 27);
    expect(data.getUint32(40, Endian.little), 1280 + 3840);
    expect(data.getUint32(48, Endian.little), 0x40000000);
    expect(data.getUint32(56, Endian.little), 0x60030040);
    // Band 0: 5 bytes for the first peak, then a 0xff escape (1 + 4) and 5
    // more for the second (delta 297 >= 255), padded to a multiple of four.
    expect(data.getUint32(60, Endian.little), 15);
    expect(bytes[64], 3);
    expect(bytes[69], 0xff);
    expect(signature.uri, startsWith(ShazamSignature.dataUriPrefix));
    expect(crc32(Uint8List.fromList(utf8.encode('123456789'))), 0xcbf43926);
  });
}
