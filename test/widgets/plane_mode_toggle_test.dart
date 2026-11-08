import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/widgets/plane_mode_toggle.dart';

class _Player implements PlaybackService {
  final _plane = BehaviorSubject<bool>.seeded(false);
  final choices = <bool>[];

  @override
  bool get planeMode => _plane.value;

  @override
  Stream<bool> get planeModeStream => _plane.stream.distinct();

  @override
  Future<void> setPlaneModePreference(bool enabled) async {
    choices.add(enabled);
    _plane.add(enabled);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Player player;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    player = _Player();
  });

  Future<void> pumpButton(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playbackServiceProvider.overrideWithValue(player)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder:
                    (context, ref, _) => TextButton(
                      key: const ValueKey('plane-mode-toggle'),
                      onPressed:
                          () => togglePlaneModeWithFeedback(context, ref),
                      child: const Text('Plane mode'),
                    ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the first switch-on explains how to listen quieter', (
    tester,
  ) async {
    await pumpButton(tester);
    await tester.tap(find.byKey(const ValueKey('plane-mode-toggle')));
    await tester.pumpAndSettle();
    expect(player.choices, [true]);
    expect(find.byKey(const ValueKey('plane-mode-tips')), findsOneWidget);
    expect(find.textContaining('tight fit'), findsOneWidget);
    expect(find.textContaining('quiet parts are just clear'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(AppSettingsService.planeModeTipShownKey), true);

    // Off, then on again: only short messages from now on.
    await tester.tap(find.byKey(const ValueKey('plane-mode-toggle')));
    await tester.pump();
    expect(find.text('Plane mode off'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.tap(find.byKey(const ValueKey('plane-mode-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plane-mode-tips')), findsNothing);
    expect(find.textContaining('Plane mode on.'), findsOneWidget);
    expect(player.choices, [true, false, true]);
  });
}
