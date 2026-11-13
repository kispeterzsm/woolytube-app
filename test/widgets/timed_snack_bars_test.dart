import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/widgets/timed_snack_bars.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester, {required bool wrap}) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(accessibleNavigation: true),
        child: MaterialApp(
          builder:
              wrap ? (context, child) => TimedSnackBars(child: child!) : null,
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => Column(
                    children: [
                      TextButton(
                        onPressed:
                            () => ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('Deleted'),
                                duration: const Duration(seconds: 4),
                                action: SnackBarAction(
                                  label: 'Undo',
                                  onPressed: () {},
                                ),
                              ),
                            ),
                        child: const Text('show'),
                      ),
                      Text(
                        'a11y ${MediaQuery.accessibleNavigationOf(context)}',
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('an Undo message closes after its time with accessibility on', (
    tester,
  ) async {
    await pumpApp(tester, wrap: true);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Deleted'), findsNothing);
  });

  testWidgets('pages below still see the real accessibility setting', (
    tester,
  ) async {
    await pumpApp(tester, wrap: true);
    expect(find.text('a11y true'), findsOneWidget);
  });

  testWidgets('without it Flutter keeps the message up (the old behaviour)', (
    tester,
  ) async {
    await pumpApp(tester, wrap: false);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Deleted'), findsOneWidget);
  });
}
