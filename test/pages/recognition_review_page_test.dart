import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/pages/recognition_review_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/recognition/chapter_estimator.dart';

import '../helpers/recognition_fakes.dart';
import '../helpers/test_database.dart';
import '../services/playback_fakes.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  testWidgets('review edits proposals, previews, and applies them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final dir = await Directory.systemTemp.createTemp('woolytube-review-');
      addTearDown(() => dir.delete(recursive: true));
      final media = await File(
        '${dir.path}/00001_mix.m4a',
      ).writeAsBytes([1, 2, 3]);
      final playlist = await insertTestPlaylist(db, outputPath: dir.path);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        status: 'complete',
        filePath: media.path,
        durationSeconds: 180,
      );
      final player = FakePlayer();
      final playback = PlaybackService(db, player: player);
      addTearDown(playback.dispose);
      final recognition = fakeRecognitionService(db, dir);
      addTearDown(recognition.dispose);
      final run = fakeRun(track.id, [
        proposal('a', 'Artist — A', 0, 60000),
        proposal(
          'u',
          'Unrecognized section',
          60000,
          90000,
          trackKey: null,
          notes: [ChapterProposal.unrecognizedNote],
        ),
        proposal('b', 'Artist — B', 90000, 180000),
      ]);

      int? applied;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWithValue(playback),
            songRecognitionServiceProvider.overrideWithValue(recognition),
          ],
          child: MaterialApp(
            home: Builder(
              builder:
                  (context) => TextButton(
                    onPressed: () async {
                      applied = await Navigator.of(context).push<int>(
                        MaterialPageRoute(
                          builder:
                              (_) =>
                                  RecognitionReviewPage(track: track, run: run),
                        ),
                      );
                    },
                    child: const Text('Open'),
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await settle(tester);

      expect(find.text('Apply (3)'), findsOneWidget);
      expect(
        find.text('3 of 4 samples recognized · 3 proposed chapters'),
        findsOneWidget,
      );
      expect(
        find.text('1 unrecognized section · 1 with review notes'),
        findsOneWidget,
      );

      // Remove the unrecognized section.
      await tester.tap(find.byTooltip('Proposal actions').at(1));
      await settle(tester);
      await tester.tap(find.text('Remove'));
      await settle(tester);
      expect(find.text('Apply (2)'), findsOneWidget);

      // Rename the first one.
      await tester.tap(find.byTooltip('Proposal actions').first);
      await settle(tester);
      await tester.tap(find.text('Rename'));
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('proposal-title')),
        'Song A',
      );
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(find.text('Song A'), findsOneWidget);
      expect(
        (await recognition.loadRun(track))!.proposals.first.title,
        'Song A',
      );

      // Preview seeks the whole-file player to the proposal start.
      await tester.tap(find.text('Play').last);
      await settle(tester);
      expect(player.seeks, isNotEmpty);
      expect(player.seeks.last, const Duration(milliseconds: 90000));
      expect(find.text('Stop preview'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('apply-proposals')));
      await settle(tester);
      expect(applied, 2);
      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.active.map((c) => c.title), ['Song A', 'Artist — B']);
      expect(data.active.every((c) => c.origin == ChapterOrigin.auto), isTrue);
      expect(data.lastRecognitionRunId, 'run1');
      // Let transient UI timers (snack bars, transitions) run out before the
      // framework checks for leaks.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
