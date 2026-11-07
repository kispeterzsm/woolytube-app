import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

/// New videos go where the owner put them on YouTube (after their nearest
/// predecessor the app already has); existing tracks keep their relative
/// order and only ever move to higher numbers.
void main() {
  late AppDatabase db;
  late Directory tempDir;
  late String folder;
  late Playlist playlist;
  late FakeYtDlpService ytdlp;
  late PlaylistService service;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_placement_');
    folder = p.join(tempDir.path, 'Playlist');
    await Directory(folder).create();
    playlist = await insertTestPlaylist(db, outputPath: folder);
    ytdlp = FakeYtDlpService();
    service = PlaylistService(
      db,
      ytdlp,
      MetadataService(db),
      FakeMediaThumbnailService(),
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Inserts tracks `videoId -> index`; a file is created for each name in
  /// [files].
  Future<Map<String, Track>> givenTracks(
    Map<String, int> indexByVideoId, {
    Map<String, String> files = const {},
  }) async {
    final result = <String, Track>{};
    for (final entry in indexByVideoId.entries) {
      final fileName = files[entry.key];
      String? path;
      if (fileName != null) {
        path = p.join(folder, fileName);
        await File(path).writeAsString(entry.key);
      }
      result[entry.key] = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: entry.value,
        videoId: entry.key,
        title: entry.key.toUpperCase(),
        filePath: path,
        status: path == null ? 'pending' : 'complete',
      );
    }
    return result;
  }

  ({Map<String, int> added, Map<String, int> moved}) plan(
    Map<String, Track> tracks,
    List<String> remote,
  ) {
    final result = PlaylistService.planPlacement(
      existingTracks: tracks.values.toList(),
      remoteVideoIds: remote,
    );
    final videoOf = {for (final t in tracks.values) t.id: t.videoId};
    return (
      added: result.newIndexByVideoId,
      moved: {
        for (final e in result.movedIndexByTrackId.entries)
          videoOf[e.key]!: e.value,
      },
    );
  }

  Map<String, dynamic> remoteEntry(String id) => {'id': id, 'title': id};

  Future<Map<String, Track>> tracksByVideoId() async => {
    for (final t in await db.getTracksForPlaylist(playlist.id)) t.videoId: t,
  };

  group('planPlacement', () {
    test('a video added in the middle goes after its predecessor and later '
        'tracks move up', () async {
      final tracks = await givenTracks({'a': 1, 'b': 2, 'c': 3});

      final result = plan(tracks, ['a', 'new', 'b', 'c']);

      expect(result.added, {'new': 2});
      expect(result.moved, {'b': 3, 'c': 4});
    });

    test('several new videos in a row keep their YouTube order', () async {
      final tracks = await givenTracks({'a': 1, 'b': 2});

      final result = plan(tracks, ['a', 'n1', 'n2', 'n3', 'b']);

      expect(result.added, {'n1': 2, 'n2': 3, 'n3': 4});
      expect(result.moved, {'b': 5});
    });

    test('a video added at the top goes before everything', () async {
      final tracks = await givenTracks({'a': 1, 'b': 2});

      final result = plan(tracks, ['top', 'a', 'b']);

      expect(result.added, {'top': 1});
      expect(result.moved, {'a': 2, 'b': 3});
    });

    test('removed and local-only tracks keep their place', () async {
      final tracks = await givenTracks({
        'a': 1,
        'gone': 2,
        'force-insert:1700000000': 3,
        'b': 4,
      });

      // After b: nothing moves.
      var result = plan(tracks, ['a', 'b', 'new']);
      expect(result.added, {'new': 5});
      expect(result.moved, isEmpty);

      // After a: the tracks YouTube no longer lists stay between a and b.
      result = plan(tracks, ['a', 'new', 'b']);
      expect(result.added, {'new': 2});
      expect(result.moved, {'gone': 3, 'force-insert:1700000000': 4, 'b': 5});
    });

    test('a gap in the numbers absorbs an insertion', () async {
      final tracks = await givenTracks({'a': 1, 'b': 5, 'c': 6});

      final result = plan(tracks, ['a', 'n1', 'n2', 'b', 'c']);

      expect(result.added, {'n1': 2, 'n2': 3});
      expect(result.moved, isEmpty);
    });

    test('remote reorders of existing tracks are not mirrored', () async {
      final tracks = await givenTracks({'a': 1, 'b': 2, 'c': 3});

      var result = plan(tracks, ['c', 'b', 'a']);
      expect(result.added, isEmpty);
      expect(result.moved, isEmpty);

      // A new video after c (last locally) is appended, not moved forward.
      result = plan(tracks, ['c', 'new', 'b', 'a']);
      expect(result.added, {'new': 4});
      expect(result.moved, isEmpty);
    });
  });

  group('sync', () {
    test(
      'renames the files of shifted tracks and keeps their paths in step',
      () async {
        await givenTracks(
          {'a': 1, 'b': 2, 'c': 3},
          files: {'a': '00001_A.m4a', 'b': '00002_B.m4a'},
        );
        ytdlp.playlistInfo = {
          'entries': [
            for (final id in ['a', 'new', 'b', 'c']) remoteEntry(id),
          ],
        };

        final result = await service.syncPlaylist(playlist);

        expect(result.added, 1);
        final tracks = await db.getTracksForPlaylist(playlist.id);
        expect(tracks.map((t) => t.videoId), ['a', 'new', 'b', 'c']);
        expect(tracks.map((t) => t.index), [1, 2, 3, 4]);
        final byId = await tracksByVideoId();
        expect(byId['a']!.filePath, p.join(folder, '00001_A.m4a'));
        expect(byId['new']!.status, 'pending');
        expect(byId['b']!.filePath, p.join(folder, '00003_B.m4a'));
        expect(await File(byId['b']!.filePath!).readAsString(), 'b');
        expect(await File(p.join(folder, '00002_B.m4a')).exists(), isFalse);
        expect(byId['c']!.filePath, isNull);

        final sidecar =
            jsonDecode(
                  await File(
                    p.join(folder, 'woolytube_meta.json'),
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        expect(
          [for (final t in sidecar['tracks'] as List) t['videoId']],
          ['a', 'new', 'b', 'c'],
        );
        expect(
          [for (final t in sidecar['tracks'] as List) t['fileName']],
          ['00001_A.m4a', null, '00003_B.m4a', null],
        );
      },
    );

    test('a video added at the top shifts every file by one', () async {
      await givenTracks(
        {'a': 1, 'b': 2},
        files: {'a': '00001_A.m4a', 'b': '00002_B.m4a'},
      );
      ytdlp.playlistInfo = {
        'entries': [
          for (final id in ['top', 'a', 'b']) remoteEntry(id),
        ],
      };

      await service.syncPlaylist(playlist);

      final byId = await tracksByVideoId();
      expect(byId['top']!.index, 1);
      expect(byId['a']!.index, 2);
      expect(byId['b']!.index, 3);
      expect(await File(byId['a']!.filePath!).readAsString(), 'a');
      expect(await File(byId['b']!.filePath!).readAsString(), 'b');
      expect(p.basename(byId['a']!.filePath!), '00002_A.m4a');
      expect(p.basename(byId['b']!.filePath!), '00003_B.m4a');
      expect(
        Directory(folder)
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path))
            .where((n) => n.endsWith('.m4a'))
            .toSet(),
        {'00002_A.m4a', '00003_B.m4a'},
      );
    });

    test('a remote reorder changes nothing locally', () async {
      final before = await givenTracks(
        {'a': 1, 'b': 2},
        files: {'a': '00001_A.m4a', 'b': '00002_B.m4a'},
      );
      ytdlp.playlistInfo = {
        'entries': [
          for (final id in ['b', 'a']) remoteEntry(id),
        ],
      };

      final result = await service.syncPlaylist(playlist);

      expect(result.hasChanges, isFalse);
      expect(await tracksByVideoId(), before);
    });

    test('a brand-new playlist takes YouTube numbering', () async {
      ytdlp.playlistInfo = {
        'entries': [
          {'id': 'x', 'playlist_index': 1, 'title': 'X'},
          {'id': 'y', 'playlist_index': 2, 'title': 'Y'},
          {'id': 'z', 'playlist_index': 4, 'title': 'Z'},
        ],
      };

      final result = await service.syncPlaylist(playlist);

      expect(result.added, 3);
      expect(
        {
          for (final t in await db.getTracksForPlaylist(playlist.id))
            t.videoId: t.index,
        },
        {'x': 1, 'y': 2, 'z': 4},
      );
    });
  });
}
