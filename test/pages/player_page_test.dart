import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show Value;
import 'package:woolytube/services/chapters.dart';
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

  for (final withChapters in [false, true]) {
    testWidgets(
      'mini-player and audio controls work (chapters: $withChapters)',
      (tester) async {
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
        final displayTrack =
            withChapters
                ? track.copyWith(
                  chaptersJson: Value(
                    const ChapterData(
                      downloaded: [
                        MediaChapter(
                          id: 'first',
                          title: 'Chapter',
                          startMs: 0,
                          endMs: 10000,
                        ),
                      ],
                    ).encode(),
                  ),
                )
                : track;
        final playback = _FakePlaybackService();
        final navigatorKey = GlobalKey<NavigatorState>();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackServiceProvider.overrideWithValue(playback),
              currentTrackProvider.overrideWith(
                (ref) => Stream<Track?>.value(displayTrack),
              ),
              currentPlaylistProvider.overrideWith(
                (ref) => Stream<Playlist?>.value(playlist),
              ),
              isPlayingProvider.overrideWith((ref) => Stream.value(false)),
              positionProvider.overrideWith(
                (ref) => Stream.value(Duration.zero),
              ),
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
        expect(
          find.byIcon(Icons.fast_forward),
          withChapters ? findsOneWidget : findsNothing,
        );
        if (withChapters) {
          await tester.tap(find.byIcon(Icons.fast_forward));
          expect(playback.nextFileCalls, 1);
        }
        await tester.tap(find.text('Audio track'));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.close), findsNothing);
        expect(
          find.byIcon(Icons.fast_forward),
          withChapters ? findsOneWidget : findsNothing,
        );
        if (withChapters) {
          await tester.tap(find.byIcon(Icons.fast_forward));
          expect(playback.nextFileCalls, 2);
        }

        await tester.tap(find.text('Audio track'));
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.close), findsOneWidget);
      },
    );
  }
}

class _FakePlaybackService implements PlaybackService {
  int nextFileCalls = 0;
  @override
  Future<void> nextFile() async {
    nextFileCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
