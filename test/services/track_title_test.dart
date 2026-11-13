import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/track_title.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

void main() {
  group('title fallback', () {
    test('"null", "None" and blank are missing titles', () {
      for (final missing in [null, '', '   ', 'null', 'None', ' null ']) {
        expect(isMissingTitle(missing), isTrue, reason: '$missing');
      }
      for (final real in ['Nullify', 'None of them', 'NULL bytes', '0']) {
        expect(isMissingTitle(real), isFalse, reason: real);
      }
    });

    test('a stored title falls back to the previous one, then the id', () {
      expect(resolveTrackTitle(' Song ', videoId: 'abc'), 'Song');
      expect(
        resolveTrackTitle('null', previous: 'Old song', videoId: 'abc'),
        'Old song',
      );
      expect(resolveTrackTitle(null, previous: 'None', videoId: 'abc'), 'abc');
      expect(resolveTrackTitle('', videoId: 'abc'), 'abc');
    });

    Track track({required String title, String? filePath}) => Track(
      id: 1,
      playlistId: 1,
      index: 18,
      videoId: 'Npv8XMyi9fM',
      title: title,
      filePath: filePath,
      status: 'complete',
      isLocalReplacement: false,
      alwaysSkip: false,
      replaceRequested: false,
    );

    test('the shown title of a "null" track is its file name, then its id', () {
      expect(track(title: 'Real').displayTitle, 'Real');
      expect(
        track(
          title: 'null',
          filePath: '/m/WoolyTube/List/00018_Some song.mp4',
        ).displayTitle,
        'Some song',
      );
      // A file named after the "null" title gives nothing better.
      expect(
        track(title: 'null', filePath: '/m/00029_null.mp4').displayTitle,
        'Npv8XMyi9fM',
      );
      expect(track(title: '').displayTitle, 'Npv8XMyi9fM');
      // The id stored as a stand-in also shows the file name.
      expect(
        track(
          title: 'Npv8XMyi9fM',
          filePath: '/m/00018_Some song.mp4',
        ).displayTitle,
        'Some song',
      );
    });
  });

  group('stored titles', () {
    late AppDatabase db;
    late Directory tempDir;
    late String folder;
    late FakeYtDlpService ytdlp;
    late MetadataService metadata;
    late PlaylistService service;

    setUp(() async {
      db = openTestDatabase();
      tempDir = await Directory.systemTemp.createTemp('woolytube_title_');
      folder = p.join(tempDir.path, 'Playlist');
      await Directory(folder).create();
      ytdlp = FakeYtDlpService();
      metadata = MetadataService(db);
      service = PlaylistService(
        db,
        ytdlp,
        metadata,
        FakeMediaThumbnailService(),
      );
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('a listed video without a title is stored under its id, never '
        '"null"', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await service.populateTracksFromInfo(playlist.id, {
        'entries': [
          // What the old plugin sent for a JSON null title.
          {'id': 'private1', 'playlist_index': 1, 'title': 'null'},
          {'id': 'terminated', 'playlist_index': 2},
          {'id': 'blank', 'playlist_index': 3, 'title': '  '},
          {'id': 'ok', 'playlist_index': 4, 'title': 'A song'},
        ],
      });

      final tracks = await db.getTracksForPlaylist(playlist.id);
      expect(tracks.map((t) => t.title), [
        'private1',
        'terminated',
        'blank',
        'A song',
      ]);
      final sidecar =
          await File(p.join(folder, 'woolytube_meta.json')).readAsString();
      expect(sidecar, isNot(contains('"title":"null"')));
    });

    test('an update replaces a "null" title with the one YouTube lists, '
        'and leaves real titles alone', () async {
      final playlist = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=titles',
        outputPath: folder,
      );
      final broken = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'broken',
        title: 'null',
        status: 'error',
      );
      final standIn = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'standin',
        title: 'standin',
      );
      final renamed = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'renamed',
        title: 'My own name',
      );
      final stillPrivate = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 4,
        videoId: 'private',
        title: 'None',
      );
      ytdlp.playlistInfo = {
        'entries': [
          {'id': 'broken', 'title': 'Back with a title'},
          {'id': 'standin', 'title': 'Real title'},
          {'id': 'renamed', 'title': 'YouTube name'},
          {'id': 'private', 'title': '[Private video]'},
        ],
      };

      await service.syncPlaylist(playlist);

      Future<String> titleOf(Track t) async => (await db.getTrack(t.id))!.title;
      expect(await titleOf(broken), 'Back with a title');
      expect(await titleOf(standIn), 'Real title');
      expect(await titleOf(renamed), 'My own name');
      // YouTube's own stand-in is no better; the next real title heals it.
      expect(await titleOf(stillPrivate), 'None');
    });

    test('a video available again never takes a missing title', () async {
      final playlist = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=back',
        outputPath: folder,
      );
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'back',
        title: 'Old title',
        status: 'unavailable',
        unavailableReason: 'deleted',
      );
      ytdlp.playlistInfo = {
        'entries': [
          {'id': 'back'},
        ],
      };

      await service.syncPlaylist(playlist);

      final fresh = (await db.getTrack(track.id))!;
      expect(fresh.status, 'pending');
      expect(fresh.title, 'Old title');
    });

    test('a downloaded video\'s metadata heals a "null" title only', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final broken = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'vid1',
        title: 'null',
        status: 'complete',
        filePath: p.join(folder, '00001_Real title.mp4'),
      );
      final kept = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'vid2',
        title: 'Owner title',
        status: 'complete',
        filePath: p.join(folder, '00002_Other.mp4'),
      );
      for (final (index, id, name) in [
        (1, 'vid1', 'Real title'),
        (2, 'vid2', 'Other'),
      ]) {
        await File(p.join(folder, '0000${index}_$name.mp4')).writeAsString('x');
        await File(
          p.join(folder, '0000${index}_$name.info.json'),
        ).writeAsString(jsonEncode({'id': id, 'title': 'From YouTube $id'}));
      }

      await metadata.reconcilePlaylist(playlist);

      expect((await db.getTrack(broken.id))!.title, 'From YouTube vid1');
      expect((await db.getTrack(kept.id))!.title, 'Owner title');
    });

    test('a sidecar "null" title imports as a healable stand-in', () async {
      await File(p.join(folder, 'woolytube_meta.json')).writeAsString(
        jsonEncode({
          'version': 2,
          'playlist': {
            'url': 'https://www.youtube.com/playlist?list=side',
            'name': 'Side',
          },
          'tracks': [
            {
              'index': 18,
              'videoId': 'Npv8XMyi9fM',
              'title': 'null',
              'status': 'unavailable',
              'unavailableReason': 'removed_by_youtube',
            },
            {'index': 19, 'videoId': 'x2', 'title': null},
            {'index': 20, 'videoId': 'x3', 'title': 'Kept'},
          ],
        }),
      );

      final discovered = await metadata.readFolder(folder);
      final id = await metadata.importPlaylist(discovered!);
      final tracks = await db.getTracksForPlaylist(id);
      expect(tracks.map((t) => t.title), ['Npv8XMyi9fM', 'x2', 'Kept']);
      expect(isStandInTitle(tracks[0].title, tracks[0].videoId), isTrue);
    });

    test('the sidecar and m3u never say "null"', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final file = p.join(folder, '00029_null.mp4');
      await File(file).writeAsString('x');
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 29,
        videoId: 'Sl_XjhxRo8k',
        title: 'null',
        status: 'complete',
        filePath: file,
      );

      final sidecar = jsonDecode(buildSidecarJson(playlist, [track], const {}));
      expect((sidecar['tracks'] as List).single['title'], 'Sl_XjhxRo8k');
      final m3u = MetadataService.buildPlaylistFile(playlist, [track]);
      expect(m3u, contains('#EXTINF:-1,Sl_XjhxRo8k'));
      expect(m3u, isNot(contains(',null')));
    });
  });
}
