import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/media_thumbnail_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/thumbnail_backfill_service.dart';

import '../helpers/test_database.dart';

const _jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46];
const _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00];
final _webp = [
  ...'RIFF'.codeUnits,
  0x24,
  0x00,
  0x00,
  0x00,
  ...'WEBPVP8 '.codeUnits,
];

class _FakeMediaThumbnails extends MediaThumbnailService {
  /// Embedded cover bytes by media path.
  final embedded = <String, List<int>>{};
  final requests = <({String mediaPath, String targetStem})>[];

  @override
  Future<String?> extractEmbeddedThumbnail({
    required String mediaPath,
    required String targetStem,
  }) async {
    requests.add((mediaPath: mediaPath, targetStem: targetStem));
    final bytes = embedded[mediaPath];
    if (bytes == null) return null;
    final path = '$targetStem.jpg';
    await File(path).writeAsBytes(bytes);
    return path;
  }
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late MetadataService metadata;
  late _FakeMediaThumbnails media;
  late Map<String, File> cache;
  late List<String> lookups;
  late Map<String, List<int>> remote;
  late List<String> downloads;
  late ThumbnailBackfillService service;
  late String folder;
  late Playlist playlist;

  String thumbsDir() => LibraryLayout.thumbnailsDir(folder);

  String ytUrl(String videoId) =>
      'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';

  Future<File> cachedImage(String name, List<int> bytes) async {
    final file = File(p.join(tempDir.path, 'image-cache', name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<Track> addTrack({
    int index = 1,
    String videoId = 'vid1',
    String? thumbnailUrl,
    String? thumbnailPath,
    bool isLocalReplacement = false,
    String status = 'complete',
    bool createFile = true,
  }) async {
    final filePath = p.join(folder, '0000${index}_Song $index.m4a');
    if (createFile) await File(filePath).writeAsBytes(const [1, 2, 3]);
    return insertTestTrack(
      db,
      playlistId: playlist.id,
      index: index,
      videoId: videoId,
      title: 'Song $index',
      thumbnailUrl: thumbnailUrl,
      thumbnailPath: thumbnailPath,
      filePath: filePath,
      status: status,
      isLocalReplacement: isLocalReplacement,
    );
  }

  Future<Track> reload(Track track) async => (await db.getTrack(track.id))!;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('woolytube_backfill_test');
    LibraryLayout.overrideBasePathsForTesting(
      audio: p.join(tempDir.path, 'Music'),
      video: p.join(tempDir.path, 'Movies'),
    );
    db = openTestDatabase();
    metadata = MetadataService(db);
    media = _FakeMediaThumbnails();
    cache = {};
    lookups = [];
    remote = {};
    downloads = [];
    service = ThumbnailBackfillService(
      db,
      metadata,
      media,
      LogService(),
      lookupCachedImage: (url) async {
        lookups.add(url);
        return cache[url];
      },
      downloadImage: (url, target) async {
        downloads.add(url);
        final body = remote[url];
        if (body == null) return false;
        await target.writeAsBytes(body);
        return true;
      },
    );
    folder = p.join(tempDir.path, 'Music', 'Mix');
    await Directory(folder).create(recursive: true);
    playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
  });

  tearDown(() async {
    await db.close();
    LibraryLayout.resetBasePathsForTesting();
    await tempDir.delete(recursive: true);
  });

  group('ensureTrackThumbnails', () {
    test('uses an image already named for the track', () async {
      final track = await addTrack();
      await Directory(thumbsDir()).create(recursive: true);
      final existing = File(p.join(thumbsDir(), 'vid1.png'));
      await existing.writeAsBytes(_png);

      expect(await service.ensureTrackThumbnails(playlist), 1);

      expect((await reload(track)).thumbnailPath, existing.path);
      expect(media.requests, isEmpty);
      expect(lookups, isEmpty);
    });

    test('extracts the cover embedded in the media file first', () async {
      final track = await addTrack();
      media.embedded[track.filePath!] = _jpeg;
      cache[ytUrl('vid1')] = await cachedImage('a', _png);

      expect(await service.ensureTrackThumbnails(playlist), 1);

      final expected = p.join(thumbsDir(), 'vid1.jpg');
      expect((await reload(track)).thumbnailPath, expected);
      expect(media.requests.single.mediaPath, track.filePath);
      expect(media.requests.single.targetStem, p.join(thumbsDir(), 'vid1'));
      expect(File(p.join(thumbsDir(), '.nomedia')).existsSync(), isTrue);
      expect(lookups, isEmpty);
    });

    test('copies the cached image when the file has no cover', () async {
      final plain = await addTrack();
      final custom = await addTrack(
        index: 2,
        videoId: 'vid2',
        thumbnailUrl: 'https://example.com/cover.webp',
      );
      cache[ytUrl('vid1')] = await cachedImage('a', _jpeg);
      cache['https://example.com/cover.webp'] = await cachedImage('b', _webp);

      expect(await service.ensureTrackThumbnails(playlist), 2);

      final plainPath = (await reload(plain)).thumbnailPath!;
      expect(plainPath, p.join(thumbsDir(), 'vid1.jpg'));
      expect(File(plainPath).readAsBytesSync(), _jpeg);
      // The file is named after its real format.
      expect(
        (await reload(custom)).thumbnailPath,
        p.join(thumbsDir(), 'vid2.webp'),
      );
      expect(downloads, isEmpty);
      // Nothing half-written is left behind.
      expect(
        Directory(thumbsDir()).listSync().map((e) => p.basename(e.path)),
        unorderedEquals(['.nomedia', 'vid1.jpg', 'vid2.webp']),
      );
    });

    test('downloads only when the network is allowed', () async {
      final track = await addTrack();
      remote[ytUrl('vid1')] = _jpeg;

      expect(await service.ensureTrackThumbnails(playlist), 0);
      expect(downloads, isEmpty);
      expect((await reload(track)).thumbnailPath, isNull);

      expect(
        await service.ensureTrackThumbnails(playlist, allowNetwork: true),
        1,
      );
      expect(downloads, [ytUrl('vid1')]);
      expect(
        (await reload(track)).thumbnailPath,
        p.join(thumbsDir(), 'vid1.jpg'),
      );
    });

    test('rejects a download that is not an image', () async {
      final track = await addTrack();
      remote[ytUrl('vid1')] = utf8.encode('<html>Not found</html>');

      expect(
        await service.ensureTrackThumbnails(playlist, allowNetwork: true),
        0,
      );

      expect((await reload(track)).thumbnailPath, isNull);
      expect(Directory(thumbsDir()).listSync().map((e) => p.basename(e.path)), [
        '.nomedia',
      ]);
    });

    test(
      'does not retry a track without any cover in the same session',
      () async {
        await addTrack();

        await service.ensureTrackThumbnails(playlist);
        await service.ensureTrackThumbnails(playlist);
        expect(media.requests, hasLength(1));
        expect(lookups, hasLength(1));

        // Network may still find one.
        await service.ensureTrackThumbnails(playlist, allowNetwork: true);
        expect(media.requests, hasLength(2));
        expect(downloads, hasLength(1));

        await service.ensureTrackThumbnails(playlist, allowNetwork: true);
        expect(media.requests, hasLength(2));
        expect(downloads, hasLength(1));
      },
    );

    test('never touches tracks that already have a local thumbnail', () async {
      final own = File(p.join(tempDir.path, 'own.jpg'))
        ..writeAsBytesSync(_jpeg);
      final track = await addTrack(thumbnailPath: own.path);
      final pending = await addTrack(
        index: 2,
        videoId: 'vid2',
        status: 'pending',
        createFile: false,
      );
      media.embedded[track.filePath!] = _png;
      cache[ytUrl('vid1')] = await cachedImage('a', _png);
      cache[ytUrl('vid2')] = await cachedImage('b', _png);

      expect(
        await service.ensureTrackThumbnails(playlist, allowNetwork: true),
        0,
      );

      expect((await reload(track)).thumbnailPath, own.path);
      expect((await reload(pending)).thumbnailPath, isNull);
      expect(media.requests, isEmpty);
      expect(lookups, isEmpty);
      expect(downloads, isEmpty);
      expect(Directory(thumbsDir()).existsSync(), isFalse);
    });

    test('replaces a recorded thumbnail whose file is gone', () async {
      final track = await addTrack(
        thumbnailPath: p.join(tempDir.path, 'deleted.jpg'),
      );
      cache[ytUrl('vid1')] = await cachedImage('a', _jpeg);

      expect(await service.ensureTrackThumbnails(playlist), 1);
      expect(
        (await reload(track)).thumbnailPath,
        p.join(thumbsDir(), 'vid1.jpg'),
      );
    });

    test('local files and forced inserts never use YouTube images', () async {
      final local = await addTrack(videoId: 'vidL', isLocalReplacement: true);
      await addTrack(index: 2, videoId: 'force-insert:1700000000');
      cache[ytUrl('vidL')] = await cachedImage('a', _jpeg);
      remote[ytUrl('vidL')] = _jpeg;

      expect(
        await service.ensureTrackThumbnails(playlist, allowNetwork: true),
        0,
      );

      expect(lookups, isEmpty);
      expect(downloads, isEmpty);
      expect(
        media.requests.map((r) => r.targetStem),
        contains(p.join(thumbsDir(), 'vidL.local')),
      );
      expect((await reload(local)).thumbnailPath, isNull);
    });

    test('records new covers in the sidecar', () async {
      await addTrack();
      cache[ytUrl('vid1')] = await cachedImage('a', _jpeg);

      await service.ensureTrackThumbnails(playlist);

      final sidecar =
          jsonDecode(
                File(
                  p.join(folder, MetadataService.metaFileName),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final tracks = sidecar['tracks'] as List<dynamic>;
      expect(
        (tracks.single as Map<String, dynamic>)['thumbnailFileName'],
        p.join(LibraryLayout.thumbnailsDirName, 'vid1.jpg'),
      );
    });

    test('creates nothing for a playlist whose folder is gone', () async {
      await addTrack();
      cache[ytUrl('vid1')] = await cachedImage('a', _jpeg);
      await Directory(folder).delete(recursive: true);

      expect(await service.ensureTrackThumbnails(playlist), 0);
      expect(Directory(folder).existsSync(), isFalse);
    });

    test('records many covers in a few batches', () async {
      for (var i = 1; i <= 30; i++) {
        final track = await addTrack(index: i, videoId: 'v$i');
        media.embedded[track.filePath!] = _jpeg;
      }
      final updates = <Set<TableUpdate>>[];
      final sub = db
          .tableUpdates(TableUpdateQuery.onTable(db.tracks))
          .listen(updates.add);
      addTearDown(sub.cancel);

      expect(await service.ensureTrackThumbnails(playlist), 30);
      await pumpEventQueue();

      for (final track in await db.getTracksForPlaylist(playlist.id)) {
        expect(track.thumbnailPath, isNotNull);
      }
      expect(updates.length, lessThanOrEqualTo(3));
    });

    test('stops when the playlist is deleted meanwhile, and never brings '
        'its folder back', () async {
      final first = await addTrack(index: 1, videoId: 'v1');
      await addTrack(index: 2, videoId: 'v2');
      cache[ytUrl('v2')] = await cachedImage('v2', _jpeg);
      media.embedded[first.filePath!] = _jpeg;
      // The first cover is extracted, then the playlist and its folder go.
      var deleted = false;
      final paused = ThumbnailBackfillService(
        db,
        metadata,
        media,
        LogService(),
        lookupCachedImage: (url) async => cache[url],
        shouldPause: () {
          if (!deleted && media.requests.isNotEmpty) {
            deleted = true;
            db.deletePlaylist(playlist.id);
            Directory(folder).deleteSync(recursive: true);
          }
          return false;
        },
      );

      await paused.ensureTrackThumbnails(playlist);

      expect(Directory(folder).existsSync(), isFalse);
    });

    test('waits while a folder is being moved or deleted', () async {
      final track = await addTrack();
      media.embedded[track.filePath!] = _jpeg;
      var busy = true;
      final waiting = ThumbnailBackfillService(
        db,
        metadata,
        media,
        LogService(),
        lookupCachedImage: (url) async => null,
        shouldPause: () => busy,
      );

      final run = waiting.ensureTrackThumbnails(playlist);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(media.requests, isEmpty);
      busy = false;
      expect(await run, 1);
    });
  });

  group('ensurePlaylistCover', () {
    const coverUrl = 'https://i.ytimg.com/vi/cover/hqdefault.jpg';
    late String coverPath;

    setUp(() async {
      coverPath = '${LibraryLayout.playlistCoverStem(folder)}.jpg';
      await db.updatePlaylistFields(
        playlist.id,
        const PlaylistsCompanion(thumbnailUrl: Value(coverUrl)),
      );
      playlist = await db.getPlaylist(playlist.id);
    });

    test('saves the cached playlist image', () async {
      cache[coverUrl] = await cachedImage('cover', _jpeg);

      expect(await service.ensurePlaylistCover(playlist), coverPath);

      expect((await db.getPlaylist(playlist.id)).thumbnailPath, coverPath);
      expect(File(coverPath).readAsBytesSync(), _jpeg);
      final sidecar =
          jsonDecode(
                File(
                  p.join(folder, MetadataService.metaFileName),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(
        (sidecar['playlist'] as Map<String, dynamic>)['thumbnailFileName'],
        p.join(LibraryLayout.thumbnailsDirName, '_playlist_cover.jpg'),
      );
    });

    test('downloads the playlist image only when allowed', () async {
      remote[coverUrl] = _jpeg;

      expect(await service.ensurePlaylistCover(playlist), isNull);
      expect(downloads, isEmpty);

      expect(
        await service.ensurePlaylistCover(playlist, allowNetwork: true),
        coverPath,
      );
      expect(downloads, [coverUrl]);
    });

    test('falls back to the first track with a cover', () async {
      await addTrack();
      final second = File(p.join(tempDir.path, 'second.png'))
        ..writeAsBytesSync(_png);
      final third = File(p.join(tempDir.path, 'third.jpg'))
        ..writeAsBytesSync(_jpeg);
      await addTrack(index: 3, videoId: 'vid3', thumbnailPath: third.path);
      await addTrack(index: 2, videoId: 'vid2', thumbnailPath: second.path);

      final cover = await service.ensurePlaylistCover(playlist);

      expect(cover, '${LibraryLayout.playlistCoverStem(folder)}.png');
      expect(File(cover!).readAsBytesSync(), _png);
      expect((await db.getPlaylist(playlist.id)).thumbnailPath, cover);
      // A copy: the track keeps its own file.
      expect(second.existsSync(), isTrue);
    });

    test('leaves an existing cover alone', () async {
      final own = File(p.join(tempDir.path, 'own.jpg'))
        ..writeAsBytesSync(_jpeg);
      await db.updatePlaylistFields(
        playlist.id,
        PlaylistsCompanion(thumbnailPath: Value(own.path)),
      );
      cache[coverUrl] = await cachedImage('cover', _png);

      expect(await service.ensurePlaylistCover(playlist), isNull);
      expect((await db.getPlaylist(playlist.id)).thumbnailPath, own.path);
      expect(lookups, isEmpty);
    });
  });

  test('backfillAll gives tracks and playlists covers', () async {
    final track = await addTrack();
    media.embedded[track.filePath!] = _jpeg;

    expect(await service.backfillAll(), 2);

    expect(
      (await reload(track)).thumbnailPath,
      p.join(thumbsDir(), 'vid1.jpg'),
    );
    // No playlist image anywhere, so the first track's cover is used.
    expect(
      (await db.getPlaylist(playlist.id)).thumbnailPath,
      '${LibraryLayout.playlistCoverStem(folder)}.jpg',
    );
  });

  test('imageExtension recognises image formats only', () {
    expect(ThumbnailBackfillService.imageExtension(_jpeg), '.jpg');
    expect(ThumbnailBackfillService.imageExtension(_png), '.png');
    expect(ThumbnailBackfillService.imageExtension(_webp), '.webp');
    expect(
      ThumbnailBackfillService.imageExtension('GIF89a....'.codeUnits),
      '.gif',
    );
    expect(
      ThumbnailBackfillService.imageExtension(utf8.encode('<html>')),
      null,
    );
    expect(ThumbnailBackfillService.imageExtension(const []), null);
  });
}
