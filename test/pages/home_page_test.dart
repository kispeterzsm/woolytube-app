import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/home_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/playback_service.dart';
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

  Future<void> pumpHome(WidgetTester tester) async {
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
        matching: find.text('Queued – starts after the current download'),
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
