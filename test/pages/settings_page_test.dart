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
import 'package:woolytube/widgets/settings_section_header.dart';

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

  testWidgets('sections run update, downloads, backup, sound, playback', (
    tester,
  ) async {
    await pumpSettings(tester);
    double top(Finder finder) => tester.getTopLeft(finder).dy;
    final headers = [
      'Update',
      'Downloads and updates',
      'Backup and restore',
      'Sound',
      'Playback',
      'Troubleshooting',
    ];
    final tops = [
      for (final header in headers)
        top(find.widgetWithText(SettingsSectionHeader, header)),
    ];
    expect(tops, orderedEquals([...tops]..sort()));

    // The app update comes first, before any section of settings.
    expect(
      top(find.byKey(const ValueKey('app-update'))),
      lessThan(top(find.text('Downloads and updates'))),
    );
    // Each row stays under its own header.
    expect(
      top(find.text('Update playlists on mobile data')),
      inExclusiveRange(tops[1], tops[2]),
    );
    expect(
      top(find.text('Downloader (yt-dlp)')),
      inExclusiveRange(tops[1], tops[2]),
    );
    expect(
      top(find.byKey(const ValueKey('restore-settings'))),
      inExclusiveRange(tops[2], tops[3]),
    );
    expect(
      top(find.text('Pause when other apps play sound')),
      inExclusiveRange(tops[4], tops[5]),
    );
    expect(top(find.byKey(const ValueKey('debug-log'))), greaterThan(tops[5]));
  });

  testWidgets('subtitles are a playlist setting, not an app setting', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text('Download subtitles'), findsNothing);
    expect(find.text('Subtitle languages'), findsNothing);
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
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(
              SwitchListTile,
              'Update playlists on mobile data',
            ),
          )
          .value,
      isTrue,
    );
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
      AppSettingsService.autoDownloadWithMobileDataKey: true,
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
