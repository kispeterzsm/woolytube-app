import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/playlist_settings_page.dart';
import 'package:woolytube/providers/providers.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp(
      'woolytube_playlist_settings_test_',
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('Force Insert asks for an index before file selection', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await insertTestTrack(db, playlistId: playlist.id, index: 1);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: PlaylistSettingsPage(playlistId: playlist.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final forceInsertButton = find.byKey(const ValueKey('force-insert-button'));
    expect(forceInsertButton, findsOneWidget);
    expect(find.text('Force Insert'), findsOneWidget);
    await tester.ensureVisible(forceInsertButton);
    await tester.tap(forceInsertButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byKey(const ValueKey('force-insert-index-field')),
      findsOneWidget,
    );
    expect(find.text('Select file'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('force-insert-index-field')),
      '3',
    );
    await tester.tap(find.byKey(const ValueKey('force-insert-select-file')));
    await tester.pump();
    expect(find.text('Enter a number from 1 to 2.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
