import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/pages/debug_log_page.dart';
import 'package:woolytube/pages/settings_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/library_export_service.dart';
import 'package:woolytube/services/playback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backgroundChannel = MethodChannel('com.woolytube/background');

  setUp(() {
    // Saving some settings reschedules the background update.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'WoolyTube',
      packageName: 'com.woolytube',
      version: '1.4.2',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, null);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('enables subtitle downloads and saves validated languages', (
    tester,
  ) async {
    await pumpSettings(tester);
    final languages = find.byKey(const ValueKey('subtitle-languages'));
    expect(languages, findsNothing);
    await tester.tap(find.text('Download subtitles'));
    await tester.pumpAndSettle();
    expect(await AppSettingsService().getDownloadSubtitles(), isTrue);
    await tester.tap(languages);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // One-tap languages and a trailing comma are fine.
    await tester.enterText(find.byType(TextFormField), 'en,');
    await tester.tap(find.widgetWithText(FilterChip, 'Hungarian'));
    await tester.pump();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      'en, hu',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(await AppSettingsService().getSubtitleLanguages(), 'en,hu');
    expect(find.text('en,hu'), findsOneWidget);
  });

  testWidgets('shows the app version and opens the debug log', (tester) async {
    await pumpSettings(tester);
    expect(find.text('WoolyTube 1.4.2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('debug-log')));
    await tester.pumpAndSettle();
    expect(find.byType(DebugLogPage), findsOneWidget);
  });

  testWidgets('restoring settings asks first, then shows and applies them', (
    tester,
  ) async {
    final player = _Player();
    await pumpSettings(
      tester,
      overrides: [
        libraryExportServiceProvider.overrideWithValue(_Exporter()),
        playbackServiceProvider.overrideWithValue(player),
      ],
    );
    SwitchListTile pauseSwitch() => tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Pause when other apps play sound'),
    );
    expect(pauseSwitch().value, isTrue);

    await tester.tap(find.byKey(const ValueKey('restore-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Restore settings?'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.text('Restored 2 settings.'), findsOneWidget);
    expect(pauseSwitch().value, isFalse);
    expect(find.byKey(const ValueKey('subtitle-languages')), findsOneWidget);
    expect(player.pauseOnInterruption, [false]);
  });

  testWidgets('a restore that ends after Settings closed still reaches the '
      'player', (tester) async {
    final player = _Player();
    final exporter = _Exporter()..gate = Completer<void>();
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryExportServiceProvider.overrideWithValue(exporter),
          playbackServiceProvider.overrideWithValue(player),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('home marker')),
        ),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('restore-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pump();

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('home marker'), findsOneWidget);
    exporter.gate!.complete();
    await tester.pumpAndSettle();

    expect(player.pauseOnInterruption, [false]);
    expect(find.text('Restored 2 settings.'), findsOneWidget);
  });

  testWidgets('the audio setting stays saved when the player cannot take it '
      'right away', (tester) async {
    final player = _Player()..fail = true;
    await pumpSettings(
      tester,
      overrides: [playbackServiceProvider.overrideWithValue(player)],
    );
    final row = find.widgetWithText(
      SwitchListTile,
      'Pause when other apps play sound',
    );

    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(row).value, isFalse);
    expect(await AppSettingsService().getPauseOnAudioInterruption(), isFalse);
    expect(
      find.textContaining('applies after the app restarts'),
      findsOneWidget,
    );
  });
}

class _Exporter implements LibraryExportService {
  /// When set, the restore waits for it.
  Completer<void>? gate;

  @override
  Future<int?> restoreSettings({String? folder}) async {
    await gate?.future;
    return AppSettingsService().importSettings({
      AppSettingsService.pauseOnAudioInterruptionKey: false,
      AppSettingsService.downloadSubtitlesKey: true,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements PlaybackService {
  final pauseOnInterruption = <bool>[];
  bool fail = false;

  @override
  Future<void> setPauseOnAudioInterruption(bool enabled) async {
    if (fail) throw StateError('audio session not ready');
    pauseOnInterruption.add(enabled);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
