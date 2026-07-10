import 'package:flutter_test/flutter_test.dart';

import 'package:woolytube/services/update_service.dart';

void main() {
  group('isVersionNewer', () {
    test('detects newer patch, minor, and major versions', () {
      expect(isVersionNewer('1.0.1', '1.0.0'), isTrue);
      expect(isVersionNewer('1.1.0', '1.0.9'), isTrue);
      expect(isVersionNewer('2.0.0', '1.9.9'), isTrue);
    });

    test('ignores tags and build metadata while comparing', () {
      expect(isVersionNewer('v1.2.4', '1.2.3+42'), isTrue);
      expect(isVersionNewer('1.2.3', 'v1.2.3+42'), isFalse);
    });

    test('rejects older, equal, and invalid versions', () {
      expect(isVersionNewer('1.2.2', '1.2.3'), isFalse);
      expect(isVersionNewer('1.2.3', '1.2.3'), isFalse);
      expect(isVersionNewer('latest', '1.2.3'), isFalse);
      expect(isVersionNewer('1.2.3', 'current'), isFalse);
    });
  });

  group('normalizeVersion', () {
    test('strips common release tag decorations', () {
      expect(normalizeVersion('v0.5.6'), '0.5.6');
      expect(normalizeVersion('1.2.3+7'), '1.2.3');
      expect(normalizeVersion('1.2.3-beta.1'), '1.2.3');
    });
  });

  group('findCompatibleApkUri', () {
    final assets = [
      {
        'name': 'woolytube-1.2.2.apk',
        'browser_download_url': 'https://example.com/woolytube-universal.apk',
      },
      {
        'name': 'woolytube-1.2.2-arm64-v8a.apk',
        'browser_download_url': 'https://example.com/woolytube-arm64.apk',
      },
      {
        'name': 'woolytube-1.2.2-armeabi-v7a.apk',
        'browser_download_url': 'https://example.com/woolytube-armv7.apk',
      },
    ];

    test('prefers the first ABI supported by the device', () {
      expect(
        findCompatibleApkUri(assets, ['arm64-v8a', 'armeabi-v7a']),
        Uri.parse('https://example.com/woolytube-arm64.apk'),
      );
    });

    test('falls back to a universal APK for older releases', () {
      expect(
        findCompatibleApkUri(assets, ['x86_64']),
        Uri.parse('https://example.com/woolytube-universal.apk'),
      );
    });

    test('does not select an APK for a different ABI', () {
      expect(findCompatibleApkUri(assets.skip(1).toList(), ['x86_64']), isNull);
    });
  });
}
