import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/chapters_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/chapter_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late _Player player;

  setUp(() {
    db = openTestDatabase();
    player = _Player();
  });

  tearDown(() async {
    await player.close();
    await db.close();
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
      filePath: '/music/mix',
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

  testWidgets('marking keeps the queue and starts the next chapter where the '
      'last one ended', (tester) async {
    final track = await addTrack();
    await pumpPage(tester, track);

    await tester.tap(find.byKey(const ValueKey('chapters-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark while listening'));
    await tester.pumpAndSettle();

    expect(player.editing, track.id);
    expect(player.editingQueue!.map((t) => t.title), ['Other', 'Long mix']);
    expect(player.playedTracks, isEmpty);

    player.sourcePositionValue = const Duration(seconds: 10);
    await tester.tap(find.byKey(const ValueKey('chapters-mark')));
    await tester.pumpAndSettle();
    expect(find.textContaining('starts at 0:10'), findsOneWidget);

    player.sourcePositionValue = const Duration(seconds: 70);
    await tester.tap(find.text('End chapter here'));
    await tester.pumpAndSettle();
    expect(find.text('Add chapter'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('chapter-title')), 'One');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = await storedChapters(track.id);
    expect(saved.active.single.title, 'One');
    expect(saved.active.single.startMs, 10000);
    expect(saved.active.single.endMs, 70000);
    expect(player.chaptersChanged, [track.id]);
    // The next chapter is already started at the end of this one.
    expect(find.textContaining('starts at 1:10'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chapters-marking-done')));
    await tester.pumpAndSettle();
    expect(player.editing, isNull);
    await unmount(tester);
  });

  testWidgets('cancelling "End chapter here" keeps the start mark and goes '
      'on playing', (tester) async {
    final track = await addTrack();
    await pumpPage(tester, track);
    await tester.tap(find.byKey(const ValueKey('chapters-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark while listening'));
    await tester.pumpAndSettle();

    player.sourcePositionValue = const Duration(seconds: 10);
    await tester.tap(find.byKey(const ValueKey('chapters-mark')));
    await tester.pumpAndSettle();
    player
      ..playing = true
      ..sourcePositionValue = const Duration(seconds: 70);
    await tester.tap(find.text('End chapter here'));
    await tester.pumpAndSettle();
    expect(player.pauses, 1);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.textContaining('starts at 0:10'), findsOneWidget);
    expect(find.text('End chapter here'), findsOneWidget);
    expect(player.resumes, 1);
    expect((await storedChapters(track.id)).active, isEmpty);
    await unmount(tester);
  });

  testWidgets('the marking panel fits a narrow phone', (tester) async {
    final track = await addTrack();
    await pumpPage(tester, track);
    await tester.tap(find.byKey(const ValueKey('chapters-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark while listening'));
    await tester.pumpAndSettle();
    player.sourcePositionValue = const Duration(minutes: 1, seconds: 10);
    await tester.tap(find.byKey(const ValueKey('chapters-mark')));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(320, 2000);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('End chapter here'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    // The times keep a readable width instead of being squeezed between
    // the buttons.
    expect(
      tester.getSize(find.textContaining('starts at 1:10')).width,
      greaterThan(200),
    );
    await unmount(tester);
  });

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

  testWidgets('adding a chapter to a file of unknown length explains why it '
      'cannot, before any typing', (tester) async {
    final track = await addTrack(
      isLocalReplacement: true,
      durationSeconds: null,
    );
    await pumpPage(tester, track);

    await tester.tap(find.byKey(const ValueKey('chapters-add')));
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditDialog), findsNothing);
    expect(
      find.textContaining('length of this file is not known'),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('a new chapter is prefilled after the last one', (tester) async {
    final track = await addTrack(
      chapters: youTubeChapters.withCustom([
        const MediaChapter(id: 'c', title: 'First', startMs: 0, endMs: 50000),
      ]),
    );
    await pumpPage(tester, track);

    await tester.tap(find.byKey(const ValueKey('chapters-add')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('chapter-start')))
          .controller!
          .text,
      '0:50',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('chapter-end')))
          .controller!
          .text,
      '3:00',
    );
    await tester.tap(find.text('Cancel'));
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
  int? editing;
  List<Track>? editingQueue;
  Duration sourcePositionValue = Duration.zero;
  final chaptersChanged = <int>[];
  final playedTracks = <(int, String?, int)>[];

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
  Future<void> beginChapterEditing(
    Track track, [
    List<Track>? playlistTracks,
  ]) async {
    editing = track.id;
    editingQueue = playlistTracks;
    current = track;
    _current.add(track);
  }

  @override
  void endChapterEditing() => editing = null;

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
