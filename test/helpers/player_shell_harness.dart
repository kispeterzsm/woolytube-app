import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/player/player_shell.dart';
import 'package:woolytube/player/player_widgets.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/playback_service.dart';

import 'test_database.dart';

/// Records what the player asked the playback service to do.
class FakePlayback implements PlaybackService {
  FakePlayback(this.harness);

  final PlayerShellHarness harness;
  bool video = false;
  int toggleCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  int nextFileCalls = 0;
  int stopCalls = 0;
  int audioOnlyToggles = 0;
  int cancelMarkCalls = 0;
  final seeks = <Duration>[];

  /// Categories passed to [markLocalSegmentBoundary], oldest first.
  final segmentMarks = <String>[];

  @override
  bool get isVideoContent => video;

  @override
  bool get isPlaying => true;

  @override
  Duration get position => harness.position.value;

  @override
  Duration get duration => harness.duration.value;

  @override
  Future<void> togglePlayPause() async => toggleCalls++;

  @override
  Future<void> next() async => nextCalls++;

  @override
  Future<void> previous() async => previousCalls++;

  @override
  Future<void> nextFile() async => nextFileCalls++;

  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);

  @override
  Future<void> stop() async {
    stopCalls++;
    harness.track.add(null);
  }

  @override
  void toggleShuffle() {}

  @override
  void toggleAutoplay() {}

  @override
  Future<void> toggleAudioOnlyMode() async => audioOnlyToggles++;

  /// Starts a mark when none is pending, else saves it, like the service.
  @override
  Future<SegmentMarkResult> markLocalSegmentBoundary(String category) async {
    segmentMarks.add(category);
    final start = harness.pendingMark.value;
    if (start == null) {
      harness.pendingMark.add(position);
      return SegmentMarkResult.started(position);
    }
    harness.pendingMark.add(null);
    return SegmentMarkResult.saved(start, position);
  }

  /// Tracks passed to [playNext], oldest first.
  final playedNext = <Track>[];

  @override
  Future<bool> playNext(Track track, {String? chapterId}) async {
    playedNext.add(track);
    return true;
  }

  @override
  Future<bool> startUpNextQueueIfIdle() async => false;

  @override
  void cancelLocalSegmentMark() {
    cancelMarkCalls++;
    harness.pendingMark.add(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Streams and fakes behind a [PlayerShell] under test.
class PlayerShellHarness {
  final track = BehaviorSubject<Track?>.seeded(null);
  final playlist = BehaviorSubject<Playlist?>.seeded(null);
  final isVideo = BehaviorSubject<bool>.seeded(false);
  final playing = BehaviorSubject<bool>.seeded(true);
  final position = BehaviorSubject<Duration>.seeded(Duration.zero);
  final duration = BehaviorSubject<Duration>.seeded(const Duration(minutes: 3));
  final item = BehaviorSubject<PlaybackItem?>.seeded(null);
  final upNext = BehaviorSubject<List<Track>>.seeded(const []);
  final sleepRemaining = BehaviorSubject<Duration?>.seeded(null);
  final stopAfterCurrent = BehaviorSubject<bool>.seeded(false);
  final pendingMark = BehaviorSubject<Duration?>.seeded(null);
  final pagesKey = GlobalKey<NavigatorState>();
  late final FakePlayback playback = FakePlayback(this);
  final systemCalls = <MethodCall>[];
  late Track audioTrack;
  late Track videoTrack;
  late Playlist testPlaylist;

  /// What the app told Android about handling back, oldest first. While
  /// the last value is not true, Android closes the app on back.
  List<Object?> get frameworkHandlesBackCalls => [
    for (final call in systemCalls)
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack')
        call.arguments,
  ];

  /// Whether the app asked Android to leave it.
  bool get systemPopped =>
      systemCalls.any((call) => call.method == 'SystemNavigator.pop');

  PlayerShellState shellState(WidgetTester tester) =>
      tester.state<PlayerShellState>(find.byType(PlayerShell));

  Future<void> close() async {
    await track.close();
    await playlist.close();
    await isVideo.close();
    await playing.close();
    await position.close();
    await duration.close();
    await item.close();
    await upNext.close();
    await sleepRemaining.close();
    await stopAfterCurrent.close();
    await pendingMark.close();
  }

  /// Starts [next] as the playing track, like the playback service does.
  void play(Track next, {bool video = false}) {
    playback.video = video;
    playlist.add(testPlaylist);
    track.add(next);
    isVideo.add(video);
  }
}

/// Pumps the real app shell with [home] as the first page.
///
/// [withLibrary] also serves the test database, its playlist and
/// [PlayerShellHarness.upNext] to the library providers, for sheets that
/// read them (Up next, track options). Leave it off when [overrides] brings
/// its own.
Future<PlayerShellHarness> pumpPlayerShell(
  WidgetTester tester, {
  Widget? home,
  bool startPlaying = true,
  bool video = false,
  bool withLibrary = false,
  List<Override> overrides = const [],
}) async {
  final harness = PlayerShellHarness();
  final db = openTestDatabase();
  addTearDown(db.close);
  addTearDown(harness.close);
  harness.testPlaylist = await insertTestPlaylist(db, audioOnly: false);
  harness.audioTrack = await insertTestTrack(
    db,
    playlistId: harness.testPlaylist.id,
    videoId: 'force-insert:audio',
    title: 'Audio track',
    status: 'complete',
    filePath: '/tmp/audio-track.m4a',
  );
  harness.videoTrack = await insertTestTrack(
    db,
    playlistId: harness.testPlaylist.id,
    index: 2,
    videoId: 'force-insert:video',
    title: 'Video track',
    status: 'complete',
    filePath: '/tmp/video-track.mp4',
  );

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      harness.systemCalls.add(call);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  addTearDown(() => audioPlayerOverlayHeightNotifier.value = 0);
  addTearDown(() => videoFullscreenNotifier.value = false);

  if (startPlaying) {
    harness.play(video ? harness.videoTrack : harness.audioTrack, video: video);
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackServiceProvider.overrideWithValue(harness.playback),
        currentTrackProvider.overrideWith((ref) => harness.track.stream),
        currentPlaylistProvider.overrideWith((ref) => harness.playlist.stream),
        isPlayingProvider.overrideWith((ref) => harness.playing.stream),
        positionProvider.overrideWith((ref) => harness.position.stream),
        durationProvider.overrideWith((ref) => harness.duration.stream),
        isVideoContentProvider.overrideWith((ref) => harness.isVideo.stream),
        videoAspectProvider.overrideWith((ref) => Stream.value(16 / 9)),
        currentPlaybackItemProvider.overrideWith((ref) => harness.item.stream),
        playbackSponsorBlockSegmentsProvider.overrideWith(
          (ref) => Stream.value(const <PlaybackSponsorBlockSegment>[]),
        ),
        shuffleEnabledProvider.overrideWith((ref) => Stream.value(false)),
        autoplayEnabledProvider.overrideWith((ref) => Stream.value(true)),
        audioOnlyModeProvider.overrideWith((ref) => Stream.value(false)),
        sleepTimerRemainingProvider.overrideWith(
          (ref) => harness.sleepRemaining.stream,
        ),
        stopAfterCurrentProvider.overrideWith(
          (ref) => harness.stopAfterCurrent.stream,
        ),
        currentItemIsChapterProvider.overrideWith(
          (ref) => harness.item.stream.map((item) => item?.chapter != null),
        ),
        pendingSegmentMarkStartProvider.overrideWith(
          (ref) => harness.pendingMark.stream,
        ),
        if (withLibrary) ...[
          upNextQueueProvider.overrideWith((ref) => harness.upNext.stream),
          databaseProvider.overrideWithValue(db),
          playlistsProvider.overrideWith(
            (ref) => Stream.value([harness.testPlaylist]),
          ),
        ],
        tracksProvider(harness.testPlaylist.id).overrideWith(
          (ref) => Stream.value([harness.audioTrack, harness.videoTrack]),
        ),
        playerVideoSurfaceProvider.overrideWithValue(
          (fit) => const ColoredBox(
            key: ValueKey('test-video-surface'),
            color: Colors.indigo,
          ),
        ),
        ...overrides,
      ],
      child: MaterialApp(
        home: PlayerShell(
          pagesNavigatorKey: harness.pagesKey,
          home: home ?? const TestPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

/// A long list page, like a playlist, that pads its bottom by the player
/// overlay height.
class TestPage extends StatelessWidget {
  const TestPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('test-page'),
      appBar: AppBar(title: const Text('Page')),
      body: ValueListenableBuilder<double>(
        valueListenable: audioPlayerOverlayHeightNotifier,
        builder:
            (context, inset, _) => ListView.builder(
              key: const ValueKey('test-list'),
              padding: EdgeInsets.only(bottom: inset),
              itemExtent: 56,
              itemCount: 100,
              itemBuilder:
                  (context, index) => ListTile(
                    key: ValueKey('row-$index'),
                    title: Text('Row $index'),
                    onTap: () {},
                  ),
            ),
      ),
    );
  }
}
