import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/audio_processing.dart';

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

  test(
    'subtitle settings default to off and English and persist changes',
    () async {
      final settings = AppSettingsService();
      expect(await settings.getDownloadSubtitles(), isFalse);
      expect(await settings.getSubtitleLanguages(), 'en');
      await settings.setDownloadSubtitles(true);
      await settings.setSubtitleLanguages('hu, en,hu, pt-BR');
      final reloaded = AppSettingsService();
      expect(await reloaded.getDownloadSubtitles(), isTrue);
      expect(await reloaded.getSubtitleLanguages(), 'hu,en,pt-BR');
    },
  );

  test('invalid subtitle languages do not replace saved languages', () async {
    final settings = AppSettingsService();
    await settings.setSubtitleLanguages('hu');
    for (final invalid in ['', ' , ', 'all', 'en.+', 'live_chat', '--help']) {
      await expectLater(
        settings.setSubtitleLanguages(invalid),
        throwsFormatException,
      );
    }
    expect(await settings.getSubtitleLanguages(), 'hu');
  });

  test('subtitle languages forgive a trailing comma and accept en.*', () {
    expect(AppSettingsService.normalizeSubtitleLanguages('en, hu,'), 'en,hu');
    expect(
      AppSettingsService.normalizeSubtitleLanguages('en.*, pt-BR'),
      'en.*,pt-BR',
    );
  });

  test('restoring settings skips invalid subtitle languages', () async {
    final settings = AppSettingsService();
    await settings.setSubtitleLanguages('hu');

    final applied = await settings.importSettings({
      AppSettingsService.subtitleLanguagesKey: 'all',
      AppSettingsService.downloadSubtitlesKey: true,
    });

    expect(applied, 1);
    expect(await settings.getSubtitleLanguages(), 'hu');
    expect(await settings.getDownloadSubtitles(), isTrue);

    await settings.importSettings({
      AppSettingsService.subtitleLanguagesKey: ' de, en ,',
    });
    expect(await settings.getSubtitleLanguages(), 'de,en');
  });

  test('sound settings default to off and standard and persist', () async {
    final settings = AppSettingsService();
    expect(await settings.getEvenOutVolume(), isFalse);
    expect(await settings.getPlaneModeStrength(), PlaneModeStrength.standard);
    expect(await settings.getPlaneModeTipShown(), isFalse);
    await settings.setEvenOutVolume(true);
    await settings.setPlaneModeStrength(PlaneModeStrength.strong);
    await settings.setPlaneModeTipShown();
    final reloaded = AppSettingsService();
    expect(await reloaded.getEvenOutVolume(), isTrue);
    expect(await reloaded.getPlaneModeStrength(), PlaneModeStrength.strong);
    expect(await reloaded.getPlaneModeTipShown(), isTrue);
  });

  test('restoring settings brings back the sound preferences only', () async {
    final settings = AppSettingsService();
    final applied = await settings.importSettings({
      AppSettingsService.evenOutVolumeKey: true,
      AppSettingsService.planeModeStrengthKey: 'strong',
      AppSettingsService.planeModeTipShownKey: true,
    });
    expect(applied, 2);
    expect(await settings.getEvenOutVolume(), isTrue);
    expect(await settings.getPlaneModeStrength(), PlaneModeStrength.strong);
    expect(await settings.getPlaneModeTipShown(), isFalse);

    // A hand-edited backup with an unknown strength changes nothing.
    expect(
      await settings.importSettings({
        AppSettingsService.planeModeStrengthKey: 'max',
      }),
      0,
    );
    expect(await settings.getPlaneModeStrength(), PlaneModeStrength.strong);
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

  test('pausing for other apps is on by default', () async {
    final settings = AppSettingsService();

    expect(await settings.getPauseOnAudioInterruption(), isTrue);
  });

  test('pausing for other apps preference is persisted', () async {
    final settings = AppSettingsService();

    await settings.setPauseOnAudioInterruption(false);

    expect(await settings.getPauseOnAudioInterruption(), isFalse);
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

  test('remembers when yt-dlp last tried to update itself', () async {
    final settings = AppSettingsService();
    expect(await settings.getLastYtDlpUpdateAttempt(), isNull);

    final at = DateTime(2026, 10, 3, 12, 30);
    await settings.setLastYtDlpUpdateAttempt(at);

    expect(await AppSettingsService().getLastYtDlpUpdateAttempt(), at);
  });
}
