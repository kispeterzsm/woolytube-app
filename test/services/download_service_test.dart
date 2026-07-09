import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/sponsorblock_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';

import '../helpers/test_database.dart';

class FakeYtDlpService extends YtDlpService {
  final downloadedUrls = <String>[];

  @override
  Stream<Map<String, dynamic>> get progressStream =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Future<void> download({
    required String url,
    required String outputPath,
    String? formatOption,
    bool audioOnly = false,
    bool embedThumbnail = true,
    String? outputTemplate,
  }) async {
    downloadedUrls.add(url);
  }

  @override
  Future<void> startDownloadService(String playlistName) async {}

  @override
  Future<void> updateDownloadServiceProgress({
    required String playlistName,
    required int currentTrack,
    required int totalTracks,
    required int progress,
  }) async {}

  @override
  Future<void> stopDownloadService() async {}
}

class FakeSponsorBlockService extends SponsorBlockService {
  final AppDatabase db;
  final refreshedTracks = <Track>[];
  final fetchedVideoIds = <String>[];
  final segmentsByVideoId = <String, List<SponsorBlockSegmentsCompanion>>{};

  FakeSponsorBlockService(this.db, LogService log) : super(db, log);

  @override
  Future<void> refreshTrackSegments(Track track) async {
    refreshedTracks.add(track);
    await db.replaceRemoteSponsorBlockSegments(
      track.id,
      segmentsByVideoId[track.videoId] ?? const [],
    );
    await db.updateTrackSponsorBlockCheckedAt(track.id, DateTime.now());
  }

  @override
  Future<List<SponsorBlockSegmentsCompanion>> fetchSegments(
    String videoId,
    int trackId,
  ) async {
    fetchedVideoIds.add(videoId);
    return segmentsByVideoId[videoId] ?? const [];
  }
}

SponsorBlockSegmentsCompanion remoteSegment(Track track) =>
    SponsorBlockSegmentsCompanion.insert(
      trackId: track.id,
      videoId: track.videoId,
      source: 'sponsorblock',
      uuid: const Value('remote-1'),
      category: 'sponsor',
      startMs: 1000,
      endMs: 2500,
      createdAt: DateTime.utc(2024),
    );

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LogService log;
  late FakeYtDlpService ytdlp;
  late FakeSponsorBlockService sponsorBlock;
  late DownloadService service;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_download_test_');
    log = LogService();
    ytdlp = FakeYtDlpService();
    sponsorBlock = FakeSponsorBlockService(db, log);
    service = DownloadService(
      db,
      ytdlp,
      log,
      MetadataService(db),
      null,
      sponsorBlock,
    );
  });

  tearDown(() async {
    service.dispose();
    log.dispose();
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'reused indexed file is treated as a downloaded YouTube track',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
        audioOnly: true,
      );
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'reused-video',
        title: 'Reused Audio',
        status: 'pending',
      );
      final existingPath = p.join(tempDir.path, '00001_Reused_Audio.m4a');
      await File(existingPath).writeAsString('audio');
      sponsorBlock.segmentsByVideoId[track.videoId] = [remoteSegment(track)];

      await service.downloadPlaylist(playlist);

      expect(ytdlp.downloadedUrls, isEmpty);
      expect(sponsorBlock.refreshedTracks, hasLength(1));
      expect(sponsorBlock.refreshedTracks.single.isLocalReplacement, isFalse);

      final updated = (await db.getTracksForPlaylist(playlist.id)).single;
      expect(updated.status, 'complete');
      expect(updated.filePath, existingPath);
      expect(updated.isLocalReplacement, isFalse);

      final segments = await db.getSegmentsForTrack(track.id);
      expect(segments.map((segment) => segment.category), ['sponsor']);
    },
  );

  test(
    'playlist update repairs legacy reused files missing remote segments',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
        audioOnly: true,
      );
      final filePath = p.join(tempDir.path, '00001_Legacy_Audio.m4a');
      await File(filePath).writeAsString('audio');
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'legacy-video',
        title: 'Legacy Audio',
        filePath: filePath,
        status: 'complete',
        isLocalReplacement: true,
      );
      sponsorBlock.segmentsByVideoId[track.videoId] = [remoteSegment(track)];

      await service.downloadPlaylist(playlist);

      expect(ytdlp.downloadedUrls, isEmpty);
      expect(sponsorBlock.fetchedVideoIds, [track.videoId]);

      final updated = (await db.getTracksForPlaylist(playlist.id)).single;
      expect(updated.isLocalReplacement, isFalse);

      final segments = await db.getSegmentsForTrack(track.id);
      expect(segments.map((segment) => segment.uuid), ['remote-1']);

      final metaFile = File(p.join(tempDir.path, 'woolytube_meta.json'));
      final meta = jsonDecode(await metaFile.readAsString()) as Map;
      final tracks = meta['tracks'] as List;
      expect(tracks.single['sponsorBlockSegments'], hasLength(1));
    },
  );

  test(
    'playlist update backfills SponsorBlock for already complete tracks',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
        audioOnly: true,
      );
      final filePath = p.join(tempDir.path, '00001_Complete_Audio.m4a');
      await File(filePath).writeAsString('audio');
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'complete-video',
        title: 'Complete Audio',
        filePath: filePath,
        status: 'complete',
        isLocalReplacement: false,
      );
      sponsorBlock.segmentsByVideoId[track.videoId] = [remoteSegment(track)];

      await service.downloadPlaylist(playlist);

      expect(ytdlp.downloadedUrls, isEmpty);
      expect(sponsorBlock.fetchedVideoIds, [track.videoId]);

      final updated = (await db.getTracksForPlaylist(playlist.id)).single;
      expect(updated.isLocalReplacement, isFalse);
      expect(updated.sponsorBlockCheckedAt, isNotNull);

      final segments = await db.getSegmentsForTrack(track.id);
      expect(segments.map((segment) => segment.category), ['sponsor']);
    },
  );

  test('playlist update does not repeatedly fetch fresh misses', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: tempDir.path,
      audioOnly: true,
    );
    final filePath = p.join(tempDir.path, '00001_Checked_Audio.m4a');
    await File(filePath).writeAsString('audio');
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'checked-video',
      title: 'Checked Audio',
      filePath: filePath,
      status: 'complete',
      sponsorBlockCheckedAt: DateTime.now(),
    );

    await service.downloadPlaylist(playlist);

    expect(sponsorBlock.fetchedVideoIds, isEmpty);
  });
}
