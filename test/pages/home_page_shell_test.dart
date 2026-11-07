import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/home_page.dart';
import 'package:woolytube/pages/playlist_settings_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/update_service.dart';

import '../helpers/player_shell_harness.dart';
import '../helpers/test_database.dart';

/// The home page inside the real player shell: padding against the
/// expanded panel, the long-press menu and its page pushes, and back.
void main() {
  late AppDatabase db;
  late List<Playlist> playlists;

  setUp(() async {
    db = openTestDatabase();
    playlists = [
      for (var i = 1; i <= 8; i++)
        await insertTestPlaylist(db, url: 'list-$i', name: 'Playlist $i'),
    ];
  });

  tearDown(() => db.close());

  Future<PlayerShellHarness> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(411 * 3, 860 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    return pumpPlayerShell(
      tester,
      home: const HomePage(),
      overrides: [
        databaseProvider.overrideWithValue(db),
        updateServiceProvider.overrideWithValue(_Updates()),
        playlistsProvider.overrideWith((ref) => Stream.value(playlists)),
        allTracksProvider.overrideWith((ref) => Stream.value(const <Track>[])),
        playlistTrackCountsStreamProvider.overrideWith(
          (ref) => Stream.value(const <int, PlaylistCounts>{}),
        ),
        syncingPlaylistsProvider.overrideWith(
          (ref) => Stream.value(const <int>{}),
        ),
        downloadQueueProvider.overrideWith(
          (ref) => Stream.value(const <int>[]),
        ),
        downloadProgressProvider.overrideWith(
          (ref) => const Stream<DownloadProgress>.empty(),
        ),
      ],
    );
  }

  Finder card(int i) =>
      find.byKey(ValueKey('playlist-card-${playlists[i].id}'));

  bool systemPopped(PlayerShellHarness harness) =>
      harness.systemCalls.any((call) => call.method == 'SystemNavigator.pop');

  testWidgets('the last card and the add button stay above the expanded '
      'panel', (tester) async {
    final harness = await pumpHome(tester);
    final shell = harness.shellState(tester);
    shell.expand();
    await tester.pumpAndSettle();
    expect(audioPlayerOverlayHeightNotifier.value, greaterThan(0));

    final panelTop = shell.geometry.size.height - shell.geometry.panelHeight;
    final fab = find.byKey(const ValueKey('home-add-playlist'));
    expect(tester.getRect(fab).bottom, lessThanOrEqualTo(panelTop));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    // Still expanded: scrolling the page does not close the panel.
    expect(shell.isExpanded, isTrue);
    final settings = find.descendant(
      of: card(7),
      matching: find.byTooltip('Playlist settings'),
    );
    expect(tester.getRect(settings).bottom, lessThan(tester.getRect(fab).top));
    expect(tester.getRect(card(7)).bottom, lessThan(panelTop));
  });

  testWidgets('the long-press menu covers the player and opens pages in the '
      'page navigator', (tester) async {
    final harness = await pumpHome(tester);
    final rootNavigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );

    await tester.longPress(card(1));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('playlist-menu-settings')),
      findsOneWidget,
    );
    // The sheet is on the root navigator, above the player.
    expect(rootNavigator.canPop(), isTrue);
    expect(harness.pagesKey.currentState!.canPop(), isTrue);

    await tester.tap(find.byKey(const ValueKey('playlist-menu-settings')));
    await tester.pumpAndSettle();
    expect(rootNavigator.canPop(), isFalse);
    expect(find.byType(PlaylistSettingsPage), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(harness.pagesKey),
        matching: find.byType(PlaylistSettingsPage),
      ),
      findsOneWidget,
    );

    // Back returns to the home page, not out of the app.
    final app = tester.state(find.byType(WidgetsApp)) as WidgetsBindingObserver;
    await app.didPopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistSettingsPage), findsNothing);
    expect(card(1), findsOneWidget);
    expect(systemPopped(harness), isFalse);
  });

  testWidgets('back collapses the panel, then closes the search, then leaves', (
    tester,
  ) async {
    final harness = await pumpHome(tester);
    final shell = harness.shellState(tester);
    final app = tester.state(find.byType(WidgetsApp)) as WidgetsBindingObserver;

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    shell.expand();
    await tester.pumpAndSettle();

    await app.didPopRoute();
    await tester.pumpAndSettle();
    expect(shell.isExpanded, isFalse);
    expect(find.byType(TextField), findsOneWidget);

    await app.didPopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(card(0), findsOneWidget);
    expect(systemPopped(harness), isFalse);

    await app.didPopRoute();
    await tester.pumpAndSettle();
    expect(systemPopped(harness), isTrue);
  });
}

class _Updates implements UpdateService {
  @override
  Future<AppUpdate?> checkForUpdate({String? currentVersion}) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
