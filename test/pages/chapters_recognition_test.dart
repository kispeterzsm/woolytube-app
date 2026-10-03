import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/pages/chapters_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/playback_service.dart';

import '../helpers/recognition_fakes.dart';
import '../helpers/test_database.dart';
import '../services/playback_fakes.dart';

/// Pumps frames while real asynchronous work (file I/O under
/// [WidgetTester.runAsync]) makes progress.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  testWidgets('chapters page offers recognition, review, remove and undo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final dir = await Directory.systemTemp.createTemp('woolytube-chapters-');
      addTearDown(() => dir.delete(recursive: true));
      final media = await File(
        '${dir.path}/00001_mix.m4a',
      ).writeAsBytes([1, 2, 3]);
      final playlist = await insertTestPlaylist(db, outputPath: dir.path);
      var track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        status: 'complete',
        filePath: media.path,
        durationSeconds: 180,
      );
      await db.writeTrackChapters(
        track.id,
        const ChapterData(
          custom: [
            MediaChapter(
              id: 'auto',
              title: 'Found song',
              startMs: 0,
              endMs: 60000,
              origin: ChapterOrigin.auto,
              reviewReasons: [
                'Name: Only one sampled detection; verify the identity.',
              ],
            ),
            MediaChapter(
              id: 'mine',
              title: 'My song',
              startMs: 60000,
              endMs: 120000,
            ),
          ],
          durationMs: 180000,
        ),
      );
      track = (await db.getTrack(track.id))!;
      final playback = PlaybackService(db, player: FakePlayer());
      addTearDown(playback.dispose);
      final recognition = fakeRecognitionService(db, dir);
      addTearDown(recognition.dispose);
      await recognition.saveRun(
        fakeRun(track.id, [
          proposal('a', 'Artist — A', 0, 90000),
          proposal('b', 'Artist — B', 90000, 180000),
        ]),
        track,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWithValue(playback),
            songRecognitionServiceProvider.overrideWithValue(recognition),
          ],
          child: MaterialApp(home: ChaptersPage(track: track)),
        ),
      );
      await settle(tester);

      expect(find.byKey(const ValueKey('recognize-songs')), findsOneWidget);
      expect(find.text('Recognize again'), findsOneWidget);
      expect(find.text('Review 2 proposals'), findsOneWidget);
      expect(find.textContaining('· Auto'), findsOneWidget);
      expect(find.textContaining('verify the identity'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('remove-automatic')));
      await settle(tester);
      var data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.active.map((c) => c.id), ['mine']);
      expect(find.byKey(const ValueKey('remove-automatic')), findsNothing);

      await tester.tap(find.text('Undo last chapter change'));
      await settle(tester);
      data = ChapterData.decode((await db.getTrack(track.id))!.chaptersJson);
      expect(data.active.map((c) => c.id), ['auto', 'mine']);

      await tester.ensureVisible(
        find.byKey(const ValueKey('review-proposals')),
      );
      await tester.tap(find.byKey(const ValueKey('review-proposals')));
      await settle(tester);
      expect(find.text('Recognized songs'), findsOneWidget);
      expect(find.text('Apply (2)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
