import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/labels_page.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/label_service.dart';
import 'package:woolytube/widgets/label_widgets.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LabelService labels;

  setUp(() {
    db = openTestDatabase();
    labels = LabelService(db);
  });

  tearDown(() => db.close());

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(411 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(theme: ThemeData.dark(), home: const LabelsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Drift's stream queries leave a timer behind; unmount first.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a new label gets a name and a color from the palette', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.textContaining('Labels mark files and chapters'), findsOne);

    await tester.tap(find.byKey(const ValueKey('labels-new-empty')));
    await tester.pumpAndSettle();
    expect(find.text('New label'), findsWidgets);
    // Nothing to save without a name.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('label-editor-save')))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('label-editor-name')),
      '  Synthwave ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('label-color-2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('label-editor-save')));
    await tester.pumpAndSettle();

    final made = (await labels.labels()).single;
    expect(made.name, 'Synthwave');
    expect(made.color, labelPalette[2].$2);
    expect(find.text('Synthwave'), findsOneWidget);
    expect(find.text('Not used yet'), findsOneWidget);

    // The next new label starts with a color no label has yet.
    await tester.tap(find.byKey(const ValueKey('labels-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('label-editor-name')),
      'Rock',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('label-editor-save')));
    await tester.pumpAndSettle();
    expect((await labels.labels()).last.color, labelPalette[0].$2);
    await unmount(tester);
  });

  testWidgets('rename and recolor; delete says how many items lose it, and '
      'Undo brings it back', (tester) async {
    final rock = await labels.create('Rock', labelPalette[0].$2);
    final playlist = await insertTestPlaylist(db);
    final song = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Song',
    );
    final mix = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'mix',
      title: 'Mix',
      chaptersJson:
          const ChapterData(
            downloaded: [
              MediaChapter(id: 'a', title: 'One', startMs: 0, endMs: 1000),
              MediaChapter(id: 'b', title: 'Two', startMs: 1000, endMs: 2000),
            ],
          ).encode(),
    );
    await labels.setTrackLabel(song.id, rock.uid, true);
    await labels.setChapterLabel(mix.id, 'a', rock.uid, true);
    await labels.setChapterLabel(mix.id, 'b', rock.uid, true);
    await pumpPage(tester);
    expect(find.text('1 file · 2 chapters'), findsOneWidget);

    await tester.tap(find.text('Rock'));
    await tester.pumpAndSettle();
    expect(find.text('Edit label'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('label-editor-name')),
      'Hard rock',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('label-color-7')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('label-editor-save')));
    await tester.pumpAndSettle();
    final edited = (await labels.labels()).single;
    expect((edited.name, edited.color), ('Hard rock', labelPalette[7].$2));
    expect(find.text('Hard rock'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('label-delete-${rock.uid}')));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Hard rock"?'), findsOneWidget);
    expect(find.textContaining('It is on 1 file · 2 chapters'), findsOne);
    await tester.tap(find.byKey(const ValueKey('label-delete-confirm')));
    await tester.pumpAndSettle();
    expect(await labels.labels(), isEmpty);
    expect(find.text('Deleted "Hard rock"'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect((await labels.labels()).single.uid, rock.uid);
    // Everything that had it has it again.
    expect((await labels.usage())[rock.uid]?.chapters, 2);
    expect(find.text('1 file · 2 chapters'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('Undo still works after leaving the page', (tester) async {
    final rock = await labels.create('Rock', labelPalette[0].$2);
    final playlist = await insertTestPlaylist(db);
    final song = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Song',
    );
    await labels.setTrackLabel(song.id, rock.uid, true);
    tester.view.physicalSize = const Size(411 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed:
                          () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const LabelsPage(),
                            ),
                          ),
                      child: const Text('Open labels'),
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open labels'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('label-delete-${rock.uid}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('label-delete-confirm')));
    await tester.pumpAndSettle();
    expect(await labels.labels(), isEmpty);

    // Back at once; the SnackBar stays over the page below.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(LabelsPage), findsNothing);
    expect(find.text('Deleted "Rock"'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect((await labels.labels()).single.uid, rock.uid);
    expect((await labels.usage())[rock.uid]?.files, 1);
    await unmount(tester);
  });
}
