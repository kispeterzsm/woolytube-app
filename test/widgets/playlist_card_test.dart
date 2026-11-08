import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/widgets/playlist_card.dart';

import '../helpers/test_database.dart';

void main() {
  Future<void> pumpCard(
    WidgetTester tester,
    PlaylistCard card, {
    double textScale = 1,
    double width = 411,
  }) async {
    tester.view.physicalSize = Size(width * 3, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 800),
            devicePixelRatio: 3,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: ListView(padding: const EdgeInsets.all(12), children: [card]),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows update, checking, queued and download states', (
    tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(db);
    var updates = 0;
    var cancels = 0;

    PlaylistCard card(PlaylistCardActivity activity) => PlaylistCard(
      playlist: playlist,
      counts: const PlaylistCounts(total: 3, downloaded: 1),
      activity: activity,
      runIndex: 2,
      runTotal: 2,
      progress: 0.75,
      onTap: () {},
      onUpdate: () => updates++,
      onCancel: () => cancels++,
      onSettings: () {},
    );

    await pumpCard(tester, card(PlaylistCardActivity.idle));
    expect(find.byTooltip('Update now'), findsOneWidget);
    expect(find.byTooltip('Playlist settings'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist-card-progress')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlist-card-update')));
    expect(updates, 1);

    await pumpCard(tester, card(PlaylistCardActivity.syncing));
    expect(find.byTooltip('Checking for new videos'), findsOneWidget);
    expect(find.text('Checking for new videos…'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist-card-update')), findsNothing);

    await pumpCard(tester, card(PlaylistCardActivity.queued));
    expect(find.text('Queued after the current download'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist-card-progress')), findsNothing);

    await pumpCard(tester, card(PlaylistCardActivity.downloading));
    expect(find.text('Downloading 2 of 2'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('playlist-card-progress')),
    );
    expect(bar.value, 0.75);
    await tester.tap(find.byKey(const ValueKey('playlist-card-cancel')));
    expect(cancels, 1);

    await pumpCard(tester, card(PlaylistCardActivity.finishing));
    expect(find.text('Finishing up…'), findsOneWidget);
    expect(find.byTooltip('Stop download'), findsOneWidget);
    expect(updates, 1);
  });

  testWidgets('counts against the tracks that can still be downloaded', (
    tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final now = DateTime.now();
    final playlist = await insertTestPlaylist(db);
    final updated = playlist.copyWith(
      lastUpdated: Value(now.subtract(const Duration(days: 3))),
    );

    PlaylistCard card(PlaylistCounts? counts, {bool loaded = true}) =>
        PlaylistCard(
          playlist: updated,
          counts: counts,
          countsLoaded: loaded,
          onTap: () {},
          onUpdate: () {},
          onSettings: () {},
        );

    // The owner's case: 2 videos removed from YouTube no longer leave the
    // playlist at "662/664" forever.
    await pumpCard(
      tester,
      card(const PlaylistCounts(total: 664, downloaded: 662, unavailable: 2)),
    );
    expect(find.text('662 tracks · updated 3d ago'), findsOneWidget);
    expect(find.text('2 unavailable'), findsOneWidget);

    await pumpCard(
      tester,
      card(
        const PlaylistCounts(
          total: 600,
          downloaded: 580,
          unavailable: 5,
          failed: 3,
        ),
      ),
    );
    expect(find.text('580 of 595 downloaded · updated 3d ago'), findsOneWidget);
    expect(find.text('3 failed · 5 unavailable'), findsOneWidget);

    // No flash of "Not updated yet" while the counts load.
    await pumpCard(tester, card(null, loaded: false));
    expect(
      find.byKey(const ValueKey('playlist-card-counts-loading')),
      findsOneWidget,
    );
    expect(find.textContaining('Not updated'), findsNothing);

    final fresh = await insertTestPlaylist(db, url: 'fresh');
    await pumpCard(
      tester,
      PlaylistCard(
        playlist: fresh,
        onTap: () {},
        onUpdate: () {},
        onSettings: () {},
      ),
    );
    expect(find.text('Not updated yet'), findsOneWidget);
  });

  test('timeAgo', () {
    final now = DateTime(2026, 11, 7, 12);
    expect(timeAgo(now.subtract(const Duration(seconds: 5)), now), 'just now');
    expect(timeAgo(now.subtract(const Duration(minutes: 5)), now), '5m ago');
    expect(timeAgo(now.subtract(const Duration(hours: 5)), now), '5h ago');
    expect(timeAgo(now.subtract(const Duration(days: 2)), now), '2d ago');
    expect(timeAgo(DateTime(2026, 3, 14), now), 'Mar 14');
    expect(timeAgo(DateTime(2025, 3, 14), now), 'Mar 14 2025');
  });

  testWidgets('long press opens a menu with the card actions', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(db, name: 'Road trip');
    final calls = <String>[];

    await pumpCard(
      tester,
      PlaylistCard(
        playlist: playlist,
        counts: const PlaylistCounts(total: 1, downloaded: 1),
        onTap: () => calls.add('open'),
        onUpdate: () => calls.add('update'),
        onSettings: () => calls.add('settings'),
        onOpenOnYouTube: () => calls.add('youtube'),
        onReorder: () => calls.add('reorder'),
      ),
    );

    for (final (key, call) in [
      ('playlist-menu-update', 'update'),
      ('playlist-menu-settings', 'settings'),
      ('playlist-menu-reorder', 'reorder'),
      ('playlist-menu-youtube', 'youtube'),
    ]) {
      await tester.longPress(find.text('Road trip'));
      await tester.pumpAndSettle();
      expect(find.text('Open on YouTube'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(calls.last, call);
      expect(find.text('Open on YouTube'), findsNothing);
    }

    await tester.tap(find.text('Road trip'));
    expect(calls.last, 'open');
  });

  testWidgets('the menu has no reorder entry without a reorder action', (
    tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(db, name: 'Only one');

    await pumpCard(
      tester,
      PlaylistCard(
        playlist: playlist,
        onTap: () {},
        onUpdate: () {},
        onSettings: () {},
      ),
    );
    await tester.longPress(find.text('Only one'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('playlist-menu-settings')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('playlist-menu-reorder')), findsNothing);
  });

  testWidgets('marks the playlist that is playing', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(db);

    PlaylistCard card({required bool nowPlaying, bool playing = true}) =>
        PlaylistCard(
          playlist: playlist,
          isNowPlaying: nowPlaying,
          isPlaying: playing,
          onTap: () {},
          onUpdate: () {},
          onSettings: () {},
        );

    await pumpCard(tester, card(nowPlaying: false));
    expect(
      find.byKey(const ValueKey('playlist-card-now-playing')),
      findsNothing,
    );

    await pumpCard(tester, card(nowPlaying: true));
    expect(
      find.byKey(const ValueKey('playlist-card-now-playing')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.equalizer), findsOneWidget);

    await pumpCard(tester, card(nowPlaying: true, playing: false));
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  testWidgets('grows with large text instead of clipping', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(
      db,
      name: 'A rather long playlist name that needs two full lines here',
    );
    final card = PlaylistCard(
      playlist: playlist.copyWith(lastUpdated: Value(DateTime.now())),
      counts: const PlaylistCounts(
        total: 20,
        downloaded: 10,
        unavailable: 1,
        failed: 1,
      ),
      onTap: () {},
      onUpdate: () {},
      onSettings: () {},
    );

    await pumpCard(tester, card, width: 360);
    final normal = tester.getSize(find.byType(PlaylistCard)).height;
    expect(tester.takeException(), isNull);

    await pumpCard(tester, card, width: 360, textScale: 1.6);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(PlaylistCard)).height,
      greaterThan(normal),
    );
    // Both buttons stay reachable.
    expect(find.byTooltip('Update now'), findsOneWidget);
    expect(find.byTooltip('Playlist settings'), findsOneWidget);
  });

  testWidgets('the status line is not cut short on a narrow phone', (
    tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(db, name: 'Long list');
    final now = DateTime.now();
    await pumpCard(
      tester,
      PlaylistCard(
        playlist: playlist.copyWith(
          lastUpdated: Value(now.subtract(const Duration(days: 3))),
        ),
        counts: const PlaylistCounts(total: 600, downloaded: 0),
        onTap: () {},
        onUpdate: () {},
        onSettings: () {},
      ),
      width: 360,
    );
    final status = find.byKey(const ValueKey('playlist-card-status'));
    expect(
      tester.widget<Text>(status).data,
      '0 of 600 downloaded · updated 3d ago',
    );
    // Room for two lines (the test font is too wide to measure the real
    // wrap), and the card grows for them.
    expect(tester.widget<Text>(status).maxLines, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the saved cover before the YouTube image', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final dir = Directory.systemTemp.createTempSync('woolytube_card_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cover = File('${dir.path}/_playlist_cover.jpg')
      ..writeAsBytesSync([0]);

    Future<void> pump(Playlist playlist) => pumpCard(
      tester,
      PlaylistCard(
        playlist: playlist,
        onTap: () {},
        onUpdate: () {},
        onSettings: () {},
      ),
    );

    await pump(
      await insertTestPlaylist(
        db,
        thumbnailUrl: 'https://example.com/cover.jpg',
        thumbnailPath: cover.path,
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    // Decoded at the size it is shown, not at the file's full size.
    expect(image.image, isA<ResizeImage>());
    final resized = image.image as ResizeImage;
    expect(resized.imageProvider, isA<FileImage>());
    expect((resized.imageProvider as FileImage).file.path, cover.path);
    expect(resized.width, 136 * 3);

    // A cover file that is gone falls back to the YouTube image.
    await pump(
      await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=other',
        thumbnailUrl: 'https://example.com/cover.jpg',
        thumbnailPath: '${dir.path}/missing.jpg',
      ),
    );
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(
      tester
          .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .memCacheWidth,
      136 * 3,
    );
  });
}
