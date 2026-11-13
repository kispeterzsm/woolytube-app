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
  Future<void> setEvenOutMode(EvenOutMode mode) async =>
      settings.add(settings.value.copyWith(evenOutMode: mode));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records what the settings page asks of loudness measuring.
class _Loudness implements LoudnessService {
  final calls = <String>[];
  bool? onlyWhileChargingValue;

  @override
  void measureNow() => calls.add('measureNow');

  @override
  void stopMeasuringNow() => calls.add('stop');

  @override
  void setOnlyWhileCharging(bool value) {
    calls.add('onlyWhileCharging:$value');
    onlyWhileChargingValue = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backgroundChannel = MethodChannel('com.woolytube/background');
  late _Player player;
  late _Loudness loudness;

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
    loudness = _Loudness();
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
          loudnessServiceProvider.overrideWithValue(loudness),
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

  testWidgets('the level choice shows only while "Even out volume" is on', (
    tester,
  ) async {
    await pumpSettings(tester);
    final mode = find.byKey(const ValueKey('even-out-mode'));
    expect(mode, findsNothing);

    await tester.tap(find.byKey(const ValueKey('even-out-volume')));
    await tester.pumpAndSettle();
    expect(mode, findsOneWidget);
    expect(find.textContaining('Normal: quiet songs are turned up'), findsOne);

    // Inside the switch's tile: plane mode stays right below it.
    final even = find.byKey(const ValueKey('even-out-volume'));
    expect(find.descendant(of: even, matching: mode), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('plane-mode-setting'))).dy,
      tester.getBottomLeft(even).dy,
    );

    await tester.tap(find.text('Quiet'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Quiet: a lower level'), findsOneWidget);
    expect(player.settings.value.evenOutMode, EvenOutMode.quiet);
    expect(player.settings.value.evenOutVolume, isTrue, reason: 'not toggled');
    expect(await AppSettingsService().getEvenOutMode(), EvenOutMode.quiet);
  });

  testWidgets('the stored level is shown', (tester) async {
    SharedPreferences.setMockInitialValues({
      AppSettingsService.evenOutVolumeKey: true,
      AppSettingsService.evenOutModeKey: 'quiet',
    });
    await pumpSettings(tester);
    final button = tester.widget<SegmentedButton<EvenOutMode>>(
      find.byKey(const ValueKey('even-out-mode')),
    );
    expect(button.selected, {EvenOutMode.quiet});
  });

  testWidgets('"Measure now" starts measuring and turns into Stop', (
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
    final button = find.byKey(const ValueKey('loudness-measure-now'));
    expect(
      find.descendant(of: button, matching: find.text('Measure now')),
      findsOneWidget,
    );
    await tester.tap(button);
    await tester.pump();
    expect(loudness.calls, ['measureNow']);
    expect(find.textContaining('Keep WoolyTube open'), findsOneWidget);
  });

  testWidgets('while measuring now, Stop ends it', (tester) async {
    await player.setEvenOutVolume(true);
    await pumpSettings(
      tester,
      progress: const LoudnessProgress(
        measured: 4,
        total: 10,
        working: true,
        forced: true,
      ),
    );
    expect(find.textContaining('also on battery'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(loudness.calls, ['stop']);
  });

  testWidgets('a measured library has no "Measure now"', (tester) async {
    await player.setEvenOutVolume(true);
    await pumpSettings(
      tester,
      progress: const LoudnessProgress(measured: 10, total: 10),
    );
    expect(find.byKey(const ValueKey('loudness-measure-now')), findsNothing);
  });

  testWidgets('files that could not be measured are counted and retryable', (
    tester,
  ) async {
    await player.setEvenOutVolume(true);
    await pumpSettings(
      tester,
      progress: const LoudnessProgress(measured: 8, total: 10, failed: 2),
    );
    expect(find.text('Measured 8 of 10 songs'), findsOneWidget);
    expect(
      find.text('2 could not be measured. Measure now tries them again.'),
      findsOneWidget,
    );
    expect(find.text('Measure now'), findsOneWidget);
  });

  testWidgets('says when measuring waits for files being moved', (
    tester,
  ) async {
    await player.setEvenOutVolume(true);
    await pumpSettings(
      tester,
      progress: const LoudnessProgress(
        measured: 3,
        total: 10,
        waitingForLibrary: true,
      ),
    );
    expect(find.textContaining('Paused while files are moved'), findsOne);
  });

  testWidgets('"Only measure while charging" shows while measuring is on, '
      'is on by default, and is saved', (tester) async {
    await pumpSettings(tester);
    final tile = find.byKey(const ValueKey('loudness-only-charging'));
    expect(tile, findsNothing);

    await player.setPlaneModePreference(true);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(loudness.calls, ['onlyWhileCharging:false']);
    expect(await AppSettingsService().getLoudnessOnlyWhileCharging(), isFalse);
  });
}
