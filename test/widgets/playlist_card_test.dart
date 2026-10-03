import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
