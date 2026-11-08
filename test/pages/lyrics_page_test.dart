import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/lyrics_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/download_network_policy.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/playback_service.dart';

import '../helpers/test_database.dart';
import 'lyrics_fakes.dart';

void main() {
  late AppDatabase db;
  late FakeLyricsService lyrics;
  late _Player player;

  setUp(() {
    db = openTestDatabase();
    lyrics = FakeLyricsService(db);
    player = _Player();
  });

  tearDown(() async {
    await db.close();
  });

  const mix = ChapterData(
    downloaded: [
      MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 60000),
      MediaChapter(
        id: 'b',
        title: 'Hey Brother',
        startMs: 60000,
        endMs: 240000,
      ),
    ],
    durationMs: 240000,
  );

  Future<Track> addTrack({
    String? lyricsMode = 'lyrics',
    ChapterData? chapters,
  }) async {
    final playlist = await insertTestPlaylist(db, lyricsMode: lyricsMode);
    return insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      title: 'Avicii - Hey Brother',
      status: 'complete',
      filePath: '/music/hey.m4a',
      durationSeconds: 240,
      chaptersJson: chapters?.encode(),
    );
  }

  LyricsDocDraft found(
    int trackId, {
    String? chapterId,
    int offsetMs = 0,
    bool pinned = false,
    LyricsMode kind = LyricsMode.lyrics,
  }) => LyricsDocDraft(
    trackId: trackId,
    chapterId: chapterId,
    offsetMs: offsetMs,
    kind: kind,
    status: LyricsStatus.found,
    source: LyricsSource.lrclib,
    sourceRef: '42',
    matchedArtist: 'Avicii',
    matchedTitle: 'Hey Brother',
    synced: true,
    pinned: pinned,
    checkedAt: DateTime(2026, 11, 8),
    lines: const [
      LyricsLineDraft('Hey brother', startMs: 5000),
      LyricsLineDraft('There\'s an endless road to rediscover', startMs: 9500),
    ],
  );

  Future<void> pumpPage(
    WidgetTester tester,
    Track track, {
    String? chapterId,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          lyricsServiceProvider.overrideWithValue(lyrics),
          playbackServiceProvider.overrideWithValue(player),
          downloadNetworkPolicyProvider.overrideWithValue(
            DownloadNetworkPolicy(
              AppSettingsService(),
              checkConnectivity: () async => [ConnectivityResult.wifi],
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: LyricsPage(track: track, chapterId: chapterId),
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

  testWidgets('nothing fetched yet: Fetch now fetches and shows the lines', (
    tester,
  ) async {
    final track = await addTrack();
    lyrics.fetched = (t) => found(t.id);
    await pumpPage(tester, track);

    expect(find.text('Not fetched yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-refetch')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lyrics-fetch-now')));
    await tester.pumpAndSettle();

    expect(lyrics.calls, ['fetch ${track.id}']);
    expect(find.text('Avicii – Hey Brother'), findsOneWidget);
    expect(find.textContaining('LRCLIB'), findsOneWidget);
    expect(find.textContaining('Found automatically'), findsOneWidget);
    expect(find.text('Hey brother'), findsOneWidget);
    expect(find.text('0:05'), findsOneWidget);
    expect(find.text('Wrong song?'), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-fetch-now')), findsNothing);
    await unmount(tester);
  });

  testWidgets('tapping a timed line plays the file from there', (tester) async {
    final track = await addTrack();
    await db.replaceLyricsDoc(found(track.id, pinned: true));
    await pumpPage(tester, track);
    expect(find.textContaining('Chosen by you'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-line-1')));
    await tester.pumpAndSettle();
    expect(player.played, [(track.id, null, true)]);
    expect(player.seeks, [const Duration(milliseconds: 9500)]);

    // Now this file plays: only a seek.
    await tester.tap(find.byKey(const ValueKey('lyrics-line-0')));
    await tester.pumpAndSettle();
    expect(player.played, hasLength(1));
    expect(player.seeks.last, const Duration(milliseconds: 5000));
    await unmount(tester);
  });

  testWidgets('a mix shows one chapter at a time; its lines play inside the '
      'chapter', (tester) async {
    final track = await addTrack(chapters: mix);
    await db.replaceLyricsDoc(found(track.id, chapterId: 'b', offsetMs: 60000));
    await pumpPage(tester, track, chapterId: 'b');

    expect(find.text('2. Hey Brother'), findsOneWidget);
    expect(find.text('Hey brother'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lyrics-line-0')));
    await tester.pumpAndSettle();
    expect(player.played, [(track.id, 'b', false)]);
    // Chapter time: the chapter starts at 1:00, the line 5 s into it.
    expect(player.seeks, [const Duration(milliseconds: 5000)]);

    await tester.tap(find.byKey(const ValueKey('lyrics-chapter-selector')));
    await tester.pumpAndSettle();
    expect(find.text('0:00 · Not fetched yet'), findsOneWidget);
    expect(find.text('1:00 · Synced lyrics'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lyrics-unit-a')));
    await tester.pumpAndSettle();
    expect(find.text('1. Intro'), findsOneWidget);
    expect(find.text('Not fetched yet'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-mark-none')));
    await tester.pumpAndSettle();
    expect(lyrics.calls, ['none ${track.id} a']);
    expect(find.text('No lyrics here'), findsWidgets);
    expect(find.byKey(const ValueKey('lyrics-mark-none')), findsNothing);
    await unmount(tester);
  });

  testWidgets('Refetch automatically asks the service again', (tester) async {
    final track = await addTrack();
    await db.replaceLyricsDoc(found(track.id, pinned: true));
    await pumpPage(tester, track);

    await tester.tap(find.byKey(const ValueKey('lyrics-refetch')));
    await tester.pumpAndSettle();
    expect(lyrics.calls, ['refetch ${track.id} null']);
    await unmount(tester);
  });

  testWidgets('Wrong song? searches with the parsed title and stores the '
      'chosen record', (tester) async {
    final track = await addTrack();
    await db.replaceLyricsDoc(found(track.id));
    lyrics.candidates = const [
      LyricsCandidate(
        id: 7,
        artist: 'Avicii',
        title: 'Hey Brother',
        album: 'True',
        durationSeconds: 255,
        synced: true,
        instrumental: false,
        plainPreview: 'Hey brother\nThere\'s an endless road',
      ),
      LyricsCandidate(
        id: 8,
        artist: 'Avicii',
        title: 'Hey Brother (Instrumental)',
        synced: false,
        instrumental: true,
        plainPreview: '',
      ),
    ];
    await pumpPage(tester, track);

    await tester.tap(find.byKey(const ValueKey('lyrics-wrong-song')));
    await tester.pumpAndSettle();
    expect(lyrics.queries, ['Avicii Hey Brother']);
    expect(find.text('Avicii – Hey Brother'), findsWidgets);
    expect(find.text('Synced'), findsOneWidget);
    expect(find.text('Instrumental'), findsOneWidget);
    expect(find.text('True · 4:15'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-candidate-7-preview')));
    await tester.pumpAndSettle();
    expect(find.textContaining('endless road'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('lyrics-candidate-7-choose')));
    await tester.pumpAndSettle();
    expect(lyrics.calls, ['pick ${track.id} null lrclib 7']);
    expect(find.byKey(const ValueKey('lyrics-picker-query')), findsNothing);
    expect(find.text('Lyrics saved'), findsOneWidget);
    expect(find.text('Picked line'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a failed pick keeps the picker open and says why', (
    tester,
  ) async {
    final track = await addTrack();
    lyrics.candidates = const [
      LyricsCandidate(
        id: 7,
        artist: 'Avicii',
        title: 'Hey Brother',
        synced: true,
        instrumental: false,
        plainPreview: 'Hey brother',
      ),
    ];
    lyrics.applyError = StateError('LRCLIB is not answering.');
    await pumpPage(tester, track);

    await tester.tap(find.byKey(const ValueKey('lyrics-wrong-song')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lyrics-candidate-7')));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not use it: LRCLIB is not answering.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('lyrics-picker-query')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a lyric video link is used for its captions', (tester) async {
    final track = await addTrack();
    await pumpPage(tester, track);

    await tester.tap(find.byKey(const ValueKey('lyrics-wrong-song')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lyrics-picker-tab-youtube')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('lyrics-picker-link')),
      'https://www.youtube.com/playlist?list=PL123',
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-picker-link-use')));
    await tester.pumpAndSettle();
    expect(
      find.text('Paste a link to one YouTube video, not a playlist'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('lyrics-picker-link')),
      'https://youtu.be/6Cp6mKbRTQY?si=abc',
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-picker-link-use')));
    await tester.pumpAndSettle();
    expect(lyrics.calls, ['pick ${track.id} null yt_subs 6Cp6mKbRTQY']);
    await unmount(tester);
  });

  testWidgets('transcript mode offers only captions from YouTube', (
    tester,
  ) async {
    final track = await addTrack(lyricsMode: 'transcript', chapters: mix);
    await db.replaceLyricsDoc(found(track.id, kind: LyricsMode.transcript));
    await pumpPage(tester, track, chapterId: 'b');

    expect(find.text('Transcript'), findsWidgets);
    // A transcript covers the whole file, so there is nothing to choose.
    expect(find.byKey(const ValueKey('lyrics-chapter-selector')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lyrics-wrong-song')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-picker-tabs')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-picker-query')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-picker-link')), findsOneWidget);
    expect(lyrics.queries, isEmpty);

    await unmount(tester);
  });

  testWidgets('a whole-file transcript line plays in the chapter it falls in', (
    tester,
  ) async {
    final track = await addTrack(lyricsMode: 'transcript', chapters: mix);
    await db.replaceLyricsDoc(
      LyricsDocDraft(
        trackId: track.id,
        kind: LyricsMode.transcript,
        status: LyricsStatus.found,
        source: LyricsSource.ytAuto,
        sourceRef: 'en-orig',
        synced: true,
        lang: 'en',
        checkedAt: DateTime(2026, 11, 8),
        lines: const [LyricsLineDraft('So today we talk', startMs: 65000)],
      ),
    );
    await pumpPage(tester, track);
    expect(
      find.textContaining('YouTube automatic captions · en'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('lyrics-line-0')));
    await tester.pumpAndSettle();
    expect(player.played, [(track.id, 'b', false)]);
    expect(player.seeks, [const Duration(milliseconds: 5000)]);
    await unmount(tester);
  });

  testWidgets('with lyrics off the page says where to turn them on', (
    tester,
  ) async {
    final track = await addTrack(lyricsMode: null);
    await pumpPage(tester, track);

    expect(find.byKey(const ValueKey('lyrics-off-notice')), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-fetch-now')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-wrong-song')), findsNothing);
    await unmount(tester);
  });

  test('menu labels follow the playlist mode', () {
    expect(lyricsMenuTitle(null), 'Lyrics…');
    expect(lyricsMenuTitle('transcript'), 'Transcript…');
    expect(lyricsMenuSubtitle(null), contains('playlist settings'));
    expect(lyricsTimestamp(65000), '1:05');
    expect(lyricsTimestamp(3725000), '1:02:05');
  });
}

/// Records plays and seeks. playTrack is answered in [noSuchMethod] so a
/// new optional parameter does not break this fake.
class _Player implements PlaybackService {
  PlaybackItem? item;
  bool playing = false;
  final played = <(int, String?, bool)>[];
  final seeks = <Duration>[];

  @override
  PlaybackItem? get currentItem => item;
  @override
  bool get isPlaying => playing;

  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);

  @override
  Future<void> resume() async => playing = true;

  @override
  Future<bool> playChapterOfCurrentFile(int trackId, String chapterId) async {
    final current = item;
    if (current == null) return false;
    final chapter =
        ChapterData.decode(
          current.track.chaptersJson,
        ).active.where((c) => c.id == chapterId).firstOrNull;
    if (chapter == null) return false;
    item = PlaybackItem(current.track, chapter);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #playTrack) {
      final track = invocation.positionalArguments.first as Track;
      final chapterId = invocation.namedArguments[#chapterId] as String?;
      final whole = invocation.namedArguments[#whole] as bool? ?? false;
      played.add((track.id, chapterId, whole));
      final chapter =
          chapterId == null
              ? null
              : ChapterData.decode(
                track.chaptersJson,
              ).active.firstWhere((c) => c.id == chapterId);
      item = PlaybackItem(track, chapter);
      playing = true;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}
