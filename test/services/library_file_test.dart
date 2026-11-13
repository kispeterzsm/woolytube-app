import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/audio_processing.dart';
import 'package:woolytube/services/label_service.dart';
import 'package:woolytube/services/labels.dart';
import 'package:woolytube/services/library_export_service.dart';
import 'package:woolytube/services/library_file.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/library_mirror.dart';
import 'package:woolytube/services/library_restore_service.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/media_thumbnail_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playback_settings_store.dart';
import 'package:woolytube/services/settings_changes.dart';
import 'package:woolytube/services/thumbnail_backfill_service.dart';

import '../helpers/test_database.dart';

/// `woolytube_library.json` keeps the home page order and where the player
/// was in both library folders, and "Import all" on a fresh install brings
/// them back with the settings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const backgroundChannel = MethodChannel('com.woolytube/background');

  late Directory tempDir;
  late String audioBase;
  late String videoBase;
  late LogService log;
  final opened = <AppDatabase>[];

  AppDatabase newDatabase() {
    final db = openTestDatabase();
    opened.add(db);
    return db;
  }

  // Each test opens the old phone's and the new phone's database.
  final warned = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(
    () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warned,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, (call) async => null);
    tempDir = await Directory.systemTemp.createTemp('woolytube_library_');
    audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
    videoBase = p.join(tempDir.path, 'Movies', 'WoolyTube');
    LibraryLayout.overrideBasePathsForTesting(
      audio: audioBase,
      video: videoBase,
    );
    log = LogService.memoryOnly();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, null);
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
    LibraryLayout.resetBasePathsForTesting();
    await tempDir.delete(recursive: true);
  });

  String libraryPath(String root) => p.join(root, LibraryFileService.fileName);

  Map<String, dynamic> readJson(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

  LibraryExportService exporterFor(AppDatabase db) {
    final metadata = MetadataService(db);
    return LibraryExportService(
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
  }

  /// A playlist with its folder and sidecar, as the app leaves it.
  Future<Playlist> addPlaylist(
    AppDatabase db,
    String name, {
    required String list,
    bool audioOnly = true,
    List<String> videos = const ['a', 'b'],
  }) async {
    final folder = p.join(audioOnly ? audioBase : videoBase, name);
    await Directory(folder).create(recursive: true);
    final playlist = await insertTestPlaylist(
      db,
      url: 'https://www.youtube.com/playlist?list=$list',
      name: name,
      audioOnly: audioOnly,
      outputPath: folder,
    );
    for (var i = 0; i < videos.length; i++) {
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: i + 1,
        videoId: '$list-${videos[i]}',
        title: 'Song ${videos[i]}',
      );
    }
    await MetadataService(
      db,
    ).writeMetadata(playlist, await db.getTracksForPlaylist(playlist.id));
    return playlist;
  }

  Future<List<String>> homeOrder(AppDatabase db) async => [
    for (final playlist in await db.getAllPlaylists()) playlist.name,
  ];

  group('the library file', () {
    test('holds the home order and where the player was, in both '
        'library folders, and reads back', () async {
      final db = newDatabase();
      final rock = await addPlaylist(db, 'Rock', list: 'rock');
      final jazz = await addPlaylist(db, 'Jazz', list: 'jazz');
      final clips = await addPlaylist(
        db,
        'Clips',
        list: 'clips',
        audioOnly: false,
      );
      await db.setPlaylistOrder([clips.id, jazz.id, rock.id]);
      final jazzSong = (await db.getTracksForPlaylist(jazz.id))[1];
      final store = MemoryPlaybackSettingsStore();
      await store.saveSession(
        PlaybackSession(
          playlistId: jazz.id,
          trackId: jazzSong.id,
          chapterId: 'ch-2',
          positionMs: 61000,
        ),
      );
      final file = LibraryFileService(
        db,
        log: log,
        playbackStore: store,
        clock: () => DateTime.utc(2026, 11, 13, 12),
      );

      expect(await file.write(), 2);

      final music = readJson(libraryPath(audioBase));
      expect(readJson(libraryPath(videoBase)), music);
      expect(music['version'], LibraryFileService.fileVersion);
      expect(music['updatedAt'], '2026-11-13T12:00:00.000Z');
      expect(music['labels'], isEmpty);
      expect(music['playlists'], [
        {
          'url': 'https://www.youtube.com/playlist?list=clips',
          'audioOnly': false,
          'folder': 'Clips',
          'name': 'Clips',
        },
        {
          'url': 'https://www.youtube.com/playlist?list=jazz',
          'audioOnly': true,
          'folder': 'Jazz',
          'name': 'Jazz',
        },
        {
          'url': 'https://www.youtube.com/playlist?list=rock',
          'audioOnly': true,
          'folder': 'Rock',
          'name': 'Rock',
        },
      ]);
      // No database ids: the point is found again by video id.
      expect(music['resume'], {
        'playlist': {
          'url': 'https://www.youtube.com/playlist?list=jazz',
          'audioOnly': true,
          'folder': 'Jazz',
          'name': 'Jazz',
        },
        'videoId': 'jazz-b',
        'index': 2,
        'chapterId': 'ch-2',
        'positionMs': 61000,
        'whole': false,
      });

      final read = (await file.read())!;
      expect(read.playlists.map((ref) => ref.folder), [
        'Clips',
        'Jazz',
        'Rock',
      ]);
      expect(read.resume!.videoId, 'jazz-b');
      expect(read.resume!.positionMs, 61000);
      expect(read.updatedAt, DateTime.utc(2026, 11, 13, 12));

      // Unchanged content is not written again.
      expect(await file.write(), 0);
      expect(await LibraryFileService(db, playbackStore: store).write(), 0);

      await db.setPlaylistOrder([rock.id, jazz.id, clips.id]);
      expect(await file.write(), 2);
      expect((await file.read())!.playlists.map((ref) => ref.folder), [
        'Rock',
        'Jazz',
        'Clips',
      ]);
    });

    test('a library without playlists gets no file', () async {
      final file = LibraryFileService(
        newDatabase(),
        playbackStore: MemoryPlaybackSettingsStore(),
      );
      expect(await file.write(), 0);
      expect(Directory(audioBase).existsSync(), isFalse);
    });

    test('only the music folder is created for it', () async {
      final db = newDatabase();
      await addPlaylist(db, 'Rock', list: 'rock');
      final file = LibraryFileService(
        db,
        playbackStore: MemoryPlaybackSettingsStore(),
      );

      expect(await file.write(), 1);
      expect(File(libraryPath(audioBase)).existsSync(), isTrue);
      expect(Directory(videoBase).existsSync(), isFalse);
    });

    test(
      'keeps what a newer app wrote and leaves a newer format alone',
      () async {
        final db = newDatabase();
        await addPlaylist(db, 'Rock', list: 'rock');
        await Directory(videoBase).create(recursive: true);
        File(libraryPath(audioBase)).writeAsStringSync(
          jsonEncode({
            'app': 'WoolyTube',
            'version': 1,
            'playlists': <Object?>[],
            'labels': [
              {
                'uid': 'label-0001',
                'name': 'Rock',
                'color': 4294198070,
                'icon': 'guitar',
              },
            ],
            'playCounts': {'rock-a': 3},
          }),
        );
        final newer = jsonEncode({'app': 'WoolyTube', 'version': 9});
        File(libraryPath(videoBase)).writeAsStringSync(newer);

        final file = LibraryFileService(
          db,
          log: log,
          playbackStore: MemoryPlaybackSettingsStore(),
        );
        expect(await file.write(), 1);

        final music = readJson(libraryPath(audioBase));
        expect(music['labels'], [
          {
            'uid': 'label-0001',
            'name': 'Rock',
            'color': 4294198070,
            'icon': 'guitar',
          },
        ]);
        expect(music['playCounts'], {'rock-a': 3});
        expect((music['playlists'] as List).single['folder'], 'Rock');
        expect(File(libraryPath(videoBase)).readAsStringSync(), newer);
      },
    );

    test('holds the labels in the owner\'s order without deleted ones, and '
        'keeps copied ones this library never had', () async {
      final db = newDatabase();
      await addPlaylist(db, 'Rock', list: 'rock');
      final labels = LabelService(db);
      final punk = await labels.create('Punk', 0xffe53935);
      final folk = await labels.create('Folk', 0xff43a047);
      final gone = await labels.create('Gone', 0xff000000);
      await labels.reorder([folk.uid, punk.uid]);
      await labels.delete(gone.uid);
      const copiedUid = '11111111-2222-4333-8444-555555555555';
      File(libraryPath(audioBase))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'app': 'WoolyTube',
            'version': 1,
            'playlists': <Object?>[],
            'labels': [
              // Deleted here: stays out.
              {'uid': gone.uid, 'name': 'Gone', 'color': '#000000'},
              // The same name as a label here: the same label.
              {
                'uid': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
                'name': 'punk',
                'color': '#ffffff',
              },
              {'uid': copiedUid, 'name': 'Jazz', 'color': '#1e88e5'},
            ],
          }),
        );
      final file = LibraryFileService(
        db,
        log: log,
        playbackStore: MemoryPlaybackSettingsStore(),
      );
      await file.write();

      final music = readJson(libraryPath(audioBase));
      expect(music['labels'], [
        PortableLabel.of((await db.getLabel(folk.uid))!).toJson(),
        PortableLabel.of((await db.getLabel(punk.uid))!).toJson(),
        {'uid': copiedUid, 'name': 'Jazz', 'color': '#1e88e5'},
      ]);
      expect((music['labels'] as List).first, {
        'uid': folk.uid,
        'name': 'Folk',
        'color': '#43a047',
        'updatedAt': folk.updatedAt.toUtc().toIso8601String(),
      });
      final read = (await file.read())!;
      expect(read.labels.map((l) => l.name), ['Folk', 'Punk', 'Jazz']);
      expect((await file.check()).every((state) => state.upToDate), isTrue);

      // A label change makes the file out of date.
      await labels.rename(folk.uid, 'Folk rock');
      expect((await file.check()).every((state) => state.upToDate), isFalse);
    });

    test('a fresh install keeps the copied order and last song until they '
        'are restored', () async {
      final old = newDatabase();
      final rock = await addPlaylist(old, 'Rock', list: 'rock');
      final jazz = await addPlaylist(old, 'Jazz', list: 'jazz');
      await old.setPlaylistOrder([jazz.id, rock.id]);
      final oldStore = MemoryPlaybackSettingsStore();
      await oldStore.saveSession(
        PlaybackSession(
          playlistId: rock.id,
          trackId: (await old.getTracksForPlaylist(rock.id)).first.id,
          positionMs: 5000,
        ),
      );
      await LibraryFileService(old, playbackStore: oldStore).write();
      final copied = File(libraryPath(audioBase)).readAsStringSync();

      // The new phone: no playlists, nothing played.
      final fresh = newDatabase();
      final file = LibraryFileService(
        fresh,
        playbackStore: MemoryPlaybackSettingsStore(),
      );
      expect(await file.write(), 0);
      expect(File(libraryPath(audioBase)).readAsStringSync(), copied);
    });
  });

  group('Import all', () {
    /// The old phone: three playlists in an order unlike the folder order,
    /// chosen settings, a song half played; then the folders are "copied"
    /// and the app installed afresh (empty settings, empty database).
    Future<void> copiedLibrary() async {
      final old = newDatabase();
      final alpha = await addPlaylist(old, 'Alpha', list: 'alpha');
      final beta = await addPlaylist(old, 'Beta', list: 'beta');
      final gamma = await addPlaylist(
        old,
        'Gamma',
        list: 'gamma',
        audioOnly: false,
      );
      await old.setPlaylistOrder([gamma.id, beta.id, alpha.id]);
      final settings = AppSettingsService();
      await settings.setEvenOutVolume(true);
      await settings.setPlaneModeStrength(PlaneModeStrength.strong);
      await SharedPreferencesPlaybackSettingsStore().saveShuffle(true);
      await exporterFor(old).writeSettingsFile();
      final store = MemoryPlaybackSettingsStore();
      await store.saveSession(
        PlaybackSession(
          playlistId: beta.id,
          trackId: (await old.getTracksForPlaylist(beta.id))[1].id,
          positionMs: 42000,
          whole: true,
        ),
      );
      await LibraryFileService(old, playbackStore: store).write();
      SharedPreferences.setMockInitialValues({});
    }

    test('on a fresh install brings back the order, the settings and the '
        'last song', () async {
      await copiedLibrary();
      final db = newDatabase();
      final metadata = MetadataService(db);
      final store = SharedPreferencesPlaybackSettingsStore();
      final file = LibraryFileService(db, playbackStore: store);
      final restore = LibraryRestoreService(
        db,
        metadata,
        exporterFor(db),
        file,
        log: log,
      );
      final found = await metadata.findUnimportedPlaylists();
      expect(found, hasLength(3));
      final settled = <String>[];

      final result = await restore.importAll(
        found,
        onSettled: (d) => settled.add(d.name),
      );

      expect(result.imported, 3);
      expect(result.failed, isEmpty);
      expect(settled, unorderedEquals(['Alpha', 'Beta', 'Gamma']));
      expect(await homeOrder(db), ['Gamma', 'Beta', 'Alpha']);
      expect(result.orderRestored, isTrue);

      expect(result.settingsRestored, greaterThan(0));
      final settings = AppSettingsService();
      expect(await settings.getEvenOutVolume(), isTrue);
      expect(await settings.getPlaneModeStrength(), PlaneModeStrength.strong);
      final preferences = await store.load();
      expect(preferences.shuffle, isTrue);

      expect(result.resumeRestored, isTrue);
      final session = preferences.session!;
      final beta = (await db.getAllPlaylists()).singleWhere(
        (pl) => pl.name == 'Beta',
      );
      final song = await db.getTrack(session.trackId);
      expect(session.playlistId, beta.id);
      expect(song!.videoId, 'beta-b');
      expect(session.positionMs, 42000);
      expect(session.whole, isTrue);
      expect(
        result.message,
        'Imported 3 playlists. Restored ${result.settingsRestored} settings, '
        'the home order and where you were listening.',
      );

      // The file now describes the restored library the same way.
      await file.write();
      final written = (await file.read())!;
      expect(written.playlists.map((ref) => ref.folder), [
        'Gamma',
        'Beta',
        'Alpha',
      ]);
      expect(written.resume!.videoId, 'beta-b');
    });

    test('never replaces the settings or last song of a library in use; '
        'imported playlists still go to their places', () async {
      await copiedLibrary();
      // This phone already has a playlist, its own settings and a song.
      final db = newDatabase();
      final mine = await addPlaylist(db, 'Mine', list: 'mine');
      final settings = AppSettingsService();
      await settings.setEvenOutVolume(false);
      await settings.setPlaneModeStrength(PlaneModeStrength.standard);
      final store = SharedPreferencesPlaybackSettingsStore();
      final mySession = PlaybackSession(
        playlistId: mine.id,
        trackId: (await db.getTracksForPlaylist(mine.id)).first.id,
        positionMs: 1000,
      );
      await store.saveSession(mySession);
      final metadata = MetadataService(db);
      final restore = LibraryRestoreService(
        db,
        metadata,
        exporterFor(db),
        LibraryFileService(db, playbackStore: store),
        log: log,
      );
      final found = await metadata.findUnimportedPlaylists();
      expect(
        found.map((d) => d.name),
        unorderedEquals(['Alpha', 'Beta', 'Gamma']),
      );

      final result = await restore.importAll(found);

      expect(result.imported, 3);
      expect(result.settingsRestored, isNull);
      expect(result.resumeRestored, isFalse);
      expect(await settings.getEvenOutVolume(), isFalse);
      expect(await settings.getPlaneModeStrength(), PlaneModeStrength.standard);
      final preferences = await store.load();
      expect(preferences.shuffle, isNull);
      expect(preferences.session, mySession);
      // The owner's playlist stays first; the copied ones keep their
      // order among themselves.
      expect(await homeOrder(db), ['Mine', 'Gamma', 'Beta', 'Alpha']);
      expect(result.message, 'Imported 3 playlists. Restored the home order.');
    });

    test('brings back the labels in their order, also ones no file carries, '
        'and the files keep theirs', () async {
      final old = newDatabase();
      final alpha = await addPlaylist(old, 'Alpha', list: 'alpha');
      final labels = LabelService(old);
      final rock = await labels.create('Rock', 0xffe53935);
      final unused = await labels.create('Unused', 0xff43a047);
      await labels.reorder([unused.uid, rock.uid]);
      final song = (await old.getTracksForPlaylist(alpha.id)).first;
      await labels.setTrackLabel(song.id, rock.uid, true);
      await MetadataService(old).writeMetadataFor(alpha.id);
      await LibraryFileService(
        old,
        playbackStore: MemoryPlaybackSettingsStore(),
      ).write();

      final db = newDatabase();
      // This phone already made a label of the same name.
      final mine = await LabelService(db).create('rock', 0xff000000);
      final metadata = MetadataService(db);
      final restore = LibraryRestoreService(
        db,
        metadata,
        exporterFor(db),
        LibraryFileService(db, playbackStore: MemoryPlaybackSettingsStore()),
        log: log,
      );
      final result = await restore.importAll(
        await metadata.findUnimportedPlaylists(),
      );
      expect(result.labelsAdded, 1);
      expect(result.message, contains('Restored 1 label'));
      expect((await db.getLabels()).map((l) => l.name), ['rock', 'Unused']);
      final imported = (await db.getAllTracks()).firstWhere(
        (t) => t.videoId == song.videoId,
      );
      expect(decodeLabelUids(imported.labelUids), [mine.uid]);
    });

    test('one playlist restored on its own goes where it was', () async {
      await copiedLibrary();
      final db = newDatabase();
      final metadata = MetadataService(db);
      final restore = LibraryRestoreService(
        db,
        metadata,
        exporterFor(db),
        LibraryFileService(db, playbackStore: MemoryPlaybackSettingsStore()),
        log: log,
      );
      final found = {
        for (final d in await metadata.findUnimportedPlaylists()) d.name: d,
      };

      await restore.importOne(found['Alpha']!);
      await restore.importOne(found['Gamma']!);
      expect(await homeOrder(db), ['Gamma', 'Alpha']);
      await restore.importOne(found['Beta']!);
      expect(await homeOrder(db), ['Gamma', 'Beta', 'Alpha']);
    });

    test('a library copied one root at a time keeps the order of the root '
        'that comes later', () async {
      await copiedLibrary();
      // Only the music folder is copied at first.
      final stash = p.join(tempDir.path, 'stash');
      await Directory(videoBase).rename(stash);
      final db = newDatabase();
      final metadata = MetadataService(db);
      var now = DateTime.utc(2030);
      final file = LibraryFileService(
        db,
        playbackStore: MemoryPlaybackSettingsStore(),
        clock: () => now,
      );
      final restore = LibraryRestoreService(
        db,
        metadata,
        exporterFor(db),
        file,
        log: log,
      );
      final first = await restore.importAll(
        await metadata.findUnimportedPlaylists(),
      );
      expect(first.imported, 2);
      expect(await homeOrder(db), ['Beta', 'Alpha']);
      now = now.add(const Duration(minutes: 1));
      await file.write();
      // The music folder's file still has the video playlist's place.
      final music = LibraryFileData.fromJson(readJson(libraryPath(audioBase)));
      expect(music.playlists.map((ref) => ref.folder), [
        'Gamma',
        'Beta',
        'Alpha',
      ]);

      // The video folder (with its older file) arrives later.
      await Directory(stash).rename(videoBase);
      final second = await restore.importAll(
        await metadata.findUnimportedPlaylists(),
      );
      expect(second.imported, 1);
      expect(await homeOrder(db), ['Gamma', 'Beta', 'Alpha']);
    });
  });

  test('read adds the playlists only the other root\'s file lists, where '
      'that file had them', () async {
    Future<void> put(String root, String updatedAt, List<String> names) async {
      await Directory(root).create(recursive: true);
      await File(libraryPath(root)).writeAsString(
        jsonEncode({
          'app': 'WoolyTube',
          'version': LibraryFileService.fileVersion,
          'updatedAt': updatedAt,
          'playlists': [
            for (final name in names)
              {
                'url': 'https://www.youtube.com/playlist?list=$name',
                'audioOnly': name != 'v',
                'folder': name,
              },
          ],
        }),
      );
    }

    // Written later, before the video folder was copied over.
    await put(audioBase, '2030-01-02T00:00:00.000Z', ['b', 'c']);
    await put(videoBase, '2030-01-01T00:00:00.000Z', ['a', 'v', 'b', 'c']);
    final read =
        (await LibraryFileService(
          newDatabase(),
          playbackStore: MemoryPlaybackSettingsStore(),
        ).read())!;
    expect(read.playlists.map((ref) => ref.folder), ['a', 'v', 'b', 'c']);
    expect(read.updatedAt, DateTime.utc(2030, 1, 2));

    // The newer file's order wins where both list a playlist.
    await put(audioBase, '2030-01-03T00:00:00.000Z', ['c', 'b']);
    final reordered =
        (await LibraryFileService(
          newDatabase(),
          playbackStore: MemoryPlaybackSettingsStore(),
        ).read())!;
    expect(reordered.playlists.map((ref) => ref.folder), ['a', 'v', 'c', 'b']);
  });

  group('applyOrder', () {
    test('playlists the file does not list stay where they are', () async {
      final db = newDatabase();
      await addPlaylist(db, 'X', list: 'x');
      final a = await addPlaylist(db, 'A', list: 'a');
      await addPlaylist(db, 'C', list: 'c');
      final y = await addPlaylist(db, 'Y', list: 'y');
      LibraryPlaylistRef ref(String list, String folder) => LibraryPlaylistRef(
        url: 'https://www.youtube.com/playlist?list=$list',
        audioOnly: true,
        folder: folder,
      );
      final file = LibraryFileData(
        playlists: [ref('c', 'C'), ref('b', 'B'), ref('a', 'A')],
      );
      final service = LibraryFileService(
        db,
        playbackStore: MemoryPlaybackSettingsStore(),
      );

      // A was just imported; C (listed) and X, Y (not listed) were there.
      expect(await service.applyOrder(file, {a.id, y.id}), 1);
      expect(await homeOrder(db), ['X', 'C', 'A', 'Y']);
    });
  });

  test('the mirror writes the file after the order changes', () async {
    final db = newDatabase();
    final rock = await addPlaylist(db, 'Rock', list: 'rock');
    final jazz = await addPlaylist(db, 'Jazz', list: 'jazz');
    final resume = StreamController<void>.broadcast();
    addTearDown(resume.close);
    final mirror = LibraryMirror(
      db,
      LibraryFileService(db, playbackStore: MemoryPlaybackSettingsStore()),
      resumeChanges: resume.stream,
      delay: const Duration(milliseconds: 10),
      startDelay: const Duration(milliseconds: 10),
    );
    addTearDown(mirror.dispose);
    mirror.start();

    Future<List<Object?>> folders() async {
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final file = File(libraryPath(audioBase));
        if (!file.existsSync()) continue;
        try {
          return [
            for (final entry in readJson(file.path)['playlists'] as List)
              (entry as Map)['folder'],
          ];
        } catch (_) {
          // Being written.
        }
      }
      return const [];
    }

    expect(await folders(), ['Rock', 'Jazz']);
    await db.setPlaylistOrder([jazz.id, rock.id]);
    for (var i = 0; i < 200; i++) {
      if ((await folders()).first == 'Jazz') break;
    }
    expect(await folders(), ['Jazz', 'Rock']);

    await LabelService(db).create('Rock', 0xffe53935);
    var labels = const <Object?>[];
    for (var i = 0; i < 200 && labels.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      try {
        labels = readJson(libraryPath(audioBase))['labels'] as List;
      } catch (_) {
        // Being written.
      }
    }
    expect((labels.single as Map)['name'], 'Rock');
  });

  test('a new last song is written at most every resume interval', () async {
    final db = newDatabase();
    await addPlaylist(db, 'Rock', list: 'rock');
    final file = _CountingLibraryFile(db);
    final resume = StreamController<void>.broadcast();
    addTearDown(resume.close);
    final mirror = LibraryMirror(
      db,
      file,
      resumeChanges: resume.stream,
      delay: const Duration(milliseconds: 10),
      startDelay: const Duration(milliseconds: 10),
      resumeInterval: const Duration(seconds: 1),
    );
    addTearDown(mirror.dispose);
    mirror.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(file.writes, 1);

    // Saved every few seconds while playing.
    for (var i = 0; i < 5; i++) {
      resume.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(file.writes, 1);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(file.writes, 2);
  });

  test('the player says when it stored a new last song', () async {
    var told = 0;
    final subscription = ResumePointChanges.stream.listen((_) => told++);
    addTearDown(subscription.cancel);
    final store = SharedPreferencesPlaybackSettingsStore();

    await store.saveSession(
      const PlaybackSession(playlistId: 1, trackId: 2, positionMs: 3),
    );
    await store.saveSession(null);
    await pumpEventQueue();

    expect(told, 2);
  });
}

class _CountingLibraryFile extends LibraryFileService {
  _CountingLibraryFile(super.db)
    : super(playbackStore: MemoryPlaybackSettingsStore());

  var writes = 0;

  @override
  Future<int> write() {
    writes++;
    return super.write();
  }
}
