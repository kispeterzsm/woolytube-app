import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/home_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/download_network_policy.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/update_service.dart';
import 'package:woolytube/widgets/playlist_card.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late List<Playlist> playlists;
  late List<Track> tracks;
  late StreamController<DownloadProgress> progress;
  late _Playback playback;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openTestDatabase();
    playlists = [
      for (var i = 1; i <= 6; i++)
        await insertTestPlaylist(db, url: 'list-$i', name: 'Playlist $i'),
    ];
    tracks = [
      await insertTestTrack(
        db,
        playlistId: playlists[1].id,
        title: 'Morning song',
        status: 'complete',
        filePath: '/tmp/a.m4a',
      ),
      await insertTestTrack(
        db,
        playlistId: playlists[1].id,
        index: 2,
        videoId: 'v2',
        title: 'Evening song',
      ),
    ];
    progress = StreamController<DownloadProgress>.broadcast();
    playback = _Playback();
  });

  tearDown(() async {
    audioPlayerOverlayHeightNotifier.value = 0;
    await progress.close();
    await db.close();
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(411 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          updateServiceProvider.overrideWithValue(_Updates()),
          playlistsProvider.overrideWith((ref) => Stream.value(playlists)),
          allTracksProvider.overrideWith((ref) => Stream.value(tracks)),
          playlistTrackCountsStreamProvider.overrideWith(
            (ref) => Stream.value({
              playlists[0].id: const PlaylistCounts(
                total: 664,
                downloaded: 662,
                unavailable: 2,
              ),
            }),
          ),
          syncingPlaylistsProvider.overrideWith(
            (ref) => Stream.value(const <int>{}),
          ),
          downloadQueueProvider.overrideWith(
            (ref) => Stream.value([playlists[2].id]),
          ),
          downloadProgressProvider.overrideWith((ref) => progress.stream),
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(tracks.first),
          ),
          isPlayingProvider.overrideWith((ref) => Stream.value(true)),
          playbackServiceProvider.overrideWithValue(playback),
          ...overrides,
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder card(int i) =>
      find.byKey(ValueKey('playlist-card-${playlists[i].id}'));

  testWidgets('cards show counts, the playing playlist and the queue', (
    tester,
  ) async {
    await pumpHome(tester);

    // Only Search and Settings in the app bar; the debug log moved into
    // Settings.
    expect(find.byIcon(Icons.bug_report), findsNothing);
    expect(find.byTooltip('Search'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);

    expect(
      find.descendant(of: card(0), matching: find.text('662 tracks')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card(0), matching: find.text('2 unavailable')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card(1),
        matching: find.byKey(const ValueKey('playlist-card-now-playing')),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('playlist-card-now-playing')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card(2),
        matching: find.text('Queued after the current download'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('only the downloading card follows the progress', (tester) async {
    await pumpHome(tester);

    DownloadProgress at(int index, double percent) => DownloadProgress(
      playlistId: playlists[0].id,
      currentTrackIndex: index,
      totalTracks: 4,
      trackProgress: percent,
      status: 'downloading',
      phase: DownloadPhase.downloading,
    );

    progress.add(at(2, 50));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(of: card(0), matching: find.text('Downloading 2 of 4')),
      findsOneWidget,
    );
    final bar = find.byKey(const ValueKey('playlist-card-progress'));
    expect(bar, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, 0.38);
    expect(
      find.descendant(of: card(0), matching: find.byTooltip('Stop download')),
      findsOneWidget,
    );

    final otherCard = tester.widget<PlaylistCard>(
      find.descendant(of: card(1), matching: find.byType(PlaylistCard)),
    );
    progress.add(at(2, 90));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(bar).value, 0.48);
    // The other cards were not rebuilt for the tick.
    expect(
      tester.widget<PlaylistCard>(
        find.descendant(of: card(1), matching: find.byType(PlaylistCard)),
      ),
      same(otherCard),
    );
  });

  testWidgets('the add button and the list stay clear of the player panel', (
    tester,
  ) async {
    await pumpHome(tester);
    final fab = find.byKey(const ValueKey('home-add-playlist'));

    Future<void> expectLastCardClear() async {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      final settings = find.descendant(
        of: card(5),
        matching: find.byTooltip('Playlist settings'),
      );
      final buttonRect = tester.getRect(settings);
      expect(buttonRect.bottom, lessThan(tester.getRect(fab).top));
      final panelTop = 800 - audioPlayerOverlayHeightNotifier.value;
      expect(tester.getRect(card(5)).bottom, lessThan(panelTop));
    }

    await expectLastCardClear();
    final restingFab = tester.getRect(fab);

    audioPlayerOverlayHeightNotifier.value = 300;
    await tester.pumpAndSettle();
    expect(tester.getRect(fab).bottom, restingFab.bottom - 300);
    await expectLastCardClear();
  });

  testWidgets('search: clear button, back closes it, playing hides the '
      'keyboard', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);

    await tester.enterText(field, 'song');
    await tester.pump();
    expect(find.text('Morning song'), findsOneWidget);
    expect(find.text('Evening song'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);

    // Playlists match by name and are listed first.
    await tester.enterText(field, 'playlist 6');
    await tester.pump();
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('Playlist 6'), findsOneWidget);

    await tester.enterText(field, 'morning');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.text('Morning song'));
    await tester.pump();
    expect(playback.played, tracks.first.id);
    expect(tester.testTextInput.isVisible, isFalse);

    // A track that is not downloaded says so instead of doing nothing.
    await tester.enterText(field, 'evening');
    await tester.pump();
    await tester.tap(find.text('Evening song'));
    await tester.pump();
    expect(find.text('Not downloaded yet'), findsOneWidget);
    expect(playback.played, tracks.first.id);

    // Back closes the search instead of leaving the app.
    final app = tester.state(find.byType(WidgetsApp)) as WidgetsBindingObserver;
    final handled = await app.didPopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.byType(TextField), findsNothing);
    expect(card(0), findsOneWidget);
  });

  testWidgets('a double tap on Update starts one update', (tester) async {
    final settings = AppSettingsService();
    final sync = Completer<void>();
    final playlistService = _SyncPlaylists(sync.future);
    final downloads = _Downloads();
    await pumpHome(
      tester,
      overrides: [
        databaseProvider.overrideWithValue(db),
        playlistServiceProvider.overrideWithValue(playlistService),
        downloadServiceProvider.overrideWithValue(downloads),
        appSettingsServiceProvider.overrideWithValue(settings),
        downloadNetworkPolicyProvider.overrideWithValue(
          DownloadNetworkPolicy(
            settings,
            checkConnectivity: () async => [ConnectivityResult.wifi],
          ),
        ),
      ],
    );
    final update = find.descendant(
      of: card(3),
      matching: find.byTooltip('Update now'),
    );
    final spot = tester.getCenter(update);
    await tester.tapAt(spot);
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    // Checking for new videos: Update stays off until the download takes
    // over.
    expect(playlistService.syncs, 1);
    expect(
      find.descendant(
        of: card(3),
        matching: find.text('Checking for new videos…'),
      ),
      findsOneWidget,
    );
    expect(update, findsNothing);
    // The second tap neither updates again nor opens the playlist.
    await tester.tapAt(spot);
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(
      tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
      isFalse,
    );

    sync.complete();
    await tester.pumpAndSettle();
    expect(playlistService.syncs, 1);
    expect(downloads.started, ['Playlist 4']);
    expect(update, findsOneWidget);
  });

  testWidgets('import banner: Not now is remembered only once Undo is gone', (
    tester,
  ) async {
    final settings = AppSettingsService();
    final found = DiscoveredPlaylist(
      folderPath: '/tmp/old',
      url: 'https://www.youtube.com/playlist?list=old',
      name: 'Old list',
      audioOnly: true,
      autoUpdate: true,
      updateFrequencyHours: 24,
      includeThumbnails: true,
      sponsorBlockEnabled: true,
      sponsorBlockCategories: '[]',
      createdAt: DateTime(2026),
      tracks: const [],
    );
    await pumpHome(
      tester,
      overrides: [
        appSettingsServiceProvider.overrideWithValue(settings),
        pendingImportsProvider.overrideWith((ref) => [found]),
      ],
    );
    final banner = find.byKey(const ValueKey('import-banner'));
    expect(banner, findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(await settings.getDismissedImportUrls(), isEmpty);

    // Undo brings the banner back and nothing is remembered.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(banner, findsOneWidget);
    expect(await settings.getDismissedImportUrls(), isEmpty);

    // Without Undo, it is remembered once the message is gone.
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(await settings.getDismissedImportUrls(), isEmpty);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
    expect(await settings.getDismissedImportUrls(), {found.url});
    expect(banner, findsNothing);
  });

  testWidgets('notice buttons sit under the text and fit large text', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpHome(
      tester,
      overrides: [
        ytDlpInitErrorProvider.overrideWith(
          (ref) => 'The yt-dlp files could not be unpacked',
        ),
        pendingImportsProvider.overrideWith(
          (ref) => [
            DiscoveredPlaylist(
              folderPath: '/tmp/old',
              url: 'u',
              name: 'Old',
              audioOnly: true,
              autoUpdate: true,
              updateFrequencyHours: 24,
              includeThumbnails: true,
              sponsorBlockEnabled: true,
              sponsorBlockCategories: '[]',
              createdAt: DateTime(2026),
              tracks: const [],
            ),
          ],
        ),
      ],
    );
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.text('Import all')).dy,
      greaterThan(
        tester.getBottomLeft(find.text('From a previous installation')).dy,
      ),
    );
    expect(find.byTooltip('Dismiss'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}

class _Playback implements PlaybackService {
  int? played;

  @override
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
    String? chapterId,
    bool whole = false,
  }) async {
    played = track.id;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Updates implements UpdateService {
  @override
  Future<AppUpdate?> checkForUpdate({String? currentVersion}) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SyncPlaylists implements PlaylistService {
  _SyncPlaylists(this.gate);

  final Future<void> gate;
  var syncs = 0;

  @override
  Set<int> get syncingPlaylistIds => const {};

  @override
  Future<SyncResult> syncPlaylist(Playlist playlist) async {
    syncs++;
    await gate;
    return const SyncResult();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads implements DownloadService {
  final started = <String>[];

  @override
  bool get isDownloading => false;

  @override
  int? get activePlaylistId => null;

  @override
  Future<DownloadStart> downloadPlaylist(
    Playlist playlist, {
    bool sourceChecked = true,
    bool Function()? shouldStop,
  }) async {
    started.add(playlist.name);
    return DownloadStart.started;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
