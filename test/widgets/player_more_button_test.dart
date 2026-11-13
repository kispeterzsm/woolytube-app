import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/chapters.dart';

import '../helpers/player_shell_harness.dart';

const _chapter = MediaChapter(
  id: 'c2',
  title: 'Chapter two',
  startMs: 61500,
  endMs: 120000,
);

Finder _key(String key) => find.byKey(ValueKey(key));

Future<PlayerShellHarness> _openPanel(
  WidgetTester tester, {
  bool withLibrary = false,
}) async {
  final harness = await pumpPlayerShell(tester, withLibrary: withLibrary);
  harness.shellState(tester).expand();
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(_key('player-more-button'));
  await tester.pumpAndSettle();
  expect(_key('player-more-list'), findsOneWidget);
}

/// Plays [track] like the service: while a chapter plays as its own track,
/// the current track is a copy titled after the chapter.
void _play(PlayerShellHarness harness, Track track, [MediaChapter? chapter]) {
  final item = PlaybackItem(track, chapter);
  harness.item.add(item);
  harness.track.add(item.displayTrack);
}

void main() {
  testWidgets('More lists its actions in order', (tester) async {
    final harness = await _openPanel(tester);
    await _openMore(tester);

    const order = [
      'player-more-add-segment',
      'player-more-lyrics',
      'player-more-sleep-timer',
      // The test playlist is a video playlist.
      'player-more-audio-only',
      'player-more-other-settings',
    ];
    final ys = [for (final key in order) tester.getCenter(_key(key)).dy];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]), reason: order[i]);
    }
    expect(find.text('Add skip segment'), findsOneWidget);
    expect(find.text('Lyrics…'), findsOneWidget);
    expect(find.text('Sleep timer'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Other settings…'), findsOneWidget);
    // Not a chapter played as a track.
    expect(_key('player-more-next-file'), findsNothing);
    // An inserted file has no YouTube timeline to share.
    expect(_key('player-more-share'), findsNothing);

    await tester.tap(_key('player-more-audio-only'));
    await tester.pumpAndSettle();
    expect(harness.playback.audioOnlyToggles, 1);
    expect(_key('player-more-list'), findsNothing);
  });

  testWidgets('Add skip segment turns More into End segment until the '
      'segment is saved or discarded', (tester) async {
    final harness = await _openPanel(tester);
    harness.position.add(const Duration(seconds: 30));
    await _openMore(tester);
    await tester.tap(find.text('Add skip segment'));
    await tester.pumpAndSettle();
    expect(harness.playback.segmentMarks, ['sponsor']);
    expect(_key('player-more-list'), findsNothing);
    expect(find.text('End segment'), findsOneWidget);
    expect(find.text('More'), findsNothing);
    // Starting shows no message over the controls.
    expect(find.byType(SnackBar), findsNothing);

    // Discard.
    await tester.tap(find.text('End segment'));
    await tester.pumpAndSettle();
    expect(find.text('Segment category'), findsOneWidget);
    await tester.tap(_key('discard-segment'));
    await tester.pumpAndSettle();
    expect(harness.playback.cancelMarkCalls, 1);
    expect(find.text('End segment'), findsNothing);
    expect(find.text('More'), findsOneWidget);

    // Save.
    await _openMore(tester);
    await tester.tap(find.text('Add skip segment'));
    await tester.pumpAndSettle();
    harness.position.add(const Duration(seconds: 50));
    await tester.tap(find.text('End segment'));
    await tester.pumpAndSettle();
    await tester.tap(_key('segment-category-sponsor'));
    await tester.pumpAndSettle();
    expect(harness.playback.segmentMarks, ['sponsor', 'sponsor', 'sponsor']);
    expect(find.textContaining('Segment saved as'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);

    // A track change drops the pending mark: the slot is More again.
    await _openMore(tester);
    await tester.tap(find.text('Add skip segment'));
    await tester.pumpAndSettle();
    expect(find.text('End segment'), findsOneWidget);
    harness.pendingMark.add(null);
    await tester.pumpAndSettle();
    expect(find.text('More'), findsOneWidget);
  });

  testWidgets('a running sleep timer shows as a dot on More', (tester) async {
    final harness = await _openPanel(tester);
    expect(_key('player-more-sleep-dot'), findsNothing);

    harness.sleepRemaining.add(const Duration(minutes: 12, seconds: 34));
    await tester.pumpAndSettle();
    expect(_key('player-more-sleep-dot'), findsOneWidget);
    expect(find.byTooltip('More (sleep timer on)'), findsOneWidget);
    // The row keeps its label.
    expect(find.text('More'), findsOneWidget);

    await _openMore(tester);
    expect(find.text('12:34 remaining'), findsOneWidget);
    await tester.tap(_key('player-more-sleep-timer'));
    await tester.pumpAndSettle();
    expect(_key('player-more-list'), findsNothing);
    expect(_key('cancel-sleep-timer'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    harness.sleepRemaining.add(null);
    harness.stopAfterCurrent.add(true);
    await tester.pumpAndSettle();
    expect(_key('player-more-sleep-dot'), findsOneWidget);
    await _openMore(tester);
    expect(find.text('Pauses when this file ends'), findsOneWidget);
  });

  testWidgets('Queue opens Up next and counts the queued songs', (
    tester,
  ) async {
    final harness = await _openPanel(tester, withLibrary: true);
    expect(find.byTooltip('Queue'), findsOneWidget);
    expect(_key('player-queue-count'), findsNothing);

    harness.upNext.add([harness.videoTrack, harness.audioTrack]);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Queue (2)'), findsOneWidget);
    expect(
      find.descendant(of: _key('player-queue-count'), matching: find.text('2')),
      findsOneWidget,
    );

    await tester.tap(_key('player-queue-button'));
    await tester.pumpAndSettle();
    expect(find.text('Up next'), findsOneWidget);
    expect(_key('up-next-list'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('up-next-list'),
        matching: find.text('Video track'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Other settings opens the file menu for the file itself, not '
      'the playing chapter, and outlives the panel', (tester) async {
    final harness = await _openPanel(tester, withLibrary: true);
    // A row the playlist's live track list does not have yet, so the sheet
    // shows the row it was given (as it does until the list has loaded).
    final file = harness.audioTrack.copyWith(id: 999, title: 'Whole file');
    _play(harness, file, _chapter);
    await tester.pumpAndSettle();
    // The panel shows the chapter as the track.
    expect(find.text('Chapter two'), findsWidgets);

    await _openMore(tester);
    await tester.tap(_key('player-more-other-settings'));
    await tester.pumpAndSettle();
    expect(_key('player-more-list'), findsNothing);
    expect(_key('track-actions-list'), findsOneWidget);
    final title = tester.widget<Text>(_key('track-actions-title'));
    expect(title.data, 'Whole file');

    // The panel goes away while the menu is open; its actions still finish.
    harness.shellState(tester).collapse();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Minimize player'), findsNothing);
    await tester.tap(_key('track-actions-play-next'));
    await tester.pumpAndSettle();
    expect(harness.playback.playedNext.single.id, 999);
    expect(harness.playback.playedNext.single.title, 'Whole file');
    expect(find.text('Plays next'), findsOneWidget);
  });

  group('Share', () {
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    late List<Map<Object?, Object?>> shared;

    setUp(() {
      shared = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            shared.add(call.arguments as Map<Object?, Object?>);
            return 'dev.fluttercommunity.plus/share/unavailable';
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('links to the playing chapter, else to the video', (
      tester,
    ) async {
      final harness = await _openPanel(tester);
      final youTube = harness.audioTrack.copyWith(videoId: 'a-B_c9');

      _play(harness, youTube, _chapter);
      await tester.pumpAndSettle();
      await _openMore(tester);
      expect(find.text('Share a link to "Chapter two"'), findsOneWidget);
      await tester.tap(_key('player-more-share'));
      await tester.pumpAndSettle();
      expect(_key('player-more-list'), findsNothing);
      expect(shared.single['uri'], 'https://youtu.be/a-B_c9?t=61');
      expect(shared.single['title'], 'Chapter two');

      // The whole file, at a time inside one of its chapters.
      final withChapters = youTube.copyWith(
        chaptersJson: Value(
          const ChapterData(
            downloaded: [
              MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 61500),
              _chapter,
            ],
            durationMs: 120000,
          ).encode(),
        ),
      );
      _play(harness, withChapters);
      harness.position.add(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await _openMore(tester);
      expect(find.text('Share a link to "Intro"'), findsOneWidget);
      await tester.tap(_key('player-more-share'));
      await tester.pumpAndSettle();
      expect(shared.last['uri'], 'https://youtu.be/a-B_c9?t=0');

      // No chapters: the plain video link.
      _play(harness, youTube);
      await tester.pumpAndSettle();
      await _openMore(tester);
      expect(find.text('Share the YouTube link'), findsOneWidget);
      await tester.tap(_key('player-more-share'));
      await tester.pumpAndSettle();
      expect(shared.last['uri'], 'https://www.youtube.com/watch?v=a-B_c9');
      expect(shared.last['title'], 'Audio track');
    });

    testWidgets('shares the chapter playing at the tap, not at opening', (
      tester,
    ) async {
      final harness = await _openPanel(tester);
      final withChapters = harness.audioTrack.copyWith(
        videoId: 'a-B_c9',
        chaptersJson: Value(
          const ChapterData(
            downloaded: [
              MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 61500),
              _chapter,
            ],
            durationMs: 120000,
          ).encode(),
        ),
      );
      _play(harness, withChapters);
      harness.position.add(const Duration(seconds: 59));
      await tester.pumpAndSettle();
      await _openMore(tester);
      expect(find.text('Share a link to "Intro"'), findsOneWidget);

      // The whole file plays on into the next chapter with the sheet open.
      harness.position.add(const Duration(seconds: 62));
      await tester.pumpAndSettle();
      expect(find.text('Share a link to "Chapter two"'), findsOneWidget);
      await tester.tap(_key('player-more-share'));
      await tester.pumpAndSettle();
      expect(shared.single['uri'], 'https://youtu.be/a-B_c9?t=61');
      expect(shared.single['title'], 'Chapter two');
    });

    testWidgets('is hidden for a file in place of the original', (
      tester,
    ) async {
      final harness = await _openPanel(tester);
      _play(
        harness,
        harness.audioTrack.copyWith(
          videoId: 'a-B_c9',
          isLocalReplacement: true,
        ),
      );
      await tester.pumpAndSettle();
      await _openMore(tester);
      expect(_key('player-more-share'), findsNothing);
      expect(_key('player-more-other-settings'), findsOneWidget);
    });
  });
}
