import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = openTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  test('orders tracks and returns only pending work', () async {
    final playlist = await insertTestPlaylist(db);
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'pending',
      status: 'pending',
    );
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'complete',
      status: 'complete',
    );
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 4,
      videoId: 'unavailable',
      status: 'unavailable',
    );
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 3,
      videoId: 'error',
      status: 'error',
    );

    final allTracks = await db.getTracksForPlaylist(playlist.id);
    expect(allTracks.map((track) => track.videoId), [
      'complete',
      'pending',
      'error',
      'unavailable',
    ]);

    final pendingTracks = await db.getPendingTracks(playlist.id);
    expect(pendingTracks.map((track) => track.videoId), ['pending', 'error']);
    expect(await db.getDownloadedTrackCount(playlist.id), 1);
    expect(await db.getTotalTrackCount(playlist.id), 4);
  });

  test('returns and watches tracks from every playlist', () async {
    final firstPlaylist = await insertTestPlaylist(
      db,
      url: 'https://example.com/first',
      name: 'First',
    );
    final secondPlaylist = await insertTestPlaylist(
      db,
      url: 'https://example.com/second',
      name: 'Second',
    );
    await insertTestTrack(
      db,
      playlistId: secondPlaylist.id,
      index: 1,
      videoId: 'second-1',
    );
    await insertTestTrack(
      db,
      playlistId: firstPlaylist.id,
      index: 2,
      videoId: 'first-2',
    );
    await insertTestTrack(
      db,
      playlistId: firstPlaylist.id,
      index: 1,
      videoId: 'first-1',
    );

    final allTracks = await db.getAllTracks();
    expect(allTracks.map((track) => track.videoId), [
      'first-1',
      'first-2',
      'second-1',
    ]);

    final watchedTracks = await db.watchAllTracks().first;
    expect(
      watchedTracks.map((track) => track.videoId),
      allTracks.map((track) => track.videoId),
    );
  });

  test('keeps track status metadata consistent', () async {
    final playlist = await insertTestPlaylist(db);
    final track = await insertTestTrack(db, playlistId: playlist.id);

    await db.updateTrackStatus(track.id, 'error', error: 'network failed');
    var updated = (await db.getTracksForPlaylist(playlist.id)).single;
    expect(updated.status, 'error');
    expect(updated.lastError, 'network failed');
    expect(updated.downloadedAt, isNull);

    await db.updateTrackStatus(
      track.id,
      'complete',
      filePath: '/tmp/song.m4a',
      isLocalReplacement: true,
    );
    updated = (await db.getTracksForPlaylist(playlist.id)).single;
    expect(updated.status, 'complete');
    expect(updated.filePath, '/tmp/song.m4a');
    expect(updated.isLocalReplacement, isTrue);
    expect(updated.lastError, isNull);
    expect(updated.downloadedAt, isNotNull);

    await db.resetTrackForRedownload(track.id);
    updated = (await db.getTracksForPlaylist(playlist.id)).single;
    expect(updated.status, 'pending');
    expect(updated.filePath, isNull);
    expect(updated.isLocalReplacement, isFalse);
    expect(updated.downloadedAt, isNull);
    expect(updated.lastError, isNull);

    await db.updateTrackStatus(track.id, 'downloading');
    await db.resetInterruptedTrack(track.id);
    updated = (await db.getTracksForPlaylist(playlist.id)).single;
    expect(updated.status, 'pending');
    expect(updated.filePath, isNull);
    expect(updated.downloadedAt, isNull);
  });

  test('persists an always-skip preference for a track', () async {
    final playlist = await insertTestPlaylist(db);
    final track = await insertTestTrack(db, playlistId: playlist.id);

    expect(track.alwaysSkip, isFalse);
    await db.updateTrackAlwaysSkip(track.id, true);
    expect((await db.getTrack(track.id))!.alwaysSkip, isTrue);

    await db.updateTrackAlwaysSkip(track.id, false);
    expect((await db.getTrack(track.id))!.alwaysSkip, isFalse);
  });

  test('finds only playlists that are due for automatic update', () async {
    final now = DateTime.now();
    final neverUpdated = await insertTestPlaylist(
      db,
      url: 'https://example.com/never',
      name: 'Never Updated',
      lastUpdated: null,
    );
    final expired = await insertTestPlaylist(
      db,
      url: 'https://example.com/expired',
      name: 'Expired',
      lastUpdated: now.subtract(const Duration(hours: 25)),
    );
    final hourly = await insertTestPlaylist(
      db,
      url: 'https://example.com/hourly',
      name: 'Hourly',
      updateFrequencyHours: 1,
      lastUpdated: now.subtract(const Duration(minutes: 61)),
    );
    await insertTestPlaylist(
      db,
      url: 'https://example.com/fresh',
      name: 'Fresh',
      lastUpdated: now.subtract(const Duration(hours: 2)),
    );
    await insertTestPlaylist(
      db,
      url: 'https://example.com/hourly-fresh',
      name: 'Hourly Fresh',
      updateFrequencyHours: 1,
      lastUpdated: now.subtract(const Duration(minutes: 59)),
    );
    await insertTestPlaylist(
      db,
      url: 'https://example.com/manual',
      name: 'Manual',
      autoUpdate: false,
      lastUpdated: null,
    );

    final due = await db.getPlaylistsDueForUpdate();
    expect(due.map((playlist) => playlist.id), [
      neverUpdated.id,
      expired.id,
      hourly.id,
    ]);
  });

  test('replaces SponsorBlock segments for a track', () async {
    final playlist = await insertTestPlaylist(db);
    final track = await insertTestTrack(db, playlistId: playlist.id);

    await db.replaceSponsorBlockSegments(track.id, [
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'sponsorblock',
        category: 'sponsor',
        startMs: 5000,
        endMs: 7000,
        votes: const Value(3),
        createdAt: DateTime(2024),
      ),
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'local',
        category: 'intro',
        startMs: 1000,
        endMs: 2000,
        createdAt: DateTime(2024),
      ),
    ]);

    var segments = await db.getSegmentsForTrack(track.id);
    expect(segments.map((segment) => segment.startMs), [1000, 5000]);

    await db.replaceSponsorBlockSegments(track.id, [
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'sponsorblock',
        category: 'outro',
        startMs: 9000,
        endMs: 12000,
        createdAt: DateTime(2024),
      ),
    ]);

    segments = await db.getSegmentsForTrack(track.id);
    expect(segments, hasLength(1));
    expect(segments.single.category, 'outro');
  });

  test('remote SponsorBlock refresh preserves local overrides', () async {
    final playlist = await insertTestPlaylist(db);
    final track = await insertTestTrack(db, playlistId: playlist.id);

    await db.replaceSponsorBlockSegments(track.id, [
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'sponsorblock',
        uuid: const Value('remote-1'),
        category: 'sponsor',
        startMs: 1000,
        endMs: 2000,
        createdAt: DateTime(2024),
      ),
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'local',
        category: 'intro',
        startMs: 3000,
        endMs: 4000,
        createdAt: DateTime(2024),
      ),
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'override',
        uuid: const Value('remote-2'),
        category: 'preview',
        startMs: 5000,
        endMs: 6000,
        createdAt: DateTime(2024),
      ),
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'hidden',
        uuid: const Value('remote-3'),
        category: 'outro',
        startMs: 7000,
        endMs: 8000,
        createdAt: DateTime(2024),
      ),
    ]);

    await db.replaceRemoteSponsorBlockSegments(track.id, [
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'sponsorblock',
        uuid: const Value('remote-1'),
        category: 'selfpromo',
        startMs: 10000,
        endMs: 12000,
        createdAt: DateTime(2025),
      ),
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'sponsorblock',
        uuid: const Value('remote-2'),
        category: 'interaction',
        startMs: 13000,
        endMs: 14000,
        createdAt: DateTime(2025),
      ),
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'sponsorblock',
        uuid: const Value('remote-3'),
        category: 'hook',
        startMs: 15000,
        endMs: 16000,
        createdAt: DateTime(2025),
      ),
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'sponsorblock',
        uuid: const Value('remote-4'),
        category: 'music_offtopic',
        startMs: 17000,
        endMs: 18000,
        createdAt: DateTime(2025),
      ),
    ]);

    final byUuid = {
      for (final segment in await db.getSegmentsForTrack(track.id))
        segment.uuid ?? 'local': segment,
    };

    expect(byUuid['local']!.source, 'local');
    expect(byUuid['remote-1']!.source, 'sponsorblock');
    expect(byUuid['remote-1']!.category, 'selfpromo');
    expect(byUuid['remote-2']!.source, 'override');
    expect(byUuid['remote-2']!.category, 'preview');
    expect(byUuid['remote-3']!.source, 'hidden');
    expect(byUuid['remote-3']!.category, 'outro');
    expect(byUuid['remote-4']!.source, 'sponsorblock');
    expect(byUuid['remote-4']!.category, 'music_offtopic');
  });
}
