import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/media_thumbnail_service.dart';
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

class FakeMediaThumbnailService extends MediaThumbnailService {
  bool hasEmbeddedThumbnail = false;
  final requestedMediaPaths = <String>[];

  @override
  Future<String?> extractEmbeddedThumbnail({
    required String mediaPath,
    required String playlistPath,
    required int trackId,
  }) async {
    requestedMediaPaths.add(mediaPath);
    if (!hasEmbeddedThumbnail) return null;
    final directory = Directory(p.join(playlistPath, '.woolytube_thumbnails'));
    await directory.create(recursive: true);
    final thumbnail = File(p.join(directory.path, 'track_$trackId.jpg'));
    await thumbnail.writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    return thumbnail.path;
  }
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late FakeYtDlpService ytdlp;
  late FakeMediaThumbnailService thumbnails;
  late PlaylistService service;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_playlist_test_');
    ytdlp = FakeYtDlpService();
    thumbnails = FakeMediaThumbnailService();
    service = PlaylistService(db, ytdlp, MetadataService(db), thumbnails);
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

  test(
    'force insert copies a video and shifts track indexes and filenames',
    () async {
      thumbnails.hasEmbeddedThumbnail = true;
      final outputDir = Directory(p.join(tempDir.path, 'video-playlist'));
      await outputDir.create();
      final playlist = await insertTestPlaylist(db, outputPath: outputDir.path);
      final firstPath = p.join(outputDir.path, '00001_First.mp4');
      final secondPath = p.join(outputDir.path, '00002_Second.mp4');
      await File(firstPath).writeAsString('first');
      await File(secondPath).writeAsString('second');
      final first = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'first',
        title: 'First',
        status: 'complete',
        filePath: firstPath,
      );
      final second = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'second',
        title: 'Second',
        status: 'complete',
        filePath: secondPath,
      );
      final source = File(p.join(tempDir.path, 'Lost Video.MP4'));
      await source.writeAsString('replacement');

      final inserted = await service.forceInsert(
        playlistId: playlist.id,
        index: 2,
        sourcePath: source.path,
        sourceFileName: 'Lost Video.MP4',
      );

      final tracks = await db.getTracksForPlaylist(playlist.id);
      expect(tracks.map((track) => track.index), [1, 2, 3]);
      expect(tracks.map((track) => track.id), [
        first.id,
        inserted.id,
        second.id,
      ]);
      expect(inserted.title, 'Lost Video');
      expect(inserted.status, 'complete');
      expect(inserted.isLocalReplacement, isTrue);
      expect(PlaylistService.isForcedInsertVideoId(inserted.videoId), isTrue);
      expect(p.basename(inserted.filePath!), '00002_Lost Video.mp4');
      expect(await File(inserted.filePath!).readAsString(), 'replacement');
      expect(inserted.thumbnailPath, isNotNull);
      expect(await File(inserted.thumbnailPath!).exists(), isTrue);
      expect(thumbnails.requestedMediaPaths, [inserted.filePath]);
      expect((await db.getTrack(first.id))!.filePath, firstPath);
      final shiftedSecond = (await db.getTrack(second.id))!;
      expect(shiftedSecond.index, 3);
      expect(p.basename(shiftedSecond.filePath!), '00003_Second.mp4');
      expect(await File(shiftedSecond.filePath!).readAsString(), 'second');
      expect(await File(secondPath).exists(), isFalse);
      expect(await source.exists(), isTrue);

      final metadata =
          jsonDecode(
                await File(
                  p.join(outputDir.path, 'woolytube_meta.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final metadataTracks = metadata['tracks'] as List<dynamic>;
      expect(metadataTracks.map((track) => track['index']), [1, 2, 3]);
      expect(metadataTracks[1]['videoId'], inserted.videoId);
      expect(metadataTracks[1]['fileName'], '00002_Lost Video.mp4');
      expect(
        metadataTracks[1]['thumbnailFileName'],
        p.join('.woolytube_thumbnails', 'track_${inserted.id}.jpg'),
      );
    },
  );

  test('local replacement extracts and stores embedded artwork', () async {
    thumbnails.hasEmbeddedThumbnail = true;
    final outputDir = Directory(p.join(tempDir.path, 'local-replacement'));
    await outputDir.create();
    final playlist = await insertTestPlaylist(db, outputPath: outputDir.path);
    final oldPath = p.join(outputDir.path, '00001_Old.mp4');
    await File(oldPath).writeAsString('old');
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'original-id',
      title: 'Original title',
      filePath: oldPath,
      status: 'complete',
    );
    final source = File(p.join(tempDir.path, 'Replacement.m4a'));
    await source.writeAsString('new');

    final updated = await service.replaceWithLocalFile(
      trackId: track.id,
      sourcePath: source.path,
      sourceFileName: 'Replacement.m4a',
    );

    expect(updated.isLocalReplacement, isTrue);
    expect(p.basename(updated.filePath!), '00001_Replacement.m4a');
    expect(await File(updated.filePath!).readAsString(), 'new');
    expect(await File(oldPath).exists(), isFalse);
    expect(updated.thumbnailPath, isNotNull);
    expect(await File(updated.thumbnailPath!).exists(), isTrue);
  });

  test(
    'backfills embedded artwork for an existing local replacement',
    () async {
      thumbnails.hasEmbeddedThumbnail = true;
      final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
      final media = File(p.join(tempDir.path, '00001_Existing.mp3'));
      await media.writeAsString('audio');
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        filePath: media.path,
        status: 'complete',
        isLocalReplacement: true,
      );

      expect(await service.backfillLocalThumbnails(playlist.id), 1);
      final updated = await db.getTrack(track.id);
      expect(updated!.thumbnailPath, isNotNull);
      expect(await File(updated.thumbnailPath!).exists(), isTrue);
      expect(await service.backfillLocalThumbnails(playlist.id), 0);
    },
  );

  test('force insert enforces the playlist media type', () async {
    final videoDir = Directory(p.join(tempDir.path, 'video'));
    final audioDir = Directory(p.join(tempDir.path, 'audio'));
    await videoDir.create();
    await audioDir.create();
    final videoPlaylist = await insertTestPlaylist(
      db,
      url: 'https://example.com/video-playlist',
      outputPath: videoDir.path,
    );
    final audioPlaylist = await insertTestPlaylist(
      db,
      url: 'https://example.com/audio-playlist',
      audioOnly: true,
      outputPath: audioDir.path,
    );
    final audioSource = File(p.join(tempDir.path, 'audio.mp3'));
    final videoSource = File(p.join(tempDir.path, 'video.mp4'));
    await audioSource.writeAsString('audio');
    await videoSource.writeAsString('video');

    await expectLater(
      service.forceInsert(
        playlistId: videoPlaylist.id,
        index: 1,
        sourcePath: audioSource.path,
      ),
      throwsA(
        isA<ForceInsertException>().having(
          (error) => error.message,
          'message',
          contains('video file'),
        ),
      ),
    );
    await expectLater(
      service.forceInsert(
        playlistId: audioPlaylist.id,
        index: 1,
        sourcePath: videoSource.path,
      ),
      throwsA(
        isA<ForceInsertException>().having(
          (error) => error.message,
          'message',
          contains('audio file'),
        ),
      ),
    );

    final insertedAudio = await service.forceInsert(
      playlistId: audioPlaylist.id,
      index: 1,
      sourcePath: audioSource.path,
    );
    expect(insertedAudio.filePath, endsWith('.mp3'));
    expect(insertedAudio.status, 'complete');
    expect(await db.getTracksForPlaylist(videoPlaylist.id), isEmpty);
  });

  test('force insert rejects an index beyond the end', () async {
    final outputDir = Directory(p.join(tempDir.path, 'index-playlist'));
    await outputDir.create();
    final playlist = await insertTestPlaylist(db, outputPath: outputDir.path);
    await insertTestTrack(db, playlistId: playlist.id, index: 1);
    final source = File(p.join(tempDir.path, 'video.mp4'));
    await source.writeAsString('video');

    await expectLater(
      service.forceInsert(
        playlistId: playlist.id,
        index: 3,
        sourcePath: source.path,
      ),
      throwsA(
        isA<ForceInsertException>().having(
          (error) => error.message,
          'message',
          contains('between 1 and 2'),
        ),
      ),
    );
  });

  test(
    'sync preserves forced insert positions for pending and new tracks',
    () async {
      final outputDir = Directory(p.join(tempDir.path, 'sync-force-insert'));
      await outputDir.create();
      final playlist = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=force-sync',
        outputPath: outputDir.path,
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'first',
        title: 'First',
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'third',
        title: 'Third',
      );
      final source = File(p.join(tempDir.path, 'Restored.mp4'));
      await source.writeAsString('restored');
      final forced = await service.forceInsert(
        playlistId: playlist.id,
        index: 2,
        sourcePath: source.path,
      );

      ytdlp.playlistInfo = {
        'entries': [
          {'id': 'first', 'playlist_index': 1, 'title': 'First'},
          {'id': 'third', 'playlist_index': 2, 'title': 'Third'},
          {'id': 'fourth', 'playlist_index': 3, 'title': 'Fourth'},
        ],
      };
      final result = await service.syncPlaylist(playlist);

      final tracks = await db.getTracksForPlaylist(playlist.id);
      final byVideoId = {for (final track in tracks) track.videoId: track};
      expect(result.added, 1);
      expect(result.removed, 0);
      expect(byVideoId[forced.videoId]!.index, 2);
      expect(byVideoId[forced.videoId]!.unavailableReason, isNull);
      expect(byVideoId['third']!.index, 3);
      expect(byVideoId['fourth']!.index, 4);
      expect(tracks.map((track) => track.index), [1, 2, 3, 4]);
    },
  );
}
