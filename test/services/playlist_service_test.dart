import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';

import '../helpers/test_database.dart';

class FakeYtDlpService extends YtDlpService {
  Map<String, dynamic> playlistInfo = {'entries': <dynamic>[]};
  final requestedPlaylistUrls = <String>[];

  @override
  Future<Map<String, dynamic>> getPlaylistInfo(String url) async {
    requestedPlaylistUrls.add(url);
    return playlistInfo;
  }
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late FakeYtDlpService ytdlp;
  late PlaylistService service;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_playlist_test_');
    ytdlp = FakeYtDlpService();
    service = PlaylistService(db, ytdlp, MetadataService(db));
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('populates tracks and marks unavailable entries', () async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);

    await service.populateTracksFromInfo(playlist.id, {
      'entries': [
        {
          'id': 'available',
          'playlist_index': 5,
          'title': 'Available Track',
          'thumbnail': 'https://example.com/available.jpg',
          'duration': 42,
        },
        {'id': 'private', 'title': '[Private video]'},
        {'id': 'deleted', 'playlist_index': 7, 'title': '[Deleted video]'},
        {'id': '', 'title': 'No id'},
        {'title': 'Missing id'},
      ],
    });

    final tracks = await db.getTracksForPlaylist(playlist.id);
    expect(tracks.map((track) => track.videoId), [
      'private',
      'available',
      'deleted',
    ]);
    expect(tracks[0].status, 'unavailable');
    expect(tracks[0].unavailableReason, 'private');
    expect(tracks[1].status, 'pending');
    expect(tracks[1].title, 'Available Track');
    expect(tracks[1].thumbnailUrl, 'https://example.com/available.jpg');
    expect(tracks[1].durationSeconds, 42);
    expect(tracks[2].status, 'unavailable');
    expect(tracks[2].unavailableReason, 'deleted');
    expect(
      await File(p.join(tempDir.path, 'woolytube_meta.json')).exists(),
      isTrue,
    );
  });

  test(
    'syncs playlist additions, removals, availability, and ordering',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=sync',
        outputPath: tempDir.path,
      );

      final downloadedGonePath = p.join(tempDir.path, '00004_Downloaded.mp4');
      final replacementPath = p.join(tempDir.path, '00006_Replacement.m4a');
      final completeIndexPath = p.join(tempDir.path, '00007_Complete.mp4');
      await File(downloadedGonePath).writeAsString('video');
      await File(replacementPath).writeAsString('audio');
      await File(completeIndexPath).writeAsString('video');

      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'complete',
        title: 'Complete',
        status: 'complete',
        filePath: p.join(tempDir.path, 'missing-complete.mp4'),
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'pending',
        title: 'Pending',
        status: 'pending',
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'gone',
        title: 'Gone',
        status: 'pending',
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 4,
        videoId: 'downloaded-gone',
        title: 'Downloaded Gone',
        status: 'complete',
        filePath: downloadedGonePath,
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 5,
        videoId: 'back',
        title: 'Old Back Title',
        status: 'unavailable',
        unavailableReason: 'deleted',
      );
      final replacement = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 6,
        videoId: 'replacement',
        title: 'Replacement',
        status: 'complete',
        filePath: replacementPath,
        unavailableReason: 'private',
        isLocalReplacement: true,
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 7,
        videoId: 'complete-index',
        title: 'Complete Index',
        status: 'complete',
        filePath: completeIndexPath,
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 8,
        videoId: 'pending-index',
        title: 'Pending Index',
        status: 'pending',
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 9,
        videoId: 'will-private',
        title: 'Will Be Private',
        status: 'pending',
      );

      ytdlp.playlistInfo = {
        'entries': [
          {
            'id': 'complete',
            'playlist_index': 99,
            'title': 'Complete New Title',
          },
          {'id': 'pending', 'playlist_index': 20, 'title': 'Pending New Index'},
          {
            'id': 'back',
            'playlist_index': 21,
            'title': 'Back Online',
            'thumbnail': 'https://example.com/back.jpg',
            'duration': 300,
          },
          {'id': 'replacement', 'playlist_index': 22, 'title': 'Back Too'},
          {
            'id': 'complete-index',
            'playlist_index': 100,
            'title': 'Complete Index',
          },
          {
            'id': 'pending-index',
            'playlist_index': 101,
            'title': 'Pending Index',
          },
          {
            'id': 'will-private',
            'playlist_index': 102,
            'title': 'Will Be Private',
            'availability': 'private',
          },
          {'id': 'new', 'playlist_index': 103, 'title': 'New Track'},
          {
            'id': 'new-private',
            'playlist_index': 104,
            'title': '[Private video]',
          },
          {'id': '', 'title': 'Ignored'},
        ],
      };

      final result = await service.syncPlaylist(playlist);

      expect(ytdlp.requestedPlaylistUrls, [playlist.url]);
      expect(result.added, 2);
      expect(result.removed, 2);
      expect(result.markedAvailable, 2);
      expect(result.markedUnavailable, 1);
      expect(result.hasChanges, isTrue);
      expect(result.hasConflicts, isTrue);
      expect(result.replacementConflicts.map((track) => track.id), [
        replacement.id,
      ]);

      final tracks = await db.getTracksForPlaylist(playlist.id);
      final byVideoId = {for (final track in tracks) track.videoId: track};

      expect(byVideoId['gone']!.status, 'unavailable');
      expect(byVideoId['gone']!.unavailableReason, 'removed');
      expect(byVideoId['downloaded-gone']!.status, 'complete');
      expect(byVideoId['downloaded-gone']!.unavailableReason, 'removed');
      expect(byVideoId['back']!.status, 'pending');
      expect(byVideoId['back']!.unavailableReason, isNull);
      expect(byVideoId['back']!.title, 'Back Online');
      expect(byVideoId['back']!.thumbnailUrl, 'https://example.com/back.jpg');
      expect(byVideoId['back']!.durationSeconds, 300);
      expect(byVideoId['back']!.index, 21);
      expect(byVideoId['replacement']!.status, 'complete');
      expect(byVideoId['replacement']!.unavailableReason, isNull);
      expect(byVideoId['complete-index']!.index, 7);
      expect(byVideoId['pending-index']!.index, 101);
      expect(byVideoId['will-private']!.status, 'unavailable');
      expect(byVideoId['will-private']!.unavailableReason, 'private');
      expect(byVideoId['will-private']!.index, 102);
      expect(byVideoId['new']!.status, 'pending');
      expect(byVideoId['new-private']!.status, 'unavailable');
      expect(byVideoId['new-private']!.unavailableReason, 'private');
      expect(
        await File(p.join(tempDir.path, 'woolytube_meta.json')).exists(),
        isTrue,
      );
    },
  );
}
