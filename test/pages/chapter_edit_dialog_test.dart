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

  testWidgets('a stored chapter past a shorter length does not block edits', (
    tester,
  ) async {
    // Recognition stored the probed length; YouTube's rounder one is
    // shorter than where the last chapter ends.
    const chapters = [
      MediaChapter(id: 'a', title: 'A', startMs: 0, endMs: 30000),
      MediaChapter(id: 'b', title: 'B', startMs: 30000, endMs: 60512),
    ];
    final saved = <MediaChapter?>[];
    Future<void> open(MediaChapter chapter) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed: () async {
                    saved.add(
                      await showDialog<MediaChapter>(
                        context: context,
                        builder:
                            (_) => ChapterEditDialog(
                              chapter: chapter,
                              durationMs: 60000,
                              chapters: chapters,
                            ),
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
        'Renamed',
      );
    }

    // Another chapter ends past the length.
    await open(chapters.first);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved.last!.title, 'Renamed');

    // This chapter keeps its stored end.
    await open(chapters.last);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved.last!.endMs, 60512);

    // A new end past the length is still refused.
    await open(chapters.last);
    await tester.enterText(find.byKey(const ValueKey('chapter-end')), '1:00.6');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(
      find.text('Chapters must stay within the media duration.'),
      findsOneWidget,
    );
  });
}
