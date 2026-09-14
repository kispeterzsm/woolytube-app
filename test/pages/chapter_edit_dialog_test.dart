import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/pages/chapters_page.dart';
import 'package:woolytube/services/chapters.dart';

void main() {
  testWidgets('saves frozen fractional timestamps after entering a title', (
    tester,
  ) async {
    MediaChapter? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => TextButton(
                onPressed: () async {
                  saved = await showDialog<MediaChapter>(
                    context: context,
                    builder:
                        (_) => const ChapterEditDialog(
                          startMs: 10125,
                          endMs: 30500,
                          durationMs: 60000,
                        ),
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chapter-title')),
      'My song',
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved!.title, 'My song');
    expect(saved!.startMs, 10125);
    expect(saved!.endMs, 30500);
  });

  testWidgets('rejects a reversed range and allows correcting it', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ChapterEditDialog(
          startMs: 20000,
          endMs: 10000,
          durationMs: 60000,
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('chapter-title')), 'Song');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('The end must be after the start.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('chapter-end')), '1:99');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(
      find.text('Use minutes:seconds or hours:minutes:seconds.'),
      findsOneWidget,
    );
  });
}
