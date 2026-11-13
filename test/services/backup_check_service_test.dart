import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/settings_page.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/backup_check_service.dart';
import 'package:woolytube/services/folder_write_errors.dart';
import 'package:woolytube/services/info_backfill_service.dart';
import 'package:woolytube/services/library_export_service.dart';
import 'package:woolytube/services/library_file.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/lyrics/lyrics_files.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_service.dart'
    show persistLyricsFile;
import 'package:woolytube/services/media_thumbnail_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playback_settings_store.dart';
import 'package:woolytube/services/sidecar_mirror.dart';
import 'package:woolytube/services/thumbnail_backfill_service.dart';

import '../helpers/test_database.dart';

const _jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46];

/// "Check backup" finds what the library folders lack without writing
/// anything, and "Fix" writes it without a database copy.
void main() {
  late Directory tempDir;
  late String audioBase;
  late String videoBase;
  late AppDatabase db;
  late LogService log;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      AppSettingsService.evenOutVolumeKey: true,
    });
    FolderWriteErrors.clearForTesting();
    tempDir = await Directory.systemTemp.createTemp('woolytube_check_');
    audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
    videoBase = p.join(tempDir.path, 'Movies', 'WoolyTube');
    LibraryLayout.overrideBasePathsForTesting(
      audio: audioBase,
      video: videoBase,
    );
    db = openTestDatabase();
    log = LogService.memoryOnly();
  });

  tearDown(() async {
    await db.close();
    FolderWriteErrors.clearForTesting();
    LibraryLayout.resetBasePathsForTesting();
    await tempDir.delete(recursive: true);
  });

  ({
    BackupCheckService service,
    LibraryExportService exporter,
    LibraryFileService libraryFile,
    MetadataService metadata,
  })
  servicesFor({bool waitsForRestore = false, InfoBackfillStore? infoStore}) {
    final metadata = MetadataService(db);
    final exporter = LibraryExportService(
      db,
      metadata,
      ThumbnailBackfillService(
        db,
        metadata,
        const MediaThumbnailService(),
        log,
        lookupCachedImage: (_) async => null,
        downloadImage: (_, __) async => false,
      ),
      AppSettingsService(),
      log,
    );
    final libraryFile = LibraryFileService(
      db,
      log: log,
      playbackStore: SharedPreferencesPlaybackSettingsStore(),
    );
    return (
      service: BackupCheckService(
        db,
        metadata,
        exporter,
        libraryFile,
        LibraryGate.unlocked(),
        log: log,
        libraryWaitsForRestore: () => waitsForRestore,
        infoBackfill: infoStore,
      ),
      exporter: exporter,
      libraryFile: libraryFile,
      metadata: metadata,
    );
  }

  /// A playlist folder with downloaded tracks; each has a cover and its
  /// YouTube info unless listed in [withoutCover].
  Future<Playlist> addPlaylist(
    String name, {
    int tracks = 2,
    Set<int> withoutCover = const {},
    bool createFolder = true,
  }) async {
    final folder = p.join(audioBase, name);
    final covers = LibraryLayout.thumbnailsDir(folder);
    if (createFolder) {
      await Directory(covers).create(recursive: true);
      await Directory(LibraryLayout.infoDir(folder)).create();
      await File(p.join(covers, '_playlist_cover.jpg')).writeAsBytes(_jpeg);
    }
    final playlist = await insertTestPlaylist(
      db,
      url: 'https://www.youtube.com/playlist?list=$name',
      name: name,
      audioOnly: true,
      outputPath: folder,
      thumbnailPath: p.join(covers, '_playlist_cover.jpg'),
    );
    for (var i = 1; i <= tracks; i++) {
      final videoId = '$name-$i';
      final file = p.join(folder, '0000${i}_$name $i.m4a');
      String? cover;
      if (createFolder) {
        await File(file).writeAsBytes(const [1, 2, 3]);
        await File(
          LibraryLayout.infoJsonPath(folder, videoId),
        ).writeAsString('{}');
        if (!withoutCover.contains(i)) {
          cover = p.join(covers, '$videoId.jpg');
          await File(cover).writeAsBytes(_jpeg);
        }
      }
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: i,
        videoId: videoId,
        title: '$name $i',
        filePath: file,
        thumbnailPath: cover,
        status: 'complete',
      );
    }
    return playlist;
  }

  LyricsDocDraft draft(
    int trackId,
    List<String> lines, {
    String? chapterId,
    int offsetMs = 0,
  }) => LyricsDocDraft(
    trackId: trackId,
    chapterId: chapterId,
    offsetMs: offsetMs,
    kind: LyricsMode.lyrics,
    status: LyricsStatus.found,
    source: LyricsSource.lrclib,
    sourceRef: '42',
    synced: true,
    checkedAt: DateTime.utc(2026, 11, 1),
    lines: [
      for (var i = 0; i < lines.length; i++)
        LyricsLineDraft(lines[i], startMs: i * 1000),
    ],
  );

  /// Every file under the temporary folder with its size and time.
  Map<String, String> snapshot() => {
    for (final entity in tempDir.listSync(recursive: true))
      if (entity is File)
        entity.path:
            '${entity.lengthSync()} ${entity.lastModifiedSync().microsecondsSinceEpoch}',
  };

  Future<Track> trackOf(Playlist playlist, int index) async => (await db
      .getTracksForPlaylist(playlist.id)).firstWhere((t) => t.index == index);

  test('a library the mirrors kept up to date is complete', () async {
    final mix = await addPlaylist('Mix');
    final song = await trackOf(mix, 1);
    await db.replaceLyricsDoc(draft(song.id, ['la la']));
    await persistLyricsFile(db, song.id);
    final s = servicesFor();
    await s.metadata.writeMetadataFor(mix.id);
    await s.exporter.writeSettingsFile();
    await s.libraryFile.write();

    final report = await s.service.check();

    expect(report.problems, isEmpty);
    expect(report.needsFix, isFalse);
    expect(report.tracks, 2);
    expect(report.settingsUpToDate, isTrue);
    expect(report.libraryFiles.map((f) => f.upToDate), [true]);
    expect(report.writeErrors, isEmpty);
    expect(report.oldDatabaseCopies, 0);
    expect(report.lastUpdated, isNotNull);
    expect(report.playlists.single.missingInfoFiles, 0);
  });

  test('finds what is missing without writing, and Fix writes it', () async {
    final mix = await addPlaylist('Mix', withoutCover: {2});
    final song = await trackOf(mix, 1);
    // The reference: what the lyrics service writes for these docs.
    await db.replaceLyricsDoc(
      draft(song.id, ['chorus'], chapterId: 'ch2', offsetMs: 60000),
    );
    await db.replaceLyricsDoc(draft(song.id, ['first', 'second']));
    await persistLyricsFile(db, song.id);
    final lyricsPath = LibraryLayout.lyricsJsonPath(mix.outputPath, 'Mix-1');
    final expectedLyrics = File(lyricsPath).readAsStringSync();
    File(lyricsPath).deleteSync();
    // A database copy an older version made, which stays.
    final backup = Directory(LibraryExportService.backupDir)
      ..createSync(recursive: true);
    File(
      p.join(backup.path, 'woolytube-20261108-0746.sqlite'),
    ).writeAsStringSync('old copy');
    final s = servicesFor();
    final before = snapshot();

    final report = await s.service.check();

    expect(snapshot(), before, reason: 'a check writes nothing');
    expect(report.needsFix, isTrue);
    expect(report.problems, [
      '"Mix": playlist files out of date',
      '"Mix": 1 track without a cover',
      '"Mix": 1 lyrics file missing',
      'Settings file missing',
      'Library file missing in Music/WoolyTube',
    ]);
    expect(report.oldDatabaseCopies, 1);
    expect(report.oldDatabaseCopyBytes, 8);

    final fixed = await s.service.fix();
    final after = await s.service.check();

    expect(fixed.problems, isEmpty);
    expect(fixed.settingsPath, isNotNull);
    // No cover can be found for the second track offline.
    expect(after.problems, ['"Mix": 1 track without a cover']);
    expect(File(lyricsPath).readAsStringSync(), expectedLyrics);
    expect(
      File(p.join(mix.outputPath, MetadataService.metaFileName)).existsSync(),
      isTrue,
    );
    // No new database copy; the old one is untouched.
    expect(
      backup
          .listSync()
          .map((e) => p.basename(e.path))
          .where((name) => name.endsWith('.sqlite')),
      ['woolytube-20261108-0746.sqlite'],
    );
    expect(
      File(
        p.join(backup.path, 'woolytube-20261108-0746.sqlite'),
      ).readAsStringSync(),
      'old copy',
    );
  });

  test('sidecar edits and a newer sidecar are told apart', () async {
    final mix = await addPlaylist('Mix');
    final other = await addPlaylist('Other');
    final s = servicesFor();
    await s.metadata.writeMetadataFor(mix.id);
    await s.metadata.writeMetadataFor(other.id);
    // A newer app wrote this one: never "fixed".
    final otherMeta = File(
      p.join(other.outputPath, MetadataService.metaFileName),
    );
    final newer = {'version': sidecarVersion + 1, 'playlist': {}, 'tracks': []};
    otherMeta.writeAsStringSync(jsonEncode(newer));
    // An edit the mirror has not written yet.
    final song = await trackOf(mix, 1);
    await db.updateTrackAlwaysSkip(song.id, true);

    final report = await s.service.check();

    final byName = {for (final pl in report.playlists) pl.name: pl};
    expect(byName['Mix']!.metadataOutOfDate, isTrue);
    expect(byName['Other']!.metadataOutOfDate, isFalse);
    expect(byName['Other']!.newerMetadataVersion, sidecarVersion + 1);

    await s.service.fix();

    expect(jsonDecode(otherMeta.readAsStringSync()), newer);
    expect(
      (await s.service.check()).playlists.every((pl) => !pl.metadataOutOfDate),
      isTrue,
    );
  });

  test('lyrics files: out of date ones are rewritten; newer ones, shared '
      'ones and files without lyrics are kept', () async {
    final mix = await addPlaylist('Mix', tracks: 4);
    final tracks = await db.getTracksForPlaylist(mix.id);
    final folder = mix.outputPath;
    for (final track in tracks.take(2)) {
      await db.replaceLyricsDoc(draft(track.id, ['line of ${track.index}']));
    }
    // 1: stale. 2: written by a newer app. 3: no lyrics in the database.
    final stale = File(LibraryLayout.lyricsJsonPath(folder, 'Mix-1'))
      ..writeAsStringSync('{"version":1,"videoId":"Mix-1","docs":[]}');
    final newer = File(LibraryLayout.lyricsJsonPath(folder, 'Mix-2'))
      ..writeAsStringSync('{"version":2,"videoId":"Mix-2","docs":[]}');
    final orphan = File(LibraryLayout.lyricsJsonPath(folder, 'Mix-3'))
      ..writeAsStringSync('{"version":1,"videoId":"Mix-3","docs":[]}');
    // 4: a video listed twice, each entry with its own lyrics, shares one
    // file holding the second entry's.
    final twice = await insertTestTrack(
      db,
      playlistId: mix.id,
      index: 5,
      videoId: 'Mix-4',
      title: 'Mix 4 again',
    );
    await db.replaceLyricsDoc(draft(tracks[3].id, ['first entry']));
    await db.replaceLyricsDoc(draft(twice.id, ['second entry']));
    await persistLyricsFile(db, twice.id);
    final shared = File(LibraryLayout.lyricsJsonPath(folder, 'Mix-4'));
    final sharedContent = shared.readAsStringSync();
    final s = servicesFor();

    final report = await s.service.check();

    final status = report.playlists.single;
    expect(status.outdatedLyricsFiles, 1);
    expect(status.missingLyricsFiles, 0);

    await s.service.fix();

    final rewritten = await readLyricsFile(folder, 'Mix-1', tracks[0].id);
    expect(rewritten.single.lines.single.text, 'line of 1');
    expect(stale.readAsStringSync(), contains('line of 1'));
    expect(
      newer.readAsStringSync(),
      '{"version":2,"videoId":"Mix-2","docs":[]}',
    );
    expect(
      orphan.readAsStringSync(),
      '{"version":1,"videoId":"Mix-3","docs":[]}',
    );
    expect(shared.readAsStringSync(), sharedContent);
    expect((await s.service.check()).playlists.single.outdatedLyricsFiles, 0);
  });

  test('the app start writes only missing lyrics files', () async {
    final mix = await addPlaylist('Mix');
    final gone = await addPlaylist('Gone', tracks: 1, createFolder: false);
    final first = await trackOf(mix, 1);
    final second = await trackOf(mix, 2);
    final lost = await trackOf(gone, 1);
    for (final track in [first, second, lost]) {
      await db.replaceLyricsDoc(draft(track.id, ['words']));
    }
    final stale = File(LibraryLayout.lyricsJsonPath(mix.outputPath, 'Mix-2'))
      ..writeAsStringSync('kept');

    final written = await servicesFor().service.repairMissingLyricsFiles();

    expect(written, 1);
    final restored = await readLyricsFile(mix.outputPath, 'Mix-1', first.id);
    expect(restored.single.lines.single.text, 'words');
    // Comparing content is left to "Check backup".
    expect(stale.readAsStringSync(), 'kept');
    // A playlist folder that is gone is not made again.
    expect(Directory(gone.outputPath).existsSync(), isFalse);
  });

  test('write failures of the mirrors show until they work again', () async {
    final mix = await addPlaylist('Mix');
    final metadata = MetadataService(db);
    final mirror = SidecarMirror(
      db,
      metadata,
      LibraryGate.unlocked(),
      log: log,
    );
    // Something in the way of the metadata file.
    final blocker = Directory(
      p.join(mix.outputPath, MetadataService.metaFileName),
    )..createSync();

    await mirror.flush();

    expect(FolderWriteErrors.unresolved.map((e) => e.what), [
      'Metadata file of "Mix"',
    ]);
    final report = await servicesFor().service.check();
    expect(report.writeErrors.single.resolved, isFalse);

    blocker.deleteSync();
    await mirror.flush();

    expect(FolderWriteErrors.unresolved, isEmpty);
    expect(FolderWriteErrors.all.single.resolved, isTrue);
    await mirror.dispose();
  });

  test(
    'the settings of a copied library waiting to be restored stay',
    () async {
      final backup = Directory(LibraryExportService.backupDir)
        ..createSync(recursive: true);
      final settings = File(
        p.join(backup.path, LibraryExportService.settingsFileName),
      )..writeAsStringSync('{"settings": {"even_out_volume": false}}');
      final s = servicesFor(waitsForRestore: true);

      final report = await s.service.check();

      expect(report.settingsWaitForRestore, isTrue);
      expect(report.problems, isEmpty);

      await s.service.fix();

      expect(
        settings.readAsStringSync(),
        '{"settings": {"even_out_volume": false}}',
      );
    },
  );

  test('counts the saved YouTube info and what cannot be fetched', () async {
    final mix = await addPlaylist('Mix', tracks: 5);
    final folder = mix.outputPath;
    final tracks = await db.getTracksForPlaylist(mix.id);
    // 2: no info yet; 3: gone from YouTube; 4: the owner's own file, which
    // is not counted; 5: given up by the background fetch.
    for (final i in [2, 3, 4, 5]) {
      await File(LibraryLayout.infoJsonPath(folder, 'Mix-$i')).delete();
    }
    Future<void> change(int index, TracksCompanion fields) =>
        (db.update(db.tracks)..where(
          (t) => t.id.equals(tracks.firstWhere((t) => t.index == index).id),
        )).write(fields);
    await change(
      3,
      const TracksCompanion(unavailableReason: Value('Removed from YouTube')),
    );
    await change(4, const TracksCompanion(isLocalReplacement: Value(true)));
    final store = InfoBackfillStore(
      directoryProvider: () async => p.join(tempDir.path, 'app'),
    );
    final pausedUntil = DateTime.now().add(const Duration(hours: 1));
    await store.save(
      InfoBackfillState(
        pausedUntil: pausedUntil,
        misses: {
          'Mix-5': InfoBackfillMiss(at: DateTime.now(), tries: 1, gone: true),
          'Mix-2': InfoBackfillMiss(at: DateTime.now(), tries: 1),
        },
      ),
    );
    final before = snapshot();

    final report = await servicesFor(infoStore: store).service.check();

    expect(report.infoSaved, 1);
    expect(report.infoTotal, 4);
    expect(report.infoUnavailable, 2);
    expect(report.infoPausedUntil, pausedUntil);
    // The background fetch fills these; Fix does not.
    expect(report.problems.where((line) => line.contains('info')), isEmpty);
    expect(snapshot(), before);
  });

  testWidgets('Check backup replaces Back up library', (tester) async {
    late Playlist mix;
    await tester.runAsync(() async {
      mix = await addPlaylist('Mix');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    Future<void> waitFor(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    await tester.pumpAndSettle();
    expect(find.text('Back up library'), findsNothing);
    await tester.scrollUntilVisible(find.text('Check backup'), 100);
    await tester.tap(find.text('Check backup'));
    await waitFor(() => find.text('Backup needs fixing').evaluate().isNotEmpty);

    expect(find.text('• "Mix": playlist files out of date'), findsOneWidget);
    expect(find.text('YouTube info: 2 of 2 saved.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fix-backup')));
    await waitFor(() => find.text('Backup fixed').evaluate().isNotEmpty);

    expect(find.text('Backup fixed'), findsOneWidget);
    expect(
      File(p.join(mix.outputPath, MetadataService.metaFileName)).existsSync(),
      isTrue,
    );
    await tester.tap(find.text('OK'));
    await waitFor(
      () =>
          find
              .textContaining('Library folders last updated:')
              .evaluate()
              .isNotEmpty,
    );
    expect(
      find.textContaining('Library folders last updated:'),
      findsOneWidget,
    );
  });
}
