import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/label_service.dart';
import 'package:woolytube/services/labels.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/metadata_service.dart';

import '../helpers/test_database.dart';

/// The sidecar (`woolytube_meta.json`) and `.m3u8` are what a reinstall,
/// another device or another player sees of a playlist.
void main() {
  late AppDatabase db;
  late Directory tempDir;
  late String audioBase;
  late String videoBase;
  late String folder;
  late MetadataService metadata;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_sidecar_');
    audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
    videoBase = p.join(tempDir.path, 'Movies', 'WoolyTube');
    LibraryLayout.overrideBasePathsForTesting(
      audio: audioBase,
      video: videoBase,
    );
    folder = p.join(audioBase, 'Round Trip');
    await Directory(folder).create(recursive: true);
    metadata = MetadataService(db);
  });

  tearDown(() async {
    LibraryLayout.resetBasePathsForTesting();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> write(String path, [String content = 'data']) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(content);
    return path;
  }

  List<Object?> segmentFields(SponsorBlockSegment s) => [
    s.videoId,
    s.source,
    s.uuid,
    s.category,
    s.actionType,
    s.startMs,
    s.endMs,
    s.votes,
    s.locked,
    s.description,
    s.createdAt.toUtc(),
  ];

  test('write, scan and import into a fresh database keeps every field the '
      'sidecar carries', () async {
    final playlistCover = await write(
      p.join(LibraryLayout.thumbnailsDir(folder), '_playlist_cover.jpg'),
    );
    final playlist = await insertTestPlaylist(
      db,
      url: 'https://www.youtube.com/playlist?list=PLround',
      name: 'Round Trip',
      thumbnailUrl: 'https://example.com/list.jpg',
      thumbnailPath: playlistCover,
      audioOnly: true,
      autoUpdate: false,
      updateFrequencyHours: 6,
      includeThumbnails: false,
      sponsorBlockEnabled: false,
      sponsorBlockCategories: '["intro"]',
      sponsorBlockCategoryActions: '{"intro":"autoSkip","sponsor":"disabled"}',
      lastUpdated: DateTime.utc(2024, 5, 6, 7, 8, 9),
      createdAt: DateTime.utc(2023, 1, 2, 3, 4, 5),
      playChapters: false,
      outputPath: folder,
      videoQuality: 480,
      downloadSubtitles: true,
      subtitleLanguages: 'en.*,hu',
      shuffleChapters: true,
    );
    final chapters =
        ChapterData(
          downloaded: const [
            MediaChapter(id: 'yt-0', title: 'Intro', startMs: 0, endMs: 10000),
          ],
          custom: const [
            MediaChapter(id: 'mine', title: 'Mine', startMs: 0, endMs: 5000),
          ],
          checkedAt: DateTime.utc(2024, 2, 3, 4, 5, 6),
          durationMs: 200000,
          shuffleChapters: true,
          skippedChapterIds: const {'mine'},
        ).encode();
    final song = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'song',
      title: 'Song One',
      thumbnailUrl: 'https://example.com/song.jpg',
      thumbnailPath: await write(
        p.join(LibraryLayout.thumbnailsDir(folder), 'song.jpg'),
      ),
      filePath: await write(p.join(folder, '00001_Song One.m4a')),
      durationSeconds: 200,
      status: 'complete',
      alwaysSkip: true,
      chaptersJson: chapters,
      chaptersEnabled: true,
      sponsorBlockCheckedAt: DateTime.utc(2024, 3, 1, 2, 3, 4),
      downloadedAt: DateTime.utc(2024, 3, 1, 1, 2, 3),
      replaceRequested: true,
      videoQuality: 720,
      downloadedMaxHeight: 720,
    );
    // A local file still in the other format's folder after a mode switch.
    final elsewhere = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 3,
      videoId: 'elsewhere',
      title: 'Elsewhere',
      thumbnailPath: await write(
        p.join(LibraryLayout.thumbnailsDir(folder), 'elsewhere.local.jpg'),
      ),
      filePath: await write(p.join(videoBase, 'Round Trip', '00003_E.mp4')),
      status: 'complete',
      unavailableReason: 'deleted',
      isLocalReplacement: true,
      chaptersEnabled: false,
      downloadedAt: DateTime.utc(2024, 4, 1),
      videoQuality: 0,
      downloadedMaxHeight: 0,
    );
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 4,
      videoId: 'private',
      title: '[Private video]',
      status: 'unavailable',
      unavailableReason: 'private',
    );
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 5,
      videoId: 'pending',
      title: 'Pending',
      sponsorBlockCheckedAt: DateTime.utc(2024, 1, 1),
    );
    await db.replaceSponsorBlockSegments(song.id, [
      SponsorBlockSegmentsCompanion.insert(
        trackId: song.id,
        videoId: song.videoId,
        source: 'sponsorblock',
        uuid: const Value('uuid-1'),
        category: 'sponsor',
        actionType: const Value('mute'),
        startMs: 1000,
        endMs: 2000,
        votes: const Value(7),
        locked: const Value(true),
        description: const Value('Ad read'),
        createdAt: DateTime.utc(2024, 1, 2, 3, 4, 5),
      ),
      SponsorBlockSegmentsCompanion.insert(
        trackId: song.id,
        videoId: song.videoId,
        source: 'hidden',
        uuid: const Value('uuid-2'),
        category: 'intro',
        startMs: 3000,
        endMs: 4000,
        createdAt: DateTime.utc(2024, 1, 3),
      ),
      SponsorBlockSegmentsCompanion.insert(
        trackId: song.id,
        videoId: song.videoId,
        source: 'local',
        category: 'outro',
        actionType: const Value('skip'),
        startMs: 5000,
        endMs: 6000,
        locked: const Value(false),
        createdAt: DateTime.utc(2024, 1, 4),
      ),
    ]);
    await db.replaceSponsorBlockSegments(elsewhere.id, [
      SponsorBlockSegmentsCompanion.insert(
        trackId: elsewhere.id,
        videoId: elsewhere.videoId,
        source: 'local',
        category: 'filler',
        startMs: 0,
        endMs: 500,
        createdAt: DateTime.utc(2024, 1, 5),
      ),
    ]);
    final original = await db.getPlaylist(playlist.id);
    final originalTracks = await db.getTracksForPlaylist(playlist.id);

    await metadata.writeMetadata(original, originalTracks);

    final fresh = openTestDatabase();
    addTearDown(fresh.close);
    final restore = MetadataService(fresh);
    final found = await restore.scanDirectory(tempDir.path);
    expect(found.map((d) => d.folderPath), [folder]);
    expect((await restore.readFolder(folder))!.tracks, hasLength(4));

    final newId = await restore.importPlaylist(found.single);

    final imported = await fresh.getPlaylist(newId);
    expect(imported.copyWith(id: original.id), original);
    final importedTracks = await fresh.getTracksForPlaylist(newId);
    expect(importedTracks, hasLength(originalTracks.length));
    for (var i = 0; i < originalTracks.length; i++) {
      final before = originalTracks[i];
      final after = importedTracks[i];
      expect(
        ChapterData.decode(after.chaptersJson).toJson(),
        ChapterData.decode(before.chaptersJson).toJson(),
        reason: before.videoId,
      );
      expect(
        after.copyWith(
          id: before.id,
          playlistId: before.playlistId,
          chaptersJson: Value(before.chaptersJson),
        ),
        before,
        reason: before.videoId,
      );
      expect(
        (await fresh.getSegmentsForTrack(after.id)).map(segmentFields),
        (await db.getSegmentsForTrack(before.id)).map(segmentFields),
        reason: before.videoId,
      );
    }
  });

  test('a stored length of 0 imports as unknown', () async {
    final playlist = await insertTestPlaylist(
      db,
      url: 'https://www.youtube.com/playlist?list=PLzero',
      name: 'Round Trip',
      outputPath: folder,
    );
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'local',
      title: 'Local mix',
      filePath: await write(p.join(folder, '00001_Local mix.mp3')),
      durationSeconds: 0,
      status: 'complete',
      isLocalReplacement: true,
    );
    await metadata.writeMetadata(
      await db.getPlaylist(playlist.id),
      await db.getTracksForPlaylist(playlist.id),
    );

    final fresh = openTestDatabase();
    addTearDown(fresh.close);
    final restore = MetadataService(fresh);
    final found = await restore.scanDirectory(tempDir.path);
    final newId = await restore.importPlaylist(found.single);
    final imported = await fresh.getTracksForPlaylist(newId);
    expect(imported.single.durationSeconds, isNull);
  });

  test('an old version-1 sidecar still imports, with skip as the segment '
      'action', () async {
    await write(p.join(folder, '00001_A.m4a'));
    await write(
      p.join(folder, 'woolytube_meta.json'),
      jsonEncode({
        'version': 1,
        'playlist': {
          'url': 'https://www.youtube.com/playlist?list=PLold',
          'name': 'Old',
          'audioOnly': true,
          'autoUpdate': true,
          'updateFrequencyHours': 24,
          'includeThumbnails': true,
          'sponsorBlockEnabled': true,
          'sponsorBlockCategories': '["sponsor"]',
          'lastUpdated': null,
          'createdAt': '2023-01-01T00:00:00.000Z',
        },
        'tracks': [
          {
            'index': 1,
            'videoId': 'a',
            'title': 'A',
            'status': 'complete',
            'fileName': '00001_A.m4a',
            'sponsorBlockSegments': [
              {
                'source': 'sponsorblock',
                'uuid': 'u',
                'category': 'sponsor',
                'startMs': 1000,
                'endMs': 2000,
              },
            ],
          },
        ],
      }),
    );

    final discovered = await metadata.readFolder(folder);
    final id = await metadata.importPlaylist(discovered!);

    final track = (await db.getTracksForPlaylist(id)).single;
    expect(track.status, 'complete');
    expect(track.filePath, p.join(folder, '00001_A.m4a'));
    // Written before video quality existed: the playlist default, unknown.
    expect(track.videoQuality, isNull);
    expect(track.downloadedMaxHeight, isNull);
    expect((await db.getPlaylist(id)).videoQuality, isNull);
    final segment = (await db.getSegmentsForTrack(track.id)).single;
    expect(segment.actionType, 'skip');
    expect(segment.uuid, 'u');
    expect(
      (await db.getPlaylist(id)).sponsorBlockCategoryActions,
      contains('"sponsor":"autoSkip"'),
    );
  });

  test('an imported playlist goes to the end of the home order, which the '
      'sidecar does not carry', () async {
    final first = await insertTestPlaylist(db, url: 'first', sortOrder: 7);
    final second = await insertTestPlaylist(db, url: 'second', sortOrder: 3);
    final source = await insertTestPlaylist(
      db,
      url: 'https://www.youtube.com/playlist?list=PLsource',
      outputPath: folder,
      audioOnly: true,
    );
    await metadata.writeMetadata(source, const []);
    final sidecar =
        jsonDecode(
              await File(p.join(folder, 'woolytube_meta.json')).readAsString(),
            )
            as Map<String, dynamic>;
    expect(
      (sidecar['playlist'] as Map<String, dynamic>).containsKey('sortOrder'),
      isFalse,
    );
    await db.deletePlaylist(source.id);

    final id = await metadata.importPlaylist(
      (await metadata.readFolder(folder))!,
    );

    expect((await db.getPlaylist(id)).sortOrder, 8);
    expect((await db.getAllPlaylists()).map((p) => p.id), [
      second.id,
      first.id,
      id,
    ]);
  });

  test('the temporary playlist imports as the temporary playlist', () async {
    final source = await insertTestPlaylist(
      db,
      url: 'woolytube:temporary',
      name: 'Temporary',
      outputPath: folder,
      autoUpdate: false,
      videoQuality: 720,
      isTemporary: true,
    );
    await metadata.writeMetadata(source, const []);
    final file = File(p.join(folder, 'woolytube_meta.json'));
    final sidecar =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((sidecar['playlist'] as Map)['temporary'], isTrue);
    await db.deletePlaylist(source.id);

    var id = await metadata.importPlaylist(
      (await metadata.readFolder(folder))!,
    );
    var imported = await db.getPlaylist(id);
    expect(imported.isTemporary, isTrue);
    expect(imported.videoQuality, 720);
    expect(imported.autoUpdate, isFalse);
    await db.deletePlaylist(id);

    // A sidecar written without the mark is still recognised by its link.
    (sidecar['playlist'] as Map).remove('temporary');
    await file.writeAsString(jsonEncode(sidecar));
    id = await metadata.importPlaylist((await metadata.readFolder(folder))!);
    imported = await db.getPlaylist(id);
    expect(imported.isTemporary, isTrue);
  });

  test('other playlists do not write the temporary mark', () async {
    final source = await insertTestPlaylist(db, outputPath: folder);
    await metadata.writeMetadata(source, const []);
    final sidecar =
        jsonDecode(
              await File(p.join(folder, 'woolytube_meta.json')).readAsString(),
            )
            as Map<String, dynamic>;
    expect(
      (sidecar['playlist'] as Map<String, dynamic>).containsKey('temporary'),
      isFalse,
    );
    final read = await metadata.readFolder(folder);
    expect(read!.isTemporary, isFalse);
  });

  test('the lyrics mode round-trips and is left out when off', () async {
    final source = await insertTestPlaylist(
      db,
      outputPath: folder,
      lyricsMode: 'transcript',
    );
    await metadata.writeMetadata(source, const []);
    final file = File(p.join(folder, 'woolytube_meta.json'));
    final sidecar =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((sidecar['playlist'] as Map)['lyricsMode'], 'transcript');
    await db.deletePlaylist(source.id);

    final id = await metadata.importPlaylist(
      (await metadata.readFolder(folder))!,
    );
    expect((await db.getPlaylist(id)).lyricsMode, 'transcript');

    await db.updatePlaylistFields(
      id,
      const PlaylistsCompanion(lyricsMode: Value(null)),
    );
    await metadata.writeMetadata(await db.getPlaylist(id), const []);
    final off = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((off['playlist'] as Map).containsKey('lyricsMode'), isFalse);
    expect((await metadata.readFolder(folder))!.lyricsMode, isNull);

    // An unknown value from a newer app reads as off.
    (off['playlist'] as Map)['lyricsMode'] = 'karaoke';
    await file.writeAsString(jsonEncode(off));
    expect((await metadata.readFolder(folder))!.lyricsMode, isNull);
  });

  test('Shuffle chapters round-trips for the playlist and each file', () async {
    final source = await insertTestPlaylist(
      db,
      outputPath: folder,
      shuffleChapters: true,
    );
    const chapter = MediaChapter(id: 'a', title: 'A', startMs: 0, endMs: 1000);
    final choices = {'default': null, 'shuffle': true, 'ordered': false};
    var index = 1;
    for (final entry in choices.entries) {
      await insertTestTrack(
        db,
        playlistId: source.id,
        index: index++,
        videoId: entry.key,
        title: entry.key,
        chaptersJson:
            const ChapterData(
              downloaded: [chapter],
            ).withShuffleChapters(entry.value).encode(),
      );
    }
    await metadata.writeMetadata(
      source,
      await db.getTracksForPlaylist(source.id),
    );
    final file = File(p.join(folder, 'woolytube_meta.json'));
    final sidecar =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((sidecar['playlist'] as Map)['shuffleChapters'], isTrue);
    final written = {
      for (final t in sidecar['tracks'] as List)
        (t as Map)['videoId']: t['chapters'] as Map,
    };
    // Older versions read the bool: only Shuffle shuffles there.
    expect(written['default']!['shuffleChapters'], isFalse);
    expect(written['default']!.containsKey('shuffleChaptersMode'), isFalse);
    expect(written['shuffle']!['shuffleChapters'], isTrue);
    expect(written['ordered']!['shuffleChaptersMode'], 'noShuffle');

    final fresh = openTestDatabase();
    addTearDown(fresh.close);
    final restore = MetadataService(fresh);
    final id = await restore.importPlaylist(
      (await restore.readFolder(folder))!,
    );
    expect((await fresh.getPlaylist(id)).shuffleChapters, isTrue);
    final imported = {
      for (final t in await fresh.getTracksForPlaylist(id))
        t.videoId: ChapterData.decode(t.chaptersJson).shuffleChapters,
    };
    expect(imported, choices);

    // Off is left out, and a sidecar without the key (an older version's)
    // imports as off.
    await db.updatePlaylistFields(
      source.id,
      const PlaylistsCompanion(shuffleChapters: Value(false)),
    );
    await metadata.writeMetadata(await db.getPlaylist(source.id), const []);
    final off = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((off['playlist'] as Map).containsKey('shuffleChapters'), isFalse);
    expect((await metadata.readFolder(folder))!.shuffleChapters, isFalse);
    // Only true turns it on.
    (off['playlist'] as Map)['shuffleChapters'] = 'yes';
    await file.writeAsString(jsonEncode(off));
    expect((await metadata.readFolder(folder))!.shuffleChapters, isFalse);
  });

  test('the subtitle choice round-trips and is left out when off', () async {
    final source = await insertTestPlaylist(
      db,
      outputPath: folder,
      downloadSubtitles: true,
      subtitleLanguages: 'en,hu',
    );
    await metadata.writeMetadata(source, const []);
    final file = File(p.join(folder, 'woolytube_meta.json'));
    final sidecar =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((sidecar['playlist'] as Map)['downloadSubtitles'], isTrue);
    expect((sidecar['playlist'] as Map)['subtitleLanguages'], 'en,hu');
    await db.deletePlaylist(source.id);

    final id = await metadata.importPlaylist(
      (await metadata.readFolder(folder))!,
    );
    final imported = await db.getPlaylist(id);
    expect(imported.downloadSubtitles, isTrue);
    expect(imported.subtitleLanguages, 'en,hu');

    await db.updatePlaylistFields(
      id,
      const PlaylistsCompanion(
        downloadSubtitles: Value(false),
        subtitleLanguages: Value(null),
      ),
    );
    await metadata.writeMetadata(await db.getPlaylist(id), const []);
    final off = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final offPlaylist = off['playlist'] as Map<String, dynamic>;
    expect(offPlaylist.containsKey('downloadSubtitles'), isFalse);
    expect(offPlaylist.containsKey('subtitleLanguages'), isFalse);
    // A sidecar of an older version has neither key.
    var read = (await metadata.readFolder(folder))!;
    expect(read.downloadSubtitles, isFalse);
    expect(read.subtitleLanguages, isNull);

    // A hand-edited list is tidied, or dropped when yt-dlp must not get it.
    for (final (value, expected) in [
      (' de, en ,', 'de,en'),
      ('all', null),
      ('--exec rm', null),
      (42, null),
      ('', null),
    ]) {
      offPlaylist['downloadSubtitles'] = 'yes';
      offPlaylist['subtitleLanguages'] = value;
      await file.writeAsString(jsonEncode(off));
      read = (await metadata.readFolder(folder))!;
      expect(read.subtitleLanguages, expected, reason: '$value');
      expect(read.downloadSubtitles, isFalse);
    }
  });

  test('import gives a repeated index to the entry whose file carries that '
      'number', () async {
    await write(p.join(folder, '00001_A.m4a'));
    await write(p.join(folder, '00002_C.m4a'));
    await write(p.join(folder, '00003_B.m4a'));
    DiscoveredTrack track(int index, String id, String file) => DiscoveredTrack(
      index: index,
      videoId: id,
      title: id.toUpperCase(),
      status: 'complete',
      fileName: file,
    );

    final id = await metadata.importPlaylist(
      DiscoveredPlaylist(
        folderPath: folder,
        url: 'https://www.youtube.com/playlist?list=PLdup',
        name: 'Dup',
        audioOnly: true,
        autoUpdate: true,
        updateFrequencyHours: 24,
        includeThumbnails: true,
        sponsorBlockEnabled: false,
        sponsorBlockCategories: '[]',
        createdAt: DateTime.utc(2024),
        tracks: [
          track(1, 'a', '00001_A.m4a'),
          // Listed first, but its file is numbered 3.
          track(2, 'b', '00003_B.m4a'),
          track(2, 'c', '00002_C.m4a'),
        ],
      ),
    );

    final tracks = {
      for (final t in await db.getTracksForPlaylist(id)) t.videoId: t,
    };
    expect(tracks['a']!.index, 1);
    expect(tracks['c']!.index, 2);
    expect(tracks['c']!.filePath, p.join(folder, '00002_C.m4a'));
    expect(tracks['b']!.index, 3);
    expect(tracks['b']!.filePath, p.join(folder, '00003_B.m4a'));
  });

  test('import never gives one file to two tracks', () async {
    // A backup written by an older version in which an age-restricted
    // track adopted the next track's file and number.
    final shared = await write(p.join(folder, '00041_Dance.m4a'), 'dance');
    DiscoveredTrack entry(String id, String title, DateTime downloadedAt) =>
        DiscoveredTrack(
          index: 41,
          videoId: id,
          title: title,
          status: 'complete',
          fileName: '00041_Dance.m4a',
          downloadedAt: downloadedAt,
        );

    final id = await metadata.importPlaylist(
      DiscoveredPlaylist(
        folderPath: folder,
        url: 'https://www.youtube.com/playlist?list=PLshared',
        name: 'Shared',
        audioOnly: true,
        autoUpdate: true,
        updateFrequencyHours: 24,
        includeThumbnails: true,
        sponsorBlockEnabled: false,
        sponsorBlockCategories: '[]',
        createdAt: DateTime.utc(2024),
        tracks: [
          entry('restricted', 'Restricted', DateTime.utc(2024, 6)),
          entry('dance', 'Dance', DateTime.utc(2024, 1)),
        ],
      ),
    );

    final tracks = await db.getTracksForPlaylist(id);
    expect(tracks.where((t) => t.filePath == shared), hasLength(1));
    // As in the database repair, the track that got the file first keeps
    // it and its number.
    final dance = tracks.singleWhere((t) => t.videoId == 'dance');
    expect(dance.index, 41);
    expect(dance.filePath, shared);
    expect(
      tracks.singleWhere((t) => t.videoId == 'restricted').status,
      'pending',
    );
  });

  test('the .m3u8 lists finished tracks in order with titles and relative '
      'paths, without Always-skip tracks', () async {
    final playlist = await insertTestPlaylist(
      db,
      name: 'Road\nTrip',
      outputPath: folder,
    );
    final tracks = [
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'second',
        title: 'Second',
        durationSeconds: 200,
        filePath: await write(p.join(folder, '00002_Second.m4a')),
        status: 'complete',
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'first',
        title: 'First: the "best"',
        durationSeconds: 100,
        filePath: await write(p.join(folder, '00001_First.m4a')),
        status: 'complete',
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'pending',
        title: 'Pending',
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 4,
        videoId: 'skipped',
        title: 'Skipped',
        filePath: await write(p.join(folder, '00004_Skipped.m4a')),
        status: 'complete',
        alwaysSkip: true,
      ),
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 5,
        videoId: 'elsewhere',
        title: 'Else\nwhere',
        filePath: await write(p.join(videoBase, 'Round Trip', '00005_E.mp4')),
        status: 'complete',
      ),
    ];

    await metadata.writeMetadata(playlist, tracks);

    final m3u = await File(p.join(folder, 'Round Trip.m3u8')).readAsString();
    expect(m3u.split('\n'), [
      '#EXTM3U',
      '#PLAYLIST:Road Trip',
      '#EXTINF:100,First: the "best"',
      '00001_First.m4a',
      '#EXTINF:200,Second',
      '00002_Second.m4a',
      '#EXTINF:-1,Else where',
      '../../../Movies/WoolyTube/Round Trip/00005_E.mp4',
      '',
    ]);
  });

  test('finding unimported playlists copes with two rows sharing a URL and '
      'skips folders already in use', () async {
    const shared = 'https://www.youtube.com/playlist?list=PLshared';
    final used = p.join(audioBase, 'Used');
    await insertTestPlaylist(
      db,
      url: shared,
      audioOnly: true,
      outputPath: used,
    );
    // Older versions allowed the same playlist twice.
    await insertTestPlaylist(
      db,
      url: shared,
      audioOnly: true,
      outputPath: p.join(audioBase, 'Used (2)'),
    );
    DiscoveredPlaylist candidate(String folderName, String url, bool audio) =>
        DiscoveredPlaylist(
          folderPath: p.join(audioBase, folderName),
          url: url,
          name: folderName,
          audioOnly: audio,
          autoUpdate: true,
          updateFrequencyHours: 24,
          includeThumbnails: true,
          sponsorBlockEnabled: false,
          sponsorBlockCategories: '[]',
          createdAt: DateTime.utc(2024),
          tracks: const [],
        );

    final result = await metadata.findUnimportedPlaylists(
      candidates: [
        candidate('Used', 'https://www.youtube.com/playlist?list=PLx', true),
        candidate('Copy', '$shared&si=abc', true),
        candidate('Video copy', shared, false),
        candidate('New', 'https://www.youtube.com/playlist?list=PLnew', true),
        candidate('New', 'https://www.youtube.com/playlist?list=PLnew', true),
      ],
    );

    expect(result.map((d) => p.basename(d.folderPath)), ['Video copy', 'New']);
  });

  group('labels', () {
    Future<Map<String, dynamic>> readSidecar() async =>
        jsonDecode(
              await File(p.join(folder, 'woolytube_meta.json')).readAsString(),
            )
            as Map<String, dynamic>;

    const goneUid = '99999999-8888-4777-8666-555555555555';

    /// A playlist whose first file is labelled Rock (and with the uid of a
    /// deleted label), and whose mix has a Live chapter; Unused labels
    /// nothing.
    Future<({Playlist playlist, Label rock, Label live})> seed() async {
      final labels = LabelService(db);
      final rock = await labels.create('Rock', 0xffe53935);
      final live = await labels.create('Live', 0x801e88e5);
      await labels.create('Unused', 0xff43a047);
      final playlist = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=PLlabels',
        outputPath: folder,
      );
      final song = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'song',
        title: 'Song',
      );
      final mix = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'mix',
        title: 'Mix',
        chaptersJson:
            const ChapterData(
              downloaded: [
                MediaChapter(
                  id: 'youtube-0-0',
                  title: 'Opening',
                  startMs: 0,
                  endMs: 60000,
                  origin: ChapterOrigin.original,
                ),
                MediaChapter(
                  id: 'youtube-1-60000',
                  title: 'Encore',
                  startMs: 60000,
                  endMs: 120000,
                  origin: ChapterOrigin.original,
                ),
              ],
              durationMs: 120000,
            ).encode(),
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'plain',
        title: 'Plain',
      );
      await db.setTrackLabelUids(song.id, '["${rock.uid}","$goneUid"]');
      await labels.setChapterLabel(mix.id, 'youtube-1-60000', live.uid, true);
      return (playlist: playlist, rock: rock, live: live);
    }

    test('files, chapters and the names and colors of the labels used go '
        'into the sidecar, and come back from it on a fresh install', () async {
      final seeded = await seed();
      await metadata.writeMetadataFor(seeded.playlist.id);
      final json = await readSidecar();
      expect(json['labels'], [
        {
          'uid': seeded.rock.uid,
          'name': 'Rock',
          'color': '#e53935',
          'updatedAt': seeded.rock.updatedAt.toUtc().toIso8601String(),
        },
        {
          'uid': seeded.live.uid,
          'name': 'Live',
          'color': '#801e88e5',
          'updatedAt': seeded.live.updatedAt.toUtc().toIso8601String(),
        },
      ]);
      final tracks = (json['tracks'] as List).cast<Map<String, dynamic>>();
      expect(tracks[0]['labels'], [seeded.rock.uid, goneUid]);
      expect(tracks[1].containsKey('labels'), isFalse);
      expect((tracks[1]['chapters'] as Map)['chapterLabels'], {
        'youtube-1-60000': [seeded.live.uid],
      });
      expect(tracks[2].containsKey('labels'), isFalse);
      expect(
        (tracks[2]['chapters'] as Map).containsKey('chapterLabels'),
        isFalse,
      );

      final fresh = openTestDatabase();
      addTearDown(fresh.close);
      final restore = MetadataService(fresh);
      final found = await restore.readFolder(folder);
      final newId = await restore.importPlaylist(found!);

      final restored = await fresh.getLabels();
      expect(restored.map((l) => (l.uid, l.name, l.color)), [
        (seeded.rock.uid, 'Rock', 0xffe53935),
        (seeded.live.uid, 'Live', 0x801e88e5),
      ]);
      expect(
        restored.first.updatedAt.isAtSameMomentAs(seeded.rock.updatedAt),
        isTrue,
      );
      final importedTracks = await fresh.getTracksForPlaylist(newId);
      // The deleted label's uid stays, ignored, as it was.
      expect(decodeLabelUids(importedTracks[0].labelUids), [
        seeded.rock.uid,
        goneUid,
      ]);
      expect(
        ChapterData.decode(
          importedTracks[1].chaptersJson,
        ).labelsOf('youtube-1-60000'),
        [seeded.live.uid],
      );
      expect(importedTracks[2].labelUids, isNull);
      expect(await LabelService(fresh).find({seeded.live.uid}), hasLength(1));

      // Written again from the new phone's database, it is the same.
      await File(p.join(folder, 'woolytube_meta.json')).delete();
      await restore.writeMetadataFor(newId);
      final again = await readSidecar();
      expect(again['labels'], json['labels']);
      expect(
        [for (final t in again['tracks'] as List) (t as Map)['labels']],
        [for (final t in tracks) t['labels']],
      );
      expect(
        [for (final t in again['tracks'] as List) (t as Map)['chapters']],
        [for (final t in tracks) t['chapters']],
      );
    });

    test('a label of the same name already on the phone is used for the '
        'imported files and chapters', () async {
      final seeded = await seed();
      await metadata.writeMetadataFor(seeded.playlist.id);

      final fresh = openTestDatabase();
      addTearDown(fresh.close);
      final mine = await LabelService(fresh).create('live', 0xff000000);
      final restore = MetadataService(fresh);
      final newId = await restore.importPlaylist(
        (await restore.readFolder(folder))!,
      );
      final importedTracks = await fresh.getTracksForPlaylist(newId);
      expect(
        ChapterData.decode(
          importedTracks[1].chaptersJson,
        ).labelsOf('youtube-1-60000'),
        [mine.uid],
      );
      expect(decodeLabelUids(importedTracks[0].labelUids), [
        seeded.rock.uid,
        goneUid,
      ]);
      expect((await fresh.getLabels()).map((l) => l.name), ['live', 'Rock']);
      expect((await fresh.getLabel(mine.uid))!.color, 0xff000000);
    });

    test('a sidecar without labels imports unlabelled, and labels a newer '
        'sidecar carries are not kept once they are removed', () async {
      final seeded = await seed();
      await metadata.writeMetadataFor(seeded.playlist.id);
      final labels = LabelService(db);
      final tracks = await db.getTracksForPlaylist(seeded.playlist.id);
      await labels.setTrackLabels(tracks[0].id, const []);
      await labels.setChapterLabels(tracks[1].id, 'youtube-1-60000', const []);
      await metadata.writeMetadataFor(seeded.playlist.id);
      final json = await readSidecar();
      expect(json.containsKey('labels'), isFalse);
      expect(
        (json['tracks'] as List).any((t) => (t as Map).containsKey('labels')),
        isFalse,
      );

      final fresh = openTestDatabase();
      addTearDown(fresh.close);
      final restore = MetadataService(fresh);
      final newId = await restore.importPlaylist(
        (await restore.readFolder(folder))!,
      );
      expect(await fresh.getLabels(), isEmpty);
      expect(
        (await fresh.getTracksForPlaylist(newId)).map((t) => t.labelUids),
        everyElement(isNull),
      );
    });

    test('renaming a label rewrites the sidecars of the playlists that use '
        'it', () async {
      final seeded = await seed();
      await metadata.writeMetadataFor(seeded.playlist.id);
      final revision = await db.playlistRevision(seeded.playlist.id);
      expect(metadata.writtenRevision(seeded.playlist.id), revision);
      await LabelService(db).rename(seeded.rock.uid, 'Hard rock');
      expect(
        await db.playlistRevision(seeded.playlist.id),
        greaterThan(revision),
      );
      await metadata.writeMetadataFor(seeded.playlist.id);
      expect(
        ((await readSidecar())['labels'] as List).first['name'],
        'Hard rock',
      );
    });
  });

  group('a sidecar written by a newer app', () {
    Future<Map<String, dynamic>> readSidecar() async =>
        jsonDecode(
              await File(p.join(folder, 'woolytube_meta.json')).readAsString(),
            )
            as Map<String, dynamic>;

    Future<void> setTrack(int id, TracksCompanion fields) =>
        (db.update(db.tracks)..where((t) => t.id.equals(id))).write(fields);

    Future<void> writeSidecar(Map<String, dynamic> json) => File(
      p.join(folder, 'woolytube_meta.json'),
    ).writeAsString(jsonEncode(json));

    test('keeps the keys this app does not know when it is rewritten, also '
        'after a restart', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        videoQuality: 720,
      );
      final first = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'a',
        title: 'A',
        videoQuality: 480,
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
        title: 'B',
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'a',
        title: 'A again',
      );
      await metadata.writeMetadataFor(playlist.id);

      final json = await readSidecar();
      json['moods'] = [
        {'id': 'l1', 'name': 'Rock'},
      ];
      (json['playlist'] as Map<String, dynamic>)['coverColor'] = 'red';
      final tracks = json['tracks'] as List<dynamic>;
      (tracks[0] as Map<String, dynamic>)['moods'] = ['l1'];
      (tracks[2] as Map<String, dynamic>)['moods'] = ['l2'];
      await writeSidecar(json);

      // A new run of the app has not written the file yet.
      metadata = MetadataService(db);
      await setTrack(
        first.id,
        const TracksCompanion(
          title: Value('A renamed'),
          videoQuality: Value(null),
        ),
      );
      await db.updatePlaylistFields(
        playlist.id,
        const PlaylistsCompanion(videoQuality: Value(null)),
      );
      await metadata.writeMetadataFor(playlist.id);

      var written = await readSidecar();
      expect(written['moods'], [
        {'id': 'l1', 'name': 'Rock'},
      ]);
      final writtenPlaylist = written['playlist'] as Map<String, dynamic>;
      expect(writtenPlaylist['coverColor'], 'red');
      // Keys this app knows follow the database, also when it cleared one.
      expect(writtenPlaylist.containsKey('videoQuality'), isFalse);
      var writtenTracks = (written['tracks'] as List).cast<Map>();
      expect(writtenTracks[0]['title'], 'A renamed');
      expect(writtenTracks[0].containsKey('videoQuality'), isFalse);
      expect(writtenTracks[0]['moods'], ['l1']);
      expect(writtenTracks[1].containsKey('moods'), isFalse);
      expect(writtenTracks[2]['moods'], ['l2']);

      // And again by the same run, which knows its last hash now.
      await setTrack(
        first.id,
        const TracksCompanion(title: Value('A renamed twice')),
      );
      await metadata.writeMetadataFor(playlist.id);
      written = await readSidecar();
      writtenTracks = (written['tracks'] as List).cast<Map>();
      expect(writtenTracks[0]['title'], 'A renamed twice');
      expect(writtenTracks[0]['moods'], ['l1']);
      expect(written['moods'], isNotNull);

      // A track that left the playlist takes its keys with it.
      await db.deleteTracks([first.id]);
      await metadata.writeMetadataFor(playlist.id);
      writtenTracks = ((await readSidecar())['tracks'] as List).cast<Map>();
      expect(writtenTracks.map((t) => t['title']), ['B', 'A again']);
      expect(writtenTracks.last['moods'], ['l2']);
    });

    test('of a newer format version is left as it is, and said once in the '
        'log', () async {
      final log = LogService.memoryOnly();
      metadata = MetadataService(db, log: log);
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        title: 'Old',
        status: 'complete',
        filePath: p.join(folder, '00001_Old.mp3'),
      );
      final newer = {
        'version': sidecarVersion + 1,
        'playlist': {'url': playlist.url, 'name': 'Newer'},
        'tracks': <Object?>[],
      };
      await writeSidecar(newer);

      await metadata.writeMetadataFor(playlist.id);
      await db.updatePlaylistFields(
        playlist.id,
        const PlaylistsCompanion(name: Value('Renamed')),
      );
      await metadata.writeMetadataFor(playlist.id);

      expect(await readSidecar(), newer);
      // The playlist file other players read is still written.
      expect(
        await File(MetadataService.playlistFilePath(folder)).exists(),
        isTrue,
      );
      expect(
        log.entries.where((e) => e.message.contains('newer app')),
        hasLength(1),
      );
    });

    test('every key this app writes is one it knows', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        thumbnailPath: p.join(folder, 'cover.jpg'),
        videoQuality: 720,
        isTemporary: true,
        lyricsMode: 'lyrics',
        downloadSubtitles: true,
        subtitleLanguages: 'en',
        shuffleChapters: true,
      );
      final rock = await LabelService(db).create('Rock', 0xffe53935);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoQuality: 480,
        downloadedMaxHeight: 480,
      );
      await LabelService(db).setTrackLabel(track.id, rock.uid, true);
      final data = buildSidecarData(
        playlist,
        [(await db.getTrack(track.id))!],
        const {},
        labels: [rock],
        lyricsPinsByTrack: {
          track.id: [
            LyricsDoc(
              id: 1,
              trackId: track.id,
              offsetMs: 0,
              kind: 'lyrics',
              status: 'found',
              timeScale: 1,
              synced: false,
              pinned: true,
              shiftMs: 10,
              timingOff: true,
              checkedAt: DateTime(2026),
              attempts: 0,
            ),
          ],
        },
      );
      expect(sidecarTopLevelKeys, containsAll(data.keys));
      expect(sidecarPlaylistKeys, containsAll((data['playlist'] as Map).keys));
      expect(
        sidecarTrackKeys,
        containsAll(((data['tracks'] as List).single as Map).keys),
      );
    });
  });
}
