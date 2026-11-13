import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/pages/settings_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/audio_processing.dart';
import 'package:woolytube/services/loudness_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/widgets/settings_section_header.dart';

/// Records what the settings page tells the player.
class _Player implements PlaybackService {
  final settings = BehaviorSubject<AudioProcessingSettings>.seeded(
    const AudioProcessingSettings(),
  );
  final planeChoices = <bool>[];

  @override
  bool get planeMode => settings.value.planeMode;

  @override
  Stream<bool> get planeModeStream =>
      settings.stream.map((s) => s.planeMode).distinct();

  @override
  Stream<AudioProcessingSettings> get audioProcessingSettingsStream =>
      settings.stream.distinct();

  @override
  Future<void> setPlaneModePreference(bool enabled) async {
    planeChoices.add(enabled);
    settings.add(settings.value.copyWith(planeMode: enabled));
  }

  @override
  Future<void> setEvenOutVolume(bool enabled) async =>
      settings.add(settings.value.copyWith(evenOutVolume: enabled));

  @override
  Future<void> setPlaneModeStrength(PlaneModeStrength strength) async =>
      settings.add(settings.value.copyWith(strength: strength));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backgroundChannel = MethodChannel('com.woolytube/background');
  late _Player player;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'WoolyTube',
      packageName: 'com.woolytube',
      version: '1.5.1',
      buildNumber: '1',
      buildSignature: '',
    );
    player = _Player();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, null);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    LoudnessProgress progress = LoudnessProgress.unknown,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackServiceProvider.overrideWithValue(player),
          loudnessProgressProvider.overrideWith(
            (ref) => Stream.value(progress),
          ),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('"Even out volume" is saved and handed to the player', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text('Sound'), findsOneWidget);
    final tile = find.byKey(const ValueKey('even-out-volume'));
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(player.settings.value.evenOutVolume, isTrue);
    expect(await AppSettingsService().getEvenOutVolume(), isTrue);
  });

  testWidgets('plane mode sits right below "Even out volume" in Sound', (
    tester,
  ) async {
    await pumpSettings(tester);
    final sound = find.widgetWithText(SettingsSectionHeader, 'Sound');
    final even = find.byKey(const ValueKey('even-out-volume'));
    final plane = find.byKey(const ValueKey('plane-mode-setting'));
    final playback = find.widgetWithText(SettingsSectionHeader, 'Playback');
    expect(
      tester.getTopLeft(even).dy,
      greaterThan(tester.getTopLeft(sound).dy),
    );
    expect(tester.getTopLeft(plane).dy, tester.getBottomLeft(even).dy);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('plane-mode-strength'))).dy,
      inExclusiveRange(
        tester.getTopLeft(plane).dy,
        tester.getTopLeft(playback).dy,
      ),
    );
  });

  testWidgets('the strength is saved and handed to the player', (tester) async {
    await pumpSettings(tester);
    expect(find.textContaining('Standard: gentle'), findsOneWidget);
    await tester.tap(find.text('Strong'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Strong: lifts quiet parts'), findsOneWidget);
    expect(player.settings.value.strength, PlaneModeStrength.strong);
    expect(
      await AppSettingsService().getPlaneModeStrength(),
      PlaneModeStrength.strong,
    );
  });

  testWidgets('the plane mode switch follows and drives the player', (
    tester,
  ) async {
    await pumpSettings(tester);
    final tile = find.byKey(const ValueKey('plane-mode-setting'));
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(player.planeChoices, [true]);
    expect(find.byKey(const ValueKey('plane-mode-tips')), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    // Switched off from the player: the setting follows.
    await player.setPlaneModePreference(false);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });

  testWidgets('measuring progress shows only while measuring is on', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      progress: const LoudnessProgress(measured: 3, total: 10, working: true),
    );
    expect(find.byKey(const ValueKey('loudness-progress')), findsNothing);

    await player.setEvenOutVolume(true);
    await tester.pumpAndSettle();
    expect(find.text('Measured 3 of 10 songs'), findsOneWidget);
  });

  testWidgets('a finished library says so', (tester) async {
    await player.setPlaneModePreference(true);
    await pumpSettings(
      tester,
      progress: const LoudnessProgress(measured: 10, total: 10),
    );
    expect(find.text('All 10 songs measured'), findsOneWidget);
  });

  testWidgets('says when the rest of the library waits for a charger', (
    tester,
  ) async {
    await player.setEvenOutVolume(true);
    await pumpSettings(
      tester,
      progress: const LoudnessProgress(
        measured: 4,
        total: 10,
        waitingForCharger: true,
      ),
    );
    expect(find.text('Measured 4 of 10 songs'), findsOneWidget);
    expect(find.textContaining('while the phone charges'), findsOneWidget);
  });
}
