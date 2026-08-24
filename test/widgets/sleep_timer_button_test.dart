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

  test('formats countdowns for tooltips and the timer sheet', () {
    expect(formatSleepTimerRemaining(const Duration(seconds: 59)), '00:59');
    expect(
      formatSleepTimerRemaining(const Duration(hours: 1, seconds: 2)),
      '1:00:02',
    );
  });
}
