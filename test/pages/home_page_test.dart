import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/home_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/download_network_policy.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/label_service.dart';
import 'package:woolytube/services/labels.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_search.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/update_service.dart';
import 'package:woolytube/widgets/playlist_card.dart';

import '../helpers/real_fonts.dart';
import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late List<Playlist> playlists;

  /// What the home page lists, when not all of [playlists].
  List<Playlist>? listed;

  /// Track counts per playlist, added to those of the first playlist.
  late Map<int, PlaylistCounts> extraCounts;
  late List<Track> tracks;
  late StreamController<DownloadProgress> progress;
  late _Playback playback;
  late _LyricsSearch lyrics;

  /// The labels in use, as the page sees them (a drift stream would leave
  /// a timer behind).
  late List<Label> labels;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    listed = null;
    extraCounts = {};
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
    lyrics = _LyricsSearch();
    labels = const [];
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
          playlistsProvider.overrideWith(
            (ref) => Stream.value(listed ?? playlists),
          ),
          allTracksProvider.overrideWith((ref) => Stream.value(tracks)),
          playlistTrackCountsStreamProvider.overrideWith(
            (ref) => Stream.value({
              playlists[0].id: const PlaylistCounts(
                total: 664,
                downloaded: 662,
                unavailable: 2,
              ),
              ...extraCounts,
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
          lyricsSearchProvider.overrideWithValue(lyrics),
          labelsProvider.overrideWith((ref) => Stream.value(labels)),
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
      find.descendant(of: card(0), matching: find.text('664 tracks')),
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

  testWidgets('the reorder button opens the reorder page', (tester) async {
    await pumpHome(tester);

    final button = find.byKey(const ValueKey('home-reorder-playlists'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('Reorder playlists'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reorder-playlists-list')),
      findsOneWidget,
    );
    for (final playlist in playlists.take(3)) {
      expect(
        find.byKey(ValueKey('reorder-playlist-${playlist.id}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('the card menu opens the reorder page too', (tester) async {
    await pumpHome(tester);

    await tester.longPress(card(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist-menu-reorder')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('reorder-playlists-list')),
      findsOneWidget,
    );
  });

  testWidgets('one playlist has nothing to reorder', (tester) async {
    listed = [playlists.first];
    await pumpHome(tester);

    expect(card(0), findsOneWidget);
    expect(find.byKey(const ValueKey('home-reorder-playlists')), findsNothing);
    await tester.longPress(card(0));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('playlist-menu-settings')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('playlist-menu-reorder')), findsNothing);
  });

  group('temporary playlist', () {
    late Playlist temporary;

    setUp(() async {
      temporary = await insertTestPlaylist(
        db,
        url: 'woolytube:temporary',
        name: 'Temporary',
        autoUpdate: false,
        isTemporary: true,
      );
    });

    Finder temporaryCard() =>
        find.byKey(ValueKey('playlist-card-${temporary.id}'));

    testWidgets('is hidden while it has no videos', (tester) async {
      listed = [temporary, playlists[0], playlists[1]];
      await pumpHome(tester);

      expect(temporaryCard(), findsNothing);
      expect(card(0), findsOneWidget);

      // Nor is it offered in the search or on the reorder page.
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Temporary');
      await tester.pumpAndSettle();
      expect(find.text('Nothing matches'), findsOneWidget);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('home-reorder-playlists')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('reorder-playlist-${temporary.id}')),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey('reorder-playlist-${playlists[0].id}')),
        findsOneWidget,
      );
    });

    testWidgets('alone and empty, the library counts as empty', (tester) async {
      listed = [temporary];
      await pumpHome(tester);

      expect(temporaryCard(), findsNothing);
      expect(find.text('No playlists yet'), findsOneWidget);
    });

    testWidgets('with videos it shows, without "Open on YouTube"', (
      tester,
    ) async {
      listed = [temporary, playlists[0]];
      extraCounts = {
        temporary.id: const PlaylistCounts(total: 2, downloaded: 1),
      };
      await pumpHome(tester);

      expect(temporaryCard(), findsOneWidget);
      await tester.longPress(temporaryCard());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('playlist-menu-youtube')), findsNothing);
      expect(find.text('Download videos not downloaded yet'), findsOneWidget);
    });
  });

  testWidgets('the reorder button is hidden while searching', (tester) async {
    await pumpHome(tester);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('home-reorder-playlists')), findsNothing);
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

  testWidgets('search: lyric lines show after a pause and play at the line', (
    tester,
  ) async {
    await db.writeTrackChapters(
      tracks.first.id,
      const ChapterData(
        downloaded: [
          MediaChapter(id: 'ch1', title: 'Opener', startMs: 0, endMs: 600000),
          MediaChapter(
            id: 'ch2',
            title: 'Hey Brother',
            startMs: 600000,
            endMs: 900000,
          ),
        ],
      ),
    );
    tracks = [(await db.getTrack(tracks.first.id))!, tracks.last];
    playlists[1] = playlists[1].copyWith(lyricsMode: const Value('lyrics'));
    lyrics.hits = [
      LyricsHit(
        trackId: tracks.first.id,
        chapterId: 'ch2',
        docId: 7,
        lineId: 70,
        lineNo: 1,
        lineText: "There's an endless road to rediscover",
        highlightRanges: const [
          LyricsHighlight(8, 10),
          LyricsHighlight(11, 18),
        ],
        positionMs: 605000,
        score: 0.95,
        kind: LyricsMode.lyrics,
      ),
    ];
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('search-filter-lyrics'));
    expect(tester.widget<FilterChip>(chip).selected, isFalse);
    await tester.enterText(find.byType(TextField), 'an endless road');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    // Lyrics are not searched while the filter is off (the default); a
    // button offers to.
    expect(lyrics.queries, isEmpty);
    expect(find.text('No titles match'), findsOneWidget);
    expect(find.text('Search lyrics too'), findsOneWidget);

    // Turning it on searches at once.
    await tester.tap(chip);
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(tester.widget<FilterChip>(chip).selected, isTrue);
    expect(lyrics.queries, ['an endless road']);
    expect(find.text('Search lyrics too'), findsNothing);
    final header = find.descendant(
      of: find.byType(ListView),
      matching: find.text('Lyrics'),
    );
    expect(header, findsOneWidget);
    final tile = find.byKey(const ValueKey('search-lyrics-7'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('Hey Brother')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile,
        matching: find.text('Morning song · Playlist 2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile,
        matching: find.text(
          "There's an endless road to rediscover",
          findRichText: true,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.text('10:05')),
      findsOneWidget,
    );

    await tester.tap(tile);
    await tester.pump();
    expect(playback.played, tracks.first.id);
    expect(playback.playedChapterId, 'ch2');
    expect(playback.playedStartAt, const Duration(milliseconds: 603000));

    // Play all queues the chapter holding the line.
    await tester.tap(find.text('Play all'));
    await tester.pump();
    expect(playback.playedEntries, [
      [
        QueueEntry(tracks.first, const {'ch2'}),
      ],
    ]);

    // A new query hides the old lines until its own search is done, a
    // moment after typing stops.
    await tester.enterText(find.byType(TextField), 'winter snow');
    await tester.pump();
    expect(find.byKey(const ValueKey('search-lyrics-7')), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(lyrics.queries, hasLength(2));
    expect(find.byKey(const ValueKey('search-lyrics-7')), findsOneWidget);

    // A short query clears the lines without searching.
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(header, findsNothing);
    expect(lyrics.queries, hasLength(2));

    // Turning the filter off hides the lines.
    await tester.enterText(find.byType(TextField), 'winter snow');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.byKey(const ValueKey('search-lyrics-7')), findsOneWidget);
    await tester.tap(chip);
    await tester.pump();
    expect(find.byKey(const ValueKey('search-lyrics-7')), findsNothing);
    expect(lyrics.queries, hasLength(3));

    // Search opens with the filter off again.
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(chip).selected, isFalse);
  });

  testWidgets('search: lyrics are offered only for a query they can search', (
    tester,
  ) async {
    playlists[1] = playlists[1].copyWith(lyricsMode: const Value('lyrics'));
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    // One letter is too short for the lyrics search.
    await tester.enterText(find.byType(TextField), 'q');
    await tester.pump();
    expect(find.text('Nothing matches'), findsOneWidget);
    expect(find.text('Search lyrics too'), findsNothing);

    await tester.enterText(find.byType(TextField), 'qu');
    await tester.pump();
    expect(find.text('Search lyrics too'), findsOneWidget);
  });

  testWidgets('search: lyrics get the words as typed, repeats included', (
    tester,
  ) async {
    playlists[1] = playlists[1].copyWith(lyricsMode: const Value('lyrics'));
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'You and me');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-filter-lyrics')));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pump();
    // Typing on with words already there searches again, as a phrase.
    await tester.enterText(find.byType(TextField), 'You and me and you');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(lyrics.queries, ['you and me', 'you and me and you']);
  });

  testWidgets('search: only the chapter title is highlighted', (tester) async {
    final set = await insertTestTrack(
      db,
      playlistId: playlists[0].id,
      videoId: 'set',
      title: 'Live set',
      status: 'complete',
      filePath: '/tmp/set.m4a',
    );
    await db.writeTrackChapters(
      set.id,
      const ChapterData(
        downloaded: [
          MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 70000),
          MediaChapter(id: 'b', title: 'Part 1', startMs: 70000, endMs: 90000),
          MediaChapter(
            id: 'c',
            title: 'Part 1 again',
            startMs: 90000,
            endMs: 110000,
          ),
        ],
      ),
    );
    tracks = [...tracks, (await db.getTrack(set.id))!];
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'part 1');
    await tester.pump();

    final line = find.descendant(
      of: find.byKey(ValueKey('search-track-${set.id}')),
      matching: find.text(
        'Chapter: Part 1 · 1:10 · +1 more',
        findRichText: true,
      ),
    );
    expect(line, findsOneWidget);
    final highlighted = <String>[];
    tester.widget<RichText>(line).text.visitChildren((span) {
      if (span is TextSpan &&
          span.text != null &&
          span.style?.fontWeight == FontWeight.w600) {
        highlighted.add(span.text!);
      }
      return true;
    });
    // Not the label, the "1" in the time or the count.
    expect(highlighted.join(), 'Part1');
  });

  testWidgets('search: best matches first, the chapter found, and Play all', (
    tester,
  ) async {
    final mix = await insertTestTrack(
      db,
      playlistId: playlists[0].id,
      videoId: 'mix',
      title: 'Vibe mix',
      status: 'complete',
      filePath: '/tmp/mix.m4a',
    );
    await db.writeTrackChapters(
      mix.id,
      const ChapterData(
        downloaded: [
          MediaChapter(id: 'intro', title: 'Intro', startMs: 0, endMs: 60000),
          MediaChapter(
            id: 'ko',
            title: 'Föl földobott kő',
            startMs: 60000,
            endMs: 120000,
          ),
          MediaChapter(
            id: 'ko2',
            title: 'Földobott kő (reprise)',
            startMs: 120000,
            endMs: 180000,
          ),
        ],
      ),
    );
    final exact = await insertTestTrack(
      db,
      playlistId: playlists[5].id,
      videoId: 'exact',
      title: 'Song',
      status: 'complete',
      filePath: '/tmp/song.m4a',
    );
    tracks = [...tracks, (await db.getTrack(mix.id))!, exact];
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    // No playlist has lyrics on: no Lyrics filter.
    expect(find.byKey(const ValueKey('search-filter-lyrics')), findsNothing);

    // Accents and word order don't matter; the chapter found shows.
    await tester.enterText(find.byType(TextField), 'ko foldobott');
    await tester.pump();
    final mixTile = find.byKey(ValueKey('search-track-${mix.id}'));
    expect(mixTile, findsOneWidget);
    expect(
      find.descendant(
        of: mixTile,
        matching: find.text(
          'Chapter: Föl földobott kő · 1:00 · +1 more',
          findRichText: true,
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('1 track'), findsOneWidget);
    await tester.tap(find.text('Play all'));
    await tester.pump();
    // Only the chapters found, not the whole mix.
    expect(playback.playedEntries.single, [
      QueueEntry(tracks[2], const {'ko', 'ko2'}),
    ]);

    // An exact title comes first, even from a later playlist; a track that
    // is not downloaded is listed but not queued.
    await tester.enterText(find.byType(TextField), 'song');
    await tester.pump();
    expect(find.text('3 tracks'), findsOneWidget);
    double top(Track track) =>
        tester.getTopLeft(find.byKey(ValueKey('search-track-${track.id}'))).dy;
    expect(top(exact), lessThan(top(tracks[0])));
    expect(top(tracks[0]), lessThan(top(tracks[1])));
    await tester.tap(find.byKey(const ValueKey('search-results-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add 2 to Up next'));
    await tester.pumpAndSettle();
    expect(playback.enqueuedEntries.single, [
      QueueEntry(exact),
      QueueEntry(tracks[0]),
    ]);
    expect(find.text('Added 2 tracks to Up next'), findsOneWidget);

    // The bar fits a narrow phone with large text.
    tester.view.physicalSize = const Size(320 * 3, 800 * 3);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Play all'), findsOneWidget);
  });

  testWidgets('search: label chips list everything with them, all or any, '
      'and Play all plays files whole and chapters alone', (tester) async {
    final service = LabelService(db);
    final rock = await service.create('Rock', 0xFFE57373);
    final live = await service.create('Live', 0xFF64B5F6);
    labels = await service.labels();
    var index = 0;
    Future<Track> track(
      String title, {
      List<String> fileLabels = const [],
      Map<String, List<String>> chapterLabels = const {},
    }) {
      index++;
      return insertTestTrack(
        db,
        playlistId: playlists[3].id,
        index: index,
        videoId: 'labelled-$index',
        title: title,
        status: 'complete',
        filePath: '/tmp/labelled-$index.m4a',
        labelUids: encodeLabelUids(fileLabels),
        chaptersJson:
            chapterLabels.isEmpty
                ? null
                : ChapterData(
                  downloaded: const [
                    MediaChapter(id: 'a', title: 'One', startMs: 0, endMs: 1),
                    MediaChapter(id: 'b', title: 'Two', startMs: 1, endMs: 2),
                  ],
                  chapterLabels: chapterLabels,
                ).encode(),
      );
    }

    final song = await track('Rock song', fileLabels: [rock.uid]);
    final liveSong = await track(
      'Live rock song',
      fileLabels: [rock.uid, live.uid],
    );
    final mix = await track(
      'A mix',
      chapterLabels: {
        'b': [live.uid],
      },
    );
    tracks = [...tracks, song, liveSong, mix];
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    Finder tile(Track t) => find.byKey(ValueKey('search-track-${t.id}'));

    // With nothing typed, a label lists everything that has it.
    await tester.tap(find.byKey(ValueKey('search-filter-label-${rock.uid}')));
    await tester.pumpAndSettle();
    expect(tile(song), findsOneWidget);
    expect(tile(liveSong), findsOneWidget);
    expect(tile(mix), findsNothing);
    expect(tile(tracks[0]), findsNothing);
    expect(find.text('2 tracks'), findsOneWidget);
    expect(
      find.byKey(ValueKey('search-track-labels-${song.id}')),
      findsOneWidget,
    );

    // Both labels: only what has both, then what has either.
    await tester.tap(find.byKey(ValueKey('search-filter-label-${live.uid}')));
    await tester.pumpAndSettle();
    expect(tile(song), findsNothing);
    expect(tile(liveSong), findsOneWidget);
    expect(tile(mix), findsNothing);
    await tester.tap(find.byKey(const ValueKey('search-label-match')));
    await tester.pumpAndSettle();
    expect(tile(song), findsOneWidget);
    expect(tile(mix), findsOneWidget);
    expect(
      find.descendant(
        of: tile(mix),
        matching: find.textContaining('Chapter: Two', findRichText: true),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Play all'));
    await tester.pump();
    expect(playback.playedEntries.single, [
      QueueEntry(song),
      QueueEntry(liveSong),
      QueueEntry(mix, const {'b'}),
    ]);

    // The results menu labels them all.
    await tester.tap(find.byKey(const ValueKey('search-results-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-label-all')), findsOneWidget);
  });

  testWidgets('a whole-file transcript hit plays the chapter at its time', (
    tester,
  ) async {
    await db.writeTrackChapters(
      tracks.first.id,
      const ChapterData(
        downloaded: [
          MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 60000),
          MediaChapter(
            id: 'b',
            title: 'Interview',
            startMs: 60000,
            endMs: 10000000,
          ),
        ],
      ),
    );
    tracks = [(await db.getTrack(tracks.first.id))!, tracks.last];
    playlists[1] = playlists[1].copyWith(lyricsMode: const Value('transcript'));
    lyrics.hits = [
      LyricsHit(
        trackId: tracks.first.id,
        docId: 3,
        lineId: 30,
        lineNo: 40,
        lineText: 'the mitochondria is the powerhouse',
        positionMs: 3723000,
        score: 0.9,
        kind: LyricsMode.transcript,
      ),
    ];
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transcripts'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'mitochondria');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    final tile = find.byKey(const ValueKey('search-lyrics-3'));
    expect(
      find.descendant(of: tile, matching: find.text('Interview')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.text('1:02:03')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile,
        matching: find.byIcon(Icons.subtitles_outlined),
      ),
      findsOneWidget,
    );
    await tester.tap(tile);
    await tester.pump();
    expect(playback.playedChapterId, 'b');
    expect(playback.playedStartAt, const Duration(milliseconds: 3721000));
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

  group('with the phone font', () {
    setUpAll(loadRoboto);

    testWidgets('the last card scrolls clear of the add button above the '
        'navigation bar', (tester) async {
      await pumpHome(tester);
      usePhoneScreen(tester);
      // Three-button navigation: the list runs on behind the bar, the add
      // button floats above it.
      const navigationBar = 48.0;
      final bar = FakeViewPadding(
        bottom: navigationBar * tester.view.devicePixelRatio,
      );
      tester.view.padding = bar;
      tester.view.viewPadding = bar;
      await tester.pumpAndSettle();
      final screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final fab = find.byKey(const ValueKey('home-add-playlist'));

      Future<void> expectLastCardClear() async {
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -3000),
        );
        await tester.pumpAndSettle();
        final settings = find.descendant(
          of: card(5),
          matching: find.byTooltip('Playlist settings'),
        );
        expect(
          tester.getRect(settings).bottom,
          lessThan(tester.getRect(fab).top),
        );
        final visibleBottom =
            screenHeight -
            navigationBar -
            audioPlayerOverlayHeightNotifier.value;
        expect(tester.getRect(card(5)).bottom, lessThan(visibleBottom));
      }

      await expectLastCardClear();
      // And with the audio panel open over the page.
      audioPlayerOverlayHeightNotifier.value = 300;
      await tester.pumpAndSettle();
      await expectLastCardClear();
    });

    testWidgets('search: a long playlist name is not cut', (tester) async {
      const name = 'less socially acceptable masterpieces and other oddities';
      final long = await insertTestPlaylist(db, url: 'list-long', name: name);
      playlists.add(long);
      await pumpHome(tester);
      usePhoneScreen(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'socially');
      await tester.pump();
      final title = find.text(name, findRichText: true);
      expect(title, findsOneWidget);
      expectNotCut(tester, title);
    });
  });
}

class _Playback implements PlaybackService {
  int? played;
  String? playedChapterId;
  Duration? playedStartAt;
  final playedEntries = <List<QueueEntry>>[];
  final enqueuedEntries = <List<QueueEntry>>[];

  @override
  Future<void> playEntries(List<QueueEntry> entries) async =>
      playedEntries.add(entries);

  @override
  Future<int> enqueueEntries(
    List<QueueEntry> entries, {
    bool first = false,
  }) async {
    enqueuedEntries.add(entries);
    return entries.length;
  }

  @override
  Future<bool> startUpNextQueueIfIdle() async => false;

  @override
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
    String? chapterId,
    bool whole = false,
    Duration? startAt,
  }) async {
    played = track.id;
    playedChapterId = chapterId;
    playedStartAt = startAt;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LyricsSearch implements LyricsSearch {
  List<LyricsHit> hits = const [];
  final queries = <String>[];

  @override
  Future<List<LyricsHit>> search(
    String query, {
    int? playlistId,
    int limit = 50,
  }) async {
    queries.add(query);
    return hits;
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
    bool scheduled = false,
  }) async {
    started.add(playlist.name);
    return DownloadStart.started;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
