import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/sponsorblock_categories.dart';

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

  test('deleting a playlist removes its tracks and segments', () async {
    final playlist = await insertTestPlaylist(db);
    final other = await insertTestPlaylist(
      db,
      url: 'https://www.youtube.com/playlist?list=other',
      name: 'Other',
    );
    final track = await insertTestTrack(db, playlistId: playlist.id);
    final kept = await insertTestTrack(
      db,
      playlistId: other.id,
      videoId: 'video-2',
    );
    await db.insertSegment(
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'local',
        category: 'intro',
        startMs: 0,
        endMs: 1000,
        createdAt: DateTime(2024),
      ),
    );

    await db.deletePlaylist(playlist.id);

    expect(await db.getTrack(track.id), isNull);
    expect(await db.getSegmentsForTrack(track.id), isEmpty);
    expect(await db.getAllTracks(), [kept]);
    expect((await db.getAllPlaylists()).map((p) => p.id), [other.id]);
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

  test('two tracks of one playlist cannot share an index', () async {
    final playlist = await insertTestPlaylist(db);
    final other = await insertTestPlaylist(
      db,
      url: 'https://www.youtube.com/playlist?list=other',
      name: 'Other',
    );
    await insertTestTrack(db, playlistId: playlist.id, index: 1);

    await expectLater(
      insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'video-2',
      ),
      throwsA(isA<Exception>()),
    );
    // The same index in another playlist is fine.
    await insertTestTrack(db, playlistId: other.id, index: 1, videoId: 'v');
    expect(await db.getTotalTrackCount(playlist.id), 1);
  });

  test('partial playlist updates leave other columns untouched', () async {
    final playlist = await insertTestPlaylist(db, name: 'Original');
    final stamp = DateTime(2025, 3, 4, 5, 6);

    await db.updatePlaylistFields(
      playlist.id,
      const PlaylistsCompanion(autoUpdate: Value(false)),
    );
    await db.markPlaylistUpdated(playlist.id, stamp);

    final updated = await db.getPlaylist(playlist.id);
    expect(updated.name, 'Original');
    expect(updated.autoUpdate, isFalse);
    expect(updated.lastUpdated, stamp);
    expect(updated.outputPath, playlist.outputPath);
  });

  test('removing remote segments keeps local and curated ones', () async {
    final playlist = await insertTestPlaylist(db);
    final track = await insertTestTrack(db, playlistId: playlist.id);
    await db.replaceSponsorBlockSegments(track.id, [
      for (final source in ['sponsorblock', 'local', 'override', 'hidden'])
        SponsorBlockSegmentsCompanion.insert(
          trackId: track.id,
          videoId: track.videoId,
          source: source,
          category: 'sponsor',
          startMs: 1000,
          endMs: 2000,
          createdAt: DateTime(2024),
        ),
    ]);

    await db.deleteRemoteSegmentsForTrack(track.id);

    expect(
      (await db.getSegmentsForTrack(track.id)).map((s) => s.source).toSet(),
      {'local', 'override', 'hidden'},
    );
  });

  test('upgrading from schema 10 repairs duplicate indices before adding the '
      'unique index', () async {
    final migrated = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (raw) {
          for (final statement in _schemaV10) {
            raw.execute(statement);
          }
          raw.execute(
            "INSERT INTO playlists (id, url, name, created_at, output_path) "
            "VALUES (1, 'https://example.com/list', 'List', 0, '/tmp/list')",
          );
          void track(
            int id,
            int index,
            String videoId,
            String status,
            String? filePath, {
            bool localReplacement = false,
          }) {
            raw.execute(
              'INSERT INTO tracks (id, playlist_id, "index", video_id, '
              'title, status, file_path, thumbnail_path, downloaded_at, '
              'is_local_replacement) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?)',
              [
                id,
                index,
                videoId,
                videoId,
                status,
                filePath,
                filePath == null ? null : '/tmp/list/thumb_$id.jpg',
                filePath == null ? null : 1700000000,
                localReplacement ? 1 : 0,
              ],
            );
          }

          track(10, 5, 'kept', 'complete', '/tmp/list/00005_Kept.mp4');
          track(
            11,
            5,
            'shared-file',
            'complete',
            '/tmp/list/00005_Kept.mp4',
            localReplacement: true,
          );
          track(12, 5, 'own-file', 'complete', '/tmp/list/00005_Own.mp4');
          track(13, 9, 'max', 'pending', null);
          track(14, 2, 'dup2a', 'pending', null);
          track(15, 2, 'dup2b', 'pending', null);
          raw.execute('PRAGMA user_version = 10');
        },
      ),
    );
    addTearDown(migrated.close);

    final tracks = await migrated.getTracksForPlaylist(1);
    final byVideoId = {for (final track in tracks) track.videoId: track};
    expect(tracks.map((track) => track.index).toSet(), hasLength(6));
    // Lowest id keeps the contested index; the rest are appended after the
    // playlist's previous maximum in (index, id) order.
    expect(byVideoId['dup2a']!.index, 2);
    expect(byVideoId['dup2b']!.index, 10);
    expect(byVideoId['kept']!.index, 5);
    expect(byVideoId['kept']!.status, 'complete');
    expect(byVideoId['kept']!.filePath, '/tmp/list/00005_Kept.mp4');
    expect(byVideoId['shared-file']!.index, 11);
    expect(byVideoId['shared-file']!.status, 'pending');
    expect(byVideoId['shared-file']!.filePath, isNull);
    expect(byVideoId['shared-file']!.thumbnailPath, isNull);
    expect(byVideoId['shared-file']!.downloadedAt, isNull);
    expect(byVideoId['shared-file']!.isLocalReplacement, isFalse);
    expect(byVideoId['own-file']!.index, 12);
    expect(byVideoId['own-file']!.status, 'complete');
    expect(byVideoId['own-file']!.filePath, '/tmp/list/00005_Own.mp4');
    expect(byVideoId['max']!.index, 9);

    final indexes =
        await migrated
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'index' "
              "AND tbl_name = 'tracks'",
            )
            .get();
    expect(
      indexes.map((row) => row.read<String>('name')),
      contains('idx_tracks_pl_index_unique'),
    );
    await expectLater(
      insertTestTrack(migrated, playlistId: 1, index: 5, videoId: 'clash'),
      throwsA(isA<Exception>()),
    );
  });
}

/// The on-device schema as created by app versions up to schema 10.
final _schemaV10 = [
  '''CREATE TABLE playlists (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL,
    name TEXT NOT NULL,
    thumbnail_url TEXT,
    thumbnail_path TEXT,
    audio_only INTEGER NOT NULL DEFAULT 0,
    auto_update INTEGER NOT NULL DEFAULT 1,
    update_frequency_hours INTEGER NOT NULL DEFAULT 24,
    include_thumbnails INTEGER NOT NULL DEFAULT 1,
    sponsor_block_enabled INTEGER NOT NULL DEFAULT 1,
    sponsor_block_categories TEXT NOT NULL
      DEFAULT '["sponsor","selfpromo","music_offtopic"]',
    sponsor_block_category_actions TEXT NOT NULL
      DEFAULT '$defaultSponsorBlockCategoryActionsJson',
    last_updated INTEGER,
    created_at INTEGER NOT NULL,
    output_path TEXT NOT NULL,
    play_chapters INTEGER
  )''',
  '''CREATE TABLE tracks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    playlist_id INTEGER NOT NULL REFERENCES playlists (id),
    "index" INTEGER NOT NULL,
    video_id TEXT NOT NULL,
    title TEXT NOT NULL,
    thumbnail_url TEXT,
    thumbnail_path TEXT,
    file_path TEXT,
    duration_seconds INTEGER,
    status TEXT NOT NULL DEFAULT 'pending',
    unavailable_reason TEXT,
    is_local_replacement INTEGER NOT NULL DEFAULT 0,
    always_skip INTEGER NOT NULL DEFAULT 0,
    downloaded_at INTEGER,
    sponsor_block_checked_at INTEGER,
    last_error TEXT,
    chapters_json TEXT,
    chapters_enabled INTEGER
  )''',
  '''CREATE TABLE sponsor_block_segments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id INTEGER NOT NULL REFERENCES tracks (id) ON DELETE CASCADE,
    video_id TEXT NOT NULL,
    source TEXT NOT NULL,
    uuid TEXT,
    category TEXT NOT NULL,
    action_type TEXT NOT NULL DEFAULT 'skip',
    start_ms INTEGER NOT NULL,
    end_ms INTEGER NOT NULL,
    votes INTEGER,
    locked INTEGER,
    description TEXT,
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX idx_tracks_pl_status ON tracks (playlist_id, status)',
  'CREATE INDEX idx_tracks_pl_index ON tracks (playlist_id, "index")',
];
