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
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playlist_service.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Playlist playlist;
  late _Downloads downloads;
  late _Playback playback;
  late BehaviorSubject<Track?> currentTrack;
  late BehaviorSubject<bool> isPlaying;

  setUp(() async {
    db = openTestDatabase();
    playlist = await insertTestPlaylist(db, name: 'Loaded name');
    downloads = _Downloads();
    playback = _Playback();
    currentTrack = BehaviorSubject<Track?>.seeded(null);
    isPlaying = BehaviorSubject<bool>.seeded(false);
  });

  tearDown(() async {
    await currentTrack.close();
    await isPlaying.close();
    await db.close();
  });

  List<Override> overrides(
    List<Track> tracks, {
    DownloadProgress progress = DownloadProgress.idle,
    Stream<DownloadProgress>? progressStream,
    bool livePlaylist = false,
  }) => [
    databaseProvider.overrideWithValue(db),
    metadataServiceProvider.overrideWithValue(_Metadata()),
    playlistServiceProvider.overrideWithValue(_Playlists()),
    downloadServiceProvider.overrideWithValue(downloads),
    tracksProvider(playlist.id).overrideWith((ref) => Stream.value(tracks)),
    if (livePlaylist)
      playlistsProvider.overrideWith((ref) => Stream.value([playlist])),
    upNextQueueProvider.overrideWith((ref) => Stream.value(<Track>[])),
    downloadProgressProvider.overrideWith(
      (ref) => progressStream ?? Stream.value(progress),
    ),
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
    DownloadProgress progress = DownloadProgress.idle,
    Stream<DownloadProgress>? progressStream,
    String? initialName,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(
          tracks,
          progress: progress,
          progressStream: progressStream,
        ),
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

  bool rowOnScreen(WidgetTester tester, Track track) {
    final row = find.byKey(ValueKey('track-row-${track.id}'));
    if (row.evaluate().isEmpty) return false;
    final rect = tester.getRect(row);
    final list = tester.getRect(
      find.byKey(const ValueKey('playlist-track-list')),
    );
    return rect.top >= list.top - 0.5 && rect.bottom <= list.bottom + 0.5;
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
      'Add to queue',
      'Always skip',
      'Chapters…',
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

  testWidgets('Update becomes Stop while this playlist downloads', (
    tester,
  ) async {
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      status: 'pending',
    );
    final progress = BehaviorSubject<DownloadProgress>.seeded(
      DownloadProgress(
        playlistId: playlist.id,
        currentTrackIndex: 1,
        totalTracks: 3,
        trackProgress: 50,
        status: 'downloading',
      ),
    );
    addTearDown(progress.close);
    await pumpPage(tester, tracks: [track], progressStream: progress.stream);
    expect(find.byKey(const ValueKey('playlist-detail-update')), findsNothing);
    expect(find.text('Stop (1/3)'), findsOneWidget);

    progress.add(
      DownloadProgress(
        playlistId: playlist.id,
        currentTrackIndex: 2,
        totalTracks: 3,
        trackProgress: 10,
        status: 'downloading',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Stop (2/3)'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      closeTo(0.1, 0.001),
    );

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
    expect(find.text('Shuffle'), findsOneWidget);
    expect(find.text('Autoplay'), findsOneWidget);
    // A video playlist also offers audio-only playback.
    expect(find.text('Audio only'), findsOneWidget);

    await tester.tap(find.text('Shuffle'));
    await tester.pump();
    expect(playback.shuffleToggles, 1);
    expect(find.textContaining('Shuffle on'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('playlist-detail-play')));
    await tester.pump();
    expect(playback.playAllCalls, 1);
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
}

class _Metadata implements MetadataService {
  @override
  Future<int> reconcilePlaylist(Playlist playlist) async => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playlists implements PlaylistService {
  @override
  Future<int> backfillLocalThumbnails(int playlistId) async => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playback implements PlaybackService {
  int toggleCalls = 0;
  int shuffleToggles = 0;
  int playAllCalls = 0;
  final playTrackIds = <int>[];
  final alwaysSkipCalls = <(int, bool)>[];

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
  }) async => playTrackIds.add(track.id);

  @override
  Future<void> setAlwaysSkip(Track track, bool alwaysSkip) async =>
      alwaysSkipCalls.add((track.id, alwaysSkip));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads implements DownloadService {
  int cancelCalls = 0;
  @override
  bool get isDownloading => false;
  @override
  Future<void> cancelActiveDownloads() async => cancelCalls++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
