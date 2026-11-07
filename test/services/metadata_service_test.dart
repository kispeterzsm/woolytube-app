import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/metadata_service.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late String folder;
  late MetadataService metadata;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_metadata_test_');
    // A playlist folder one level below a library root, as on the device:
    // writing metadata also puts a README into the root.
    folder = p.join(tempDir.path, 'Music', 'Playlist');
    await Directory(folder).create(recursive: true);
    metadata = MetadataService(db);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String at(String name) => p.join(folder, name);

  Future<String> touch(String name, [String content = 'data']) async {
    final path = at(name);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(content);
    return path;
  }

  bool exists(String name) => File(at(name)).existsSync();

  test('formats safe filenames and resolves media by index prefix', () async {
    expect(MetadataService.paddingWidth(10), 5);
    expect(MetadataService.paddingWidth(100000), 6);
    expect(MetadataService.paddedIndex(7, 10), '00007');
    expect(MetadataService.paddedIndex(7, 100000), '000007');
    expect(MetadataService.sanitizeFilename('  A:/B * C  '), 'A__B _ C');
    expect(MetadataService.sanitizeFilename('   '), '_');

    final media = await touch('00001_Title.m4a', 'audio');
    await touch('00001_Title.txt', 'text');

    expect(MetadataService.resolveMediaFile(folder, '00001_'), media);
    expect(MetadataService.resolveMediaFile(folder, '00002_'), isNull);
  });

  // Updated: images, parked force-insert originals and format streams
  // whose merged file is missing are no longer deleted.
  test('cleanup deletes only download leftovers', () async {
    await touch('00001_Title.mp3', 'audio');
    await touch('woolytube_meta.json', '{}');
    final removed = [
      'download.part',
      'download.part-Frag12',
      'download.ytdl',
      'woolytube_meta.json.tmp',
      '.woolytube-force-insert-1.mp4',
      '.woolytube-local-replacement-1.m4a',
      'woolytube_meta.json.tmp.1700000000.3',
    ];
    final kept = [
      '00001_Title.mp3',
      'woolytube_meta.json',
      'cover.jpg',
      'folder.jpg',
      '00002_Title.webp',
      // No merged 00002_Title.mp4: these may be the only copy.
      '00002_Title.f137.mp4',
      '00002_Title.f140.m4a',
      '00002_Title.temp.mp4',
      // A file an older force insert parked under a temporary name.
      '.woolytube-force-move-1-0.mp4',
    ];
    for (final name in [...removed, ...kept]) {
      if (!exists(name)) await touch(name, 'junk');
    }

    final deleted = await MetadataService.cleanupPlaylistFolder(folder);

    expect(deleted, removed.length);
    for (final name in removed) {
      expect(exists(name), isFalse, reason: name);
    }
    for (final name in kept) {
      expect(exists(name), isTrue, reason: name);
    }
  });

  // Updated: the sidecar is version 2 and carries every segment field,
  // the download time and a pending replacement request.
  test(
    'writes playlist metadata including files and SponsorBlock segments',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        name: 'Metadata Playlist',
        thumbnailUrl: 'https://example.com/playlist.jpg',
        outputPath: folder,
        lastUpdated: DateTime.utc(2024, 1, 2, 3, 4, 5),
        createdAt: DateTime.utc(2024, 1, 1),
      );
      final mediaPath = at('00001_Song.m4a');
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'video-1',
        title: 'Song',
        thumbnailUrl: 'https://example.com/song.jpg',
        filePath: mediaPath,
        durationSeconds: 123,
        status: 'complete',
        alwaysSkip: true,
        downloadedAt: DateTime.utc(2024, 3, 4, 5, 6, 7),
        replaceRequested: true,
      );
      await db.replaceSponsorBlockSegments(track.id, [
        SponsorBlockSegmentsCompanion.insert(
          trackId: track.id,
          videoId: track.videoId,
          source: 'sponsorblock',
          uuid: const Value('segment-1'),
          category: 'sponsor',
          startMs: 1000,
          endMs: 2500,
          createdAt: DateTime.utc(2024, 1, 1),
        ),
      ]);

      await metadata.writeMetadata(playlist, [(await db.getTrack(track.id))!]);

      final data =
          jsonDecode(await File(at('woolytube_meta.json')).readAsString())
              as Map<String, dynamic>;
      expect(data['version'], 2);
      expect(data['playlist']['name'], 'Metadata Playlist');
      expect(data['playlist']['lastUpdated'], '2024-01-02T03:04:05.000Z');

      final tracks = data['tracks'] as List<dynamic>;
      expect(tracks, hasLength(1));
      expect(tracks.single['videoId'], 'video-1');
      expect(tracks.single['fileName'], '00001_Song.m4a');
      expect(tracks.single['alwaysSkip'], isTrue);
      expect(tracks.single['downloadedAt'], '2024-03-04T05:06:07.000Z');
      expect(tracks.single['replaceRequested'], isTrue);
      expect(tracks.single['sponsorBlockSegments'], [
        {
          'source': 'sponsorblock',
          'uuid': 'segment-1',
          'category': 'sponsor',
          'actionType': 'skip',
          'startMs': 1000,
          'endMs': 2500,
          'votes': null,
          'locked': null,
          'description': null,
          'createdAt': '2024-01-01T00:00:00.000Z',
        },
      ]);
    },
  );

  group('reconcile (link only)', () {
    // Updated: reconcile no longer deletes or renames anything and keeps
    // isLocalReplacement on a track whose file is missing. The renaming and
    // cleanup now belong to repairPlaylist, tested below.
    test('links files without deleting or renaming anything', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final first = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'first',
        title: 'First',
        status: 'pending',
      );
      final missing = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'missing',
        title: 'Missing',
        filePath: at('missing.m4a'),
        status: 'complete',
        isLocalReplacement: true,
        downloadedAt: DateTime.utc(2024),
      );
      final moved = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'moved',
        title: 'Moved',
        filePath: at('old-name.mp4'),
        status: 'complete',
        downloadedAt: DateTime.utc(2024),
      );
      final names = [
        '1_First.mp3',
        '3_Moved.mp4',
        'cover.jpg',
        'download.part',
        'download.ytdl',
        'old.tmp',
        '00009_Unknown.f137.mp4',
        'woolytube_meta.json',
      ];
      for (final name in names) {
        await touch(name);
      }

      final fixed = await metadata.reconcilePlaylist(playlist);

      expect(fixed, 3);
      final firstAfter = (await db.getTrack(first.id))!;
      expect(firstAfter.status, 'complete');
      expect(firstAfter.filePath, at('1_First.mp3'));
      final missingAfter = (await db.getTrack(missing.id))!;
      expect(missingAfter.status, 'pending');
      expect(missingAfter.filePath, isNull);
      expect(missingAfter.downloadedAt, isNull);
      expect(missingAfter.isLocalReplacement, isTrue);
      final movedAfter = (await db.getTrack(moved.id))!;
      expect(movedAfter.status, 'complete');
      expect(movedAfter.filePath, at('3_Moved.mp4'));

      final after =
          Directory(folder).listSync().map((e) => p.basename(e.path)).toSet();
      expect(after, names.toSet());
    });

    test('never demotes tracks when the folder lists no media although tracks '
        'point into it', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final tracks = [
        await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 1,
          videoId: 'a',
          filePath: at('00001_A.m4a'),
          status: 'complete',
          downloadedAt: DateTime.utc(2024),
        ),
        await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 2,
          videoId: 'b',
          filePath: at('00002_B.m4a'),
          status: 'complete',
          isLocalReplacement: true,
          downloadedAt: DateTime.utc(2024),
        ),
      ];
      // Storage not readable yet (no permission, not mounted): only the
      // sidecar is visible.
      await touch('woolytube_meta.json', '{}');

      expect(await metadata.reconcilePlaylist(playlist), 0);
      expect(await metadata.repairPlaylist(playlist), 0);

      expect(await db.getTracksForPlaylist(playlist.id), tracks);
    });

    test('never gives one file to two tracks', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final shared = await touch('00001_Song.m4a');
      final pending = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'pending',
        title: 'Song',
      );
      // Another track already uses the file numbered 1 (for example after
      // an interrupted renumbering).
      final owner = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'owner',
        title: 'Song',
        filePath: shared,
        status: 'complete',
      );

      await metadata.reconcilePlaylist(playlist);

      expect((await db.getTrack(pending.id))!.status, 'pending');
      expect((await db.getTrack(pending.id))!.filePath, isNull);
      expect((await db.getTrack(owner.id))!.filePath, shared);
    });

    test(
      'keeps an existing file path even when another file has its number',
      () async {
        final playlist = await insertTestPlaylist(db, outputPath: folder);
        final own = await touch('00004_Mine.m4a');
        await touch('00001_Other.m4a');
        final track = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 1,
          videoId: 'mine',
          title: 'Mine',
          filePath: own,
          status: 'complete',
        );

        await metadata.reconcilePlaylist(playlist);

        expect((await db.getTrack(track.id))!.filePath, own);
        expect(exists('00001_Other.m4a'), isTrue);
      },
    );

    test('keeps isLocalReplacement when the file is missing', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final local = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'local',
        filePath: at('00001_My Version.m4a'),
        status: 'complete',
        isLocalReplacement: true,
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'other',
        filePath: await touch('00002_Other.m4a'),
        status: 'complete',
      );

      await metadata.reconcilePlaylist(playlist);

      final after = (await db.getTrack(local.id))!;
      expect(after.status, 'pending');
      expect(after.isLocalReplacement, isTrue);
    });

    test('leaves a downloading track alone; repair resets it', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        status: 'downloading',
      );
      await touch('00002_Unrelated.m4a');

      await metadata.reconcilePlaylist(playlist);
      expect((await db.getTrack(track.id))!.status, 'downloading');

      await metadata.repairPlaylist(playlist);
      expect((await db.getTrack(track.id))!.status, 'pending');
    });

    // Updated: intermediates used to be deleted by reconcile. Now reconcile
    // never deletes, and even repair keeps them while their merged file is
    // missing.
    test('intermediates never complete a track and are kept without a merged '
        'file', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);
      await touch('00001_Title.f137.mp4', 'video');
      await touch('00001_Title.temp.mp4', 'video');

      expect(await metadata.reconcilePlaylist(playlist), 0);
      await metadata.repairPlaylist(playlist);

      expect((await db.getTrack(track.id))!.status, 'pending');
      expect(exists('00001_Title.f137.mp4'), isTrue);
      expect(exists('00001_Title.temp.mp4'), isTrue);
    });

    test('consumes info sidecars with one directory listing', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final first = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'first',
        filePath: at('00001_First.mp4'),
        status: 'complete',
      );
      final second = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'second',
        filePath: at('00002_Second.mp4'),
        status: 'complete',
      );
      await File(first.filePath!).writeAsString('video');
      await File(second.filePath!).writeAsString('video');
      Future<File> sidecar(String name, String id, String chapter) async {
        final file = File(at(name));
        await file.writeAsString(
          jsonEncode({
            'id': id,
            'duration': 60,
            'formats': [
              {'url': 'x'},
            ],
            'chapters': [
              {'title': chapter, 'start_time': 0, 'end_time': 60},
            ],
          }),
        );
        return file;
      }

      final firstInfo = await sidecar('00001_First.info.json', 'first', 'One');
      final secondInfo = await sidecar(
        '00002_Second.info.json',
        'second',
        'Two',
      );
      final foreign = await sidecar('00002_Other.info.json', 'other', 'Nope');

      await metadata.reconcilePlaylist(playlist);

      String? chapterTitle(Track? track) =>
          ChapterData.decode(track?.chaptersJson).active.singleOrNull?.title;
      expect(chapterTitle(await db.getTrack(first.id)), 'One');
      expect(chapterTitle(await db.getTrack(second.id)), 'Two');
      expect(await firstInfo.exists(), isFalse);
      expect(await secondInfo.exists(), isFalse);
      expect(await foreign.exists(), isTrue);
      // The information is kept, trimmed, in the info folder.
      final kept =
          jsonDecode(
                await File(
                  at(p.join('.woolytube_info', 'first.info.json')),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(kept['id'], 'first');
      expect(kept.containsKey('formats'), isFalse);
    });
  });

  group('repair', () {
    test(
      'renames files to their track numbers and removes download leftovers',
      () async {
        final playlist = await insertTestPlaylist(db, outputPath: folder);
        final first = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 1,
          videoId: 'first',
          title: 'First',
          status: 'pending',
        );
        final moved = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 3,
          videoId: 'moved',
          title: 'Moved',
          filePath: at('old-name.mp4'),
          status: 'complete',
        );
        for (final name in [
          '1_First.mp3',
          '3_Moved.mp4',
          'cover.jpg',
          'download.part',
          'download.ytdl',
          'old.tmp',
          'woolytube_meta.json',
        ]) {
          await touch(name);
        }

        await metadata.repairPlaylist(playlist);

        expect((await db.getTrack(first.id))!.filePath, at('00001_First.mp3'));
        expect((await db.getTrack(moved.id))!.filePath, at('00003_Moved.mp4'));
        expect(exists('00001_First.mp3'), isTrue);
        expect(exists('00003_Moved.mp4'), isTrue);
        expect(exists('1_First.mp3'), isFalse);
        expect(exists('3_Moved.mp4'), isFalse);
        expect(exists('download.part'), isFalse);
        expect(exists('download.ytdl'), isFalse);
        expect(exists('old.tmp'), isFalse);
        expect(exists('cover.jpg'), isTrue);
        expect(exists('woolytube_meta.json'), isTrue);
      },
    );

    test(
      "renames a file whose number does not match its track's index",
      () async {
        final playlist = await insertTestPlaylist(db, outputPath: folder);
        final track = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 3,
          videoId: 'moved',
          title: 'Moved',
          filePath: await touch('00002_Moved.mp4', 'video'),
          status: 'complete',
        );

        expect(await metadata.repairPlaylist(playlist), 1);

        final after = (await db.getTrack(track.id))!;
        expect(after.filePath, at('00003_Moved.mp4'));
        expect(await File(after.filePath!).readAsString(), 'video');
        expect(exists('00002_Moved.mp4'), isFalse);
      },
    );

    test(
      'startup recovery resolves interrupted downloads without starting them',
      () async {
        final playlist = await insertTestPlaylist(db, outputPath: folder);
        final missing = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 1,
          videoId: 'interrupted-missing',
          status: 'downloading',
        );
        final finished = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 2,
          videoId: 'interrupted-finished',
          status: 'downloading',
        );
        final finishedPath = await touch('00002_Finished.m4a', 'audio');
        await touch('00001_Missing.m4a.part', 'partial');
        await touch(
          p.join('.woolytube-staging', 'track-${missing.id}', '00001_x.m4a'),
        );

        final fixed = await metadata.recoverInterruptedDownloads();

        expect(fixed, 3);
        expect((await db.getTrack(missing.id))!.status, 'pending');
        expect((await db.getTrack(finished.id))!.status, 'complete');
        expect((await db.getTrack(finished.id))!.filePath, finishedPath);
        expect(exists('00001_Missing.m4a.part'), isFalse);
        expect(await Directory(at('.woolytube-staging')).exists(), isFalse);

        final sidecar =
            jsonDecode(await File(at('woolytube_meta.json')).readAsString())
                as Map<String, dynamic>;
        final tracks = sidecar['tracks'] as List<dynamic>;
        expect(tracks.first['status'], 'pending');
        expect(tracks.last['status'], 'complete');
      },
    );
  });

  group('cleanup', () {
    test('keeps folder covers and adopts a numbered root image as the '
        "track's cover", () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'vid-3',
        filePath: await touch('00003_x.m4a'),
        status: 'complete',
      );
      await touch('folder.jpg', 'folder');
      await touch('cover.jpg', 'cover');
      await touch('00003_x.webp', 'webp');
      // No track 9: an image numbered like it is not touched.
      await touch('00009_y.jpg', 'other');

      await metadata.cleanupPlaylist(playlist);

      expect(await File(at('folder.jpg')).readAsString(), 'folder');
      expect(await File(at('cover.jpg')).readAsString(), 'cover');
      expect(exists('00009_y.jpg'), isTrue);
      final cover = at(p.join('.woolytube_thumbnails', 'vid-3.webp'));
      expect((await db.getTrack(track.id))!.thumbnailPath, cover);
      expect(await File(cover).readAsString(), 'webp');
      expect(exists('00003_x.webp'), isFalse);
    });

    test('keeps format streams until their merged file exists', () async {
      await touch('00002_Title.f137.mp4');
      await touch('00002_Title.f140.m4a');

      expect(await MetadataService.cleanupPlaylistFolder(folder), 0);
      expect(exists('00002_Title.f137.mp4'), isTrue);
      expect(exists('00002_Title.f140.m4a'), isTrue);

      await touch('00002_Title.mp4');
      expect(await MetadataService.cleanupPlaylistFolder(folder), 2);
      expect(exists('00002_Title.f137.mp4'), isFalse);
      expect(exists('00002_Title.f140.m4a'), isFalse);
      expect(exists('00002_Title.mp4'), isTrue);
    });

    test('never deletes a file a track uses', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      // A real song whose title happens to end like a yt-dlp temp file.
      final song = await touch('00005_Mix.temp.mp4', 'song');
      await touch('00005_Mix.mp4', 'other');
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 5,
        filePath: song,
        status: 'complete',
      );

      await metadata.cleanupPlaylist(playlist);
      await metadata.repairPlaylist(playlist);

      expect(await File(song).readAsString(), 'song');
    });

    test('never deletes files an older force insert parked', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await touch('.woolytube-force-move-1700000000-0.mp4', 'only copy');
      await touch('00001_A.mp4');

      await metadata.repairPlaylist(playlist);
      await MetadataService.cleanupPlaylistFolder(folder);

      expect(
        await File(at('.woolytube-force-move-1700000000-0.mp4')).readAsString(),
        'only copy',
      );
    });
  });

  group('force insert interrupted part-way', () {
    // A force insert at 2 renames from the highest number down, recording
    // each new path just before the file moves, and changes indices only at
    // the end. These build the state a crash leaves behind.
    late Playlist playlist;
    late Track a;
    late Track b;
    late Track c;

    setUp(() async {
      playlist = await insertTestPlaylist(db, outputPath: folder);
      a = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'a',
        title: 'A',
        filePath: await touch('00001_A.mp4', 'a'),
        status: 'complete',
      );
      b = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
        title: 'B',
        filePath: await touch('00002_B.mp4', 'b'),
        status: 'complete',
      );
      c = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'c',
        title: 'C',
        filePath: await touch('00003_C.mp4', 'c'),
        status: 'complete',
      );
      await touch(p.join('.woolytube-staging', 'insert-1', 'source.mp4'), 'x');
    });

    Future<void> renamed(Track track, String to) async {
      await db.updateTrackFields(track.id, filePath: at(to));
      await File(track.filePath!).rename(at(to));
    }

    Future<Map<String, String>> contentByTrack() async => {
      for (final t in await db.getTracksForPlaylist(playlist.id))
        t.videoId: await File(t.filePath!).readAsString(),
    };

    test('after some renames, every track keeps its own file and repair '
        'puts the names back', () async {
      await renamed(c, '00004_C.mp4');
      await renamed(b, '00003_B.mp4');

      await metadata.reconcilePlaylist(playlist);

      expect((await db.getTrack(a.id))!.filePath, at('00001_A.mp4'));
      expect((await db.getTrack(b.id))!.filePath, at('00003_B.mp4'));
      expect((await db.getTrack(c.id))!.filePath, at('00004_C.mp4'));
      expect(await contentByTrack(), {'a': 'a', 'b': 'b', 'c': 'c'});

      await metadata.repairPlaylist(playlist);

      final tracks = await db.getTracksForPlaylist(playlist.id);
      expect(tracks.map((t) => t.index), [1, 2, 3]);
      expect(tracks.map((t) => p.basename(t.filePath!)), [
        '00001_A.mp4',
        '00002_B.mp4',
        '00003_C.mp4',
      ]);
      expect(await contentByTrack(), {'a': 'a', 'b': 'b', 'c': 'c'});
      expect(await Directory(at('.woolytube-staging')).exists(), isFalse);
    });

    test('with one rename in flight, that track finds its file by its '
        'unchanged number', () async {
      await renamed(c, '00004_C.mp4');
      // The path was recorded, but the app died before the file moved.
      await db.updateTrackFields(b.id, filePath: at('00003_B.mp4'));

      await metadata.reconcilePlaylist(playlist);

      expect((await db.getTrack(b.id))!.filePath, at('00002_B.mp4'));
      expect((await db.getTrack(c.id))!.filePath, at('00004_C.mp4'));
      expect(await contentByTrack(), {'a': 'a', 'b': 'b', 'c': 'c'});

      await metadata.repairPlaylist(playlist);

      expect(
        (await db.getTracksForPlaylist(
          playlist.id,
        )).map((t) => p.basename(t.filePath!)),
        ['00001_A.mp4', '00002_B.mp4', '00003_C.mp4'],
      );
      expect(await contentByTrack(), {'a': 'a', 'b': 'b', 'c': 'c'});
    });
  });

  test(
    'imports discovered playlists and keeps only valid local segments',
    () async {
      final thumbnail = File(
        at(p.join('.woolytube_thumbnails', 'track_7.jpg')),
      );
      await thumbnail.parent.create();
      await thumbnail.writeAsString('image');
      await touch('00001_Existing.m4a', 'audio');

      await metadata.importPlaylist(
        DiscoveredPlaylist(
          folderPath: folder,
          url: 'https://www.youtube.com/playlist?list=imported',
          name: 'Imported',
          thumbnailUrl: 'https://example.com/imported.jpg',
          audioOnly: true,
          autoUpdate: false,
          updateFrequencyHours: 12,
          includeThumbnails: false,
          sponsorBlockEnabled: false,
          sponsorBlockCategories: '["intro"]',
          lastUpdated: DateTime.utc(2024, 1, 2),
          createdAt: DateTime.utc(2024, 1, 1),
          tracks: [
            DiscoveredTrack(
              index: 1,
              videoId: 'existing',
              title: 'Existing',
              status: 'complete',
              fileName: '00001_Existing.m4a',
              thumbnailFileName: p.join('.woolytube_thumbnails', 'track_7.jpg'),
              alwaysSkip: true,
              sponsorBlockSegments: const [
                DiscoveredSponsorBlockSegment(
                  source: 'local',
                  category: 'intro',
                  startMs: 1000,
                  endMs: 2000,
                ),
                DiscoveredSponsorBlockSegment(
                  source: 'local',
                  category: 'intro',
                  startMs: 3000,
                  endMs: 2500,
                ),
              ],
            ),
            DiscoveredTrack(
              index: 2,
              videoId: 'missing',
              title: 'Missing',
              status: 'complete',
              fileName: '00002_Missing.m4a',
            ),
            DiscoveredTrack(
              index: 3,
              videoId: 'private',
              title: '[Private video]',
              status: 'unavailable',
              unavailableReason: 'private',
            ),
          ],
        ),
      );

      final playlist = await db.getPlaylistByUrl(
        'https://www.youtube.com/playlist?list=imported',
      );
      expect(playlist, isNotNull);
      expect(playlist!.audioOnly, isTrue);
      expect(playlist.autoUpdate, isFalse);
      expect(playlist.includeThumbnails, isFalse);
      expect(playlist.sponsorBlockCategories, '["intro"]');

      final tracks = await db.getTracksForPlaylist(playlist.id);
      expect(tracks.map((track) => track.videoId), [
        'existing',
        'missing',
        'private',
      ]);
      expect(tracks[0].status, 'complete');
      expect(tracks[0].filePath, at('00001_Existing.m4a'));
      expect(tracks[0].thumbnailPath, thumbnail.path);
      expect(tracks[0].alwaysSkip, isTrue);
      expect(tracks[1].status, 'pending');
      expect(tracks[1].filePath, isNull);
      expect(tracks[2].status, 'unavailable');
      expect(tracks[2].unavailableReason, 'private');

      final segments = await db.getSegmentsForTrack(tracks[0].id);
      expect(segments, hasLength(1));
      expect(segments.single.source, 'local');
      expect(segments.single.category, 'intro');
      expect(segments.single.startMs, 1000);
      expect(segments.single.endMs, 2000);
    },
  );

  test('classifies transient files', () {
    for (final name in [
      '00001_Title.mp4.part',
      '00001_Title.mp4.part-Frag3',
      '00001_Title.mp4.ytdl',
      '00001_Title.f137.mp4',
      '00001_Title.f140.m4a',
      '00001_Title.temp.mp4',
      'woolytube_meta.json.tmp',
      'woolytube_meta.json.tmp.1.2',
      '.woolytube-force-insert-9.mp4',
      '.woolytube-force-move-9-1.mp4',
      '.woolytube-local-replacement-9.m4a',
    ]) {
      expect(MetadataService.isTransientFile(name), isTrue, reason: name);
    }
    for (final name in [
      '00001_Title.mp4',
      '00001_Title.m4a',
      '00001_Title.info.json',
      'woolytube_meta.json',
      '00001_Part_Two.mp4',
      '00001_Temperature.mp4',
    ]) {
      expect(MetadataService.isTransientFile(name), isFalse, reason: name);
    }
  });

  test('intermediate files are never resolved as the track media', () async {
    for (final name in [
      '00001_Title.f137.mp4',
      '00001_Title.f140.m4a',
      '00001_Title.temp.mp4',
      '00001_Title.mp4.part',
      '00001_Title.mp4.ytdl',
    ]) {
      await touch(name, 'partial');
    }
    expect(MetadataService.resolveMediaFile(folder, '00001_'), isNull);

    final media = await touch('00001_Title.mp4', 'video');
    expect(MetadataService.resolveMediaFile(folder, '00001_'), media);
  });

  // Updated: writing metadata now also writes the `.m3u8` playlist.
  test(
    'concurrent metadata writes serialise and leave no temp files',
    () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);

      await Future.wait([
        for (var i = 0; i < 25; i++) metadata.writeMetadata(playlist, [track]),
      ]);

      final names =
          Directory(
            folder,
          ).listSync().map((entity) => p.basename(entity.path)).toSet();
      expect(names, {'woolytube_meta.json', 'Playlist.m3u8'});
      final data =
          jsonDecode(await File(at('woolytube_meta.json')).readAsString())
              as Map<String, dynamic>;
      expect((data['tracks'] as List).single['videoId'], track.videoId);
    },
  );

  test('import de-duplicates indices from an older sidecar', () async {
    DiscoveredTrack track(int index, String videoId) => DiscoveredTrack(
      index: index,
      videoId: videoId,
      title: videoId,
      status: 'pending',
    );

    await metadata.importPlaylist(
      DiscoveredPlaylist(
        folderPath: folder,
        url: 'https://www.youtube.com/playlist?list=dups',
        name: 'Dups',
        audioOnly: true,
        autoUpdate: false,
        updateFrequencyHours: 24,
        includeThumbnails: false,
        sponsorBlockEnabled: false,
        sponsorBlockCategories: '[]',
        createdAt: DateTime.utc(2024),
        tracks: [track(1, 'a'), track(2, 'b'), track(2, 'c'), track(0, 'd')],
      ),
    );

    final playlist = await db.getPlaylistByUrl(
      'https://www.youtube.com/playlist?list=dups',
    );
    final imported = await db.getTracksForPlaylist(playlist!.id);
    expect(
      {for (final t in imported) t.videoId: t.index},
      {'a': 1, 'b': 2, 'c': 3, 'd': 4},
    );
  });

  test('a video listed twice keeps each entry\'s own segments', () async {
    DiscoveredTrack entry(int index, int startMs) => DiscoveredTrack(
      index: index,
      videoId: 'same',
      title: 'Same',
      status: 'pending',
      sponsorBlockSegments: [
        DiscoveredSponsorBlockSegment(
          source: 'local',
          category: 'sponsor',
          startMs: startMs,
          endMs: startMs + 1000,
        ),
      ],
    );

    final id = await metadata.importPlaylist(
      DiscoveredPlaylist(
        folderPath: folder,
        url: 'https://www.youtube.com/playlist?list=twice',
        name: 'Twice',
        audioOnly: true,
        autoUpdate: false,
        updateFrequencyHours: 24,
        includeThumbnails: false,
        sponsorBlockEnabled: false,
        sponsorBlockCategories: '[]',
        createdAt: DateTime.utc(2024),
        tracks: [entry(1, 1000), entry(2, 5000)],
      ),
    );

    final tracks = await db.getTracksForPlaylist(id);
    final starts = [
      for (final t in tracks)
        (await db.getSegmentsForTrack(t.id)).map((s) => s.startMs).toList(),
    ];
    expect(starts, [
      [1000],
      [5000],
    ]);
  });

  group('metadata files', () {
    test('a big playlist is written from a worker isolate', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final count = MetadataService.isolateTrackThreshold + 5;
      for (var i = 1; i <= count; i++) {
        await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: i,
          videoId: 'v$i',
          title: 'Track $i',
        );
      }

      await metadata.writeMetadataFor(playlist.id);

      final data =
          jsonDecode(await File(at('woolytube_meta.json')).readAsString())
              as Map<String, dynamic>;
      expect(data['tracks'] as List, hasLength(count));
      expect(
        metadata.writtenRevision(playlist.id),
        await db.playlistRevision(playlist.id),
      );
    });

    test('unchanged files are not rewritten, even after a restart', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(db, playlistId: playlist.id);
      await metadata.writeMetadataFor(playlist.id);
      final file = File(at('woolytube_meta.json'));
      final old = DateTime(2020);
      await file.setLastModified(old);

      // A new service knows nothing about what was written before.
      await MetadataService(db).writeMetadataFor(playlist.id);
      expect(await file.lastModified(), old);

      await db.updateTrackAlwaysSkip(
        (await db.getTracksForPlaylist(playlist.id)).single.id,
        true,
      );
      await metadata.writeMetadataFor(playlist.id);
      expect(await file.lastModified(), isNot(old));
    });

    test('requests while a write waits share it and read fresh data', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);
      final first = metadata.writeMetadataFor(playlist.id);
      final second = metadata.writeMetadataFor(playlist.id);
      final third = metadata.writeMetadataFor(playlist.id);
      expect(identical(second, third), isTrue);
      await db.updateTrackFields(track.id, title: 'Renamed');
      await Future.wait([first, second, third]);

      final data =
          jsonDecode(await File(at('woolytube_meta.json')).readAsString())
              as Map<String, dynamic>;
      expect((data['tracks'] as List).single['title'], 'Renamed');
    });

    test('a deleted playlist is ignored', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await db.deletePlaylist(playlist.id);
      await metadata.writeMetadataFor(playlist.id);
      expect(exists('woolytube_meta.json'), isFalse);
    });
  });

  test(
    'the import scan does not read folders already in the library',
    () async {
      final libraryRoot = p.join(tempDir.path, 'Music');
      final known = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(db, playlistId: known.id);
      await metadata.writeMetadataFor(known.id);
      final found = await metadata.scanDirectory(
        libraryRoot,
        maxDepth: 1,
        skipFolders: [folder],
      );
      expect(found, isEmpty);
      final all = await metadata.scanDirectory(libraryRoot, maxDepth: 1);
      expect(all.map((d) => d.folderPath), [folder]);
    },
  );
}
