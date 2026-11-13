import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/chapter_editor_page.dart';
import 'package:woolytube/pages/chapters_page.dart';
import 'package:woolytube/pages/lyrics_page.dart';
import 'package:woolytube/providers/chapter_editor_providers.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/chapter_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/label_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';

import '../helpers/real_fonts.dart';
import '../helpers/test_database.dart';
import 'chapter_editor_fakes.dart';

void main() {
  late AppDatabase db;
  late _Player player;
  late FakePreviewFactory previews;
  late Directory dir;
  late String mediaPath;

  setUp(() {
    db = openTestDatabase();
    player = _Player();
    previews = FakePreviewFactory();
    ChapterEditorPage.resetSessionChoices();
    // The editor plays the real file, so it has to exist.
    dir = Directory.systemTemp.createTempSync('woolytube-chapters-page-');
    mediaPath = '${dir.path}/mix.mp3';
    File(mediaPath).writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() async {
    await player.close();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  const youTubeChapters = ChapterData(
    downloaded: [
      MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 60000),
      MediaChapter(id: 'b', title: 'Song', startMs: 60000, endMs: 180000),
    ],
    durationMs: 180000,
  );

  Future<Track> addTrack({
    ChapterData? chapters,
    bool isLocalReplacement = false,
    int? durationSeconds = 180,
    String videoId = 'video-1',
  }) async {
    final playlist = await insertTestPlaylist(db);
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'other',
      title: 'Other',
    );
    return insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: videoId,
      title: 'Long mix',
      status: 'complete',
      filePath: mediaPath,
      durationSeconds: durationSeconds,
      isLocalReplacement: isLocalReplacement,
      chaptersJson: chapters?.encode(),
    );
  }

  Future<void> pumpPage(WidgetTester tester, Track track) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playbackServiceProvider.overrideWithValue(player),
          chapterServiceProvider.overrideWithValue(_Chapters(db)),
          chapterPreviewPlayerFactoryProvider.overrideWithValue(previews.call),
          waveformServiceProvider.overrideWithValue(fakeWaveforms()),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: ChaptersPage(track: track),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Drift's stream queries leave a timer behind; unmount first.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<ChapterData> storedChapters(int id) async =>
      ChapterData.decode((await db.getTrack(id))!.chaptersJson);

  testWidgets('"Play as" saves the choice and explains the default', (
    tester,
  ) async {
    final track = await addTrack(chapters: youTubeChapters);
    await pumpPage(tester, track);

    expect(find.textContaining('which is on'), findsOneWidget);
    expect(find.text('From YouTube'), findsOneWidget);
    await tester.tap(find.text('Whole file'));
    await tester.pumpAndSettle();

    expect((await db.getTrack(track.id))!.chaptersEnabled, isFalse);
    expect(
      find.textContaining('Chapters are off for this video'),
      findsOneWidget,
    );
    expect(player.chaptersChanged, [track.id]);
    await unmount(tester);
  });

  group('Shuffle chapters', () {
    Finder segment(String label) => find.descendant(
      of: find.byKey(const ValueKey('chapters-shuffle')),
      matching: find.text(label),
    );
    bool shuffleEnabled(WidgetTester tester) =>
        (tester.widget(find.byKey(const ValueKey('chapters-shuffle')))
                as dynamic)
            .onSelectionChanged !=
        null;

    testWidgets('saves Default, Shuffle or Don\'t shuffle and names the '
        'playlist setting', (tester) async {
      final track = await addTrack(chapters: youTubeChapters);
      await pumpPage(tester, track);

      expect(shuffleEnabled(tester), isTrue);
      expect(
        find.textContaining('"Shuffle chapters", which is off'),
        findsOneWidget,
      );
      expect((await storedChapters(track.id)).shuffleChapters, isNull);

      await tester.tap(segment('Shuffle'));
      await tester.pumpAndSettle();
      expect((await storedChapters(track.id)).shuffleChapters, isTrue);
      await tester.tap(segment('Don\'t shuffle'));
      await tester.pumpAndSettle();
      expect((await storedChapters(track.id)).shuffleChapters, isFalse);
      await tester.tap(segment('Default'));
      await tester.pumpAndSettle();
      expect((await storedChapters(track.id)).shuffleChapters, isNull);
      expect(player.chaptersChanged, [track.id, track.id, track.id]);

      await db.updatePlaylistFields(
        track.playlistId,
        const PlaylistsCompanion(shuffleChapters: Value(true)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('"Shuffle chapters", which is on'),
        findsOneWidget,
      );
      await unmount(tester);
    });

    testWidgets('is greyed out while the file plays as a whole file', (
      tester,
    ) async {
      final track = await addTrack(
        chapters: youTubeChapters.withShuffleChapters(true),
      );
      await pumpPage(tester, track);
      expect(shuffleEnabled(tester), isTrue);

      await tester.tap(find.text('Whole file'));
      await tester.pumpAndSettle();
      expect(shuffleEnabled(tester), isFalse);
      expect(find.textContaining('can\'t be shuffled'), findsOneWidget);
      // A tap does nothing; the stored choice stays for later.
      await tester.tap(segment('Don\'t shuffle'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect((await storedChapters(track.id)).shuffleChapters, isTrue);

      // Default, with a playlist that plays whole files, is the same.
      await db.updatePlaylistFields(
        track.playlistId,
        const PlaylistsCompanion(playChapters: Value(false)),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('chapters-play-as')),
          matching: find.text('Default'),
        ),
      );
      await tester.pumpAndSettle();
      expect(shuffleEnabled(tester), isFalse);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('chapters-play-as')),
          matching: find.text('Chapters'),
        ),
      );
      await tester.pumpAndSettle();
      expect((await db.getTrack(track.id))!.chaptersEnabled, isTrue);
      expect(shuffleEnabled(tester), isTrue);
      expect(find.textContaining('can\'t be shuffled'), findsNothing);
      await unmount(tester);
    });

    testWidgets('is greyed out for a file with only one chapter', (
      tester,
    ) async {
      final one = await addTrack(
        chapters: const ChapterData(
          downloaded: [
            MediaChapter(id: 'a', title: 'Only', startMs: 0, endMs: 180000),
          ],
          durationMs: 180000,
        ),
      );
      await pumpPage(tester, one);
      expect(shuffleEnabled(tester), isFalse);
      expect(find.textContaining('only one chapter'), findsOneWidget);
      expect(find.textContaining('"Shuffle chapters", which is'), findsNothing);
      await tester.tap(segment('Shuffle'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect((await storedChapters(one.id)).shuffleChapters, isNull);
      await unmount(tester);
    });

    testWidgets('stays a choice when chapters are marked Always skip', (
      tester,
    ) async {
      // Tapping a skipped chapter plays it along with the rest, and a file
      // whose chapters are all skipped plays them all when tapped, so the
      // order still matters.
      for (final (index, chapters)
          in [
            youTubeChapters.withChapterSkip('a', true),
            youTubeChapters
                .withChapterSkip('a', true)
                .withChapterSkip('b', true),
          ].indexed) {
        final track = await addTrack(
          chapters: chapters,
          videoId: 'video-skip-$index',
        );
        await pumpPage(tester, track);
        expect(shuffleEnabled(tester), isTrue);
        expect(find.textContaining('nothing to shuffle'), findsNothing);
        expect(
          find.textContaining('"Shuffle chapters", which is'),
          findsOneWidget,
        );
        await tester.tap(segment('Don\'t shuffle'));
        await tester.pumpAndSettle();
        expect((await storedChapters(track.id)).shuffleChapters, isFalse);
        await unmount(tester);
      }
    });

    testWidgets('is not shown for a file without chapters', (tester) async {
      final track = await addTrack();
      await pumpPage(tester, track);
      expect(find.byKey(const ValueKey('chapters-shuffle')), findsNothing);
      await unmount(tester);
    });
  });

  testWidgets('deleting a chapter can be undone', (tester) async {
    final track = await addTrack(chapters: youTubeChapters);
    await pumpPage(tester, track);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('chapter-a')),
        matching: find.byTooltip('Chapter options'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect((await storedChapters(track.id)).active.map((c) => c.id), ['b']);
    expect(find.textContaining('now uses your own'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final restored = await storedChapters(track.id);
    expect(restored.active.map((c) => c.id), ['a', 'b']);
    expect(restored.custom, isNull);
    await unmount(tester);
  });

  testWidgets('Undo still brings a deleted chapter back after leaving the '
      'page', (tester) async {
    final track = await addTrack(chapters: youTubeChapters);
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playbackServiceProvider.overrideWithValue(player),
          chapterServiceProvider.overrideWithValue(_Chapters(db)),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData.dark(),
          home: const Scaffold(body: Text('player marker')),
        ),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => ChaptersPage(track: track)),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('chapter-a')),
        matching: find.byTooltip('Chapter options'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect((await storedChapters(track.id)).active.map((c) => c.id), ['b']);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('player marker'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final restored = await storedChapters(track.id);
    expect(restored.active.map((c) => c.id), ['a', 'b']);
    expect(player.chaptersChanged, [track.id, track.id]);
    await unmount(tester);
  });

  testWidgets('tapping a chapter of the song that is playing keeps the '
      'queue', (tester) async {
    final track = await addTrack(chapters: youTubeChapters);
    player.item = PlaybackItem(track, youTubeChapters.downloaded.first);
    await pumpPage(tester, track);

    await tester.tap(find.text('Song'));
    await tester.pumpAndSettle();
    expect(player.chapterJumps, [(track.id, 'b')]);
    expect(player.playedTracks, isEmpty);
    await unmount(tester);
  });

  testWidgets('tapping a chapter while the whole file plays jumps there', (
    tester,
  ) async {
    final track = await addTrack(chapters: youTubeChapters);
    player.item = PlaybackItem(track);
    await pumpPage(tester, track);

    await tester.tap(find.text('Song'));
    await tester.pumpAndSettle();
    expect(player.seeks, [const Duration(minutes: 1)]);
    expect(player.resumes, 1);
    expect(player.playedTracks, isEmpty);
    await unmount(tester);
  });

  testWidgets('tapping a chapter plays it with the playlist as the queue', (
    tester,
  ) async {
    final track = await addTrack(chapters: youTubeChapters);
    await pumpPage(tester, track);

    await tester.tap(find.text('Song'));
    await tester.pumpAndSettle();
    expect(player.playedTracks.single, (track.id, 'b', 2));
    await unmount(tester);
  });

  Future<void> openChapterOptions(WidgetTester tester, String id) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('chapter-$id')),
        matching: find.byTooltip('Chapter options'),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Ends a preview the editor started, so frames stop and the tree
  /// settles.
  Future<void> finishPreview(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 200));
    previews.last.finish();
    await tester.pumpAndSettle();
  }

  testWidgets('Edit chapters opens the editor on the YouTube chapters and '
      'saves the result as one change Undo takes back', (tester) async {
    final track = await addTrack(chapters: youTubeChapters);
    await pumpPage(tester, track);

    expect(find.text('Edit chapters'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chapters-edit')));
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditorPage), findsOneWidget);
    expect(find.text('Boundary 2 of 3'), findsOneWidget);
    expect(previews.last.filePath, mediaPath);

    await tester.tap(find.byKey(const ValueKey('editor-nudge-1000')));
    await finishPreview(tester);
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();

    // Saving stores the list and stays in the editor; back then leaves
    // without asking.
    expect(find.byType(ChapterEditorPage), findsOneWidget);
    expect(find.text('Chapters saved.'), findsOneWidget);
    expect(player.chaptersChanged, [track.id]);

    // A second save in the same session is part of the same change.
    await tester.tap(find.byKey(const ValueKey('editor-nudge-1000')));
    await finishPreview(tester);
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(player.chaptersChanged, [track.id, track.id]);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    expect(find.byType(ChapterEditorPage), findsNothing);
    expect(
      find.text('Chapters saved. Undo last chapter change takes it back.'),
      findsOneWidget,
    );
    final saved = await storedChapters(track.id);
    expect(saved.active.map((c) => (c.id, c.startMs, c.endMs)), [
      ('a', 0, 62000),
      ('b', 62000, 180000),
    ]);
    expect(saved.active.every((c) => c.manuallyEdited), isTrue);
    expect(previews.last.disposed, isTrue);

    await tester.tap(find.byKey(const ValueKey('chapters-undo')));
    await tester.pumpAndSettle();
    // Undo goes back to before the editor: following YouTube again.
    final undone = await storedChapters(track.id);
    expect(undone.custom, isNull);
    expect(undone.active.first.endMs, 60000);
    await unmount(tester);
  });

  testWidgets('Create chapters works on a file of unknown length', (
    tester,
  ) async {
    final track = await addTrack(
      isLocalReplacement: true,
      durationSeconds: null,
    );
    await pumpPage(tester, track);
    expect(find.textContaining('Tap Create chapters'), findsOneWidget);

    await tester.tap(find.text('Create chapters'));
    await tester.pumpAndSettle();
    expect(find.text('No chapters yet'), findsOneWidget);
    // The preview player measured the file.
    await tester.tap(find.byKey(const ValueKey('editor-start-scratch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();

    final saved = await storedChapters(track.id);
    expect(saved.active.map((c) => (c.title, c.startMs, c.endMs)), [
      ('Chapter 1', 0, 180000),
    ]);
    expect(saved.active.single.origin, ChapterOrigin.user);
    await unmount(tester);
  });

  testWidgets('a chapter can be played next, queued and marked Always skip', (
    tester,
  ) async {
    final track = await addTrack(chapters: youTubeChapters);
    await pumpPage(tester, track);

    await openChapterOptions(tester, 'b');
    expect(find.byKey(const ValueKey('chapter-actions-title')), findsOneWidget);
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();
    expect(player.queued, [(track.id, 'b', true)]);
    expect(player.idleStarts, 1);
    expect(find.text('Plays next: "Song"'), findsOneWidget);

    await openChapterOptions(tester, 'b');
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();
    expect(player.queued.last, (track.id, 'b', false));

    await openChapterOptions(tester, 'b');
    await tester.tap(find.byKey(const ValueKey('chapter-actions-always-skip')));
    await tester.pumpAndSettle();
    final stored = await storedChapters(track.id);
    expect(stored.isSkipped('b'), isTrue);
    // A setting, not an edit: the YouTube chapters are still followed.
    expect(stored.custom, isNull);
    expect(player.chaptersChanged, [track.id]);
    expect(find.text('Turn off Always skip to queue it'), findsNWidgets(2));
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('chapter-actions-play-next')),
          )
          .enabled,
      isFalse,
    );
    // Play still plays it: the user chose it.
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('chapter-actions-play')))
          .enabled,
      isTrue,
    );

    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chapter-b')),
        matching: find.textContaining('Always\u00A0skip'),
      ),
      findsOneWidget,
    );

    await openChapterOptions(tester, 'b');
    await tester.tap(find.byKey(const ValueKey('chapter-actions-always-skip')));
    await tester.pumpAndSettle();
    expect((await storedChapters(track.id)).isSkipped('b'), isFalse);
    await unmount(tester);
  });

  testWidgets('a chapter gets labels from its menu; they show as dots', (
    tester,
  ) async {
    final labels = LabelService(db);
    final rock = await labels.create('Rock', 0xFFE57373);
    final track = await addTrack(chapters: youTubeChapters);
    await pumpPage(tester, track);
    expect(find.byKey(const ValueKey('chapter-labels-b')), findsNothing);

    await openChapterOptions(tester, 'b');
    await tester.tap(find.byKey(const ValueKey('chapter-actions-labels')));
    await tester.pumpAndSettle();
    expect(find.text('Chapter labels'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('label-picker-${rock.uid}')));
    await tester.pumpAndSettle();
    final stored = await storedChapters(track.id);
    expect(stored.labelsOf('b'), [rock.uid]);
    expect(stored.labelsOf('a'), isEmpty);
    // A label, not an edit: the YouTube chapters are still followed.
    expect(stored.custom, isNull);

    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chapter-labels-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('chapter-labels-a')), findsNothing);

    // The menu shows it as a chip and by name.
    await openChapterOptions(tester, 'b');
    expect(find.byKey(ValueKey('label-chip-${rock.uid}')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chapter-actions-labels')),
        matching: find.text('Rock'),
      ),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('Edit chapters on the file that is playing opens on the '
      'chapter it plays, with its playhead where the player is', (
    tester,
  ) async {
    final track = await addTrack(chapters: youTubeChapters);
    player.item = PlaybackItem(track);
    player.position = const Duration(milliseconds: 30250);
    await pumpPage(tester, track);
    String topBar() => tester
        .widget<Text>(find.byKey(const ValueKey('editor-top-playhead')))
        .textSpan!
        .toPlainText(includePlaceholders: false);

    await tester.tap(find.byKey(const ValueKey('chapters-edit')));
    await tester.pumpAndSettle();
    // "Intro" plays: its start is selected, not the usual first shared
    // boundary, and the preview playhead is where the player is.
    expect(find.text('Boundary 1 of 3'), findsOneWidget);
    expect(previews.last.seeks, [30250]);
    expect(topBar(), '0:30.250');

    // The top bar shows the editor's playhead, not the app's player
    // (which the editor's preview pauses).
    player.position = const Duration(milliseconds: 31500);
    await tester.pumpAndSettle();
    expect(topBar(), '0:30.250');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditorPage), findsNothing);
    await unmount(tester);
  });

  testWidgets('Adjust boundaries opens the editor on that chapter', (
    tester,
  ) async {
    final track = await addTrack(chapters: youTubeChapters);
    await pumpPage(tester, track);

    await openChapterOptions(tester, 'b');
    await tester.tap(find.text('Adjust boundaries…'));
    await tester.pumpAndSettle();
    expect(find.text('Boundary 2 of 3'), findsOneWidget);
    expect(find.text('Starts'), findsOneWidget);

    // Unchanged: back leaves without asking.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditorPage), findsNothing);
    expect(player.chaptersChanged, isEmpty);
    await unmount(tester);
  });

  group('Share link', () {
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    late List<Map<Object?, Object?>> shared;

    setUp(() {
      shared = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            shared.add(call.arguments as Map<Object?, Object?>);
            return 'dev.fluttercommunity.plus/share/unavailable';
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('shares the YouTube link to the chapter start', (tester) async {
      final track = await addTrack(
        chapters: const ChapterData(
          downloaded: [
            MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 61500),
            MediaChapter(id: 'b', title: 'Song', startMs: 61500, endMs: 180000),
          ],
          durationMs: 180000,
        ),
        videoId: 'a-B_c9',
      );
      await pumpPage(tester, track);

      await openChapterOptions(tester, 'b');
      expect(find.text('Opens YouTube at 1:01'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chapter-actions-share')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chapter-actions-list')), findsNothing);
      expect(shared, hasLength(1));
      expect(shared.single['uri'], 'https://youtu.be/a-B_c9?t=61');
      expect(shared.single['title'], 'Song');

      await openChapterOptions(tester, 'a');
      await tester.tap(find.byKey(const ValueKey('chapter-actions-share')));
      await tester.pumpAndSettle();
      expect(shared.last['uri'], 'https://youtu.be/a-B_c9?t=0');
      await unmount(tester);
    });

    testWidgets('is not offered for a file put in place of the original', (
      tester,
    ) async {
      final track = await addTrack(
        chapters: youTubeChapters,
        isLocalReplacement: true,
      );
      await pumpPage(tester, track);

      await openChapterOptions(tester, 'b');
      expect(
        find.byKey(const ValueKey('chapter-actions-title')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('chapter-actions-share')), findsNothing);
      await unmount(tester);
    });

    testWidgets('is not offered for an inserted local file', (tester) async {
      final track = await addTrack(
        chapters: youTubeChapters,
        videoId: 'force-insert:1700000000',
      );
      await pumpPage(tester, track);

      await openChapterOptions(tester, 'b');
      expect(
        find.byKey(const ValueKey('chapter-actions-title')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('chapter-actions-share')), findsNothing);
      await unmount(tester);
    });
  });

  testWidgets('Lyrics opens that chapter on the lyrics page', (tester) async {
    final track = await addTrack(chapters: youTubeChapters);
    await (db.update(db.playlists)..where(
      (p) => p.id.equals(track.playlistId),
    )).write(const PlaylistsCompanion(lyricsMode: Value('lyrics')));
    await pumpPage(tester, track);

    await openChapterOptions(tester, 'b');
    expect(find.text('See the lyrics, or pick the right song'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chapter-actions-lyrics')));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsPage), findsOneWidget);
    expect(find.text('2. Song'), findsOneWidget);
    expect(find.text('Not fetched yet'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a chapter can be renamed and its times typed', (tester) async {
    final track = await addTrack(chapters: youTubeChapters);
    await pumpPage(tester, track);

    await openChapterOptions(tester, 'a');
    await tester.tap(find.text('Edit times…'));
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditDialog), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('chapter-end')))
          .controller!
          .text,
      '1:00',
    );
    await tester.enterText(find.byKey(const ValueKey('chapter-end')), '0:50');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await storedChapters(track.id)).active.first.endMs, 50000);

    await openChapterOptions(tester, 'b');
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chapter-rename')),
      'Tune',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final renamed = (await storedChapters(track.id)).active.last;
    expect(renamed.title, 'Tune');
    expect(renamed.manuallyEdited, isTrue);
    expect(player.chaptersChanged, [track.id, track.id]);
    await unmount(tester);
  });

  group('the playing chapter', () {
    const accent = Color(0xFF2196F3);
    // The Recognize songs button uses the same icon, so only rows count.
    final playingIcon = find.byWidgetPredicate(
      (w) =>
          w is Icon &&
          w.icon == Icons.graphic_eq &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('chapter-playing-'),
    );

    Text title(WidgetTester tester, String id) =>
        tester.widget<Text>(find.byKey(ValueKey('chapter-title-$id')));

    Finder playingMark(String id) =>
        find.byKey(ValueKey('chapter-playing-$id'));

    testWidgets('is marked like the current track and follows the position '
        'while the whole file plays', (tester) async {
      final track = await addTrack(chapters: youTubeChapters);
      player.item = PlaybackItem(track);
      player.playing = true;
      await pumpPage(tester, track);

      expect(playingMark('a'), findsOneWidget);
      expect(playingIcon, findsOneWidget);
      expect(title(tester, 'a').style?.color, accent);
      expect(title(tester, 'a').style?.fontWeight, FontWeight.w600);
      expect(title(tester, 'b').style?.color, isNull);

      player.position = const Duration(seconds: 30);
      await tester.pumpAndSettle();
      expect(playingMark('a'), findsOneWidget);

      player.position = const Duration(seconds: 90);
      await tester.pumpAndSettle();
      expect(playingMark('b'), findsOneWidget);
      expect(playingIcon, findsOneWidget);
      expect(title(tester, 'a').style?.color, isNull);
      expect(title(tester, 'b').style?.color, accent);

      // Paused: still marked, without the playing icon.
      player.playing = false;
      await tester.pumpAndSettle();
      expect(playingIcon, findsNothing);
      expect(title(tester, 'b').style?.color, accent);
      await unmount(tester);
    });

    testWidgets('is the chapter played as its own track', (tester) async {
      final track = await addTrack(chapters: youTubeChapters);
      player.item = PlaybackItem(track, youTubeChapters.downloaded.last);
      player.playing = true;
      await pumpPage(tester, track);
      expect(playingMark('b'), findsOneWidget);

      // The position is on the chapter's own timeline: 10 s into 'b'.
      player.position = const Duration(seconds: 10);
      await tester.pumpAndSettle();
      expect(playingMark('b'), findsOneWidget);

      player.item = PlaybackItem(track, youTubeChapters.downloaded.first);
      await tester.pumpAndSettle();
      expect(playingMark('a'), findsOneWidget);
      expect(playingIcon, findsOneWidget);
      await unmount(tester);
    });

    testWidgets('is not marked while another file plays', (tester) async {
      final track = await addTrack(chapters: youTubeChapters);
      final other = (await db.getTracksForPlaylist(
        track.playlistId,
      )).firstWhere((t) => t.id != track.id);
      player.item = PlaybackItem(other);
      player.playing = true;
      await pumpPage(tester, track);
      expect(playingIcon, findsNothing);
      expect(title(tester, 'a').style?.color, isNull);
      expect(title(tester, 'b').style?.color, isNull);
      await unmount(tester);
    });
  });

  testWidgets('stand-in chapter names are red, even while playing', (
    tester,
  ) async {
    final track = await addTrack(
      chapters: const ChapterData(
        downloaded: [
          MediaChapter(id: 'a', title: 'Chapter 1', startMs: 0, endMs: 60000),
          MediaChapter(
            id: 'b',
            title: unrecognizedChapterTitle,
            startMs: 60000,
            endMs: 120000,
          ),
          MediaChapter(
            id: 'c',
            title: 'Chapter 3 (live)',
            startMs: 120000,
            endMs: 180000,
          ),
        ],
        durationMs: 180000,
      ),
    );
    player.item = PlaybackItem(track);
    player.playing = true;
    await pumpPage(tester, track);

    Color? colorOf(String id) =>
        tester
            .widget<Text>(find.byKey(ValueKey('chapter-title-$id')))
            .style
            ?.color;
    final error =
        Theme.of(
          tester.element(find.byKey(const ValueKey('chapter-title-c'))),
        ).colorScheme.error;
    expect(find.byKey(const ValueKey('chapter-playing-a')), findsOneWidget);
    expect(colorOf('a'), error);
    expect(colorOf('b'), error);
    expect(colorOf('c'), isNot(error));
    await unmount(tester);
  });

  testWidgets('chapter lengths are right-aligned', (tester) async {
    final track = await addTrack(
      chapters: const ChapterData(
        downloaded: [
          MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 5000),
          MediaChapter(id: 'b', title: 'Song', startMs: 5000, endMs: 180000),
        ],
        durationMs: 180000,
      ),
    );
    await pumpPage(tester, track);

    final a = find.byKey(const ValueKey('chapter-length-a'));
    final b = find.byKey(const ValueKey('chapter-length-b'));
    expect(tester.widget<Text>(a).data, '0:05');
    expect(tester.widget<Text>(b).data, '2:55');
    expect(tester.getTopRight(a).dx, tester.getTopRight(b).dx);
    // Past the times, at the right of the row's text.
    final times = find.descendant(
      of: find.byKey(const ValueKey('chapter-b')),
      matching: find.textContaining('0:05 –\u2060\u00A03:00'),
    );
    expect(tester.getTopLeft(b).dx, greaterThan(tester.getTopRight(times).dx));
    await unmount(tester);
  });

  testWidgets('the chapter list fits a narrow phone', (tester) async {
    final track = await addTrack(
      chapters: youTubeChapters.withChapterSkip('b', true),
    );
    await pumpPage(tester, track);
    tester.view.physicalSize = const Size(320, 2000);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await openChapterOptions(tester, 'b');
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(160, 20));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  // Last in the file: Roboto stays loaded for the rest of the run.
  group('with the phone font on a 411 dp screen', () {
    setUpAll(loadRoboto);

    testWidgets('labelled chapters keep their lines whole', (tester) async {
      final labels = LabelService(db);
      final uids = [
        for (final (i, name) in ['Rock', 'Live', 'Eighties', 'Ballad'].indexed)
          (await labels.create(name, 0xFF64B5F6 + i)).uid,
      ];
      const fileMs = 3900000;
      final track = await addTrack(
        durationSeconds: fileMs ~/ 1000,
        chapters: const ChapterData(
              downloaded: [
                MediaChapter(
                  id: 'a',
                  title: 'A song with quite a long name, by somebody else',
                  startMs: 0,
                  endMs: 3753456,
                  origin: ChapterOrigin.auto,
                  manuallyEdited: true,
                ),
                MediaChapter(
                  id: 'b',
                  title: 'Outro',
                  startMs: 3753456,
                  endMs: fileMs,
                ),
              ],
              durationMs: fileMs,
            )
            .withChapterSkip('a', true)
            .withChapterLabels('a', uids)
            .withChapterLabels('b', uids.take(1)),
      );
      await pumpPage(tester, track);
      usePhoneScreen(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      for (final id in ['a', 'b']) {
        expect(find.byKey(ValueKey('chapter-labels-$id')), findsOneWidget);
        expectNotCut(tester, find.byKey(ValueKey('chapter-times-$id')));
        expectNotCut(tester, find.byKey(ValueKey('chapter-length-$id')));
      }
      // The long title wraps to its two lines as it did without labels.
      expectNotCut(tester, find.byKey(const ValueKey('chapter-title-a')));
      await unmount(tester);
    });

    testWidgets('Share link reads its time like the header above it', (
      tester,
    ) async {
      // An hour-long file: the header shows hours, so the link's time does
      // too.
      const fileMs = 3900000;
      final track = await addTrack(
        durationSeconds: fileMs ~/ 1000,
        chapters: const ChapterData(
          downloaded: [
            MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 300000),
            MediaChapter(
              id: 'b',
              title: 'Song',
              startMs: 300000,
              endMs: fileMs,
            ),
          ],
          durationMs: fileMs,
        ),
        videoId: 'a-B_c9',
      );
      await pumpPage(tester, track);
      usePhoneScreen(tester);
      await tester.pumpAndSettle();

      await openChapterOptions(tester, 'b');
      expect(find.text('0:05:00 – 1:05:00 · 1:00:00'), findsOneWidget);
      final share = find.byKey(const ValueKey('chapter-actions-share'));
      expect(
        find.descendant(
          of: share,
          matching: find.text('Opens YouTube at 0:05:00'),
        ),
        findsOneWidget,
      );
      expectNotCut(tester, share);
      await unmount(tester);
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('no chapter line ends with a "·" or "–" at text size '
          '$scale', (tester) async {
        // An hour-long mix: times with hours and milliseconds, marks and
        // origins, so the grey lines wrap.
        const fileMs = 3900000;
        final track = await addTrack(
          durationSeconds: fileMs ~/ 1000,
          chapters: const ChapterData(
            downloaded: [
              MediaChapter(
                id: 'a',
                title: 'Intro',
                startMs: 0,
                endMs: 3753456,
                origin: ChapterOrigin.auto,
                manuallyEdited: true,
              ),
              MediaChapter(
                id: 'b',
                title: 'A song with quite a long name, by somebody',
                startMs: 3753456,
                endMs: 3812345,
                origin: ChapterOrigin.auto,
              ),
              MediaChapter(
                id: 'c',
                title: 'Outro',
                startMs: 3812345,
                endMs: fileMs,
              ),
            ],
            durationMs: fileMs,
          ).withChapterSkip('a', true).withChapterSkip('b', true),
        );
        await pumpPage(tester, track);
        usePhoneScreen(tester);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectNoDanglingSeparator(
          find.byKey(const ValueKey('chapters-summary')),
        );

        for (final id in ['a', 'b', 'c']) {
          final times = find.byKey(ValueKey('chapter-times-$id'));
          await tester.scrollUntilVisible(times, 200);
          expectNoDanglingSeparator(times);
          expectNotCut(tester, times);
        }
        // At 411 dp the skipped, edited chapter needs more than one line.
        expect(
          renderedLines(find.byKey(const ValueKey('chapter-times-a'))).single,
          hasLength(greaterThan(1)),
        );
        await unmount(tester);
      });
    }
  });
}

class _Chapters extends ChapterService {
  _Chapters(AppDatabase db) : super(db, YtDlpService());

  @override
  Future<void> persist(int playlistId) async {}
}

class _Player implements PlaybackService {
  final _current = StreamController<Track?>.broadcast();
  final _items = StreamController<PlaybackItem?>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  Track? current;
  PlaybackItem? _item;
  bool _isPlaying = false;
  Duration _position = Duration.zero;

  PlaybackItem? get item => _item;
  set item(PlaybackItem? value) {
    _item = value;
    _items.add(value);
  }

  bool get playing => _isPlaying;
  set playing(bool value) {
    _isPlaying = value;
    _playing.add(value);
  }

  /// The position on the current item's own timeline.
  set position(Duration value) {
    _position = value;
    _positions.add(value);
  }

  int pauses = 0;
  int resumes = 0;
  final seeks = <Duration>[];
  final chapterJumps = <(int, String)>[];
  Duration sourcePositionValue = Duration.zero;
  final chaptersChanged = <int>[];
  final playedTracks = <(int, String?, int)>[];

  /// (track id, chapter id, first) per Play next / Add to queue.
  final queued = <(int, String?, bool)>[];
  int idleStarts = 0;

  Future<void> close() async {
    await _current.close();
    await _items.close();
    await _positions.close();
    await _playing.close();
  }

  @override
  Stream<Track?> get currentTrackStream => _current.stream;
  @override
  Stream<PlaybackItem?> get currentItemStream async* {
    yield _item;
    yield* _items.stream;
  }

  @override
  Stream<Duration> get positionStream async* {
    yield _position;
    yield* _positions.stream;
  }

  @override
  Stream<Duration> get durationStream => const Stream.empty();
  @override
  Stream<bool> get isPlayingStream => _playing.stream;
  @override
  Track? get currentTrack => current;
  @override
  Duration get sourcePosition => sourcePositionValue;
  @override
  Duration get sourceDuration =>
      current == null ? Duration.zero : const Duration(minutes: 3);
  @override
  bool get isPlaying => _isPlaying;
  @override
  PlaybackItem? get currentItem => item;
  @override
  Duration get position => _position;

  @override
  Future<bool> playChapterOfCurrentFile(int trackId, String chapterId) async {
    chapterJumps.add((trackId, chapterId));
    return true;
  }

  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);

  @override
  Future<void> resume() async {
    resumes++;
    playing = true;
  }

  @override
  Future<bool> playNext(Track track, {String? chapterId}) =>
      addToUpNextQueue(track, chapterId: chapterId, first: true);

  @override
  Future<bool> addToUpNextQueue(
    Track track, {
    String? chapterId,
    bool first = false,
  }) async {
    queued.add((track.id, chapterId, first));
    return true;
  }

  @override
  Future<bool> startUpNextQueueIfIdle() async {
    idleStarts++;
    return false;
  }

  @override
  Future<void> trackChaptersChanged(Track track) async {
    chaptersChanged.add(track.id);
  }

  @override
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
    String? chapterId,
    bool whole = false,
    Duration? startAt,
  }) async {
    playedTracks.add((track.id, chapterId, allTracks.length));
  }

  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
