import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/metadata_service.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late MetadataService metadata;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_metadata_test_');
    metadata = MetadataService(db);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('formats safe filenames and resolves media by index prefix', () async {
    expect(MetadataService.paddingWidth(10), 5);
    expect(MetadataService.paddingWidth(100000), 6);
    expect(MetadataService.paddedIndex(7, 10), '00007');
    expect(MetadataService.paddedIndex(7, 100000), '000007');
    expect(MetadataService.sanitizeFilename('  A:/B * C  '), 'A__B _ C');
    expect(MetadataService.sanitizeFilename('   '), '_');

    final media = File(p.join(tempDir.path, '00001_Title.m4a'));
    await media.writeAsString('audio');
    await File(p.join(tempDir.path, '00001_Title.txt')).writeAsString('text');

    expect(
      MetadataService.resolveMediaFile(tempDir.path, '00001_'),
      media.path,
    );
    expect(MetadataService.resolveMediaFile(tempDir.path, '00002_'), isNull);
  });

  test(
    'cleans temporary and thumbnail files while keeping media and metadata',
    () async {
      final keepMedia = File(p.join(tempDir.path, '00001_Title.mp3'));
      final keepMetadata = File(p.join(tempDir.path, 'woolytube_meta.json'));
      await keepMedia.writeAsString('audio');
      await keepMetadata.writeAsString('{}');
      await File(p.join(tempDir.path, 'cover.jpg')).writeAsString('image');
      await File(
        p.join(tempDir.path, 'download.part'),
      ).writeAsString('partial');
      await File(
        p.join(tempDir.path, 'download.part-Frag12'),
      ).writeAsString('partial');
      await File(p.join(tempDir.path, 'download.ytdl')).writeAsString('state');
      await File(
        p.join(tempDir.path, 'woolytube_meta.json.tmp'),
      ).writeAsString('{}');

      final deleted = await MetadataService.cleanupPlaylistFolder(tempDir.path);

      expect(deleted, 5);
      expect(await keepMedia.exists(), isTrue);
      expect(await keepMetadata.exists(), isTrue);
      expect(await File(p.join(tempDir.path, 'cover.jpg')).exists(), isFalse);
      expect(
        await File(p.join(tempDir.path, 'download.part')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(tempDir.path, 'download.part-Frag12')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(tempDir.path, 'download.ytdl')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(tempDir.path, 'woolytube_meta.json.tmp')).exists(),
        isFalse,
      );
    },
  );

  test(
    'writes playlist metadata including files and SponsorBlock segments',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        name: 'Metadata Playlist',
        thumbnailUrl: 'https://example.com/playlist.jpg',
        outputPath: tempDir.path,
        lastUpdated: DateTime.utc(2024, 1, 2, 3, 4, 5),
        createdAt: DateTime.utc(2024, 1, 1),
      );
      final mediaPath = p.join(tempDir.path, '00001_Song.m4a');
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

      await metadata.writeMetadata(playlist, [track]);

      final metaFile = File(p.join(tempDir.path, 'woolytube_meta.json'));
      final data =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      expect(data['version'], 1);
      expect(data['playlist']['name'], 'Metadata Playlist');
      expect(data['playlist']['lastUpdated'], '2024-01-02T03:04:05.000Z');

      final tracks = data['tracks'] as List<dynamic>;
      expect(tracks, hasLength(1));
      expect(tracks.single['videoId'], 'video-1');
      expect(tracks.single['fileName'], '00001_Song.m4a');
      expect(tracks.single['alwaysSkip'], isTrue);
      expect(tracks.single['sponsorBlockSegments'], [
        {
          'source': 'sponsorblock',
          'uuid': 'segment-1',
          'category': 'sponsor',
          'startMs': 1000,
          'endMs': 2500,
        },
      ]);
    },
  );

  test('reconciles database state with files on disk', () async {
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
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
      filePath: p.join(tempDir.path, 'missing.m4a'),
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
      filePath: p.join(tempDir.path, 'old-name.mp4'),
      status: 'complete',
      downloadedAt: DateTime.utc(2024),
    );
    await File(p.join(tempDir.path, '1_First.mp3')).writeAsString('audio');
    await File(p.join(tempDir.path, '3_Moved.mp4')).writeAsString('video');
    await File(p.join(tempDir.path, 'cover.jpg')).writeAsString('image');
    await File(p.join(tempDir.path, 'download.part')).writeAsString('partial');
    await File(p.join(tempDir.path, 'download.ytdl')).writeAsString('state');
    await File(p.join(tempDir.path, 'old.tmp')).writeAsString('tmp');
    await File(p.join(tempDir.path, 'woolytube_meta.json')).writeAsString('{}');

    final fixed = await metadata.reconcilePlaylist(playlist);

    expect(fixed, greaterThanOrEqualTo(3));
    final tracksByVideoId = {
      for (final track in await db.getTracksForPlaylist(playlist.id))
        track.videoId: track,
    };
    final firstPath = p.join(tempDir.path, '00001_First.mp3');
    final movedPath = p.join(tempDir.path, '00003_Moved.mp4');
    expect(tracksByVideoId[first.videoId]!.status, 'complete');
    expect(tracksByVideoId[first.videoId]!.filePath, firstPath);
    expect(tracksByVideoId[missing.videoId]!.status, 'pending');
    expect(tracksByVideoId[missing.videoId]!.filePath, isNull);
    expect(tracksByVideoId[missing.videoId]!.downloadedAt, isNull);
    expect(tracksByVideoId[missing.videoId]!.isLocalReplacement, isFalse);
    expect(tracksByVideoId[moved.videoId]!.status, 'complete');
    expect(tracksByVideoId[moved.videoId]!.filePath, movedPath);

    expect(await File(firstPath).exists(), isTrue);
    expect(await File(movedPath).exists(), isTrue);
    expect(await File(p.join(tempDir.path, '1_First.mp3')).exists(), isFalse);
    expect(await File(p.join(tempDir.path, '3_Moved.mp4')).exists(), isFalse);
    expect(await File(p.join(tempDir.path, 'cover.jpg')).exists(), isFalse);
    expect(await File(p.join(tempDir.path, 'download.part')).exists(), isFalse);
    expect(await File(p.join(tempDir.path, 'download.ytdl')).exists(), isFalse);
    expect(await File(p.join(tempDir.path, 'old.tmp')).exists(), isFalse);
    expect(
      await File(p.join(tempDir.path, 'woolytube_meta.json')).exists(),
      isTrue,
    );
  });

  test(
    'imports discovered playlists and keeps only valid local segments',
    () async {
      await File(
        p.join(tempDir.path, '00001_Existing.m4a'),
      ).writeAsString('audio');

      await metadata.importPlaylist(
        DiscoveredPlaylist(
          folderPath: tempDir.path,
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
      expect(tracks[0].filePath, p.join(tempDir.path, '00001_Existing.m4a'));
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
}
