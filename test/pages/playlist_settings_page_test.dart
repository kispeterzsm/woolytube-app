import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/playlist_settings_page.dart';
import 'package:woolytube/pages/sponsorblock_settings_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/sponsorblock_categories.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late _Playlists playlists;
  late _Player player;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp(
      'woolytube_playlist_settings_test_',
    );
    playlists = _Playlists(db);
    player = _Player();
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Pumps a home marker route, a detail marker route, and the settings page
  /// on top, mirroring the real navigation stack.
  Future<void> pumpStack(WidgetTester tester, int playlistId) async {
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
          downloadServiceProvider.overrideWithValue(_Downloads()),
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
  });
}

/// Records settings writes and applies them to the test database, like the
/// real service minus the file work.
class _Playlists implements PlaylistService {
  _Playlists(this.db);

  final AppDatabase db;
  final calls = <Map<String, Object?>>[];
  final deletedIds = <int>[];
  final deleteFilesFlags = <bool>[];
  Exception? failWith;

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
  }) async {
    final failure = failWith;
    if (failure != null) throw failure;
    calls.add({
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
    });
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
          )
          .toCompanion(true),
    );
  }

  @override
  Future<List<Track>> getTracksForPlaylist(int playlistId) =>
      db.getTracksForPlaylist(playlistId);

  @override
  Future<void> deletePlaylist(int id, {bool deleteFiles = false}) async {
    deletedIds.add(id);
    deleteFilesFlags.add(deleteFiles);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements PlaybackService {
  final settingsChanged = <int>[];

  @override
  Future<void> playlistSettingsChanged(int playlistId) async {
    settingsChanged.add(playlistId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads implements DownloadService {
  @override
  bool get isDownloading => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
