import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/chapter_editor_page.dart';
import 'package:woolytube/pages/chapters_page.dart';
import 'package:woolytube/providers/chapter_editor_providers.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/chapter_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';

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

    expect(find.byType(ChapterEditorPage), findsNothing);
    expect(
      find.text('Chapters saved. Undo last chapter change takes it back.'),
      findsOneWidget,
    );
    final saved = await storedChapters(track.id);
    expect(saved.active.map((c) => (c.id, c.startMs, c.endMs)), [
      ('a', 0, 61000),
      ('b', 61000, 180000),
    ]);
    expect(saved.active.every((c) => c.manuallyEdited), isTrue);
    expect(player.chaptersChanged, [track.id]);
    expect(previews.last.disposed, isTrue);

    await tester.tap(find.byKey(const ValueKey('chapters-undo')));
    await tester.pumpAndSettle();
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
        matching: find.textContaining('Always skip'),
      ),
      findsOneWidget,
    );

    await openChapterOptions(tester, 'b');
    await tester.tap(find.byKey(const ValueKey('chapter-actions-always-skip')));
    await tester.pumpAndSettle();
    expect((await storedChapters(track.id)).isSkipped('b'), isFalse);
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
}

class _Chapters extends ChapterService {
  _Chapters(AppDatabase db) : super(db, YtDlpService());

  @override
  Future<void> persist(int playlistId) async {}
}

class _Player implements PlaybackService {
  final _current = StreamController<Track?>.broadcast();
  Track? current;
  PlaybackItem? item;
  bool playing = false;
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

  Future<void> close() => _current.close();

  @override
  Stream<Track?> get currentTrackStream => _current.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration> get durationStream => const Stream.empty();
  @override
  Stream<bool> get isPlayingStream => const Stream.empty();
  @override
  Track? get currentTrack => current;
  @override
  Duration get sourcePosition => sourcePositionValue;
  @override
  Duration get sourceDuration =>
      current == null ? Duration.zero : const Duration(minutes: 3);
  @override
  bool get isPlaying => playing;
  @override
  PlaybackItem? get currentItem => item;

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
