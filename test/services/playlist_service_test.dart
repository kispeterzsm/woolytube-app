import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/lyrics/lyrics_files.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_service.dart'
    show persistLyricsFile;
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/video_quality.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late String folder;
  late FakeYtDlpService ytdlp;
  late FakeMediaThumbnailService thumbnails;
  late PlaylistService service;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_playlist_test_');
    // Writing metadata also puts a README into the folder above.
    folder = p.join(tempDir.path, 'Playlist');
    await Directory(folder).create();
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

  group('movePlaylist', () {
    late List<int> ids;

    setUp(() async {
      ids = [
        for (final url in ['a', 'b', 'c', 'd'])
          (await insertTestPlaylist(db, url: url, outputPath: folder)).id,
      ];
    });

    Future<List<int>> order() async => [
      for (final playlist in await db.getAllPlaylists()) playlist.id,
    ];

    test('moves a playlist before another one', () async {
      await service.movePlaylist(ids[3], beforeId: ids[1]);
      expect(await order(), [ids[0], ids[3], ids[1], ids[2]]);

      await service.movePlaylist(ids[0], beforeId: ids[2]);
      expect(await order(), [ids[3], ids[1], ids[0], ids[2]]);
    });

    test('moves a playlist to the end', () async {
      await service.movePlaylist(ids[0]);
      expect(await order(), [ids[1], ids[2], ids[3], ids[0]]);
    });

    test('moving a playlist before itself changes nothing', () async {
      await service.movePlaylist(ids[2], beforeId: ids[2]);
      expect(await order(), ids);
      expect((await db.getAllPlaylists()).map((p) => p.sortOrder), [
        0,
        1,
        2,
        3,
      ]);
    });

    test('a playlist the list does not show keeps its place among the '
        'others', () async {
      // The page shows a, c, d (b is hidden) and moves d before c.
      await service.movePlaylist(ids[3], beforeId: ids[2]);
      expect(await order(), [ids[0], ids[1], ids[3], ids[2]]);
    });

    test('moves made one after another all apply', () async {
      await Future.wait([
        service.movePlaylist(ids[3], beforeId: ids[0]),
        service.movePlaylist(ids[2], beforeId: ids[3]),
      ]);
      expect(await order(), [ids[2], ids[3], ids[0], ids[1]]);
    });

    test('does not write the metadata files', () async {
      await service.movePlaylist(ids[3], beforeId: ids[0]);
      expect(
        await File(p.join(folder, 'woolytube_meta.json')).exists(),
        isFalse,
      );
    });
  });

  group('video quality', () {
    test('the effective cap follows track, then playlist, never audio', () {
      int? cap({bool audioOnly = false, int? playlist, int? track}) =>
          effectiveMaxHeightOf(
            audioOnly: audioOnly,
            playlistQuality: playlist,
            trackQuality: track,
          );
      expect(cap(), isNull);
      expect(cap(playlist: 720), 720);
      expect(cap(playlist: 720, track: 480), 480);
      expect(cap(playlist: 720, track: 0), isNull);
      expect(cap(track: 1080), 1080);
      expect(cap(audioOnly: true, playlist: 720, track: 480), isNull);
    });

    test('the resolution is the shorter side of the kept info', () {
      expect(videoResolutionFromInfo({'width': 1920, 'height': 1080}), 1080);
      expect(videoResolutionFromInfo({'width': 1080, 'height': 1920}), 1080);
      expect(videoResolutionFromInfo({'height': 720}), 720);
      expect(videoResolutionFromInfo({'title': 'x'}), isNull);
      expect(videoResolutionFromInfo(null), isNull);
    });

    test('setters save the playlist and track quality', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);

      await service.setPlaylistVideoQuality(playlist.id, 720);
      await service.setTrackVideoQuality(track.id, 0);
      expect((await db.getPlaylist(playlist.id)).videoQuality, 720);
      expect((await db.getTrack(track.id))!.videoQuality, 0);

      await service.setPlaylistVideoQuality(playlist.id, null);
      await service.setTrackVideoQuality(track.id, null);
      expect((await db.getPlaylist(playlist.id)).videoQuality, isNull);
      expect((await db.getTrack(track.id))!.videoQuality, isNull);
    });

    group('affected tracks', () {
      late Playlist playlist;
      var nextIndex = 1;

      setUp(() async {
        nextIndex = 1;
        playlist = await insertTestPlaylist(db, outputPath: folder);
      });

      /// A downloaded video of [resolution] (null: no kept info).
      Future<Track> downloaded({
        int? resolution,
        int? downloadedMaxHeight,
        int? videoQuality,
        bool isLocalReplacement = false,
        String? unavailableReason,
        String? videoId,
      }) async {
        final index = nextIndex++;
        final id = videoId ?? 'video-$index';
        final path = p.join(folder, '${index}_Video.mp4');
        await File(path).writeAsString('media');
        if (resolution != null) {
          final info = File(LibraryLayout.infoJsonPath(folder, id));
          await info.parent.create(recursive: true);
          await info.writeAsString(
            jsonEncode({'width': resolution * 16 ~/ 9, 'height': resolution}),
          );
        }
        return insertTestTrack(
          db,
          playlistId: playlist.id,
          index: index,
          videoId: id,
          status: 'complete',
          filePath: path,
          downloadedMaxHeight: downloadedMaxHeight,
          videoQuality: videoQuality,
          isLocalReplacement: isLocalReplacement,
          unavailableReason: unavailableReason,
        );
      }

      Future<List<int>> affected({
        required int? oldMax,
        required int? newMax,
        Iterable<Track>? only,
      }) async => [
        for (final track in await service.tracksAffectedByQualityChange(
          playlist,
          oldMax: oldMax,
          newMax: newMax,
          only: only,
        ))
          track.id,
      ];

      test('lowering counts files above the new cap or of unknown '
          'size', () async {
        final big = await downloaded(resolution: 1080, downloadedMaxHeight: 0);
        await downloaded(resolution: 480, downloadedMaxHeight: 0);
        final unknown = await downloaded();

        expect(await affected(oldMax: null, newMax: 720), [big.id, unknown.id]);
      });

      test('raising counts files downloaded under a lower cap that they '
          'filled', () async {
        final capped = await downloaded(
          resolution: 720,
          downloadedMaxHeight: 720,
        );
        // The video had nothing sharper than 480p.
        await downloaded(resolution: 480, downloadedMaxHeight: 720);
        // Downloaded without a cap: already the best.
        await downloaded(resolution: 720, downloadedMaxHeight: 0);
        final unknown = await downloaded(resolution: 720);

        expect(await affected(oldMax: 720, newMax: null), [
          capped.id,
          unknown.id,
        ]);
        expect(await affected(oldMax: 720, newMax: 1080), [
          capped.id,
          unknown.id,
        ]);
      });

      test('a vertical video counts by its shorter side', () async {
        final path = p.join(folder, '1_Short.mp4');
        await File(path).writeAsString('media');
        final info = File(LibraryLayout.infoJsonPath(folder, 'short'));
        await info.parent.create(recursive: true);
        await info.writeAsString(jsonEncode({'width': 720, 'height': 1280}));
        await insertTestTrack(
          db,
          playlistId: playlist.id,
          videoId: 'short',
          status: 'complete',
          filePath: path,
          downloadedMaxHeight: 720,
        );

        expect(await affected(oldMax: 1080, newMax: 720), isEmpty);
      });

      test('leaves out tracks YouTube cannot give again, tracks with a '
          'quality of their own, and missing files', () async {
        await downloaded(resolution: 1080, isLocalReplacement: true);
        await downloaded(resolution: 1080, unavailableReason: 'private');
        await downloaded(
          resolution: 1080,
          videoId: '${PlaylistService.forcedInsertVideoIdPrefix}x',
        );
        await downloaded(resolution: 1080, videoQuality: 0);
        final gone = await downloaded(resolution: 1080);
        await File(gone.filePath!).delete();
        await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 99,
          videoId: 'pending',
        );

        expect(await affected(oldMax: null, newMax: 720), isEmpty);
      });

      test('a track change checks only that track, even with its own '
          'quality', () async {
        final own = await downloaded(resolution: 1080, videoQuality: 480);
        await downloaded(resolution: 1080);

        expect(await affected(oldMax: null, newMax: 480, only: [own]), [
          own.id,
        ]);
        expect(await affected(oldMax: 480, newMax: 480, only: [own]), isEmpty);
      });

      test('audio-only playlists have nothing to change', () async {
        playlist = await insertTestPlaylist(
          db,
          url: 'audio',
          outputPath: folder,
          audioOnly: true,
        );
        await downloaded(resolution: 1080);
        expect(await affected(oldMax: null, newMax: 720), isEmpty);
      });
    });

    test('requestRedownload queues the tracks for replacement', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final a = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'a',
        status: 'complete',
        filePath: p.join(folder, '1_a.mp4'),
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
        status: 'complete',
        filePath: p.join(folder, '2_b.mp4'),
      );

      await service.requestRedownload(playlist.id, [a.id]);

      expect((await db.getReplacementRequests(playlist.id)).map((t) => t.id), [
        a.id,
      ]);
    });
  });

  test('populates tracks and marks unavailable entries', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);

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
    expect(await File(p.join(folder, 'woolytube_meta.json')).exists(), isTrue);
  });

  test(
    'syncs playlist additions, removals and availability without renumbering',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=sync',
        outputPath: folder,
      );

      final downloadedGonePath = p.join(folder, '00004_Downloaded.mp4');
      final replacementPath = p.join(folder, '00006_Replacement.m4a');
      final completeIndexPath = p.join(folder, '00007_Complete.mp4');
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
      expect(byVideoId['back']!.index, 5);
      expect(byVideoId['replacement']!.status, 'complete');
      expect(byVideoId['replacement']!.unavailableReason, isNull);
      expect(byVideoId['complete-index']!.index, 7);
      expect(byVideoId['pending-index']!.index, 8);
      expect(byVideoId['will-private']!.status, 'unavailable');
      expect(byVideoId['will-private']!.unavailableReason, 'private');
      expect(byVideoId['will-private']!.index, 9);
      expect(byVideoId['new']!.status, 'pending');
      expect(byVideoId['new']!.index, 10);
      expect(byVideoId['new-private']!.status, 'unavailable');
      expect(byVideoId['new-private']!.unavailableReason, 'private');
      expect(byVideoId['new-private']!.index, 11);
      expect(tracks.map((track) => track.index).toSet(), hasLength(11));
      expect(
        await File(p.join(folder, 'woolytube_meta.json')).exists(),
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
      // Covers are named by video id (a local file gets `.local`), so the
      // name survives a reinstall and import.
      expect(
        metadataTracks[1]['thumbnailFileName'],
        p.join(
          '.woolytube_thumbnails',
          '${LibraryLayout.safeId(inserted.videoId)}.local.jpg',
        ),
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

  test('a local replacement drops lyrics timed to the old file', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      lyricsMode: 'lyrics',
    );
    final oldPath = p.join(folder, '00001_Downloaded.mp4');
    await File(oldPath).writeAsString('downloaded');
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      filePath: oldPath,
      status: 'complete',
      chaptersJson:
          const ChapterData(
            downloaded: [
              MediaChapter(id: 'c1', title: 'A', startMs: 0, endMs: 1000),
            ],
          ).encode(),
    );
    LyricsDocDraft doc({
      String? chapterId,
      bool synced = false,
      bool pinned = false,
    }) => LyricsDocDraft(
      trackId: track.id,
      chapterId: chapterId,
      kind: LyricsMode.lyrics,
      status: LyricsStatus.found,
      synced: synced,
      pinned: pinned,
      checkedAt: DateTime(2026),
      lines: const [LyricsLineDraft('darkness', startMs: 500)],
    );
    await db.replaceLyricsDoc(doc(chapterId: 'c1', pinned: true));
    await db.replaceLyricsDoc(doc(synced: true));
    await persistLyricsFile(db, track.id);
    final source = File(p.join(tempDir.path, 'Mine.mp4'));
    await source.writeAsString('mine');

    await service.replaceWithLocalFile(
      trackId: track.id,
      sourcePath: source.path,
      sourceFileName: 'Mine.mp4',
    );

    expect(await db.lyricsDocsForTrack(track.id), isEmpty);
    expect(await readLyricsFile(folder, track.videoId, track.id), isEmpty);
  });

  test('a local replacement keeps the previous file aside', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    final oldPath = p.join(folder, '00001_Downloaded.mp4');
    await File(oldPath).writeAsString('downloaded');
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      filePath: oldPath,
      status: 'complete',
    );
    final source = File(p.join(tempDir.path, 'Better copy.mp4'));
    await source.writeAsString('better');

    final updated = await service.replaceWithLocalFile(
      trackId: track.id,
      sourcePath: source.path,
      sourceFileName: 'Better copy.mp4',
    );

    expect(updated.filePath, p.join(folder, '00001_Better copy.mp4'));
    expect(await File(updated.filePath!).readAsString(), 'better');
    expect(await File(oldPath).exists(), isFalse);
    expect(
      await File(
        p.join(folder, '.woolytube_replaced', '00001_Downloaded.mp4'),
      ).readAsString(),
      'downloaded',
    );
    // The picked file is copied, never moved.
    expect(await source.readAsString(), 'better');
    // No working copy is left behind.
    expect(
      await Directory(p.join(folder, '.woolytube-staging')).list().isEmpty,
      isTrue,
    );
  });

  test(
    'backfills embedded artwork for an existing local replacement',
    () async {
      thumbnails.hasEmbeddedThumbnail = true;
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final media = File(p.join(folder, '00001_Existing.mp3'));
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

  test(
    'an entry removed on YouTube never renumbers downloaded or pending tracks',
    () async {
      final outputDir = Directory(p.join(tempDir.path, 'append-only'));
      await outputDir.create();
      final playlist = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=append-only',
        audioOnly: true,
        outputPath: outputDir.path,
      );
      final keptPath = p.join(outputDir.path, '00050_Kept.m4a');
      await File(keptPath).writeAsString('audio');
      final early = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 49,
        videoId: 'early',
        title: 'Early',
      );
      final kept = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 50,
        videoId: 'kept',
        title: 'Kept',
        status: 'complete',
        filePath: keptPath,
      );
      final later = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 51,
        videoId: 'later',
        title: 'Later',
      );
      ytdlp.playlistInfo = {
        'entries': [
          {'id': 'kept', 'playlist_index': 1, 'title': 'Kept'},
          {'id': 'later', 'playlist_index': 2, 'title': 'Later'},
          {'id': 'fresh', 'playlist_index': 3, 'title': 'Fresh'},
        ],
      };

      final result = await service.syncPlaylist(playlist);

      expect(result.added, 1);
      expect(result.removed, 1);
      final tracks = await db.getTracksForPlaylist(playlist.id);
      final byVideoId = {for (final track in tracks) track.videoId: track};
      expect(byVideoId['early']!.index, 49);
      expect(byVideoId['early']!.status, 'unavailable');
      expect(byVideoId['early']!.unavailableReason, 'removed');
      expect(byVideoId['kept']!.index, 50);
      expect(byVideoId['later']!.index, 51);
      expect(byVideoId['fresh']!.index, 52);
      expect(tracks.map((track) => track.index).toSet(), hasLength(4));
      expect(byVideoId['early']!.id, early.id);
      expect(byVideoId['later']!.id, later.id);

      // The pending ex-#51 must not inherit #50's file on the next update.
      // yt-dlp "succeeds" without a file, like a download whose merge failed.
      ytdlp.createOutputFile = false;
      final log = LogService();
      final downloads = DownloadService(
        db,
        ytdlp,
        log,
        MetadataService(db),
        null,
        null,
        null,
        DownloadLock(directoryProvider: () async => tempDir.path),
        DownloadLock.foregroundOwner,
        null,
        thumbnails,
      );
      addTearDown(() {
        downloads.dispose();
        log.dispose();
      });
      await downloads.downloadPlaylist(await db.getPlaylist(playlist.id));

      final laterAfter = (await db.getTrack(later.id))!;
      expect(laterAfter.status, 'error');
      expect(laterAfter.filePath, isNull);
      expect((await db.getTrack(kept.id))!.filePath, keptPath);
    },
  );

  // Updated (owner decision 2026-11-05): new entries go where they are on
  // YouTube, after their nearest predecessor the app already has, instead of
  // being appended. Here the gap before b absorbs new-1, so b keeps 7.
  test('new remote entries go after their YouTube predecessor', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    await insertTestTrack(db, playlistId: playlist.id, index: 3, videoId: 'a');
    await insertTestTrack(db, playlistId: playlist.id, index: 7, videoId: 'b');
    ytdlp.playlistInfo = {
      'entries': [
        {'id': 'a', 'playlist_index': 1, 'title': 'A'},
        {'id': 'new-1', 'playlist_index': 2, 'title': 'New 1'},
        {'id': 'b', 'playlist_index': 3, 'title': 'B'},
        {'id': 'new-2', 'playlist_index': 4, 'title': 'New 2'},
      ],
    };

    final result = await service.syncPlaylist(playlist);

    expect(result.added, 2);
    final byVideoId = {
      for (final track in await db.getTracksForPlaylist(playlist.id))
        track.videoId: track,
    };
    expect(byVideoId['a']!.index, 3);
    expect(byVideoId['new-1']!.index, 4);
    expect(byVideoId['b']!.index, 7);
    expect(byVideoId['new-2']!.index, 8);
  });

  test('duplicate remote video IDs are stored once', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    await insertTestTrack(db, playlistId: playlist.id, index: 1, videoId: 'x');
    ytdlp.playlistInfo = {
      'entries': [
        {'id': 'x', 'playlist_index': 1, 'title': 'X'},
        {'id': 'dup', 'playlist_index': 2, 'title': 'First'},
        {'id': 'dup', 'playlist_index': 3, 'title': 'Second'},
        {'id': 'other', 'playlist_index': 4, 'title': 'Other'},
      ],
    };

    final result = await service.syncPlaylist(playlist);

    expect(result.added, 2);
    final tracks = await db.getTracksForPlaylist(playlist.id);
    expect(tracks.map((track) => track.videoId), ['x', 'dup', 'other']);
    expect(tracks.map((track) => track.index), [1, 2, 3]);
    expect(tracks[1].title, 'First');
  });

  test(
    'a fresh playlist keeps remote numbering but never repeats it',
    () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);

      await service.populateTracksFromInfo(playlist.id, {
        'entries': [
          {'id': 'dup', 'playlist_index': 4, 'title': 'First'},
          {'id': 'dup', 'playlist_index': 4, 'title': 'Second'},
          {'id': 'clash', 'playlist_index': 4, 'title': 'Clash'},
          {'id': 'later', 'playlist_index': 9, 'title': 'Later'},
        ],
      });

      final tracks = await db.getTracksForPlaylist(playlist.id);
      expect(tracks.map((track) => track.videoId), ['dup', 'clash', 'later']);
      expect(tracks.map((track) => track.index), [4, 5, 9]);
    },
  );

  test(
    'an empty remote response fails instead of removing everything',
    () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.playlistInfo = {'entries': <dynamic>[]};

      await expectLater(service.syncPlaylist(playlist), throwsStateError);

      final unchanged = (await db.getTrack(track.id))!;
      expect(unchanged.status, 'pending');
      expect(unchanged.unavailableReason, isNull);

      // Without local tracks there is nothing to protect.
      final empty = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=empty',
        outputPath: folder,
      );
      expect((await service.syncPlaylist(empty)).hasChanges, isFalse);
    },
  );

  test('concurrent settings updates do not overwrite each other', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      lastUpdated: DateTime.utc(2024, 5, 6),
    );

    await Future.wait([
      service.updatePlaylistSettings(id: playlist.id, name: 'Renamed'),
      service.updatePlaylistSettings(id: playlist.id, autoUpdate: false),
      service.updatePlaylistSettings(id: playlist.id, updateFrequencyHours: 6),
    ]);

    final updated = await db.getPlaylist(playlist.id);
    expect(updated.name, 'Renamed');
    expect(updated.autoUpdate, isFalse);
    expect(updated.updateFrequencyHours, 6);
    expect(updated.lastUpdated, playlist.lastUpdated);
    expect(updated.outputPath, playlist.outputPath);
    expect(updated.sponsorBlockCategories, playlist.sponsorBlockCategories);
  });

  test('a local replacement drops remote SponsorBlock segments', () async {
    final outputDir = Directory(p.join(tempDir.path, 'segments'));
    await outputDir.create();
    final playlist = await insertTestPlaylist(db, outputPath: outputDir.path);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'segmented',
      status: 'complete',
      filePath: p.join(outputDir.path, '00001_Old.mp4'),
    );
    await File(track.filePath!).writeAsString('old');
    await db.replaceSponsorBlockSegments(track.id, [
      for (final source in ['sponsorblock', 'local', 'override'])
        SponsorBlockSegmentsCompanion.insert(
          trackId: track.id,
          videoId: track.videoId,
          source: source,
          uuid: Value('$source-uuid'),
          category: 'sponsor',
          startMs: 1000,
          endMs: 2000,
          createdAt: DateTime(2024),
        ),
    ]);
    final source = File(p.join(tempDir.path, 'Replacement.mp4'));
    await source.writeAsString('new');

    final updated = await service.replaceWithLocalFile(
      trackId: track.id,
      sourcePath: source.path,
      sourceFileName: 'Replacement.mp4',
    );

    expect(updated.isLocalReplacement, isTrue);
    expect(updated.sponsorBlockCheckedAt, isNotNull);
    final remaining = await db.getSegmentsForTrack(track.id);
    expect(remaining.map((segment) => segment.source), ['local', 'override']);
  });

  test('force insert at the front shifts every later track', () async {
    final outputDir = Directory(p.join(tempDir.path, 'front-insert'));
    await outputDir.create();
    final playlist = await insertTestPlaylist(db, outputPath: outputDir.path);
    final ids = <int>[];
    for (var i = 1; i <= 3; i++) {
      ids.add(
        (await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: i,
          videoId: 'video-$i',
        )).id,
      );
    }
    final source = File(p.join(tempDir.path, 'Intro.mp4'));
    await source.writeAsString('intro');

    final inserted = await service.forceInsert(
      playlistId: playlist.id,
      index: 1,
      sourcePath: source.path,
    );

    final tracks = await db.getTracksForPlaylist(playlist.id);
    expect(tracks.map((track) => track.index), [1, 2, 3, 4]);
    expect(tracks.map((track) => track.id), [inserted.id, ...ids]);
    expect(inserted.sponsorBlockCheckedAt, isNotNull);
  });
}
