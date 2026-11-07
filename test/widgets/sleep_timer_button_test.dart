import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/widgets/sleep_timer_button.dart';

void main() {
  testWidgets('shows active timer state and remaining time', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sleepTimerRemainingProvider.overrideWith(
            (ref) => Stream.value(const Duration(minutes: 14, seconds: 5)),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SleepTimerButton())),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.bedtime), findsOneWidget);
    expect(find.byTooltip('Sleep timer: 14:05 remaining'), findsOneWidget);
  });

  for (final chapter in [false, true]) {
    final unit = chapter ? 'chapter' : 'file';
    testWidgets('end-of-$unit mode names what it waits for', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sleepTimerRemainingProvider.overrideWith(
              (ref) => const Stream<Duration?>.empty(),
            ),
            stopAfterCurrentProvider.overrideWith((ref) => Stream.value(true)),
            currentItemIsChapterProvider.overrideWith(
              (ref) => Stream.value(chapter),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: SleepTimerButton())),
        ),
      );
      await tester.pump();

      expect(
        find.byTooltip('Sleep timer: pauses when this $unit ends'),
        findsOneWidget,
      );
      await tester.tap(find.byType(SleepTimerButton));
      await tester.pumpAndSettle();
      expect(find.text('End of this $unit'), findsOneWidget);
      expect(find.text('Pauses when this $unit ends'), findsOneWidget);
    });
  }

  test('formats countdowns for tooltips and the timer sheet', () {
    expect(formatSleepTimerRemaining(const Duration(seconds: 59)), '00:59');
    expect(
      formatSleepTimerRemaining(const Duration(hours: 1, seconds: 2)),
      '1:00:02',
    );
  });
}
