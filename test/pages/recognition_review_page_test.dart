import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/pages/chapter_editor_page.dart';
import 'package:woolytube/pages/recognition_review_page.dart';
import 'package:woolytube/providers/chapter_editor_providers.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapter_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/recognition/chapter_estimator.dart';
import 'package:woolytube/services/recognition/song_recognition_service.dart';

import '../helpers/recognition_fakes.dart';
import '../helpers/test_database.dart';
import '../services/playback_fakes.dart';
import 'chapter_editor_fakes.dart';

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
      final previews = FakePreviewFactory();
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
      ], fileKey: (await SongRecognitionService.currentFileKey(track))!);

      int? applied;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWithValue(playback),
            songRecognitionServiceProvider.overrideWithValue(recognition),
            chapterPreviewPlayerFactoryProvider.overrideWithValue(
              previews.call,
            ),
            waveformServiceProvider.overrideWithValue(fakeWaveforms()),
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

      // Previews play on their own player: the app's queue and player are
      // left alone, apart from being paused.
      await tester.tap(find.text('Play').last);
      await settle(tester);
      final preview = previews.last;
      expect(preview.ranges.last, (startMs: 90000, endMs: 180000, loop: false));
      expect(player.opened, isEmpty);
      expect(find.text('Stop preview'), findsOneWidget);

      // Boundary plays across the start, from the song before.
      await tester.tap(find.text('Boundary').last);
      await settle(tester);
      expect(preview.ranges.last, (startMs: 86000, endMs: 96000, loop: false));

      // Stopping (or the main player closing) never leaves the buttons
      // dead: the next tap plays again, on the same player.
      await tester.tap(find.text('Stop preview'));
      await settle(tester);
      expect(find.text('Stop preview'), findsNothing);
      expect(preview.isPlaying, isFalse);
      await tester.tap(find.text('Play').first);
      await settle(tester);
      expect(preview.ranges.last, (startMs: 0, endMs: 60000, loop: false));
      expect(previews.made, hasLength(1));
      expect(find.text('Stop preview'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('apply-proposals')));
      await settle(tester);
      expect(applied, 2);
      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.active.map((c) => c.title), ['Song A', 'Artist — B']);
      expect(data.active.every((c) => c.origin == ChapterOrigin.auto), isTrue);
      // The typed title is the user's own work: later scans keep it.
      expect(data.active.map((c) => c.manuallyEdited), [true, false]);
      expect(data.lastRecognitionRunId, 'run1');
      expect(preview.disposed, isTrue);
      // Let transient UI timers (snack bars, transitions) run out before the
      // framework checks for leaks.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  testWidgets('Adjust opens the chapter editor; moved, split and edited '
      'proposals come back for review', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ChapterEditorPage.resetSessionChoices();
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
        durationSeconds: 0,
        isLocalReplacement: true,
      );
      final playback = PlaybackService(db, player: FakePlayer());
      addTearDown(playback.dispose);
      final previews = FakePreviewFactory();
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
        proposal(
          'b',
          'Artist — B',
          90000,
          180000,
          notes: [ChapterProposal.noSilenceNote],
        ),
      ], fileKey: (await SongRecognitionService.currentFileKey(track))!);

      int? applied;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWithValue(playback),
            songRecognitionServiceProvider.overrideWithValue(recognition),
            chapterPreviewPlayerFactoryProvider.overrideWithValue(
              previews.call,
            ),
            waveformServiceProvider.overrideWithValue(fakeWaveforms()),
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
      expect(find.text('Fine-tune in editor'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('proposal-adjust-b')));
      await settle(tester);
      expect(find.byType(ChapterEditorPage), findsOneWidget);
      expect(find.text('Adjust proposals'), findsOneWidget);
      expect(find.text('Boundary 3 of 4'), findsOneWidget);
      expect(find.text(ChapterProposal.unrecognizedNote), findsOneWidget);
      final editorPreview = previews.last;

      // Move B's start a second later, then split B at 2:00.
      await tester.tap(find.byKey(const ValueKey('editor-auto-replay')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('editor-nudge-1000')));
      await settle(tester);
      // Split here acts on a playhead the user chose: play to 2:00.
      await tester.tap(find.byKey(const ValueKey('editor-play-pause')));
      await settle(tester);
      editorPreview.position = 120000;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('editor-split')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('editor-play-pause')));
      await settle(tester);
      expect(find.text('Done'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-save')));
      await settle(tester);

      expect(find.byType(ChapterEditorPage), findsNothing);
      expect(editorPreview.disposed, isTrue);
      expect(find.text('Apply (4)'), findsOneWidget);
      expect(find.text('Added by you'), findsOneWidget);
      expect(find.textContaining('start set by you'), findsOneWidget);
      // The note doubting B's old start no longer applies.
      expect(find.text(ChapterProposal.noSilenceNote), findsNothing);
      final saved = (await recognition.loadRun(track))!.proposals;
      expect(saved.map((p) => (p.id, p.startMs, p.endMs)).toList(), [
        ('a', 0, 60000),
        ('u', 60000, 91000),
        ('b', 91000, 120000),
        (saved.last.id, 120000, 180000),
      ]);
      expect(saved.map((p) => p.edited), [false, true, true, true]);
      expect(saved[2].boundaryMethod, ChapterProposal.manualBoundary);
      expect(saved.last.addedByUser, isTrue);
      expect(saved.last.title, 'Chapter 4');

      await tester.tap(find.byKey(const ValueKey('apply-proposals')));
      await settle(tester);
      expect(applied, 4);
      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.active.map((c) => c.title), [
        'Artist — A',
        'Unrecognized section',
        'Artist — B',
        'Chapter 4',
      ]);
      expect(data.active.map((c) => c.manuallyEdited), [
        false,
        true,
        true,
        true,
      ]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  testWidgets('Apply refuses a run from a replaced file or undone chapters', (
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
      const mine = MediaChapter(
        id: 'mine',
        title: 'Mine',
        startMs: 0,
        endMs: 60000,
      );
      await db.writeTrackChapters(
        track.id,
        const ChapterData(custom: [mine], durationMs: 180000),
      );
      final playback = PlaybackService(db, player: FakePlayer());
      addTearDown(playback.dispose);
      final previews = FakePreviewFactory();
      final recognition = fakeRecognitionService(db, dir);
      addTearDown(recognition.dispose);
      final run = fakeRun(track.id, [
        proposal('a', 'Artist — A', 0, 90000),
        proposal('b', 'Artist — B', 90000, 180000),
      ], fileKey: (await SongRecognitionService.currentFileKey(track))!);

      int? applied;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWithValue(playback),
            songRecognitionServiceProvider.overrideWithValue(recognition),
            chapterPreviewPlayerFactoryProvider.overrideWithValue(
              previews.call,
            ),
            waveformServiceProvider.overrideWithValue(fakeWaveforms()),
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
      final stored = (await db.getTrack(track.id))!.chaptersJson;

      Future<void> tapApply() async {
        ScaffoldMessenger.of(
          tester.element(find.text('Recognized songs')),
        ).clearSnackBars();
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('apply-proposals')));
        await settle(tester);
      }

      // The file was replaced at the same path after the scan.
      await media.writeAsBytes([4, 5, 6]);
      await tapApply();
      expect(find.text(StaleRecognitionRun.fileChangedMessage), findsOneWidget);
      expect(applied, isNull);
      expect((await db.getTrack(track.id))!.chaptersJson, stored);

      // Replaced and the epoch moved on (as a replacement does): still the
      // file's message, not the one about undone chapters.
      await db.writeTrackChapters(
        track.id,
        const ChapterData(
          custom: [mine],
          durationMs: 180000,
          recognitionEpoch: 1,
        ),
      );
      await tapApply();
      expect(find.text(StaleRecognitionRun.fileChangedMessage), findsOneWidget);
      expect(applied, isNull);

      // Same file, but the chapters were undone since the scan.
      await media.writeAsBytes([1, 2, 3]);
      await db.writeTrackChapters(
        track.id,
        const ChapterData(
          custom: [mine],
          durationMs: 180000,
          recognitionEpoch: 1,
        ),
      );
      final undone = (await db.getTrack(track.id))!.chaptersJson;
      await tapApply();
      expect(
        find.text(StaleRecognitionRun.chaptersChangedMessage),
        findsOneWidget,
      );
      expect(find.textContaining('Recognize again'), findsOneWidget);
      expect(applied, isNull);
      expect((await db.getTrack(track.id))!.chaptersJson, undone);

      // This run was applied and then undone: the undo moved the epoch on,
      // so the way on is Recognize again, not "already applied".
      await db.writeTrackChapters(
        track.id,
        const ChapterData(
          custom: [mine],
          durationMs: 180000,
          recognitionEpoch: 1,
          lastRecognitionRunId: 'run1',
        ),
      );
      final appliedThenUndone = (await db.getTrack(track.id))!.chaptersJson;
      await tapApply();
      expect(
        find.text(StaleRecognitionRun.chaptersChangedMessage),
        findsOneWidget,
      );
      expect(find.textContaining('already applied'), findsNothing);
      expect(applied, isNull);
      expect((await db.getTrack(track.id))!.chaptersJson, appliedThenUndone);

      // Applied in this very epoch: that is what the message says.
      await db.writeTrackChapters(
        track.id,
        const ChapterData(
          custom: [mine],
          durationMs: 180000,
          lastRecognitionRunId: 'run1',
        ),
      );
      await tapApply();
      expect(
        find.text('These proposals were already applied to this file.'),
        findsOneWidget,
      );
      expect(applied, isNull);

      // Back as the scan saw it: the run applies around the user's chapter.
      await db.writeTrackChapters(
        track.id,
        const ChapterData(custom: [mine], durationMs: 180000),
      );
      await tapApply();
      expect(applied, 2);
      expect(
        ChapterData.decode(
          (await db.getTrack(track.id))!.chaptersJson,
        ).active.map((c) => c.title),
        ['Mine', 'Artist — A', 'Artist — B'],
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  testWidgets('a run from the old decoder on an MP3 says so and does not '
      'apply', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final dir = await Directory.systemTemp.createTemp('woolytube-review-');
      addTearDown(() => dir.delete(recursive: true));
      final media = await File(
        '${dir.path}/00001_mix.mp3',
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
      final recognition = fakeRecognitionService(db, dir);
      addTearDown(recognition.dispose);
      // Saved before decoder versions existed.
      final json =
          fakeRun(
              track.id,
              [
                proposal('a', 'Artist — A', 0, 90000),
                proposal('b', 'Artist — B', 90000, 180000),
              ],
              fileKey: (await SongRecognitionService.currentFileKey(track))!,
            ).toJson()
            ..remove('decoderVersion');
      await recognition.saveRun(RecognitionRun.fromJson(json), track);
      final run = (await recognition.loadRun(track))!;
      expect(run.decoderOutdated, isTrue);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWithValue(playback),
            songRecognitionServiceProvider.overrideWithValue(recognition),
            chapterPreviewPlayerFactoryProvider.overrideWithValue(
              FakePreviewFactory().call,
            ),
            waveformServiceProvider.overrideWithValue(fakeWaveforms()),
          ],
          child: MaterialApp(
            home: RecognitionReviewPage(track: track, run: run),
          ),
        ),
      );
      await settle(tester);

      final banner = find.byKey(const ValueKey('review-decoder-outdated'));
      expect(
        tester.widget<Text>(banner).data,
        RecognitionRun.decoderOutdatedMessage,
      );
      final apply = find.byKey(const ValueKey('apply-proposals'));
      expect(tester.widget<TextButton>(apply).onPressed, isNull);
      await tester.tap(apply);
      await settle(tester);
      expect((await db.getTrack(track.id))!.chaptersJson, isNull);

      // Review edits are kept, and the run stays marked.
      await tester.tap(find.byTooltip('Proposal actions').first);
      await settle(tester);
      await tester.tap(find.text('Remove'));
      await settle(tester);
      final saved = (await recognition.loadRun(track))!;
      expect(saved.proposals.length, 1);
      expect(saved.decoderOutdated, isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
