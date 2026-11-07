import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/chapters_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/recognition/shazam_client.dart';
import 'package:woolytube/services/recognition/shazam_signature.dart';
import 'package:woolytube/services/recognition/song_recognition_service.dart';

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

/// Shazam answering every lookup with "slow down".
class _RateLimitedRecognizer implements ShazamRecognizer {
  int calls = 0;
  @override
  Future<ShazamResult> recognize(
    ShazamSignature signature, {
    Future<void>? cancelled,
  }) async {
    calls++;
    throw const ShazamHttpException(429, '');
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
        ], fileKey: (await SongRecognitionService.currentFileKey(track))!),
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
      expect(find.byKey(const ValueKey('recognition-run-hint')), findsNothing);

      await tester.ensureVisible(
        find.byKey(const ValueKey('review-proposals')),
      );
      await tester.tap(find.byKey(const ValueKey('review-proposals')));
      await settle(tester);
      expect(find.text('Recognized songs'), findsOneWidget);
      expect(find.text('Apply (2)'), findsOneWidget);
      Navigator.of(tester.element(find.text('Recognized songs'))).pop();
      await settle(tester);

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

      // The undo moved the chapters past the scan: its proposals are not
      // offered for applying; Recognize again rebuilds them.
      expect(find.byKey(const ValueKey('review-proposals')), findsNothing);
      expect(find.text('Recognize again'), findsOneWidget);
      expect(
        find.text(
          'The chapters were undone or reset since this scan. Recognize '
          'again rebuilds its proposals from saved lookups.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  /// Opens the chapters page of a track whose run 'run1' was applied while
  /// it followed YouTube (no chapters there), then runs [body].
  Future<void> withAppliedRun(
    WidgetTester tester,
    Future<void> Function(
      ProviderContainer container,
      AppDatabase db,
      Track track,
    )
    body,
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
      // Applying names each chapter after its proposal: '<proposal id>-…'.
      await db.writeTrackChapters(
        track.id,
        const ChapterData(
          custom: [
            MediaChapter(
              id: 'a-0-90000',
              title: 'Artist — A',
              startMs: 0,
              endMs: 90000,
              origin: ChapterOrigin.auto,
            ),
            MediaChapter(
              id: 'b-90000-180000',
              title: 'Artist — B',
              startMs: 90000,
              endMs: 180000,
              origin: ChapterOrigin.auto,
            ),
          ],
          undoChapters: [],
          undoFollowsDownloaded: true,
          durationMs: 180000,
          lastRecognitionRunId: 'run1',
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
        ], fileKey: (await SongRecognitionService.currentFileKey(track))!),
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

      expect(find.byKey(const ValueKey('review-proposals')), findsNothing);
      expect(
        find.text('The results of the last scan are applied.'),
        findsOneWidget,
      );

      await body(
        ProviderScope.containerOf(tester.element(find.byType(ChaptersPage))),
        db,
        track,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  }

  testWidgets('an applied or undone run is not offered for review again', (
    tester,
  ) async {
    await withAppliedRun(tester, (container, db, track) async {
      await tester.tap(find.text('Undo last chapter change'));
      await settle(tester);
      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.custom, isNull);
      expect(data.recognitionEpoch, 1);
      expect(find.text('Undo last chapter change'), findsNothing);
      expect(find.byKey(const ValueKey('review-proposals')), findsNothing);
      expect(find.text('Recognize again'), findsOneWidget);
      expect(
        find.text(
          'These results were taken back. Recognize again rebuilds them '
          'from saved lookups.',
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('an undo that brings the results back does not call them '
      'taken back', (tester) async {
    await withAppliedRun(tester, (container, db, track) async {
      const neutral =
          'The chapters were undone or reset since this scan. Recognize '
          'again rebuilds its proposals from saved lookups.';
      final chapters = container.read(chapterServiceProvider);

      // Rename a recognized chapter, then Undo last chapter change.
      await chapters.rename(track, 'a-0-90000', 'Renamed');
      await settle(tester);
      await tester.tap(find.text('Undo last chapter change'));
      await settle(tester);
      var data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.active.map((c) => c.title), ['Artist — A', 'Artist — B']);
      expect(data.recognitionEpoch, 1);
      expect(find.byKey(const ValueKey('review-proposals')), findsNothing);
      expect(find.text(neutral), findsOneWidget);
      expect(find.textContaining('taken back'), findsNothing);

      // Delete one, then the snack bar's Undo (replaceChapters).
      final before = await chapters.delete(track, 'b-90000-180000');
      await chapters.replaceChapters(track, before!);
      await settle(tester);
      data = ChapterData.decode((await db.getTrack(track.id))!.chaptersJson);
      expect(data.active.map((c) => c.id), ['a-0-90000', 'b-90000-180000']);
      expect(data.recognitionEpoch, 2);
      expect(find.byKey(const ValueKey('review-proposals')), findsNothing);
      expect(find.text(neutral), findsOneWidget);
      expect(find.textContaining('taken back'), findsNothing);
    });
  });

  testWidgets('an applied run whose chapters were all deleted says so', (
    tester,
  ) async {
    await withAppliedRun(tester, (container, db, track) async {
      final chapters = container.read(chapterServiceProvider);
      await chapters.delete(track, 'a-0-90000');
      await settle(tester);
      // One recognized chapter is still listed.
      expect(
        find.text('The results of the last scan are applied.'),
        findsOneWidget,
      );
      await chapters.delete(track, 'b-90000-180000');
      await settle(tester);
      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.active, isEmpty);
      expect(data.recognitionEpoch, 0);
      expect(data.lastRecognitionRunId, 'run1');
      expect(find.byKey(const ValueKey('review-proposals')), findsNothing);
      expect(find.text('Recognize again'), findsOneWidget);
      expect(
        find.text(
          'The results of the last scan were applied, then removed. '
          'Recognize again rebuilds them from saved lookups.',
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('a rate-limited scan shows its wait and can be cancelled', (
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
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        status: 'complete',
        filePath: media.path,
        durationSeconds: 180,
      );
      final playback = PlaybackService(db, player: FakePlayer());
      addTearDown(playback.dispose);
      final recognizer = _RateLimitedRecognizer();
      final never = Completer<void>();
      final recognition = SongRecognitionService(
        db,
        decoder: SilentDecoder(),
        recognizer: recognizer,
        rootDirectory: () async => dir,
        delay: (_) => never.future,
      );
      addTearDown(recognition.dispose);

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

      final outcome = recognition
          .scan(track)
          .then<Object?>((_) => null, onError: (Object e) => e);
      await settle(tester);

      expect(recognizer.calls, 1);
      expect(
        find.textContaining(
          RegExp(r'^Shazam asked us to slow down\. Retrying in 0:[23]\d…'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('(0 of 4 done)'), findsOneWidget);
      expect(find.byKey(const ValueKey('recognize-songs')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('cancel-recognition')));
      expect(await outcome, isA<RecognitionCancelled>());
      expect(never.isCompleted, isFalse);
      await settle(tester);
      expect(find.byKey(const ValueKey('recognition-waiting')), findsNothing);
      expect(find.byKey(const ValueKey('recognize-songs')), findsOneWidget);
      expect(recognizer.calls, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  testWidgets('a scan that gave up while the page was closed says so when '
      'it opens', (tester) async {
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
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        status: 'complete',
        filePath: media.path,
        durationSeconds: 180,
      );
      final playback = PlaybackService(db, player: FakePlayer());
      addTearDown(playback.dispose);
      final recognition = SongRecognitionService(
        db,
        decoder: SilentDecoder(),
        recognizer: _RateLimitedRecognizer(),
        rootDirectory: () async => dir,
        // No room for even one wait: the first 429 gives up.
        rateLimitBudget: Duration.zero,
      );
      addTearDown(recognition.dispose);

      // Nobody is watching the progress while the scan gives up.
      await expectLater(
        recognition.scan(track),
        throwsA(isA<RecognitionRateLimited>()),
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

      final failed = find.byKey(const ValueKey('recognition-failed'));
      expect(failed, findsOneWidget);
      expect(
        tester.widget<Text>(failed).data,
        'Shazam is limiting requests right now. Progress is saved; '
        'try again later.',
      );
      expect(find.byKey(const ValueKey('recognize-songs')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
