import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/chapters_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/download_network_policy.dart';
import 'package:woolytube/services/download_service.dart';
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

/// Opens the chapters' ⋮ menu, checks it lists [label], and closes it.
Future<void> expectInMoreMenu(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('chapters-more')));
  await settle(tester);
  expect(find.text(label), findsOneWidget);
  Navigator.of(tester.element(find.text(label))).pop();
  await settle(tester);
}

/// No download running.
class _IdleDownloads implements DownloadService {
  @override
  bool get isDownloading => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Shazam knowing one song everywhere, or answering only after [gate]
/// opens (or the lookup is cancelled).
class _OneSongRecognizer implements ShazamRecognizer {
  _OneSongRecognizer({this.gate});
  final Completer<void>? gate;
  int calls = 0;
  @override
  Future<ShazamResult> recognize(
    ShazamSignature signature, {
    Future<void>? cancelled,
  }) async {
    calls++;
    final gate = this.gate;
    if (gate != null) {
      await Future.any([gate.future, if (cancelled != null) cancelled]);
      if (!gate.isCompleted) throw StateError('cancelled');
    }
    return ShazamResult.fromJson(const {
      'track': {'key': 'k1', 'title': 'Found Title', 'subtitle': 'Singer'},
      'matches': [
        {'id': 'ref', 'offset': 10.0},
      ],
    });
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
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Opens the chapters page of a 3-minute file with [chapters], recognized
  /// with [recognizer] (no match when null), then runs [body].
  Future<void> withChapters(
    WidgetTester tester, {
    required List<MediaChapter> chapters,
    ShazamRecognizer? recognizer,
    bool isLocalReplacement = false,
    required Future<void> Function(
      AppDatabase db,
      Track track,
      SongRecognitionService recognition,
    )
    body,
  }) async {
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
        isLocalReplacement: isLocalReplacement,
      );
      if (chapters.isNotEmpty) {
        await db.writeTrackChapters(
          track.id,
          ChapterData(custom: chapters, durationMs: 180000),
        );
        track = (await db.getTrack(track.id))!;
      }
      final playback = PlaybackService(db, player: FakePlayer());
      addTearDown(playback.dispose);
      final recognition = SongRecognitionService(
        db,
        decoder: SilentDecoder(),
        recognizer: recognizer ?? NoMatchRecognizer(),
        rootDirectory: () async => dir,
      );
      addTearDown(recognition.dispose);
      final settings = AppSettingsService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWithValue(playback),
            songRecognitionServiceProvider.overrideWithValue(recognition),
            downloadServiceProvider.overrideWithValue(_IdleDownloads()),
            appSettingsServiceProvider.overrideWithValue(settings),
            downloadNetworkPolicyProvider.overrideWithValue(
              DownloadNetworkPolicy(
                settings,
                checkConnectivity: () async => [ConnectivityResult.wifi],
              ),
            ),
          ],
          child: MaterialApp(home: ChaptersPage(track: track)),
        ),
      );
      await settle(tester);
      await body(db, track, recognition);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  }

  const crafted = [
    MediaChapter(id: 'one', title: 'Known song', startMs: 0, endMs: 60000),
    MediaChapter(
      id: 'two',
      title: 'Unrecognized section',
      startMs: 60000,
      endMs: 150000,
      origin: ChapterOrigin.auto,
      manuallyEdited: true,
    ),
  ];

  test('the Fetch from YouTube message says what is in use', () {
    const yt = [
      MediaChapter(
        id: 'y1',
        title: 'YouTube one',
        startMs: 0,
        endMs: 1000,
        origin: ChapterOrigin.original,
      ),
    ];
    const mine = [MediaChapter(id: 'm', title: 'Mine', startMs: 0, endMs: 900)];
    const mine2 = [
      MediaChapter(id: 'm2', title: 'Crafted', startMs: 0, endMs: 800),
    ];
    expect(
      fetchedChaptersMessage(
        const ChapterData(custom: mine),
        const ChapterData(downloaded: yt, custom: mine),
      ),
      'Found 1 chapter on YouTube. Your own chapters are unchanged and still '
      'used; ⋮ > Use YouTube chapters again switches to YouTube\'s.',
    );
    expect(
      fetchedChaptersMessage(
        const ChapterData(custom: mine),
        const ChapterData(custom: mine),
      ),
      'This video has no chapters on YouTube. Your own chapters are '
      'unchanged and still used.',
    );
    expect(
      fetchedChaptersMessage(
        const ChapterData(),
        const ChapterData(downloaded: yt),
      ),
      'Found 1 chapter on YouTube. They are shown below.',
    );
    expect(
      fetchedChaptersMessage(
        const ChapterData(downloaded: mine),
        const ChapterData(downloaded: yt),
      ),
      'Found 1 chapter on YouTube. The list below was updated. Undo last '
      'chapter change brings back the previous one.',
    );
    // The Undo step kept the own chapters set aside before the fetch.
    expect(
      fetchedChaptersMessage(
        const ChapterData(downloaded: mine, undoChapters: mine2),
        const ChapterData(downloaded: yt, undoChapters: mine2),
      ),
      'Found 1 chapter on YouTube. The list below was updated. Undo last '
      'chapter change still brings back your earlier chapters.',
    );
  });

  testWidgets('with chapters, Recognize is in the ⋮ menu and asks before a '
      'scan that leaves the chapters alone', (tester) async {
    await withChapters(
      tester,
      chapters: crafted,
      body: (db, track, recognition) async {
        final stored = (await db.getTrack(track.id))!.chaptersJson;
        expect(find.byKey(const ValueKey('recognize-songs')), findsNothing);
        // Nothing to show until there is a scan.
        expect(find.byKey(const ValueKey('recognition-section')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('chapters-more')));
        await settle(tester);
        expect(find.text('Fetch from YouTube'), findsOneWidget);
        await tester.tap(find.text('Recognize songs…'));
        await settle(tester);
        expect(find.text('Replace your chapters?'), findsOneWidget);
        expect(
          find.textContaining('replaces the current 2 chapters'),
          findsOne,
        );
        await tester.tap(find.text('Cancel'));
        await settle(tester);
        expect(await recognition.loadRun(track), isNull);

        await tester.tap(find.byKey(const ValueKey('chapters-more')));
        await settle(tester);
        await tester.tap(find.text('Recognize songs…'));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('confirm-recognize')));
        await settle(tester);
        await settle(tester);

        // The scan finished; the chapters are exactly as before.
        expect(await recognition.loadRun(track), isNotNull);
        expect((await db.getTrack(track.id))!.chaptersJson, stored);
        expect(
          find.byKey(const ValueKey('recognition-section')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('review-proposals')), findsOneWidget);
        await expectInMoreMenu(tester, 'Recognize again…');
      },
    );
  });

  testWidgets('a local file with chapters has the ⋮ menu for Recognize only', (
    tester,
  ) async {
    await withChapters(
      tester,
      chapters: crafted,
      isLocalReplacement: true,
      body: (db, track, recognition) async {
        await tester.tap(find.byKey(const ValueKey('chapters-more')));
        await settle(tester);
        expect(find.text('Recognize songs…'), findsOneWidget);
        expect(find.text('Fetch from YouTube'), findsNothing);
        Navigator.of(tester.element(find.text('Recognize songs…'))).pop();
        await settle(tester);
      },
    );
  });

  testWidgets('without chapters, Recognize songs stays a visible button', (
    tester,
  ) async {
    await withChapters(
      tester,
      chapters: const [],
      body: (db, track, recognition) async {
        expect(find.byKey(const ValueKey('recognize-songs')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('chapters-more')));
        await settle(tester);
        expect(find.text('Recognize songs…'), findsNothing);
        Navigator.of(tester.element(find.text('Fetch from YouTube'))).pop();
        await settle(tester);
      },
    );
  });

  testWidgets('Recognize song on one chapter lists matches and renames it '
      'without moving it', (tester) async {
    await withChapters(
      tester,
      chapters: crafted,
      recognizer: _OneSongRecognizer(),
      body: (db, track, recognition) async {
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('chapter-two')),
            matching: find.byTooltip('Chapter options'),
          ),
        );
        await settle(tester);
        await tester.tap(
          find.byKey(const ValueKey('chapter-actions-recognize')),
        );
        await settle(tester);
        await settle(tester);

        expect(find.text('Singer — Found Title'), findsOneWidget);
        expect(find.textContaining('into the chapter'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('recognize-chapter-mixed')),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('recognize-chapter-use-0')));
        await settle(tester);

        final data = ChapterData.decode(
          (await db.getTrack(track.id))!.chaptersJson,
        );
        final two = data.active.firstWhere((c) => c.id == 'two');
        expect(two.title, 'Singer — Found Title');
        expect((two.startMs, two.endMs), (60000, 150000));
        expect(data.active.first.title, 'Known song');
        expect(data.undoChapters?.map((c) => c.title), [
          'Known song',
          'Unrecognized section',
        ]);
        expect(recognition.isScanning, isFalse);
        // Nothing else was scanned or stored as a run.
        expect(await recognition.loadRun(track), isNull);
      },
    );
  });

  testWidgets('closing the Recognize song sheet cancels its lookup', (
    tester,
  ) async {
    final recognizer = _OneSongRecognizer(gate: Completer<void>());
    await withChapters(
      tester,
      chapters: crafted,
      recognizer: recognizer,
      body: (db, track, recognition) async {
        final stored = (await db.getTrack(track.id))!.chaptersJson;
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('chapter-two')),
            matching: find.byTooltip('Chapter options'),
          ),
        );
        await settle(tester);
        await tester.tap(
          find.byKey(const ValueKey('chapter-actions-recognize')),
        );
        await settle(tester);
        expect(recognition.isScanning, isTrue);
        expect(
          find.byKey(const ValueKey('recognize-chapter-progress')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('recognize-chapter-close')));
        await settle(tester);
        expect(recognition.isScanning, isFalse);
        expect(recognizer.calls, 1);
        expect((await db.getTrack(track.id))!.chaptersJson, stored);
      },
    );
  });

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

      // The file has chapters: Recognize is in the ⋮ menu, not a button.
      expect(find.byKey(const ValueKey('recognize-songs')), findsNothing);
      await expectInMoreMenu(tester, 'Recognize again…');
      expect(find.text('Review 2 proposals'), findsOneWidget);
      expect(find.textContaining('·\u00A0Auto'), findsOneWidget);
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
      await expectInMoreMenu(tester, 'Recognize again…');
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

  /// Opens the chapters page of a track in [fileName] with a saved run made
  /// before decoder versions existed (version 1), applied when [applied],
  /// then runs [body].
  Future<void> withVersion1Run(
    WidgetTester tester, {
    required String fileName,
    required bool applied,
    required Future<void> Function(AppDatabase db, Track track) body,
  }) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final dir = await Directory.systemTemp.createTemp('woolytube-chapters-');
      addTearDown(() => dir.delete(recursive: true));
      final media = await File('${dir.path}/$fileName').writeAsBytes([1, 2, 3]);
      final playlist = await insertTestPlaylist(db, outputPath: dir.path);
      var track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        status: 'complete',
        filePath: media.path,
        durationSeconds: 180,
      );
      if (applied) {
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
      }
      final playback = PlaybackService(db, player: FakePlayer());
      addTearDown(playback.dispose);
      final recognition = fakeRecognitionService(db, dir);
      addTearDown(recognition.dispose);
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
      await body(db, track);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  }

  testWidgets('an MP3 scan from the old decoder asks for a new scan', (
    tester,
  ) async {
    await withVersion1Run(
      tester,
      fileName: '00001_mix.mp3',
      applied: false,
      body: (db, track) async {
        final hint = find.byKey(const ValueKey('recognition-run-hint'));
        expect(
          tester.widget<Text>(hint).data,
          RecognitionRun.decoderOutdatedMessage,
        );
        expect(
          RecognitionRun.decoderOutdatedMessage,
          contains('Recognize again for exact timings.'),
        );
        expect(find.byKey(const ValueKey('review-proposals')), findsNothing);
        expect(find.text('Recognize again'), findsOneWidget);
      },
    );
  });

  testWidgets('chapters applied from an old MP3 scan stay, with a hint', (
    tester,
  ) async {
    await withVersion1Run(
      tester,
      fileName: '00001_mix.mp3',
      applied: true,
      body: (db, track) async {
        final hint = find.byKey(const ValueKey('recognition-run-hint'));
        expect(
          tester.widget<Text>(hint).data,
          'The automatic chapters from the last scan were made with an '
          'older, less accurate scan of MP3 files, so their timings can be '
          'off by several seconds. Recognize again for exact timings.',
        );
        expect(find.textContaining('·\u00A0Auto'), findsNWidgets(2));
        final data = ChapterData.decode(
          (await db.getTrack(track.id))!.chaptersJson,
        );
        expect(data.active.map((c) => c.id), ['a-0-90000', 'b-90000-180000']);
        await expectInMoreMenu(tester, 'Recognize again…');
      },
    );
  });

  testWidgets('an old scan of another format is still offered for review', (
    tester,
  ) async {
    await withVersion1Run(
      tester,
      fileName: '00001_mix.m4a',
      applied: false,
      body: (db, track) async {
        expect(
          find.byKey(const ValueKey('recognition-run-hint')),
          findsNothing,
        );
        expect(find.text('Review 2 proposals'), findsOneWidget);
      },
    );
  });
}
