import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/widgets/playlist_card.dart';

import '../helpers/test_database.dart';

void main() {
  testWidgets('shows sync, syncing, and cancel states', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(db);
    var updates = 0;
    var cancels = 0;

    Future<void> pump({
      required bool isDownloading,
      required bool isSyncing,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistCard(
              playlist: playlist,
              downloadedCount: 1,
              totalCount: 3,
              isDownloading: isDownloading,
              isSyncing: isSyncing,
              downloadProgress: 40,
              onTap: () {},
              onUpdate: () => updates++,
              onCancel: () => cancels++,
              onSettings: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pump(isDownloading: false, isSyncing: false);
    expect(find.byTooltip('Update playlist'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-card-update')));
    expect(updates, 1);

    await pump(isDownloading: false, isSyncing: true);
    expect(find.byTooltip('Syncing playlist'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Syncing...'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist-card-update')), findsNothing);

    await pump(isDownloading: true, isSyncing: false);
    expect(find.byTooltip('Cancel download'), findsOneWidget);
    expect(find.text('Downloading 1 / 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-card-cancel')));
    expect(cancels, 1);
    expect(updates, 1);
  });

  testWidgets('shows the saved cover before the YouTube image', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final dir = Directory.systemTemp.createTempSync('woolytube_card_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cover = File('${dir.path}/_playlist_cover.jpg')
      ..writeAsBytesSync([0]);

    Future<void> pump(Playlist playlist) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistCard(
              playlist: playlist,
              downloadedCount: 0,
              totalCount: 0,
              isDownloading: false,
              downloadProgress: 0,
              onTap: () {},
              onUpdate: () {},
              onSettings: () {},
            ),
          ),
        ),
      );
    }

    await pump(
      await insertTestPlaylist(
        db,
        thumbnailUrl: 'https://example.com/cover.jpg',
        thumbnailPath: cover.path,
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<FileImage>());
    expect((image.image as FileImage).file.path, cover.path);

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
  });
}
