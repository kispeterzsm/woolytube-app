import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const backgroundChannel = MethodChannel('com.woolytube/background');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, null);
  });

  test('mobile-data auto download is off by default', () async {
    final settings = AppSettingsService();

    expect(await settings.getAutoDownloadWithMobileData(), isFalse);
  });

  test('mobile-data auto download preference is persisted', () async {
    final settings = AppSettingsService();

    await settings.setAutoDownloadWithMobileData(true);

    expect(await settings.getAutoDownloadWithMobileData(), isTrue);
  });

  test('reschedules automatic updates with the new preference', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, (call) async {
          calls.add(call);
          return null;
        });
    final settings = AppSettingsService();

    await settings.setAutoDownloadWithMobileData(true);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'scheduleAutoUpdate');
    expect(calls.single.arguments, {'allowMobileData': true});
  });
}
