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
  final seeks = <Duration>[];

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
  Future<void> toggleAudioOnlyMode() async {}

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
  final pagesKey = GlobalKey<NavigatorState>();
  late final FakePlayback playback = FakePlayback(this);
  final systemCalls = <MethodCall>[];
  late Track audioTrack;
  late Track videoTrack;
  late Playlist testPlaylist;

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
Future<PlayerShellHarness> pumpPlayerShell(
  WidgetTester tester, {
  Widget? home,
  bool startPlaying = true,
  bool video = false,
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
          (ref) => Stream<Duration?>.value(null),
        ),
        pendingSegmentMarkStartProvider.overrideWith(
          (ref) => Stream<Duration?>.value(null),
        ),
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
