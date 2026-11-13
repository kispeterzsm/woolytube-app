import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/playlist_settings_page.dart';
import 'package:woolytube/pages/sponsorblock_settings_page.dart';
import 'package:woolytube/providers/chapter_fetch_jobs.dart';
import 'package:woolytube/providers/lyrics_fetch_jobs.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/chapter_service.dart';
import 'package:woolytube/services/download_network_policy.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/sponsorblock_categories.dart';

import '../helpers/test_database.dart';
import 'lyrics_fakes.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late _Playlists playlists;
  late _Player player;
  late _Downloads downloads;
  late List<String> events;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp(
      'woolytube_playlist_settings_test_',
    );
    events = [];
    playlists = _Playlists(db, events);
    player = _Player(events);
    downloads = _Downloads(events);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Pumps a home marker route, a detail marker route, and the settings page
  /// on top, mirroring the real navigation stack.
  Future<void> pumpStack(
    WidgetTester tester,
    int playlistId, {
    List<Override> overrides = const [],
  }) async {
    // Tall enough that every row of the page is built.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playlistServiceProvider.overrideWithValue(playlists),
          playbackServiceProvider.overrideWithValue(player),
          downloadServiceProvider.overrideWithValue(downloads),
          ...overrides,
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData.dark(),
          home: const Scaffold(body: Text('home marker')),
        ),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('detail marker')),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => PlaylistSettingsPage(playlistId: playlistId),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Pumps a while without settling (a running job animates).
  Future<void> pumpFor(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> tapRow(WidgetTester tester, String key) async {
    final row = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  testWidgets('has sections and no Save button', (tester) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);

    expect(find.text('Playlist settings'), findsOneWidget);
    expect(find.text('Save'), findsNothing);
    for (final section in ['Playlist', 'Downloads', 'Updates', 'Playback']) {
      expect(find.text(section), findsOneWidget);
    }
    expect(find.text('Danger zone'), findsOneWidget);
    expect(find.text('Tools'), findsOneWidget);
    expect(find.text('Force Insert'), findsNothing);
    expect(find.text('Add a file from this phone'), findsOneWidget);
  });

  testWidgets('the temporary playlist has no YouTube link, format, updates '
      'or delete', (tester) async {
    final playlist = await insertTestPlaylist(
      db,
      url: 'woolytube:temporary',
      name: 'Temporary',
      outputPath: tempDir.path,
      autoUpdate: false,
      videoQuality: 720,
      isTemporary: true,
    );
    await pumpStack(tester, playlist.id);

    for (final key in [
      'playlist-open-youtube',
      'playlist-audio-only',
      'playlist-auto-update',
      'playlist-update-frequency',
      'delete-playlist-button',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect(find.text('Updates'), findsNothing);
    expect(find.text('Danger zone'), findsNothing);
    expect(find.byKey(const ValueKey('playlist-name-field')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('playlist-video-quality')),
      findsOneWidget,
    );
    expect(find.text('Up to 720p'), findsOneWidget);
  });

  testWidgets('a switch saves at once, from anywhere on its row, and reaches '
      'the player', (tester) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);

    // Tap the title, not the switch.
    await tester.tap(find.text('Add cover art to files'));
    await tester.pumpAndSettle();

    expect((await db.getPlaylist(playlist.id)).includeThumbnails, isFalse);
    expect(playlists.calls.single, {'includeThumbnails': false});
    expect(player.settingsChanged, [playlist.id]);

    // Back leaves without asking anything.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('detail marker'), findsOneWidget);
  });

  testWidgets('a failed save puts the switch back and says why', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    playlists.failWith = const LibraryBusyException('Busy right now.');
    await pumpStack(tester, playlist.id);

    await tester.tap(find.text('SponsorBlock'));
    await tester.pumpAndSettle();

    expect(find.text('Busy right now.'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('playlist-sponsorblock')),
    );
    expect(tile.value, isTrue);
    expect((await db.getPlaylist(playlist.id)).sponsorBlockEnabled, isTrue);
  });

  testWidgets('the name saves when editing finishes; an empty name is not '
      'saved', (tester) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);
    final field = find.byKey(const ValueKey('playlist-name-field'));

    await tester.enterText(field, '   ');
    await tester.pump();
    expect(find.text('Enter a name'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(playlists.calls, isEmpty);
    expect(find.textContaining('A playlist needs a name'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'Test Playlist');

    await tester.enterText(field, 'Road trip');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect((await db.getPlaylist(playlist.id)).name, 'Road trip');

    // Leaving with Back keeps an edit that was not submitted.
    await tester.enterText(field, 'Road trip 2');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('detail marker'), findsOneWidget);
    expect((await db.getPlaylist(playlist.id)).name, 'Road trip 2');
  });

  testWidgets('switching the format asks first and then applies at once', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);

    await tapRow(tester, 'playlist-audio-only');
    expect(find.text('Switch to audio only?'), findsOneWidget);
    expect(find.textContaining('No file is deleted'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(playlists.calls, isEmpty);
    expect((await db.getPlaylist(playlist.id)).audioOnly, isFalse);

    await tapRow(tester, 'playlist-audio-only');
    await tester.tap(find.text('Switch'));
    await tester.pumpAndSettle();
    expect(playlists.calls.single, {'audioOnly': true});
    expect((await db.getPlaylist(playlist.id)).audioOnly, isTrue);
    expect(find.text('Switched to audio only.'), findsOneWidget);

    await tapRow(tester, 'playlist-audio-only');
    expect(find.text('Switch to video?'), findsOneWidget);
  });

  testWidgets('an unusual update interval is kept until the owner changes it', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: tempDir.path,
      updateFrequencyHours: 6,
    );
    await pumpStack(tester, playlist.id);
    expect(find.text('Every 6 hours'), findsOneWidget);

    // Another change does not touch the interval.
    await tester.tap(find.text('Add cover art to files'));
    await tester.pumpAndSettle();
    expect((await db.getPlaylist(playlist.id)).updateFrequencyHours, 6);

    await tapRow(tester, 'playlist-update-frequency');
    expect(find.text('Every 6 hours'), findsNWidgets(2));
    await tester.tap(find.text('Every day'));
    await tester.pumpAndSettle();
    expect((await db.getPlaylist(playlist.id)).updateFrequencyHours, 24);
    expect(find.text('Every day'), findsOneWidget);
  });

  testWidgets('the interval row is disabled while automatic checks are off', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: tempDir.path,
      autoUpdate: false,
    );
    await pumpStack(tester, playlist.id);
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('playlist-update-frequency')),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('Check for new videos automatically'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('playlist-update-frequency')),
          )
          .enabled,
      isTrue,
    );
  });

  testWidgets('skip choices are summarised, saved at once and need '
      'SponsorBlock on', (tester) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);
    expect(find.text('7 skipped'), findsOneWidget);

    await tapRow(tester, 'playlist-skip-segments');
    expect(find.byType(SponsorBlockSettingsPage), findsOneWidget);
    final sponsor = find.byKey(const ValueKey('sponsorblock-category-sponsor'));
    await tester.tap(find.descendant(of: sponsor, matching: find.text('Show')));
    await tester.pumpAndSettle();
    final stored = decodeSponsorBlockCategoryActions(
      (await db.getPlaylist(playlist.id)).sponsorBlockCategoryActions,
    );
    expect(stored['sponsor'], SponsorBlockCategoryAction.showInSeekbar);
    expect(player.settingsChanged, [playlist.id]);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('6 skipped · 1 shown'), findsOneWidget);

    await tester.tap(find.text('SponsorBlock'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('playlist-skip-segments')),
          )
          .enabled,
      isFalse,
    );
  });

  testWidgets('fetching chapters says so when nothing is missing', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);

    await tapRow(tester, 'fetch-missing-chapters');
    expect(
      find.text('All downloaded videos already have chapter info.'),
      findsOneWidget,
    );
  });

  testWidgets('adding a local file asks for a position before the file', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await insertTestTrack(db, playlistId: playlist.id, index: 1);
    await pumpStack(tester, playlist.id);

    // The row shows a spinner while the dialog is open, so the frames never
    // settle.
    await tester.tap(find.byKey(const ValueKey('force-insert-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byKey(const ValueKey('force-insert-index-field')),
      findsOneWidget,
    );
    expect(find.text('Choose file'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('force-insert-index-field')),
      '3',
    );
    await tester.tap(find.byKey(const ValueKey('force-insert-select-file')));
    await tester.pump();
    expect(find.text('Enter a number from 1 to 2.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('delete offers file removal and returns to the home page', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);

    await tapRow(tester, 'delete-playlist-button');
    expect(find.text('Also delete downloaded files'), findsOneWidget);
    expect(find.textContaining('Downloaded files are kept'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-files-checkbox')));
    await tester.pumpAndSettle();
    expect(find.textContaining('deletes its downloaded files'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-playlist-confirm')));
    await tester.pumpAndSettle();

    expect(playlists.deletedIds, [playlist.id]);
    expect(playlists.deleteFilesFlags, [true]);
    expect(find.text('home marker'), findsOneWidget);
    expect(find.text('detail marker'), findsNothing);
    // Its songs left the player first.
    expect(events, ['playlistRemoved ${playlist.id}', 'delete ${playlist.id}']);
  });

  testWidgets('deleting a playlist that is downloading stops the download '
      'first', (tester) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    downloads
      ..downloading = true
      ..activePlaylistId = playlist.id;
    await pumpStack(tester, playlist.id);

    await tapRow(tester, 'delete-playlist-button');
    expect(find.text('Its running download will be stopped.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-playlist-confirm')));
    await tester.pump();
    expect(events, ['cancel downloads']);
    expect(playlists.deletedIds, isEmpty, reason: 'waits for the run to end');

    downloads.finishRun();
    await tester.pumpAndSettle();
    expect(events, [
      'cancel downloads',
      'playlistRemoved ${playlist.id}',
      'delete ${playlist.id}',
    ]);
    expect(find.text('home marker'), findsOneWidget);
  });

  testWidgets('a download that does not stop keeps the playlist', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    downloads
      ..downloading = true
      ..activePlaylistId = playlist.id;
    await pumpStack(tester, playlist.id);

    await tapRow(tester, 'delete-playlist-button');
    await tester.tap(find.byKey(const ValueKey('delete-playlist-confirm')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not stop the download. Try again.'),
      findsOneWidget,
    );
    expect(playlists.deletedIds, isEmpty);
    expect(events, ['cancel downloads']);
    expect(find.text('Playlist settings'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('delete-playlist-button')),
          )
          .enabled,
      isTrue,
    );
  });

  testWidgets('a queued download of the playlist is dropped before deleting', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    downloads.queued.add(playlist.id);
    await pumpStack(tester, playlist.id);

    await tapRow(tester, 'delete-playlist-button');
    expect(
      find.text('Its waiting download will be cancelled.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('delete-playlist-confirm')));
    await tester.pumpAndSettle();
    expect(downloads.queued, isEmpty);
    expect(playlists.deletedIds, [playlist.id]);
  });

  testWidgets('delete waits for a running chapter fetch to stop', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    final chapters = _SlowChapters(events);
    await pumpStack(
      tester,
      playlist.id,
      overrides: [chapterServiceProvider.overrideWithValue(chapters)],
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlaylistSettingsPage)),
    );
    final job = container
        .read(chapterFetchJobsProvider.notifier)
        .start(playlist.id);
    await tester.pump();
    expect(find.text('Fetching missing chapters'), findsOneWidget);

    // The job's spinner never settles, so pump by hand.
    await tester.tap(find.byKey(const ValueKey('delete-playlist-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('delete-playlist-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(chapters.cancellation!.isCancelled, isTrue);
    expect(playlists.deletedIds, isEmpty, reason: 'one video is still checked');

    chapters.finishCurrentVideo();
    await tester.pumpAndSettle();
    expect(events, [
      'chapter job ended',
      'playlistRemoved ${playlist.id}',
      'delete ${playlist.id}',
    ]);
    // Quietly: no result for a deleted playlist.
    expect(await job, isNull);
    expect(find.textContaining('chapters'), findsNothing);
  });

  testWidgets('a failed save shows what is stored without losing a change '
      'queued after it', (tester) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);
    final firstWrite = Completer<void>();
    playlists.beforeWrite = (call) async {
      if (call.containsKey('sponsorBlockEnabled')) {
        await firstWrite.future;
        throw StateError('Disk full');
      }
    };

    await tester.tap(find.text('SponsorBlock'));
    await tester.pump();
    await tester.tap(find.text('Add cover art to files'));
    await tester.pump();
    firstWrite.complete();
    await tester.pumpAndSettle();

    expect(find.text('Could not save: Disk full'), findsOneWidget);
    SwitchListTile tile(String key) =>
        tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));
    expect(tile('playlist-sponsorblock').value, isTrue);
    expect(tile('playlist-include-thumbnails').value, isFalse);
    final stored = await db.getPlaylist(playlist.id);
    expect(stored.sponsorBlockEnabled, isTrue);
    expect(stored.includeThumbnails, isFalse);
  });

  group('video quality', () {
    final wifi = [
      downloadNetworkPolicyProvider.overrideWithValue(
        DownloadNetworkPolicy(
          AppSettingsService(),
          checkConnectivity: () async => [ConnectivityResult.wifi],
        ),
      ),
    ];

    testWidgets('is offered for video playlists only', (tester) async {
      final audio = await insertTestPlaylist(
        db,
        url: 'audio',
        outputPath: tempDir.path,
        audioOnly: true,
      );
      await pumpStack(tester, audio.id);
      expect(
        find.byKey(const ValueKey('playlist-video-quality')),
        findsNothing,
      );

      final video = await insertTestPlaylist(
        db,
        url: 'video',
        outputPath: tempDir.path,
      );
      await pumpStack(tester, video.id);
      expect(
        find.byKey(const ValueKey('playlist-video-quality')),
        findsOneWidget,
      );
      expect(find.text('Best available'), findsOneWidget);
    });

    testWidgets('a new quality is saved at once; without downloaded videos '
        'nothing is asked', (tester) async {
      final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
      await pumpStack(tester, playlist.id, overrides: wifi);

      await tapRow(tester, 'playlist-video-quality');
      await tester.tap(find.byKey(const ValueKey('video-quality-option-720')));
      await tester.pumpAndSettle();

      expect((await db.getPlaylist(playlist.id)).videoQuality, 720);
      expect(find.text('Up to 720p'), findsOneWidget);
      expect(playlists.qualityChecks, [(null, 720)]);
      expect(
        find.byKey(const ValueKey('video-quality-redownload-dialog')),
        findsNothing,
      );
      expect(player.settingsChanged, [playlist.id]);
    });

    testWidgets('choosing Best saves no cap', (tester) async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
        videoQuality: 480,
      );
      await pumpStack(tester, playlist.id, overrides: wifi);

      await tapRow(tester, 'playlist-video-quality');
      await tester.tap(find.byKey(const ValueKey('video-quality-option-best')));
      await tester.pumpAndSettle();

      expect((await db.getPlaylist(playlist.id)).videoQuality, isNull);
      expect(playlists.qualityChecks, [(480, null)]);
    });

    testWidgets('"Only new downloads" keeps the files', (tester) async {
      final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        status: 'complete',
        filePath: '${tempDir.path}/00001_A.mp4',
      );
      playlists.affected = [track];
      await pumpStack(tester, playlist.id, overrides: wifi);

      await tapRow(tester, 'playlist-video-quality');
      await tester.tap(find.byKey(const ValueKey('video-quality-option-480')));
      await tester.pumpAndSettle();

      expect(find.text('Download 1 video again at 480p?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-quality-keep')));
      await tester.pumpAndSettle();

      expect((await db.getPlaylist(playlist.id)).videoQuality, 480);
      expect(playlists.redownloads, isEmpty);
      expect(downloads.started, isEmpty);
      expect((await db.getTrack(track.id))!.replaceRequested, isFalse);
    });

    testWidgets('"Download again" asks for new copies and starts the '
        'download', (tester) async {
      final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        status: 'complete',
        filePath: '${tempDir.path}/00001_A.mp4',
      );
      playlists.affected = [track];
      await pumpStack(tester, playlist.id, overrides: wifi);

      await tapRow(tester, 'playlist-video-quality');
      await tester.tap(find.byKey(const ValueKey('video-quality-option-720')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-quality-redownload')));
      await tester.pumpAndSettle();

      expect(playlists.redownloads, [
        [track.id],
      ]);
      expect((await db.getTrack(track.id))!.replaceRequested, isTrue);
      expect(downloads.started, [(playlist.id, false)]);
      expect(find.text('Downloading 1 video again'), findsOneWidget);
    });
  });

  testWidgets('a name that cannot be saved after leaving is reported', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);
    playlists.failWith = Exception('disk full');

    await tester.enterText(
      find.byKey(const ValueKey('playlist-name-field')),
      'Road trip',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('detail marker'), findsOneWidget);
    expect(
      find.textContaining('Could not rename the playlist to "Road trip"'),
      findsOneWidget,
    );
    expect((await db.getPlaylist(playlist.id)).name, 'Test Playlist');
  });

  group('lyrics', () {
    late FakeLyricsService lyrics;
    setUp(() => lyrics = FakeLyricsService()..instantBackfill = true);
    List<Override> overrides() => [
      lyricsServiceProvider.overrideWithValue(lyrics),
      downloadNetworkPolicyProvider.overrideWithValue(
        DownloadNetworkPolicy(
          AppSettingsService(),
          checkConnectivity: () async => [ConnectivityResult.wifi],
        ),
      ),
    ];

    testWidgets('is off by default and has no fetch tool then', (tester) async {
      final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
      await pumpStack(tester, playlist.id, overrides: overrides());

      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('playlist-lyrics-mode')),
      );
      expect((tile.subtitle! as Text).data, 'Off');
      expect(find.byKey(const ValueKey('fetch-lyrics')), findsNothing);
    });

    testWidgets('turning it on saves the mode and starts fetching', (
      tester,
    ) async {
      final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
      await pumpStack(tester, playlist.id, overrides: overrides());

      await tapRow(tester, 'playlist-lyrics-mode');
      expect(find.text('Spoken transcript'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyrics-mode-option-lyrics')));
      await tester.pumpAndSettle();

      expect((await db.getPlaylist(playlist.id)).lyricsMode, 'lyrics');
      expect(playlists.calls.single, {'lyricsMode': LyricsMode.lyrics});
      expect(lyrics.calls, ['backfill ${playlist.id}']);
      expect(find.text('Found lyrics for 3 of 3'), findsOneWidget);
      expect(find.text('Fetch lyrics now'), findsOneWidget);

      // The tool runs it again.
      await tapRow(tester, 'fetch-lyrics');
      expect(lyrics.calls, hasLength(2));
    });

    testWidgets('turning it off saves null and hides the tool', (tester) async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
        lyricsMode: 'transcript',
      );
      await pumpStack(tester, playlist.id, overrides: overrides());
      expect(find.text('Fetch transcripts now'), findsOneWidget);

      await tapRow(tester, 'playlist-lyrics-mode');
      await tester.tap(find.byKey(const ValueKey('lyrics-mode-option-off')));
      await tester.pumpAndSettle();

      expect(playlists.calls.single, {'lyricsMode': null});
      expect((await db.getPlaylist(playlist.id)).lyricsMode, isNull);
      expect(lyrics.calls, isEmpty);
      expect(find.byKey(const ValueKey('fetch-lyrics')), findsNothing);
    });

    testWidgets('the running job shows progress and stops', (tester) async {
      lyrics = FakeLyricsService();
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
        lyricsMode: 'lyrics',
      );
      await pumpStack(tester, playlist.id, overrides: overrides());
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlaylistSettingsPage)),
      );
      final job = container
          .read(lyricsFetchJobsProvider.notifier)
          .start(playlist.id);
      await tester.pump();
      expect(find.text('Fetching lyrics'), findsOneWidget);
      expect(find.text('Checking 0 of 3…'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fetch-lyrics-stop')));
      await tester.pump();
      expect(find.text('Stopping after this track…'), findsOneWidget);
      lyrics.step();
      await tester.pumpAndSettle();
      expect(find.text('Fetch lyrics now'), findsOneWidget);
      expect((await job)!.cancelled, isTrue);
    });

    testWidgets('switching the mode during a job starts the new mode\'s '
        'fetch once the old job ends', (tester) async {
      lyrics = FakeLyricsService();
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
        lyricsMode: 'lyrics',
      );
      await pumpStack(tester, playlist.id, overrides: overrides());
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlaylistSettingsPage)),
      );
      unawaited(
        container.read(lyricsFetchJobsProvider.notifier).start(playlist.id),
      );
      await tester.pump();

      // A running job animates: no pumpAndSettle until it ends.
      Future<void> pumpABit() async {
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
      }

      final row = find.byKey(const ValueKey('playlist-lyrics-mode'));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await pumpABit();
      await tester.tap(row);
      await pumpABit();
      await tester.tap(
        find.byKey(const ValueKey('lyrics-mode-option-transcript')),
      );
      await pumpABit();
      expect(lyrics.cancellation!.isCancelled, isTrue);
      // The old job finishes its track; then the transcripts are fetched.
      lyrics
        ..instantBackfill = true
        ..step();
      await tester.pumpAndSettle();
      expect(lyrics.calls, [
        'backfill ${playlist.id}',
        'backfill ${playlist.id}',
      ]);
      expect((await db.getPlaylist(playlist.id)).lyricsMode, 'transcript');
    });

    group('while a mode switch waits for the old job', () {
      Future<Playlist> startAndSwitch(WidgetTester tester) async {
        lyrics = FakeLyricsService();
        final playlist = await insertTestPlaylist(
          db,
          outputPath: tempDir.path,
          lyricsMode: 'lyrics',
        );
        await pumpStack(tester, playlist.id, overrides: overrides());
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PlaylistSettingsPage)),
        );
        unawaited(
          container.read(lyricsFetchJobsProvider.notifier).start(playlist.id),
        );
        await tester.pump();
        final row = find.byKey(const ValueKey('playlist-lyrics-mode'));
        await tester.scrollUntilVisible(
          row,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await pumpFor(tester);
        await tester.tap(row);
        await pumpFor(tester);
        await tester.tap(find.byKey(const ValueKey('lyrics-mode-option-off')));
        await pumpFor(tester);
        expect(lyrics.cancellation!.isCancelled, isTrue);
        return playlist;
      }

      testWidgets('delete and the other settings wait for the new mode', (
        tester,
      ) async {
        final playlist = await startAndSwitch(tester);
        final delete = find.byKey(const ValueKey('delete-playlist-button'));
        await tester.scrollUntilVisible(
          delete,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await pumpFor(tester);
        await tester.tap(delete);
        await pumpFor(tester);
        expect(
          find.byKey(const ValueKey('delete-playlist-confirm')),
          findsNothing,
        );

        // Other settings wait too, so the mode save cannot undo them.
        final autoUpdate = find.byKey(const ValueKey('playlist-auto-update'));
        expect(tester.widget<SwitchListTile>(autoUpdate).onChanged, isNull);

        lyrics.step();
        await tester.pumpAndSettle();
        expect((await db.getPlaylist(playlist.id)).lyricsMode, isNull);
        expect(playlists.deletedIds, isEmpty);
        expect(tester.widget<SwitchListTile>(autoUpdate).onChanged, isNotNull);
      });

      testWidgets('leaving the page still saves the new mode', (tester) async {
        final playlist = await startAndSwitch(tester);
        await tester.pageBack();
        await pumpFor(tester);
        expect(find.text('detail marker'), findsOneWidget);
        lyrics.step();
        await tester.pumpAndSettle();
        expect((await db.getPlaylist(playlist.id)).lyricsMode, isNull);
        expect(lyrics.calls, ['backfill ${playlist.id}']);
      });
    });

    testWidgets('switching the format stops a running lyrics job first', (
      tester,
    ) async {
      lyrics = FakeLyricsService();
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
        lyricsMode: 'lyrics',
      );
      await pumpStack(tester, playlist.id, overrides: overrides());
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlaylistSettingsPage)),
      );
      unawaited(
        container.read(lyricsFetchJobsProvider.notifier).start(playlist.id),
      );
      await tester.pump();
      final row = find.byKey(const ValueKey('playlist-audio-only'));
      await tester.tap(row);
      await pumpFor(tester);
      await tester.tap(find.text('Switch'));
      await pumpFor(tester);
      expect(lyrics.cancellation!.isCancelled, isTrue);
      expect(playlists.calls, isEmpty, reason: 'the job is on a track');
      lyrics.step();
      await tester.pumpAndSettle();
      expect((await db.getPlaylist(playlist.id)).audioOnly, isTrue);
    });

    testWidgets('delete waits for a running lyrics job to stop', (
      tester,
    ) async {
      lyrics = FakeLyricsService()..failWhenStopped = true;
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
        lyricsMode: 'lyrics',
      );
      await pumpStack(tester, playlist.id, overrides: overrides());
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlaylistSettingsPage)),
      );
      final job = container
          .read(lyricsFetchJobsProvider.notifier)
          .start(playlist.id);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('delete-playlist-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('delete-playlist-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(lyrics.cancellation!.isCancelled, isTrue);
      expect(
        playlists.deletedIds,
        isEmpty,
        reason: 'one track is still checked',
      );

      lyrics.step();
      await tester.pumpAndSettle();
      expect(playlists.deletedIds, [playlist.id]);
      expect(await job, isNull);
    });
  });
}

/// Fetches chapters until cancelled, then finishes the video it is on when
/// told to and fails like a job whose playlist was deleted.
class _SlowChapters implements ChapterService {
  _SlowChapters(this.events);

  final List<String> events;
  ChapterFetchCancellation? cancellation;
  final _videoDone = Completer<void>();

  void finishCurrentVideo() => _videoDone.complete();

  @override
  Future<ChapterFetchResult> fetchMissingChapters(
    int playlistId, {
    void Function(int done, int total)? onProgress,
    ChapterFetchCancellation? cancellation,
    int persistEvery = 25,
  }) async {
    this.cancellation = cancellation;
    onProgress?.call(0, 5);
    await _videoDone.future;
    events.add('chapter job ended');
    throw StateError('No element');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records settings writes and applies them to the test database, like the
/// real service minus the file work.
class _Playlists implements PlaylistService {
  _Playlists(this.db, this.events);

  final AppDatabase db;
  final List<String> events;

  /// Runs before each settings write with the changed fields; may throw.
  Future<void> Function(Map<String, Object?> call)? beforeWrite;
  final calls = <Map<String, Object?>>[];
  final deletedIds = <int>[];
  final deleteFilesFlags = <bool>[];
  Exception? failWith;

  /// What [tracksAffectedByQualityChange] answers, and the (old, new) caps
  /// it was asked about.
  List<Track> affected = const [];
  final qualityChecks = <(int?, int?)>[];
  final redownloads = <List<int>>[];

  @override
  Future<void> setPlaylistVideoQuality(int id, int? maxHeight) async {
    final failure = failWith;
    if (failure != null) throw failure;
    await db.updatePlaylistFields(
      id,
      PlaylistsCompanion(videoQuality: Value(maxHeight)),
    );
  }

  @override
  Future<List<Track>> tracksAffectedByQualityChange(
    Playlist playlist, {
    required int? oldMax,
    required int? newMax,
    Iterable<Track>? only,
  }) async {
    qualityChecks.add((oldMax, newMax));
    return affected;
  }

  @override
  Future<void> requestRedownload(int playlistId, List<int> trackIds) async {
    redownloads.add(trackIds);
    for (final id in trackIds) {
      await db.setTrackReplaceRequested(id, true);
    }
  }

  @override
  Future<void> updatePlaylistSettings({
    required int id,
    String? name,
    bool? audioOnly,
    bool? autoUpdate,
    bool? playChapters,
    int? updateFrequencyHours,
    bool? includeThumbnails,
    bool? sponsorBlockEnabled,
    List<String>? sponsorBlockCategories,
    Map<String, SponsorBlockCategoryAction>? sponsorBlockCategoryActions,
    Value<LyricsMode?> lyricsMode = const Value.absent(),
  }) async {
    final failure = failWith;
    if (failure != null) throw failure;
    final call = {
      if (name != null) 'name': name,
      if (audioOnly != null) 'audioOnly': audioOnly,
      if (autoUpdate != null) 'autoUpdate': autoUpdate,
      if (playChapters != null) 'playChapters': playChapters,
      if (updateFrequencyHours != null)
        'updateFrequencyHours': updateFrequencyHours,
      if (includeThumbnails != null) 'includeThumbnails': includeThumbnails,
      if (sponsorBlockEnabled != null)
        'sponsorBlockEnabled': sponsorBlockEnabled,
      if (sponsorBlockCategoryActions != null)
        'sponsorBlockCategoryActions': sponsorBlockCategoryActions,
      if (lyricsMode.present) 'lyricsMode': lyricsMode.value,
    };
    await beforeWrite?.call(call);
    calls.add(call);
    final current = await db.getPlaylist(id);
    await db.updatePlaylist(
      current
          .copyWith(
            name: name,
            audioOnly: audioOnly,
            autoUpdate: autoUpdate,
            updateFrequencyHours: updateFrequencyHours,
            includeThumbnails: includeThumbnails,
            sponsorBlockEnabled: sponsorBlockEnabled,
            sponsorBlockCategoryActions:
                sponsorBlockCategoryActions == null
                    ? null
                    : encodeSponsorBlockCategoryActions(
                      sponsorBlockCategoryActions,
                    ),
            lyricsMode:
                lyricsMode.present
                    ? Value(LyricsMode.toDb(lyricsMode.value))
                    : const Value.absent(),
          )
          .toCompanion(true),
    );
    // toCompanion(true) leaves out nulls, so "off" is written here.
    if (lyricsMode.present) {
      await db.updatePlaylistFields(
        id,
        PlaylistsCompanion(
          lyricsMode: Value(LyricsMode.toDb(lyricsMode.value)),
        ),
      );
    }
  }

  @override
  Future<List<Track>> getTracksForPlaylist(int playlistId) =>
      db.getTracksForPlaylist(playlistId);

  @override
  Future<void> deletePlaylist(int id, {bool deleteFiles = false}) async {
    events.add('delete $id');
    deletedIds.add(id);
    deleteFilesFlags.add(deleteFiles);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements PlaybackService {
  _Player(this.events);

  final List<String> events;
  final settingsChanged = <int>[];

  @override
  Future<void> playlistRemoved(int playlistId) async {
    events.add('playlistRemoved $playlistId');
  }

  @override
  Future<void> playlistSettingsChanged(int playlistId) async {
    settingsChanged.add(playlistId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads implements DownloadService {
  _Downloads(this.events);

  final List<String> events;
  bool downloading = false;
  final queued = <int>[];
  Completer<void>? _run;

  @override
  int? activePlaylistId;

  @override
  bool get isDownloading => downloading;

  @override
  List<int> get queuedPlaylistIds => List.of(queued);

  @override
  bool removeFromQueue(int playlistId) => queued.remove(playlistId);

  /// (playlist id, sourceChecked) of each [downloadPlaylist] call.
  final started = <(int, bool)>[];

  @override
  Future<DownloadStart> downloadPlaylist(
    Playlist playlist, {
    bool sourceChecked = true,
    bool Function()? shouldStop,
    bool scheduled = false,
  }) async {
    started.add((playlist.id, sourceChecked));
    return DownloadStart.started;
  }

  @override
  Future<void> cancelActiveDownloads() async {
    events.add('cancel downloads');
    queued.clear();
    _run ??= Completer<void>();
  }

  @override
  Future<void> get runFinished =>
      downloading ? (_run ??= Completer<void>()).future : Future.value();

  void finishRun() {
    downloading = false;
    activePlaylistId = null;
    _run?.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
