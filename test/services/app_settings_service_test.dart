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

  test('the old app-wide subtitle setting is read once and removed', () async {
    final settings = AppSettingsService();
    expect(await settings.readLegacySubtitleSetting(), isNull);

    SharedPreferences.setMockInitialValues({
      AppSettingsService.legacyDownloadSubtitlesKey: true,
      AppSettingsService.legacySubtitleLanguagesKey: 'en,hu',
      AppSettingsService.evenOutVolumeKey: true,
    });
    expect(await settings.readLegacySubtitleSetting(), (
      enabled: true,
      languages: 'en,hu',
    ));
    await settings.clearLegacySubtitleSetting();
    expect(await settings.readLegacySubtitleSetting(), isNull);
    expect(await settings.getEvenOutVolume(), isTrue);

    // Only the languages, without the switch: it was off.
    SharedPreferences.setMockInitialValues({
      AppSettingsService.legacySubtitleLanguagesKey: 'de',
    });
    expect(await settings.readLegacySubtitleSetting(), (
      enabled: false,
      languages: 'de',
    ));
  });

  test('restoring an old backup skips the app-wide subtitle setting', () async {
    final settings = AppSettingsService();

    final applied = await settings.importSettings({
      AppSettingsService.legacySubtitleLanguagesKey: 'en,hu',
      AppSettingsService.legacyDownloadSubtitlesKey: true,
      AppSettingsService.evenOutVolumeKey: true,
    });

    expect(applied, 1);
    expect(await settings.getEvenOutVolume(), isTrue);
    expect(await settings.readLegacySubtitleSetting(), isNull);
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

  test(
    'levelling mode and measuring rule default, persist and restore',
    () async {
      final settings = AppSettingsService();
      expect(await settings.getEvenOutMode(), EvenOutMode.normal);
      expect(await settings.getLoudnessOnlyWhileCharging(), isTrue);
      await settings.setEvenOutMode(EvenOutMode.quiet);
      await settings.setLoudnessOnlyWhileCharging(false);
      final reloaded = AppSettingsService();
      expect(await reloaded.getEvenOutMode(), EvenOutMode.quiet);
      expect(await reloaded.getLoudnessOnlyWhileCharging(), isFalse);

      // Both are in the backup...
      final exported = await settings.exportSettings();
      expect(exported[AppSettingsService.evenOutModeKey], 'quiet');
      expect(
        exported[AppSettingsService.loudnessOnlyWhileChargingKey],
        isFalse,
      );

      // ... and come back from it.
      SharedPreferences.setMockInitialValues({});
      expect(await settings.importSettings(exported), 2);
      expect(await settings.getEvenOutMode(), EvenOutMode.quiet);
      expect(await settings.getLoudnessOnlyWhileCharging(), isFalse);

      // An unknown mode in a hand-edited backup changes nothing.
      expect(
        await settings.importSettings({
          AppSettingsService.evenOutModeKey: 'loud',
        }),
        0,
      );
      expect(await settings.getEvenOutMode(), EvenOutMode.quiet);
    },
  );

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
