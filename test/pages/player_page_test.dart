import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/player_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/widgets/mini_player.dart';

import '../helpers/test_database.dart';

void main() {
  setUp(() {
    videoFullscreenNotifier.value = false;
  });

  tearDown(() {
    videoFullscreenNotifier.value = false;
  });

  testWidgets('expanded player route owns mini-player visibility', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(null),
          ),
          isVideoContentProvider.overrideWith(
            (ref) => Stream<bool>.value(false),
          ),
        ],
        child: const MaterialApp(home: PlayerPage()),
      ),
    );

    expect(videoFullscreenNotifier.value, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    expect(videoFullscreenNotifier.value, isFalse);
  });

  testWidgets('mini-player reappears immediately after audio player closes', (
    tester,
  ) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final playlist = await insertTestPlaylist(database, audioOnly: true);
    final track = await insertTestTrack(
      database,
      playlistId: playlist.id,
      title: 'Audio track',
      status: 'complete',
      filePath: '/tmp/audio-track.m4a',
    );
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackServiceProvider.overrideWithValue(_FakePlaybackService()),
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(track),
          ),
          currentPlaylistProvider.overrideWith(
            (ref) => Stream<Playlist?>.value(playlist),
          ),
          isPlayingProvider.overrideWith((ref) => Stream.value(false)),
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          durationProvider.overrideWith(
            (ref) => Stream.value(const Duration(minutes: 3)),
          ),
          isVideoContentProvider.overrideWith((ref) => Stream.value(false)),
          playbackSponsorBlockSegmentsProvider.overrideWith(
            (ref) => Stream.value(const <PlaybackSponsorBlockSegment>[]),
          ),
          queueProvider.overrideWith((ref) => Stream.value([track])),
          queueIndexProvider.overrideWith((ref) => Stream.value(0)),
          shuffleEnabledProvider.overrideWith((ref) => Stream.value(false)),
          autoplayEnabledProvider.overrideWith((ref) => Stream.value(true)),
          audioOnlyModeProvider.overrideWith((ref) => Stream.value(false)),
          sleepTimerRemainingProvider.overrideWith(
            (ref) => Stream<Duration?>.value(null),
          ),
          pendingSegmentMarkStartProvider.overrideWith(
            (ref) => Stream<Duration?>.value(null),
          ),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder:
              (context, child) => Column(
                children: [
                  Expanded(child: child!),
                  MiniPlayerBar(
                    onOpenPlayer: () {
                      navigatorKey.currentState!.push(playerPageRoute());
                    },
                  ),
                ],
              ),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.text('Audio track'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsNothing);

    await tester.tap(find.text('Audio track'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 2));

    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('fullscreen teardown schedules a mini-player redraw', (
    tester,
  ) async {
    const track = Track(
      id: 1,
      playlistId: 1,
      index: 1,
      videoId: 'audio-track',
      title: 'Audio track',
      filePath: '/tmp/audio-track.m4a',
      status: 'complete',
      isLocalReplacement: false,
      alwaysSkip: false,
    );
    videoFullscreenNotifier.value = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackServiceProvider.overrideWithValue(_FakePlaybackService()),
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(track),
          ),
          isPlayingProvider.overrideWith((ref) => Stream.value(false)),
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          durationProvider.overrideWith(
            (ref) => Stream.value(const Duration(minutes: 3)),
          ),
          isVideoContentProvider.overrideWith((ref) => Stream.value(false)),
          playbackSponsorBlockSegmentsProvider.overrideWith(
            (ref) => Stream.value(const <PlaybackSponsorBlockSegment>[]),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(bottomNavigationBar: MiniPlayerBar()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsNothing);

    // PlayerPage.dispose can flip this flag while Flutter is completing a
    // frame. Without another scheduled frame, the redraw waits for scrolling.
    tester.binding.addPostFrameCallback((_) {
      videoFullscreenNotifier.value = false;
    });
    tester.binding.scheduleFrame();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2));

    expect(find.byIcon(Icons.close), findsOneWidget);
  });
}

class _FakePlaybackService implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
