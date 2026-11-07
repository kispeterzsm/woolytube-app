import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/pages/debug_log_page.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/log_service.dart';

void main() {
  testWidgets('shows the log with dates, filters by level and follows new '
      'lines', (tester) async {
    final log = LogService.memoryOnly();
    addTearDown(log.dispose);
    log.info('Update started');
    log.warn('Sync of "Mix" failed');
    log.error('Download failed');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [logServiceProvider.overrideWithValue(log)],
        child: const MaterialApp(home: DebugLogPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('INFO: Update started'), findsOneWidget);
    expect(find.textContaining('WARN: Sync of "Mix" failed'), findsOneWidget);

    await tester.tap(find.text('Errors'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Update started'), findsNothing);
    expect(find.textContaining('Download failed'), findsOneWidget);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    log.info('Another line');
    await tester.pumpAndSettle();
    expect(find.textContaining('Another line'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(find.text('The log is empty'), findsOneWidget);
  });
}
