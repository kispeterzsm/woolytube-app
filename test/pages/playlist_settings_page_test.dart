import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/playlist_settings_page.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/playlist_service.dart';

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

  /// Pumps a home marker route, a detail marker route, and the settings page
  /// on top, mirroring the real navigation stack.
  Future<void> pumpStack(
    WidgetTester tester,
    int playlistId, {
    PlaylistService? playlistService,
  }) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          if (playlistService != null)
            playlistServiceProvider.overrideWithValue(playlistService),
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

  Finder switchFor(String title) => find.descendant(
    of: find.ancestor(of: find.text(title), matching: find.byType(Row)),
    matching: find.byType(Switch),
  );

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

  testWidgets('Save is disabled while the name is empty', (tester) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);

    final save = find.byKey(const ValueKey('playlist-settings-save'));
    expect(tester.widget<TextButton>(save).enabled, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey('playlist-name-field')),
      '   ',
    );
    await tester.pump();
    expect(tester.widget<TextButton>(save).enabled, isFalse);
    expect(find.text('Enter a name'), findsOneWidget);
  });

  testWidgets('leaving with unsaved changes asks for confirmation', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);

    // Clean page: back leaves immediately.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('detail marker'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpStack(tester, playlist.id);
    await tester.tap(switchFor('Include thumbnails').first);
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Playlist Settings'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('detail marker'), findsOneWidget);
  });

  testWidgets('turning on audio only asks before re-downloading', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await pumpStack(tester, playlist.id);

    final audioSwitch = switchFor('Audio only');
    await tester.tap(audioSwitch.first);
    await tester.pumpAndSettle();
    expect(find.text('Switch to audio only?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(audioSwitch.first).value, isFalse);

    await tester.tap(audioSwitch.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(audioSwitch.first).value, isTrue);
  });

  testWidgets('delete offers file removal and returns to the home page', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    final service = _Playlists();
    await pumpStack(tester, playlist.id, playlistService: service);

    final deleteButton = find.byKey(const ValueKey('delete-playlist-button'));
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    expect(find.text('Also delete downloaded files'), findsOneWidget);
    expect(find.textContaining('Downloaded files are kept'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-files-checkbox')));
    await tester.pumpAndSettle();
    expect(find.textContaining('deletes its downloaded files'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-playlist-confirm')));
    await tester.pumpAndSettle();

    expect(service.deletedIds, [playlist.id]);
    expect(service.deleteFilesFlags, [true]);
    expect(find.text('home marker'), findsOneWidget);
    expect(find.text('detail marker'), findsNothing);
  });
}

class _Playlists implements PlaylistService {
  final deletedIds = <int>[];
  final deleteFilesFlags = <bool>[];

  @override
  Future<void> deletePlaylist(int id, {bool deleteFiles = false}) async {
    deletedIds.add(id);
    deleteFilesFlags.add(deleteFiles);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
