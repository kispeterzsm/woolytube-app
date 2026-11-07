import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/widgets/update_frequency_dropdown.dart';

void main() {
  test('labels read as plain intervals', () {
    expect(updateFrequencyLabel(1), 'Every hour');
    expect(updateFrequencyLabel(6), 'Every 6 hours');
    expect(updateFrequencyLabel(24), 'Every day');
    expect(updateFrequencyLabel(72), 'Every 3 days');
    expect(updateFrequencyLabel(168), 'Every week');
    expect(updateFrequencyLabel(336), 'Every 2 weeks');
  });

  test('an unusual stored interval is offered as it is', () {
    expect(updateFrequencyChoices(24), updateFrequencyOptions);
    final choices = updateFrequencyChoices(6);
    expect(choices.keys, [1, 6, 12, 24, 72, 168]);
    expect(choices[6], '6 hours');
  });

  testWidgets('the dropdown shows a stored 6 hours instead of snapping it', (
    tester,
  ) async {
    int? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateFrequencyDropdown(
            value: 6,
            onChanged: (hours) => changed = hours,
          ),
        ),
      ),
    );
    expect(find.text('6 hours'), findsOneWidget);
    expect(find.text('1 hour'), findsNothing);
    expect(changed, isNull);
  });
}
