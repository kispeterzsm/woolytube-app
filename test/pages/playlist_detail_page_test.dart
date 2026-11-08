import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/playlist_detail_page.dart';
import 'package:woolytube/pages/playlist_settings_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_search.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playlist_service.dart';

import '../helpers/player_shell_harness.dart';
import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Playlist playlist;
  late _Downloads downloads;
  late _Playback playback;
  late _LyricsSearch lyrics;
  late _Playlists playlists;
  late _Metadata metadata;
  late BehaviorSubject<Track?> currentTrack;
  late BehaviorSubject<bool> isPlaying;
  late BehaviorSubject<Set<int>> syncing;
  late BehaviorSubject<List<int>> queued;
  late BehaviorSubject<List<Track>> upNext;

  setUp(() async {
    resetPlaylistOpenChecks();
    db = openTestDatabase();
    playlist = await insertTestPlaylist(db, name: 'Loaded name');
    downloads = _Downloads();
    playback = _Playback();
    lyrics = _LyricsSearch();
    playlists = _Playlists();
    metadata = _Metadata();
    currentTrack = BehaviorSubject<Track?>.seeded(null);
    isPlaying = BehaviorSubject<bool>.seeded(false);
    syncing = BehaviorSubject<Set<int>>.seeded(const {});
    queued = BehaviorSubject<List<int>>.seeded(const []);
    upNext = BehaviorSubject<List<Track>>.seeded(const []);
  });

  tearDown(() async {
    audioPlayerOverlayHeightNotifier.value = 0;
    await currentTrack.close();
    await isPlaying.close();
    await syncing.close();
    await queued.close();
    await upNext.close();
    await db.close();
  });

  /// Everything the page needs besides playback.
  List<Override> serviceOverrides({
    DownloadProgress progress = DownloadProgress.idle,
    Stream<DownloadProgress>? progressStream,
  }) => [
    databaseProvider.overrideWithValue(db),
    libraryGateProvider.overrideWithValue(LibraryGate.unlocked()),
    metadataServiceProvider.overrideWithValue(metadata),
    playlistServiceProvider.overrideWithValue(playlists),
    downloadServiceProvider.overrideWithValue(downloads),
    upNextQueueProvider.overrideWith((ref) => upNext.stream),
    downloadProgressProvider.overrideWith(
      (ref) => progressStream ?? Stream.value(progress),
    ),
    syncingPlaylistsProvider.overrideWith((ref) => syncing.stream),
    downloadQueueProvider.overrideWith((ref) => queued.stream),
    lyricsSearchProvider.overrideWithValue(lyrics),
  ];

  List<Override> overrides(
    List<Track> tracks, {
    Stream<List<Track>>? tracksStream,
    DownloadProgress progress = DownloadProgress.idle,
    Stream<DownloadProgress>? progressStream,
    bool livePlaylist = false,
  }) => [
    ...serviceOverrides(progress: progress, progressStream: progressStream),
    tracksProvider(
      playlist.id,
    ).overrideWith((ref) => tracksStream ?? Stream.value(tracks)),
    if (livePlaylist)
      playlistsProvider.overrideWith((ref) => Stream.value([playlist])),
    playbackServiceProvider.overrideWithValue(playback),
    currentTrackProvider.overrideWith((ref) => currentTrack.stream),
    isPlayingProvider.overrideWith((ref) => isPlaying.stream),
    shuffleEnabledProvider.overrideWith((ref) => Stream.value(false)),
    autoplayEnabledProvider.overrideWith((ref) => Stream.value(true)),
    audioOnlyModeProvider.overrideWith((ref) => Stream.value(false)),
  ];

  Future<void> pumpPage(
    WidgetTester tester, {
    required List<Track> tracks,
    Stream<List<Track>>? tracksStream,
    DownloadProgress progress = DownloadProgress.idle,
    Stream<DownloadProgress>? progressStream,
    String? initialName,
    bool settle = true,
    List<Override> extra = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides(
            tracks,
            tracksStream: tracksStream,
            progress: progress,
            progressStream: progressStream,
          ),
          ...extra,
        ],
        child: MaterialApp(
          home: PlaylistDetailPage(
            playlistId: playlist.id,
            initialName: initialName,
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  /// Pumps the page with the tracks and the playing track already loaded,
  /// the way they are when a playlist is reopened (both providers are kept
  /// alive), and renders exactly one frame.
  Future<ProviderContainer> pumpWarmPage(
    WidgetTester tester,
    List<Track> tracks,
  ) async {
    final container = ProviderContainer(overrides: overrides(tracks));
    addTearDown(container.dispose);
    container.listen(tracksProvider(playlist.id), (_, __) {});
    container.listen(currentTrackProvider, (_, __) {});
    container.listen(isPlayingProvider, (_, __) {});
    await container.read(tracksProvider(playlist.id).future);
    await container.read(currentTrackProvider.future);
    await container.read(isPlayingProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: PlaylistDetailPage(playlistId: playlist.id)),
      ),
    );
    return container;
  }

  Future<List<Track>> longPlaylist(int count) async {
    final base = await insertTestTrack(
      db,
      playlistId: playlist.id,
      status: 'complete',
      filePath: '/tmp/base.m4a',
    );
    return [
      for (var i = 0; i < count; i++)
        base.copyWith(
          id: 1000 + i,
          index: i + 1,
          videoId: 'video-$i',
          title: 'Song ${i + 1}',
          durationSeconds: const Value(200),
        ),
    ];
  }

  ScrollPosition listPosition(WidgetTester tester) {
    return tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('playlist-track-list')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
  }

  /// Whether [track]'s row is fully inside the part of the list that the
  /// expanded player panel does not cover.
  bool rowOnScreen(WidgetTester tester, Track track) {
    final row = find.byKey(ValueKey('track-row-${track.id}'));
    if (row.evaluate().isEmpty) return false;
    final rect = tester.getRect(row);
    final list = tester.getRect(
      find.byKey(const ValueKey('playlist-track-list')),
    );
    final bottom = list.bottom - audioPlayerOverlayHeightNotifier.value;
    return rect.top >= list.top - 0.5 && rect.bottom <= bottom + 0.5;
  }

  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('shows the passed name until the playlist row loads', (
    tester,
  ) async {
    await pumpPage(
      tester,
      tracks: const [],
      initialName: 'Initial name',
      settle: false,
    );
    expect(find.text('Initial name'), findsOneWidget);
    expect(find.text('Playlist'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Loaded name'), findsOneWidget);
    expect(find.text('Initial name'), findsNothing);
  });

  testWidgets('empty playlist keeps search available and explains itself', (
    tester,
  ) async {
    await pumpPage(tester, tracks: const []);
    expect(
      find.text('No tracks yet. Tap Update to fetch them.'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Search tracks'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('Close search'), findsOneWidget);
  });

  testWidgets('search with no hits shows an empty state', (tester) async {
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Only song',
      status: 'complete',
      filePath: '/tmp/only.m4a',
    );
    await pumpPage(tester, tracks: [track]);
    await tester.tap(find.byTooltip('Search tracks'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'nothing like this');
    await tester.pumpAndSettle();
    expect(find.text('No matching tracks'), findsOneWidget);
    expect(find.text('Only song'), findsNothing);
  });

  testWidgets('search: clear button, chapter matches and back closes it', (
    tester,
  ) async {
    final album = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Full album',
      status: 'complete',
      filePath: '/tmp/album.m4a',
      chaptersJson:
          const ChapterData(
            downloaded: [
              MediaChapter(id: 'a', title: 'Opening', startMs: 0, endMs: 1),
              MediaChapter(
                id: 'b',
                title: 'Hidden Melody',
                startMs: 80000,
                endMs: 90000,
              ),
            ],
          ).encode(),
    );
    final other = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'other',
      title: 'Another file',
      status: 'complete',
      filePath: '/tmp/other.m4a',
    );
    await pumpPage(tester, tracks: [album, other]);

    await tester.tap(find.byTooltip('Search tracks'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'melody');
    await tester.pumpAndSettle();
    expect(find.text('Another file'), findsNothing);
    expect(
      find.textContaining('Chapter: Hidden Melody · 1:20'),
      findsOneWidget,
    );
    expect(find.text('Play results'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('playlist-search-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Another file'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget, reason: 'still searching');

    // System back closes the search instead of leaving the page.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('search adds lyric matches with a one-line subtitle', (
    tester,
  ) async {
    playlist = await insertTestPlaylist(
      db,
      url: 'lyrics',
      name: 'Songs',
      lyricsMode: 'lyrics',
    );
    final title = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Endless road trip',
      status: 'complete',
      filePath: '/tmp/title.m4a',
      durationSeconds: 200,
    );
    final song = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'song',
      title: 'Avicii - Hey Brother',
      status: 'complete',
      filePath: '/tmp/song.m4a',
      durationSeconds: 255,
    );
    final other = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 3,
      videoId: 'other',
      title: 'Something else',
      status: 'complete',
      filePath: '/tmp/other.m4a',
    );
    lyrics.hits = [
      LyricsHit(
        trackId: song.id,
        docId: 5,
        lineId: 50,
        lineNo: 3,
        lineText:
            "Oh brother, there's an endless road to rediscover, "
            'far away from home and every single thing we know',
        highlightRanges: const [
          LyricsHighlight(23, 30),
          LyricsHighlight(31, 35),
        ],
        positionMs: 83000,
        score: 0.9,
        kind: LyricsMode.lyrics,
      ),
    ];
    await pumpPage(tester, tracks: [title, song, other]);
    final rowHeight =
        tester.getSize(find.byKey(ValueKey('track-row-${title.id}'))).height;

    await tester.tap(find.byTooltip('Search tracks'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Endless road');
    await tester.pump();
    // Title matches show at once; lyrics once typing pauses.
    expect(find.text('Endless road trip'), findsOneWidget);
    expect(find.text('Avicii - Hey Brother'), findsNothing);
    expect(lyrics.queries, isEmpty);

    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(lyrics.queries, [('endless road', playlist.id)]);
    expect(find.text('Avicii - Hey Brother'), findsOneWidget);
    expect(find.text('Something else'), findsNothing);
    final subtitle = find.byKey(ValueKey('track-lyric-${song.id}'));
    expect(subtitle, findsOneWidget);
    expect(
      find.descendant(of: subtitle, matching: find.text('” · 1:23')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: subtitle,
        matching: find.textContaining('endless road', findRichText: true),
      ),
      findsOneWidget,
    );
    // Still one subtitle line: the row keeps the fixed height.
    expect(
      tester.getSize(find.byKey(ValueKey('track-row-${song.id}'))).height,
      rowHeight,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Avicii - Hey Brother'));
    await tester.pump();
    expect(playback.playTrackIds, [song.id]);
    expect(playback.startAts, [const Duration(milliseconds: 81000)]);

    // Closing the search forgets the lyric matches.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('track-lyric-${song.id}')), findsNothing);
  });

  testWidgets('a playlist with lyrics off never searches lyrics', (
    tester,
  ) async {
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Only song',
      status: 'complete',
      filePath: '/tmp/only.m4a',
    );
    await pumpPage(tester, tracks: [track]);
    await tester.tap(find.byTooltip('Search tracks'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'endless road');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(lyrics.queries, isEmpty);
    expect(find.text('No matching tracks'), findsOneWidget);
  });

  testWidgets('every row has the same height whatever its content', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final tracks = [
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'a',
        title: 'Short',
        status: 'complete',
        filePath: '/tmp/a.m4a',
        durationSeconds: 61,
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
        title: 'A very long title ' * 8,
        status: 'complete',
        filePath: '/tmp/b.m4a',
        alwaysSkip: true,
        durationSeconds: 4000,
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'c',
        title: 'Failed ' * 10,
        status: 'error',
        lastError: 'ERROR: something went badly wrong ' * 5,
        alwaysSkip: true,
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 4,
        videoId: 'd',
        title: 'Downloading',
        status: 'downloading',
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1742,
        videoId: 'e',
        title: 'Gone',
        status: 'unavailable',
        unavailableReason: 'private',
      ),
    ];
    await pumpPage(tester, tracks: tracks, settle: false);
    await tester.pump();
    await tester.pump();

    final heights = {
      for (final track in tracks)
        tester.getSize(find.byKey(ValueKey('track-row-${track.id}'))).height,
    };
    expect(heights, hasLength(1));
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('playlist-track-list')),
    );
    expect(list.itemExtent, heights.single);
    // The 4-digit number is not cut off.
    expect(find.text('1742'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening a long playlist starts at the playing track', (
    tester,
  ) async {
    final tracks = await longPlaylist(664);
    final playing = tracks[659];
    currentTrack.add(playing);

    await pumpWarmPage(tester, tracks);

    // The very first frame already shows the playing row; the top of the
    // list was never built.
    expect(rowOnScreen(tester, playing), isTrue);
    expect(find.byKey(ValueKey('track-row-${tracks.first.id}')), findsNothing);
    final offset = listPosition(tester).pixels;
    expect(offset, greaterThan(0));

    // Nothing animates or jumps afterwards.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();
    expect(listPosition(tester).pixels, offset);
    expect(
      find.byKey(const ValueKey('playlist-jump-to-playing')),
      findsNothing,
    );
  });

  testWidgets('a playing track that loads later is jumped to, not animated', (
    tester,
  ) async {
    final tracks = await longPlaylist(400);
    final late = BehaviorSubject<Track?>();
    addTearDown(late.close);
    currentTrack = late;
    await pumpPage(tester, tracks: tracks);
    expect(listPosition(tester).pixels, 0);

    late.add(tracks[300]);
    await tester.pump();
    await tester.pump();
    expect(rowOnScreen(tester, tracks[300]), isTrue);
    final offset = listPosition(tester).pixels;
    await tester.pumpAndSettle();
    expect(listPosition(tester).pixels, offset, reason: 'no animation');
  });

  testWidgets('follows the next track, but not while the user browses', (
    tester,
  ) async {
    final tracks = await longPlaylist(300);
    currentTrack.add(tracks[150]);
    await pumpWarmPage(tester, tracks);
    await tester.pumpAndSettle();

    // A far track change while following: jump straight there.
    currentTrack.add(tracks[10]);
    await tester.pumpAndSettle();
    expect(rowOnScreen(tester, tracks[10]), isTrue);

    // Next track while following: stays visible.
    currentTrack.add(tracks[11]);
    await tester.pumpAndSettle();
    expect(rowOnScreen(tester, tracks[11]), isTrue);

    // The user scrolls far away; the next track change leaves the list.
    await tester.fling(
      find.byKey(const ValueKey('playlist-track-list')),
      const Offset(0, -3000),
      3000,
    );
    await tester.pumpAndSettle();
    final browsing = listPosition(tester).pixels;
    expect(rowOnScreen(tester, tracks[11]), isFalse);
    expect(
      find.byKey(const ValueKey('playlist-jump-to-playing')),
      findsOneWidget,
    );

    currentTrack.add(tracks[12]);
    await tester.pumpAndSettle();
    expect(listPosition(tester).pixels, browsing);

    await tester.tap(find.byKey(const ValueKey('playlist-jump-to-playing')));
    await tester.pumpAndSettle();
    expect(rowOnScreen(tester, tracks[12]), isTrue);
    expect(
      find.byKey(const ValueKey('playlist-jump-to-playing')),
      findsNothing,
    );
  });

  testWidgets('tapping the playing row toggles play and pause', (tester) async {
    final playingTrack = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Playing song',
      status: 'complete',
      filePath: '/tmp/a.m4a',
    );
    final otherTrack = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'other',
      title: 'Other song',
      status: 'complete',
      filePath: '/tmp/b.m4a',
    );
    currentTrack.add(playingTrack);
    isPlaying.add(true);
    await pumpPage(tester, tracks: [playingTrack, otherTrack]);

    await tester.tap(find.text('Playing song'));
    await tester.pump();
    expect(playback.toggleCalls, 1);
    expect(playback.playTrackIds, isEmpty);

    final toggle = find.byKey(ValueKey('track-toggle-${playingTrack.id}'));
    expect(tester.widget<IconButton>(toggle).tooltip, 'Pause');
    await tester.tap(toggle);
    await tester.pump();
    expect(playback.toggleCalls, 2);
    expect(playback.playTrackIds, isEmpty);

    isPlaying.add(false);
    await tester.pump();
    expect(tester.widget<IconButton>(toggle).tooltip, 'Play');

    await tester.tap(find.text('Other song'));
    await tester.pump();
    expect(playback.playTrackIds, [otherTrack.id]);
    expect(playback.toggleCalls, 2);
  });

  testWidgets('the track menu is one flat list with every action', (
    tester,
  ) async {
    useTallScreen(tester);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 7,
      title: 'Normal song',
      status: 'complete',
      filePath: '/tmp/normal.m4a',
      durationSeconds: 185,
    );
    await pumpPage(tester, tracks: [track]);

    await tester.tap(find.byKey(ValueKey('track-more-${track.id}')));
    await tester.pumpAndSettle();

    expect(find.text('#7 · 3:05 · Downloaded'), findsOneWidget);
    final expected = [
      'Play next',
      'Add to queue',
      'Always skip',
      'Chapters…',
      'Lyrics…',
      'Skip segments…',
      'File',
      'Edit title & file name',
      'Replace with a file from this phone',
      'Download a new copy',
      'YouTube',
      'Open on YouTube',
      'Share link',
      'Copy video ID',
      'Find in web archives',
    ];
    final tops = <double>[];
    for (final label in expected) {
      final finder = find.text(label);
      expect(finder, findsOneWidget, reason: label);
      tops.add(tester.getTopLeft(finder).dy);
    }
    // In that order, all on one level.
    expect(tops, orderedEquals([...tops]..sort()));
    expect(
      find.textContaining(RegExp('album|action group', caseSensitive: false)),
      findsNothing,
    );
    expect(find.byIcon(Icons.chevron_right), findsNothing);

    // Always skip is a switch that saves at once.
    await tester.tap(find.byKey(const ValueKey('track-actions-always-skip')));
    await tester.pumpAndSettle();
    expect(playback.alwaysSkipCalls, [(track.id, true)]);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('track-actions-always-skip')),
          )
          .value,
      isTrue,
    );
    expect(
      find.text('Turn off Always skip to queue this track'),
      findsOneWidget,
    );
  });

  testWidgets('a track without a file offers Download, a failed one Retry', (
    tester,
  ) async {
    useTallScreen(tester);
    final pending = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Pending song',
      status: 'pending',
    );
    final failed = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'failed',
      title: 'Failed song',
      status: 'error',
      lastError: 'ERROR: [youtube] failed: HTTP Error 403: Forbidden',
    );
    await pumpPage(tester, tracks: [pending, failed]);

    // Tapping a row without a file opens its options.
    await tester.tap(find.text('Pending song'));
    await tester.pumpAndSettle();
    expect(find.text('Download now'), findsOneWidget);
    expect(find.text('Add to queue'), findsNothing);
    expect(
      find.byKey(const ValueKey('track-actions-redownload')),
      findsNothing,
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Download now'), findsNothing);

    await tester.tap(find.byKey(ValueKey('track-more-${failed.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Retry download'), findsOneWidget);
    expect(find.text('Show error details'), findsOneWidget);
    await tester.tap(find.text('Show error details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP Error 403'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('Download a new copy is hidden for local replacements', (
    tester,
  ) async {
    useTallScreen(tester);
    final replaced = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'replaced',
      title: 'Replaced song',
      status: 'complete',
      filePath: '/tmp/replaced.m4a',
      isLocalReplacement: true,
      unavailableReason: 'private',
    );
    final normal = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'normal',
      title: 'Normal song',
      status: 'complete',
      filePath: '/tmp/normal.m4a',
    );
    await pumpPage(tester, tracks: [replaced, normal]);

    await tester.tap(find.byKey(ValueKey('track-more-${replaced.id}')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('track-actions-redownload')),
      findsNothing,
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('track-more-${normal.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('track-actions-redownload')));
    await tester.pumpAndSettle();
    expect(find.text('Download a new copy?'), findsOneWidget);
    expect(find.textContaining('"Normal song"'), findsOneWidget);
    // The old file is never deleted up front any more.
    expect(find.textContaining('nothing changes'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Download a new copy?'), findsNothing);
  });

  testWidgets('a video can have its own quality; audio tracks cannot', (
    tester,
  ) async {
    useTallScreen(tester);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Video',
      status: 'complete',
      filePath: '/tmp/video.mp4',
    );
    await pumpPage(tester, tracks: [track]);

    await tester.tap(find.byKey(ValueKey('track-more-${track.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Playlist default (Best available)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('track-actions-video-quality')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-quality-option-inherit')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('video-quality-option-480')));
    await tester.pumpAndSettle();
    expect(playlists.trackQualities, [(track.id, 480)]);
    // Nothing to download again: no question.
    expect(
      find.byKey(const ValueKey('video-quality-redownload-dialog')),
      findsNothing,
    );

    playlist = await insertTestPlaylist(
      db,
      url: 'https://www.youtube.com/playlist?list=audio',
      audioOnly: true,
    );
    final song = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Song',
      status: 'complete',
      filePath: '/tmp/song.m4a',
    );
    await tester.pumpWidget(const SizedBox());
    await pumpPage(tester, tracks: [song]);
    await tester.tap(find.byKey(ValueKey('track-more-${song.id}')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('track-actions-video-quality')),
      findsNothing,
    );
  });

  testWidgets('Update becomes Stop download, with what the run is doing', (
    tester,
  ) async {
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      status: 'pending',
    );
    DownloadProgress report(
      DownloadPhase phase, {
      int index = 0,
      int total = 0,
      double percent = 0,
      String? title,
    }) => DownloadProgress(
      playlistId: playlist.id,
      currentTrackIndex: index,
      totalTracks: total,
      trackProgress: percent,
      status: 'downloading',
      phase: phase,
      currentTitle: title,
    );
    final progress = BehaviorSubject<DownloadProgress>.seeded(
      report(DownloadPhase.preparing),
    );
    addTearDown(progress.close);
    await pumpPage(
      tester,
      tracks: [track],
      progressStream: progress.stream,
      settle: false,
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('playlist-detail-update')), findsNothing);
    expect(find.text('Stop download'), findsOneWidget);
    expect(find.text('Getting ready to download…'), findsOneWidget);

    progress.add(
      report(
        DownloadPhase.downloading,
        index: 1,
        total: 3,
        percent: 50,
        title: 'First song',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Downloading 1 of 3 · First song'), findsOneWidget);
    LinearProgressIndicator bar() => tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('playlist-download-progress')),
    );
    expect(bar().value, closeTo(0.5 / 3, 0.001));

    progress.add(
      report(
        DownloadPhase.downloading,
        index: 2,
        total: 3,
        percent: 10,
        title: 'Second song',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Downloading 2 of 3 · Second song'), findsOneWidget);
    expect(bar().value, closeTo(1.1 / 3, 0.001));

    await tester.tap(find.byKey(const ValueKey('playlist-detail-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Stop downloading?'), findsOneWidget);
    await tester.tap(find.text('Keep downloading'));
    await tester.pumpAndSettle();
    expect(downloads.cancelCalls, 0);

    await tester.tap(find.byKey(const ValueKey('playlist-detail-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(downloads.cancelCalls, 1);

    progress.add(report(DownloadPhase.finishing));
    await tester.pump();
    await tester.pump();
    expect(find.text('Finishing up…'), findsOneWidget);

    progress.add(DownloadProgress.idle);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('playlist-detail-update')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('playlist-run-status')), findsNothing);
  });

  testWidgets('the check for new videos and the queue can be stopped', (
    tester,
  ) async {
    await pumpPage(tester, tracks: const []);

    syncing.add({playlist.id});
    await tester.pump();
    await tester.pump();
    expect(find.text('Checking for new videos…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-detail-stop-check')));
    await tester.pump();
    expect(playlists.cancelSyncCalls, [playlist.id]);

    syncing.add(const {});
    queued.add([playlist.id]);
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Queued — starts after the current download'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('playlist-detail-leave-queue')));
    await tester.pump();
    expect(downloads.removedFromQueue, [playlist.id]);
  });

  testWidgets('a stopped check returns quietly and downloads nothing', (
    tester,
  ) async {
    playlists.syncError = const SyncCancelledException();
    await pumpPage(tester, tracks: const []);
    final context = tester.element(find.byType(PlaylistDetailPage));
    final result = await syncAndDownloadPlaylist(
      context: context,
      playlist: playlist,
      playlists: playlists,
      downloads: downloads,
      db: db,
    );
    await tester.pump();
    expect(result, isNull);
    expect(downloads.downloadPlaylistCalls, 0);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a video removed from YouTube can be tried again', (
    tester,
  ) async {
    useTallScreen(tester);
    final removed = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Gone song',
      status: 'unavailable',
      unavailableReason: removedFromYouTubeReason,
    );
    await pumpPage(tester, tracks: [removed]);
    expect(find.textContaining('Removed from YouTube'), findsOneWidget);

    await tester.tap(find.text('Gone song'));
    await tester.pumpAndSettle();
    expect(find.text('Try again now'), findsOneWidget);
    expect(find.text('Download now'), findsNothing);
    await tester.tap(find.text('Try again on the next update'));
    await tester.pumpAndSettle();
    expect(playlists.retriedTracks, [removed.id]);
    expect(find.text('The next update tries it again'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('playlist-detail-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try removed videos again (1)'));
    await tester.pumpAndSettle();
    expect(playlists.retriedPlaylists, [playlist.id]);
  });

  testWidgets('Play next puts a track at the front of Up next', (tester) async {
    useTallScreen(tester);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Next song',
      status: 'complete',
      filePath: '/tmp/next.m4a',
    );
    await pumpPage(tester, tracks: [track]);
    await tester.tap(find.byKey(ValueKey('track-more-${track.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();
    expect(playback.queued, [(track.id, true)]);
    expect(find.text('Plays next'), findsOneWidget);
  });

  testWidgets('Up next: tap plays an entry now, drag reorders', (tester) async {
    useTallScreen(tester);
    final tracks = await longPlaylist(3);
    upNext.add(tracks);
    await pumpPage(tester, tracks: tracks);

    await tester.tap(find.byTooltip('Up next (3)'));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('up-next-list'));
    expect(sheet, findsOneWidget);
    await tester.tap(find.descendant(of: sheet, matching: find.text('Song 2')));
    await tester.pumpAndSettle();
    expect(playback.playedUpNext, [1]);
    expect(sheet, findsNothing, reason: 'the sheet closes');

    await tester.tap(find.byTooltip('Up next (3)'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.drag_handle).first),
    );
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(playback.moves, [(0, 2)]);
    // The dropped order shows at once.
    final titles =
        tester
            .widgetList<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('up-next-list')),
                matching: find.byType(Text),
              ),
            )
            .map((t) => t.data)
            .where((t) => t != null && t.startsWith('Song'))
            .toList();
    expect(titles, ['Song 2', 'Song 3', 'Song 1']);
  });

  testWidgets('header shows a summary and labelled mode switches', (
    tester,
  ) async {
    final tracks = [
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        status: 'complete',
        filePath: '/tmp/a.m4a',
        durationSeconds: 3600,
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
        durationSeconds: 1200,
      ),
    ];
    await pumpPage(tester, tracks: tracks);
    expect(find.text('2 tracks · 1 downloaded · 1 h 20 min'), findsOneWidget);
    const shuffle = ValueKey('playlist-mode-shuffle');
    const autoplay = ValueKey('playlist-mode-autoplay');
    // A video playlist also offers audio-only playback.
    const audioOnly = ValueKey('playlist-mode-audio-only');
    final playY =
        tester.getCenter(find.byKey(const ValueKey('playlist-detail-play'))).dy;
    for (final key in [shuffle, autoplay, audioOnly]) {
      expect(find.byKey(key), findsOneWidget);
      // Everything sits in one row next to Play.
      expect(tester.getCenter(find.byKey(key)).dy, closeTo(playY, 1));
    }
    expect(find.byTooltip('Shuffle is off'), findsOneWidget);

    await tester.tap(find.byKey(shuffle));
    await tester.pump();
    expect(playback.shuffleToggles, 1);
    expect(find.textContaining('Shuffle on'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('playlist-detail-play')));
    await tester.pump();
    expect(playback.playAllCalls, 1);
  });

  testWidgets('the menu jumps from one failed track to the next', (
    tester,
  ) async {
    final tracks = [
      for (var i = 1; i <= 60; i++)
        await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: i,
          videoId: 'v$i',
          title: 'Track $i',
          status: i == 30 ? 'error' : (i == 50 ? 'unavailable' : 'complete'),
          filePath: i == 30 || i == 50 ? null : '/tmp/$i.m4a',
          lastError: i == 30 ? 'HTTP Error 403' : null,
        ),
    ];
    await pumpPage(tester, tracks: tracks);

    Future<void> jump() async {
      await tester.tap(find.byKey(const ValueKey('playlist-detail-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Jump to next failed (2)'), findsOneWidget);
      await tester.tap(find.text('Jump to next failed (2)'));
      await tester.pumpAndSettle();
    }

    await jump();
    expect(find.byKey(ValueKey('track-row-${tracks[29].id}')), findsOneWidget);
    expect(find.textContaining('1 of 2: #30 download failed'), findsOneWidget);

    await jump();
    expect(find.byKey(ValueKey('track-row-${tracks[49].id}')), findsOneWidget);
    expect(find.textContaining('2 of 2: #50 unavailable'), findsOneWidget);

    await jump();
    expect(find.byKey(ValueKey('track-row-${tracks[29].id}')), findsOneWidget);
    expect(find.textContaining('Back to the first'), findsOneWidget);
  });

  group('temporary playlist', () {
    setUp(() async {
      playlist = await insertTestPlaylist(
        db,
        url: 'woolytube:temporary',
        name: 'Temporary',
        autoUpdate: false,
        videoQuality: 720,
        isTemporary: true,
      );
    });

    testWidgets('its menu has Clear all instead of Open on YouTube', (
      tester,
    ) async {
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        title: 'Saved',
        status: 'complete',
        filePath: '/tmp/saved.mp4',
      );
      await pumpPage(tester, tracks: [track]);

      await tester.tap(find.byKey(const ValueKey('playlist-detail-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Open on YouTube'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('playlist-detail-clear-temporary')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Removes the video and deletes its file.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('clear-temporary-confirm')));
      await tester.pumpAndSettle();

      expect(downloads.stoppedPlaylists, [playlist.id]);
      expect(playback.removedPlaylists, [playlist.id]);
      expect(playlists.cleared, [playlist.id]);
      expect(find.text('Temporary playlist cleared'), findsOneWidget);
    });

    testWidgets('a video can be removed from it', (tester) async {
      useTallScreen(tester);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        title: 'Saved',
        status: 'complete',
        filePath: '/tmp/saved.mp4',
      );
      await pumpPage(tester, tracks: [track]);

      await tester.tap(find.byKey(ValueKey('track-more-${track.id}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('track-actions-remove-temporary')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-temporary-confirm')));
      await tester.pumpAndSettle();

      expect(downloads.stoppedPlaylists, [playlist.id]);
      expect(playback.removedTracks, [
        {track.id},
      ]);
      expect(playlists.removedTracks, hasLength(1));
      expect(playlists.removedTracks.single.$1, playlist.id);
      expect(playlists.removedTracks.single.$2, {track.id});
      expect(find.text('Removed "Saved"'), findsOneWidget);
    });

    testWidgets('removing while another playlist downloads touches nothing', (
      tester,
    ) async {
      useTallScreen(tester);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        title: 'Saved',
        status: 'complete',
        filePath: '/tmp/saved.mp4',
      );
      await pumpPage(tester, tracks: [track]);
      downloads.downloading = playlist.id + 100;

      await tester.tap(find.byKey(ValueKey('track-more-${track.id}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('track-actions-remove-temporary')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-temporary-confirm')));
      await tester.pumpAndSettle();

      expect(downloads.stoppedPlaylists, isEmpty);
      expect(playback.removedTracks, isEmpty);
      expect(playlists.removedTracks, isEmpty);
      expect(
        find.text('Wait until the current download finishes.'),
        findsOneWidget,
      );
    });

    testWidgets('Clear all leaves the player alone when the library is busy', (
      tester,
    ) async {
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        title: 'Saved',
        status: 'complete',
        filePath: '/tmp/saved.mp4',
      );
      await pumpPage(tester, tracks: [track]);
      playlists.busy = 'Wait until the current playlist update finishes.';

      await tester.tap(find.byKey(const ValueKey('playlist-detail-menu')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('playlist-detail-clear-temporary')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('clear-temporary-confirm')));
      await tester.pumpAndSettle();

      expect(playback.removedPlaylists, isEmpty);
      expect(playlists.cleared, isEmpty);
      expect(
        find.text('Wait until the current playlist update finishes.'),
        findsOneWidget,
      );
    });
  });

  testWidgets('the track menu does not offer saving to Temporary', (
    tester,
  ) async {
    useTallScreen(tester);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'abcdefghijk',
      status: 'complete',
      filePath: '/tmp/keeper.m4a',
    );
    await pumpPage(tester, tracks: [track]);

    await tester.tap(find.byKey(ValueKey('track-more-${track.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Open on YouTube'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('track-actions-save-temporary')),
      findsNothing,
    );
    expect(find.text('Save to Temporary playlist'), findsNothing);
  });

  testWidgets('the jump entry is hidden when nothing failed', (tester) async {
    await pumpPage(tester, tracks: const []);
    await tester.tap(find.byKey(const ValueKey('playlist-detail-menu')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Jump to next failed'), findsNothing);
  });

  testWidgets('the menu opens the playlist settings', (tester) async {
    await pumpPage(tester, tracks: const []);
    await tester.tap(find.byKey(const ValueKey('playlist-detail-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Playlist settings'), findsOneWidget);
    await tester.tap(find.text('Playlist settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PlaylistSettingsPage), findsOneWidget);
  });

  testWidgets('the page follows renames and deletion of the playlist', (
    tester,
  ) async {
    final playlists = BehaviorSubject<List<Playlist>>.seeded([playlist]);
    addTearDown(playlists.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides(const []),
          playlistsProvider.overrideWith((ref) => playlists.stream),
        ],
        child: MaterialApp(home: PlaylistDetailPage(playlistId: playlist.id)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Loaded name'), findsOneWidget);
    playlists.add([playlist.copyWith(name: 'Renamed')]);
    await tester.pumpAndSettle();
    expect(find.text('Renamed'), findsOneWidget);

    playlists.add(const []);
    await tester.pumpAndSettle();
    expect(find.text('This playlist was deleted.'), findsOneWidget);
  });

  testWidgets('starts at the playing track above the expanded player', (
    tester,
  ) async {
    audioPlayerOverlayHeightNotifier.value = 302;
    final tracks = await longPlaylist(664);
    final playing = tracks[640];
    currentTrack.add(playing);

    await pumpWarmPage(tester, tracks);

    // Visible on the first frame in the part the panel leaves free.
    expect(rowOnScreen(tester, playing), isTrue);
    final offset = listPosition(tester).pixels;
    await tester.pumpAndSettle();
    expect(listPosition(tester).pixels, offset);
    // The end of the list can be scrolled out from under the panel.
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('playlist-track-list')),
    );
    expect(list.padding, const EdgeInsets.only(bottom: 302));
  });

  testWidgets('opening the player over the playing row moves the list', (
    tester,
  ) async {
    final tracks = await longPlaylist(300);
    currentTrack.add(tracks[150]);
    await pumpWarmPage(tester, tracks);
    await tester.pumpAndSettle();
    expect(rowOnScreen(tester, tracks[150]), isTrue);

    audioPlayerOverlayHeightNotifier.value = 302;
    await tester.pumpAndSettle();
    expect(rowOnScreen(tester, tracks[150]), isTrue);

    // Closing it again leaves the list where it is.
    final offset = listPosition(tester).pixels;
    audioPlayerOverlayHeightNotifier.value = 0;
    await tester.pumpAndSettle();
    expect(listPosition(tester).pixels, offset);
  });

  testWidgets('tracks that arrive after the playing track start there', (
    tester,
  ) async {
    final tracks = await longPlaylist(500);
    currentTrack.add(tracks[420]);
    final lateTracks = BehaviorSubject<List<Track>>();
    addTearDown(lateTracks.close);
    await pumpPage(
      tester,
      tracks: const [],
      tracksStream: lateTracks.stream,
      settle: false,
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    lateTracks.add(tracks);
    await tester.pump();
    // The first frame with a list is already on the playing row.
    expect(rowOnScreen(tester, tracks[420]), isTrue);
    expect(find.byKey(ValueKey('track-row-${tracks.first.id}')), findsNothing);
    final offset = listPosition(tester).pixels;
    await tester.pumpAndSettle();
    expect(listPosition(tester).pixels, offset);
  });

  testWidgets('rows keep one height with huge text on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(340, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final tracks = [
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'a',
        title: 'Short',
        status: 'complete',
        filePath: '/tmp/a.m4a',
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1234,
        videoId: 'b',
        title: 'A really long title that wraps ' * 4,
        status: 'error',
        lastError: 'ERROR: something failed ' * 4,
        alwaysSkip: true,
        durationSeconds: 7200,
      ),
    ];
    await pumpPage(tester, tracks: tracks);
    final heights = {
      for (final track in tracks)
        tester.getSize(find.byKey(ValueKey('track-row-${track.id}'))).height,
    };
    expect(heights, hasLength(1));
    expect(
      tester
          .widget<ListView>(find.byKey(const ValueKey('playlist-track-list')))
          .itemExtent,
      heights.single,
    );
    expect(find.text('1234'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download, playback and play/pause ticks rebuild no page', (
    tester,
  ) async {
    final tracks = await longPlaylist(50);
    currentTrack.add(tracks[3]);
    isPlaying.add(true);
    DownloadProgress tick(double percent, {int index = 1}) => DownloadProgress(
      playlistId: playlist.id,
      currentTrackIndex: index,
      totalTracks: 5,
      trackProgress: percent,
      status: 'downloading',
      phase: DownloadPhase.downloading,
      currentTitle: 'Song $index',
    );
    final progress = BehaviorSubject<DownloadProgress>.seeded(tick(1));
    addTearDown(progress.close);
    await pumpPage(tester, tracks: tracks, progressStream: progress.stream);

    var pageBuilds = 0;
    var rowBuilds = 0;
    var labelBuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final name = element.widget.runtimeType.toString();
      if (element.widget is PlaylistDetailPage) pageBuilds++;
      if (name == '_TrackRow') rowBuilds++;
      if (name == '_DownloadingText') labelBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    for (var percent = 2.0; percent < 40; percent += 3) {
      progress.add(tick(percent));
      await tester.pump();
    }
    await tester.pump();
    expect(pageBuilds, 0);
    expect(rowBuilds, 0);
    expect(labelBuilds, 0, reason: 'same track, only the bar moves');
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('playlist-download-progress')),
          )
          .value,
      closeTo(0.38 / 5, 0.001),
    );

    progress.add(tick(0, index: 2));
    await tester.pump();
    await tester.pump();
    expect(pageBuilds, 0);
    expect(labelBuilds, 1);

    // Play/pause rebuilds the playing row only.
    isPlaying.add(false);
    await tester.pump();
    await tester.pump();
    expect(pageBuilds, 0);
    expect(rowBuilds, 1);

    // A track change rebuilds the old and the new playing row.
    currentTrack.add(tracks[4]);
    await tester.pump();
    await tester.pump();
    expect(pageBuilds, 0);
    expect(rowBuilds, 3);
  });

  testWidgets('the folder check runs once per few minutes, after opening', (
    tester,
  ) async {
    Future<void> open() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(const [], livePlaylist: true),
          child: MaterialApp(home: PlaylistDetailPage(playlistId: playlist.id)),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open();
    expect(metadata.reconcileCalls, 1);
    await tester.pumpWidget(const SizedBox());
    await open();
    expect(metadata.reconcileCalls, 1, reason: 'ran moments ago');

    resetPlaylistOpenChecks();
    await tester.pumpWidget(const SizedBox());
    await open();
    expect(metadata.reconcileCalls, 2);
  });

  testWidgets('inside the player shell: back closes search, pages stay '
      'under the player', (tester) async {
    final livePlaylists = BehaviorSubject<List<Playlist>>.seeded([playlist]);
    addTearDown(livePlaylists.close);
    final harness = await pumpPlayerShell(
      tester,
      overrides: [
        ...serviceOverrides(),
        playlistsProvider.overrideWith((ref) => livePlaylists.stream),
      ],
    );
    // The harness's playlist is the first one of its own database, like
    // ours, so the page reads ours and shows the harness's tracks.
    expect(harness.testPlaylist.id, playlist.id);
    final pages = harness.pagesKey.currentState!;
    unawaited(
      pages.push(
        MaterialPageRoute<void>(
          builder: (_) => PlaylistDetailPage(playlistId: playlist.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Audio track'), findsWidgets);
    expect(
      Navigator.of(tester.element(find.byType(PlaylistDetailPage))),
      same(pages),
    );

    // System back closes the search first, then leaves the page.
    await tester.tap(find.byTooltip('Search tracks'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);

    // The expanded panel pads the list; the playing row stays visible.
    harness.shellState(tester).expand();
    await tester.pumpAndSettle();
    final overlay = audioPlayerOverlayHeightNotifier.value;
    expect(overlay, greaterThan(0));
    expect(
      tester
          .widget<ListView>(find.byKey(const ValueKey('playlist-track-list')))
          .padding,
      EdgeInsets.only(bottom: overlay),
    );
    harness.shellState(tester).collapse();
    await tester.pumpAndSettle();

    // Playlist settings open in the page navigator, under the player.
    await tester.tap(find.byKey(const ValueKey('playlist-detail-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlist settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PlaylistSettingsPage), findsOneWidget);
    expect(
      Navigator.of(tester.element(find.byType(PlaylistSettingsPage))),
      same(pages),
    );
  });
}

class _Metadata implements MetadataService {
  int reconcileCalls = 0;

  @override
  Future<int> reconcilePlaylist(Playlist playlist) async {
    reconcileCalls++;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playlists implements PlaylistService {
  final cancelSyncCalls = <int>[];
  final cleared = <int>[];
  final removedTracks = <(int, Set<int>)>[];

  /// When set, removals fail like a busy library, before the player is
  /// told.
  String? busy;

  @override
  Future<void> clearPlaylist(
    int playlistId, {
    Future<void> Function()? beforeDelete,
  }) async {
    if (busy != null) throw LibraryBusyException(busy!);
    await beforeDelete?.call();
    cleared.add(playlistId);
  }

  @override
  Future<void> removeTracks(
    int playlistId,
    Iterable<int> trackIds, {
    Future<void> Function()? beforeDelete,
  }) async {
    if (busy != null) throw LibraryBusyException(busy!);
    await beforeDelete?.call();
    removedTracks.add((playlistId, trackIds.toSet()));
  }

  final trackQualities = <(int, int?)>[];

  @override
  Future<void> setTrackVideoQuality(int trackId, int? quality) async =>
      trackQualities.add((trackId, quality));

  @override
  Future<List<Track>> tracksAffectedByQualityChange(
    Playlist playlist, {
    required int? oldMax,
    required int? newMax,
    Iterable<Track>? only,
  }) async => const [];
  final retriedTracks = <int>[];
  final retriedPlaylists = <int>[];
  Object? syncError;

  @override
  Future<int> backfillLocalThumbnails(int playlistId) async => 0;

  @override
  bool cancelSync(int playlistId) {
    cancelSyncCalls.add(playlistId);
    return true;
  }

  @override
  Future<SyncResult> syncPlaylist(Playlist playlist) async {
    final error = syncError;
    if (error != null) throw error;
    throw UnimplementedError();
  }

  @override
  Future<void> retryRemovedTrack(int trackId) async =>
      retriedTracks.add(trackId);

  @override
  Future<int> retryRemovedTracks(int playlistId) async {
    retriedPlaylists.add(playlistId);
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LyricsSearch implements LyricsSearch {
  List<LyricsHit> hits = const [];
  final queries = <(String, int?)>[];

  @override
  Future<List<LyricsHit>> search(
    String query, {
    int? playlistId,
    int limit = 50,
  }) async {
    queries.add((query, playlistId));
    return hits;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playback implements PlaybackService {
  int toggleCalls = 0;
  final removedPlaylists = <int>[];
  final removedTracks = <Set<int>>[];

  @override
  Future<void> playlistRemoved(int playlistId) async =>
      removedPlaylists.add(playlistId);

  @override
  Future<void> tracksRemoved(Set<int> trackIds) async =>
      removedTracks.add(trackIds);
  int shuffleToggles = 0;
  int playAllCalls = 0;
  final playTrackIds = <int>[];
  final startAts = <Duration?>[];
  final alwaysSkipCalls = <(int, bool)>[];
  final queued = <(int, bool)>[];
  final playedUpNext = <int>[];
  final moves = <(int, int)>[];

  @override
  Future<void> togglePlayPause() async => toggleCalls++;

  @override
  void toggleShuffle() => shuffleToggles++;

  @override
  Future<void> playAll(List<Track> tracks, {Playlist? playlist}) async =>
      playAllCalls++;

  @override
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
    String? chapterId,
    bool whole = false,
    Duration? startAt,
  }) async {
    playTrackIds.add(track.id);
    startAts.add(startAt);
  }

  @override
  Future<void> setAlwaysSkip(Track track, bool alwaysSkip) async =>
      alwaysSkipCalls.add((track.id, alwaysSkip));

  @override
  Future<bool> playNext(Track track, {String? chapterId}) async {
    queued.add((track.id, true));
    return true;
  }

  @override
  Future<bool> addToUpNextQueue(
    Track track, {
    String? chapterId,
    bool first = false,
  }) async {
    queued.add((track.id, first));
    return true;
  }

  @override
  Future<bool> startUpNextQueueIfIdle() async => false;

  @override
  Future<void> playUpNextAt(int index) async => playedUpNext.add(index);

  @override
  void moveUpNextQueue(int from, int to) => moves.add((from, to));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads implements DownloadService {
  int cancelCalls = 0;
  final stoppedPlaylists = <int>[];

  /// The playlist downloading, if any.
  int? downloading;

  @override
  int? get activePlaylistId => downloading;

  @override
  Future<T> runWithDownloadStopped<T>(
    int playlistId,
    Future<T> Function() action, {
    bool resume = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (downloading != null && downloading != playlistId) {
      throw const LibraryBusyException(
        'Wait until the current download finishes.',
      );
    }
    stoppedPlaylists.add(playlistId);
    return action();
  }

  int downloadPlaylistCalls = 0;
  final removedFromQueue = <int>[];

  @override
  bool get isDownloading => downloading != null;

  @override
  List<int> get queuedPlaylistIds => const [];

  @override
  Future<void> cancelActiveDownloads() async => cancelCalls++;

  @override
  bool removeFromQueue(int playlistId) {
    removedFromQueue.add(playlistId);
    return true;
  }

  @override
  Future<DownloadStart> downloadPlaylist(
    Playlist playlist, {
    bool sourceChecked = true,
    bool Function()? shouldStop,
  }) async {
    downloadPlaylistCalls++;
    return DownloadStart.started;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
