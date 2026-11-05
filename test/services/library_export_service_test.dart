import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/settings_page.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/library_export_service.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/media_thumbnail_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/thumbnail_backfill_service.dart';

import '../helpers/test_database.dart';

const _jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46];

class _FakeMediaThumbnails extends MediaThumbnailService {
  final embedded = <String, List<int>>{};

  @override
  Future<String?> extractEmbeddedThumbnail({
    required String mediaPath,
    required String targetStem,
  }) async {
    final bytes = embedded[mediaPath];
    if (bytes == null) return null;
    final path = '$targetStem.jpg';
    await File(path).writeAsBytes(bytes);
    return path;
  }
}

void main() {
  late Directory tempDir;
  late String audioBase;
  late String videoBase;
  late AppDatabase db;
  late _FakeMediaThumbnails media;
  late DateTime now;

  LibraryExportService exporterFor(AppDatabase database) {
    final metadata = MetadataService(database);
    return LibraryExportService(
      database,
      metadata,
      ThumbnailBackfillService(
        database,
        metadata,
        media,
        LogService(),
        lookupCachedImage: (_) async => null,
        downloadImage: (_, __) async => false,
      ),
      AppSettingsService(),
      LogService(),
      clock: () => now,
    );
  }

  Future<Playlist> addPlaylist(
    AppDatabase database,
    String name, {
    bool audioOnly = true,
    int tracks = 1,
    bool createFolder = true,
  }) async {
    final folder = p.join(audioOnly ? audioBase : videoBase, name);
    if (createFolder) await Directory(folder).create(recursive: true);
    final playlist = await insertTestPlaylist(
      database,
      url: 'https://www.youtube.com/playlist?list=$name',
      name: name,
      audioOnly: audioOnly,
      outputPath: folder,
    );
    for (var i = 1; i <= tracks; i++) {
      final file = p.join(
        folder,
        '0000${i}_$name $i.${audioOnly ? 'm4a' : 'mp4'}',
      );
      if (createFolder) await File(file).writeAsBytes(const [1, 2, 3]);
      await insertTestTrack(
        database,
        playlistId: playlist.id,
        index: i,
        videoId: '$name-$i',
        title: '$name $i',
        filePath: file,
        status: 'complete',
      );
    }
    return playlist;
  }

  String backupDir() => p.join(audioBase, LibraryExportService.backupDirName);

  List<String> backupNames() =>
      Directory(
          backupDir(),
        ).listSync().map((entity) => p.basename(entity.path)).toList()
        ..sort();

  setUpAll(() {
    // The tests open database copies next to the live one on purpose.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('woolytube_export_test');
    audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
    videoBase = p.join(tempDir.path, 'Movies', 'WoolyTube');
    LibraryLayout.overrideBasePathsForTesting(
      audio: audioBase,
      video: videoBase,
    );
    SharedPreferences.setMockInitialValues({
      AppSettingsService.downloadSubtitlesKey: true,
      AppSettingsService.subtitleLanguagesKey: 'en,hu',
      AppSettingsService.dismissedImportUrlsKey: [
        'https://www.youtube.com/playlist?list=gone',
      ],
    });
    db = openTestDatabase();
    media = _FakeMediaThumbnails();
    now = DateTime(2026, 11, 5, 14, 30);
  });

  tearDown(() async {
    await db.close();
    LibraryLayout.resetBasePathsForTesting();
    await tempDir.delete(recursive: true);
  });

  test('writes sidecars, playlist files, covers, a database copy and the '
      'settings', () async {
    final music = await addPlaylist(db, 'Music', tracks: 2);
    final videos = await addPlaylist(db, 'Videos', audioOnly: false);
    final firstTrack = (await db.getTracksForPlaylist(music.id)).first;
    media.embedded[firstTrack.filePath!] = _jpeg;
    final progress = <int>[];

    final result = await exporterFor(
      db,
    ).exportLibrary(onProgress: (update) => progress.add(update.done));

    expect(result.problems, isEmpty);
    expect(result.playlists, 2);
    expect(result.tracks, 3);
    expect(result.trackCovers, 1);
    // The first track's cover became the playlist cover.
    expect(result.playlistCovers, 1);
    expect(result.newCovers, 2);
    expect(progress, [0, 1, 2]);

    for (final playlist in [music, videos]) {
      expect(
        File(
          p.join(playlist.outputPath, MetadataService.metaFileName),
        ).existsSync(),
        isTrue,
      );
    }
    final m3u = File(MetadataService.playlistFilePath(music.outputPath));
    expect(m3u.readAsLinesSync().where((line) => !line.startsWith('#')), [
      '00001_Music 1.m4a',
      '00002_Music 2.m4a',
    ]);

    final copyPath = p.join(backupDir(), 'woolytube-20261105-1430.sqlite');
    expect(result.databaseCopyPath, copyPath);
    final copy = AppDatabase.forTesting(NativeDatabase(File(copyPath)));
    addTearDown(copy.close);
    expect((await copy.getAllPlaylists()).map((pl) => pl.name), [
      'Music',
      'Videos',
    ]);
    expect(await copy.getAllTracks(), hasLength(3));

    final settingsPath = p.join(
      backupDir(),
      LibraryExportService.settingsFileName,
    );
    expect(result.settingsPath, settingsPath);
    final settings =
        (jsonDecode(File(settingsPath).readAsStringSync())
                as Map<String, dynamic>)['settings']
            as Map<String, dynamic>;
    expect(settings[AppSettingsService.downloadSubtitlesKey], true);
    expect(settings[AppSettingsService.subtitleLanguagesKey], 'en,hu');
    expect(settings[AppSettingsService.dismissedImportUrlsKey], [
      'https://www.youtube.com/playlist?list=gone',
    ]);

    expect(backupNames(), [
      '.nomedia',
      'woolytube-20261105-1430.sqlite',
      LibraryExportService.settingsFileName,
    ]);
  });

  test('keeps only the newest three database copies', () async {
    await addPlaylist(db, 'Music');
    await Directory(backupDir()).create(recursive: true);
    for (final name in [
      'woolytube-20260101-0900.sqlite',
      'woolytube-20260301-0900.sqlite',
      'woolytube-20260201-0900.sqlite',
      'notes.txt',
    ]) {
      File(p.join(backupDir(), name)).writeAsStringSync('old');
    }
    final exporter = exporterFor(db);

    await exporter.writeDatabaseCopy();
    now = DateTime(2026, 11, 6, 8, 5);
    await exporter.writeDatabaseCopy();

    expect(backupNames(), [
      '.nomedia',
      'notes.txt',
      'woolytube-20260301-0900.sqlite',
      'woolytube-20261105-1430.sqlite',
      'woolytube-20261106-0805.sqlite',
    ]);
  });

  test('a playlist that cannot be exported does not stop the rest', () async {
    await addPlaylist(db, 'Gone', createFolder: false);
    final kept = await addPlaylist(db, 'Kept');

    final result = await exporterFor(db).exportLibrary();

    expect(result.playlists, 1);
    expect(result.tracks, 1);
    expect(result.problems, hasLength(1));
    expect(result.problems.single, startsWith('Gone: folder not found'));
    expect(
      File(p.join(kept.outputPath, MetadataService.metaFileName)).existsSync(),
      isTrue,
    );
    expect(result.databaseCopyPath, isNotNull);
    expect(result.settingsPath, isNotNull);
    // The missing folder is not created.
    expect(Directory(p.join(audioBase, 'Gone')).existsSync(), isFalse);
  });

  test('copies a database file through its own folder', () async {
    final dbDir = await Directory(
      p.join(tempDir.path, 'app_data'),
    ).create(recursive: true);
    final fileDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(dbDir.path, 'woolytube.sqlite'))),
    );
    addTearDown(fileDb.close);
    await addPlaylist(fileDb, 'Music', tracks: 2);

    final copyPath = await exporterFor(fileDb).writeDatabaseCopy();

    // The staging copy beside the database is gone again.
    expect(
      dbDir.listSync().map((entity) => p.basename(entity.path)),
      isNot(contains(contains('export'))),
    );
    final copy = AppDatabase.forTesting(NativeDatabase(File(copyPath)));
    addTearDown(copy.close);
    expect(await copy.getAllTracks(), hasLength(2));
  });

  testWidgets('restore lists dismissed playlists and imports them', (
    tester,
  ) async {
    late String folder;
    await tester.runAsync(() async {
      // A playlist folder from an earlier install, dismissed on the home page.
      final earlier = openTestDatabase();
      final playlist = await addPlaylist(earlier, 'Mix', tracks: 2);
      await MetadataService(earlier).writeMetadataFor(playlist.id);
      await earlier.close();
      folder = playlist.outputPath;
      await AppSettingsService().addDismissedImportUrls([playlist.url]);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    // File and database work completes on the real event loop; let it run
    // and rebuild in turns until [done].
    Future<void> waitFor(bool Function() done) async {
      for (var i = 0; i < 50 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Restore playlists'), 100);
    await tester.tap(find.text('Restore playlists'));
    await waitFor(() => find.text('Import').evaluate().isNotEmpty);

    expect(find.text('Mix'), findsOneWidget);
    await tester.tap(find.text('Import'));
    await waitFor(
      () => find.text('Restored "Mix" with 2 tracks.').evaluate().isNotEmpty,
    );

    final playlists = await tester.runAsync(db.getAllPlaylists);
    expect(playlists!.single.outputPath, folder);
    // Only the restored playlist leaves the dismissed list.
    expect(await AppSettingsService().getDismissedImportUrls(), {
      'https://www.youtube.com/playlist?list=gone',
    });
    expect(find.text('Restored "Mix" with 2 tracks.'), findsOneWidget);
    expect(find.text('Import'), findsNothing);
  });
}
