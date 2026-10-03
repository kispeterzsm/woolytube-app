import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/widgets/mini_player.dart';

import '../helpers/test_database.dart';

void main() {
  setUp(() => videoFullscreenNotifier.value = false);
  tearDown(() => videoFullscreenNotifier.value = false);

  testWidgets('mini-player has its own Material, tooltips and semantics', (
    tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(db, audioOnly: true);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Audio track',
      status: 'complete',
      filePath: '/tmp/audio-track.m4a',
    );
    final playback = _FakePlaybackService();
    var opened = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackServiceProvider.overrideWithValue(playback),
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(track),
          ),
          isPlayingProvider.overrideWith((ref) => Stream.value(true)),
          positionProvider.overrideWith(
            (ref) => Stream.value(const Duration(seconds: 30)),
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
        ],
        child: MaterialApp(
          // Mirrors main.dart: the bar sits outside any Scaffold.
          builder:
              (context, child) => Column(
                children: [
                  Expanded(child: child!),
                  MiniPlayerBar(onOpenPlayer: () => opened++),
                ],
              ),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = find.descendant(
      of: find.byType(MiniPlayerBar),
      matching: find.text('Audio track'),
    );
    expect(title, findsOneWidget);
    // A Material ancestor inside the bar means the text is not drawn with
    // the yellow-underline fallback style.
    expect(
      find.ancestor(
        of: title,
        matching: find.descendant(
          of: find.byType(MiniPlayerBar),
          matching: find.byType(Material),
        ),
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);

    // No Overlay exists above the Navigator, so the buttons expose their
    // labels through semantics instead of Tooltip (which would assert).
    expect(find.byType(Tooltip), findsNothing);
    final pause = find.bySemanticsLabel('Pause');
    final next = find.bySemanticsLabel('Next');
    final close = find.bySemanticsLabel('Close player');
    expect(pause, findsOneWidget);
    expect(next, findsOneWidget);
    expect(close, findsOneWidget);
    expect(find.bySemanticsLabel('Open player'), findsOneWidget);

    await tester.tap(title);
    expect(opened, 1);
    await tester.tap(
      find.descendant(of: pause, matching: find.byType(IconButton)),
    );
    expect(playback.toggleCalls, 1);
    await tester.tap(
      find.descendant(of: next, matching: find.byType(IconButton)),
    );
    expect(playback.nextCalls, 1);
    await tester.tap(
      find.descendant(of: close, matching: find.byType(IconButton)),
    );
    expect(playback.stopCalls, 1);
  });

  testWidgets('mini-player uses tooltips when an Overlay is available', (
    tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(db, audioOnly: true);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Audio track',
      status: 'complete',
      filePath: '/tmp/audio-track.m4a',
    );
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
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byTooltip('Next'), findsOneWidget);
    expect(find.byTooltip('Close player'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FakePlaybackService implements PlaybackService {
  int toggleCalls = 0;
  int nextCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> togglePlayPause() async => toggleCalls++;

  @override
  Future<void> next() async => nextCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
