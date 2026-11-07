import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapter_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/recognition/chapter_estimator.dart';
import 'package:woolytube/services/recognition/song_recognition_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';
import '../helpers/test_database.dart';

class _Ytdlp extends YtDlpService {
  int calls = 0;
  bool fail = false;
  @override
  Future<Map<String, dynamic>> getVideoInfo(String url) async {
    calls++;
    if (fail) throw StateError('Offline');
    return {
      'duration': 60,
      'chapters': [
        {'title': 'First', 'start_time': 0, 'end_time': 30},
        {'title': 'Second', 'start_time': 30, 'end_time': 60},
      ],
    };
  }
}

void main() {
  late AppDatabase db;
  late Directory root;
  late Directory dir;
  late File media;
  late Track track;
  late _Ytdlp ytdlp;
  late ChapterService service;
  setUp(() async {
    db = openTestDatabase();
    root = await Directory.systemTemp.createTemp('woolytube-chapters-');
    // Writing metadata also puts a README into the folder above the
    // playlist, so keep that inside the temp folder too.
    dir = await Directory('${root.path}/Playlist').create();
    media = await File(
      '${dir.path}/00001_album.m4a',
    ).writeAsBytes([0, 1, 2, 3, 255]);
    final playlist = await insertTestPlaylist(db, outputPath: dir.path);
    track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      status: 'complete',
      filePath: media.path,
      durationSeconds: 60,
    );
    ytdlp = _Ytdlp();
    service = ChapterService(db, ytdlp);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('fractional starts, missing ends, and malformed ranges', () {
    final data = ChapterData.fromVideoInfo({
      'duration': 90,
      'chapters': [
        {'title': 'First', 'start_time': 0},
        {'title': 'Second', 'start_time': 30.125},
      ],
    });
    expect(data.active.first.endMs, 30125);
    expect(data.active.last.endMs, 90000);
    for (final bad in [-1, double.nan, double.infinity, 100]) {
      expect(
        ChapterData.fromVideoInfo({
          'duration': 60,
          'chapters': [
            {'title': 'Bad', 'start_time': bad, 'end_time': 60},
          ],
        }).active,
        isEmpty,
      );
    }
    expect(parseChapterTimestamp('1:02:03.125'), 3723125);
    expect(parseChapterTimestamp('1:99'), isNull);
    expect(parseChapterTimestamp('NaN'), isNull);
  });

  test(
    'custom editing preserves media bytes and survives YouTube refresh',
    () async {
      await service.refresh(track);
      track = (await db.getTrack(track.id))!;
      final first = ChapterData.decode(track.chaptersJson).active.first;
      await service.save(
        track,
        MediaChapter(id: first.id, title: 'My title', startMs: 0, endMs: 30000),
      );
      await service.refresh(track);
      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.active.first.title, 'My title');
      expect(data.downloaded.first.title, 'First');
      expect(await media.readAsBytes(), [0, 1, 2, 3, 255]);
      await service.delete(track, first.id);
      await service.delete(track, data.active.last.id);
      expect(
        ChapterData.decode((await db.getTrack(track.id))!.chaptersJson).active,
        isEmpty,
      );
      await service.restore(track);
      expect(
        ChapterData.decode((await db.getTrack(track.id))!.chaptersJson).active,
        hasLength(2),
      );
    },
  );

  test('fetching missing chapters reports progress and can stop', () async {
    final others = <Track>[];
    for (var i = 2; i <= 4; i++) {
      final file = await File(
        '${dir.path}/0000${i}_song.m4a',
      ).writeAsBytes([i]);
      others.add(
        await insertTestTrack(
          db,
          playlistId: track.playlistId,
          index: i,
          videoId: 'video-$i',
          status: 'complete',
          filePath: file.path,
        ),
      );
    }
    expect(await service.countMissing(track.playlistId), 4);

    final progress = <(int, int)>[];
    final cancellation = ChapterFetchCancellation();
    final partial = await service.fetchMissingChapters(
      track.playlistId,
      cancellation: cancellation,
      onProgress: (done, total) {
        progress.add((done, total));
        if (done == 2) cancellation.cancel();
      },
    );
    expect(progress, [(0, 4), (1, 4), (2, 4)]);
    expect(partial.cancelled, isTrue);
    expect(partial.updated, 2);
    expect(ytdlp.calls, 2);
    // Stopping early still brings the sidecar up to date once.
    expect(await File('${dir.path}/woolytube_meta.json').exists(), isTrue);

    ytdlp.fail = true;
    final rest = await service.fetchMissingChapters(track.playlistId);
    expect(rest.eligible, 2);
    expect(rest.failed, 2);
    expect(rest.cancelled, isFalse);

    ytdlp.fail = false;
    final done = await service.fetchMissingChapters(track.playlistId);
    expect(done.updated, 2);
    expect(await service.countMissing(track.playlistId), 0);
    expect((await service.fetchMissingChapters(track.playlistId)).eligible, 0);
  });

  test('a sidecar changed by another writer is rewritten', () async {
    final sidecar = File('${dir.path}/woolytube_meta.json');
    await service.persist(track.playlistId);
    final written = await sidecar.readAsString();
    // Downloads or sync (another MetadataService) rewrote it meanwhile.
    await sidecar.writeAsString('{}');
    await service.persist(track.playlistId);
    expect(await sidecar.readAsString(), written);
  });

  test('a deleted chapter can be put back', () async {
    await service.refresh(track);
    track = (await db.getTrack(track.id))!;
    final first = ChapterData.decode(track.chaptersJson).active.first;
    final before = await service.delete(track, first.id);
    expect(
      ChapterData.decode((await db.getTrack(track.id))!.chaptersJson).active,
      hasLength(1),
    );
    await service.replaceChapters(track, before!);
    expect(
      ChapterData.decode((await db.getTrack(track.id))!.chaptersJson).active,
      hasLength(2),
    );
  });

  test(
    'chapter shuffle preference survives refresh, edit, and restore',
    () async {
      await service.setShuffleChapters(track, true);
      await service.refresh(track);
      await service.save(
        track,
        const MediaChapter(
          id: 'custom',
          title: 'Custom',
          startMs: 60000,
          endMs: 90000,
        ),
        durationMs: 120000,
      );
      await service.restore(track);
      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.shuffleChapters, isTrue);
      expect(data.invalidate().shuffleChapters, isTrue);
    },
  );

  test('rejects overlaps and out-of-file custom chapters', () async {
    await service.refresh(track);
    await expectLater(
      service.save(
        track,
        const MediaChapter(
          id: 'local',
          title: 'Overlap',
          startMs: 1000,
          endMs: 2000,
        ),
      ),
      throwsFormatException,
    );
    await expectLater(
      service.save(
        track,
        const MediaChapter(
          id: 'local',
          title: 'Too long',
          startMs: 60000,
          endMs: 61000,
        ),
      ),
      throwsFormatException,
    );
  });

  test(
    'failed refresh preserves data; replaced files invalidate old timings',
    () async {
      await service.refresh(track);
      final before = (await db.getTrack(track.id))!.chaptersJson;
      ytdlp.fail = true;
      await expectLater(service.refresh(track), throwsStateError);
      expect((await db.getTrack(track.id))!.chaptersJson, before);
      await db.invalidateTrackChapters(track.id);
      expect(
        ChapterData.decode((await db.getTrack(track.id))!.chaptersJson).active,
        isEmpty,
      );
    },
  );

  test('download sidecar provides chapters and cannot modify media', () async {
    final sidecar = File('${dir.path}/00001_album.info.json');
    await sidecar.writeAsString(
      jsonEncode({
        'id': track.videoId,
        'duration': 60,
        'chapters': [
          {'title': 'Song', 'start_time': 0, 'end_time': 60},
        ],
      }),
    );
    await MetadataService(db).captureChapterMetadata(track, dir.path);
    expect(
      ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      ).active.single.title,
      'Song',
    );
    expect(await sidecar.exists(), isFalse);
    expect(await media.readAsBytes(), [0, 1, 2, 3, 255]);
  });

  test(
    'folder metadata round trip preserves custom chapters and album override',
    () async {
      await service.refresh(track);
      track = (await db.getTrack(track.id))!;
      final data = ChapterData.decode(track.chaptersJson);
      await service.save(
        track,
        MediaChapter(
          id: data.active.first.id,
          title: 'Local title',
          startMs: 0,
          endMs: 30000,
        ),
      );
      await service.setOverride(track, true);
      await service.setShuffleChapters(track, true);
      final contents =
          jsonDecode(
                await File('${dir.path}/woolytube_meta.json').readAsString(),
              )
              as Map;
      final saved = (contents['tracks'] as List).single as Map;
      final imported = openTestDatabase();
      try {
        await MetadataService(imported).importPlaylist(
          DiscoveredPlaylist(
            folderPath: dir.path,
            url: 'imported',
            name: 'Album',
            audioOnly: true,
            autoUpdate: false,
            updateFrequencyHours: 24,
            includeThumbnails: false,
            sponsorBlockEnabled: false,
            sponsorBlockCategories: '[]',
            createdAt: DateTime.now(),
            playChapters: true,
            tracks: [
              DiscoveredTrack(
                index: 1,
                videoId: track.videoId,
                title: track.title,
                status: 'complete',
                fileName: saved['fileName'] as String,
                chaptersJson: ChapterData.fromJson(saved['chapters']).encode(),
                chaptersEnabled: saved['chaptersEnabled'] as bool?,
              ),
            ],
          ),
        );
        final result = (await imported.getAllTracks()).single;
        expect(result.chaptersEnabled, isTrue);
        expect(ChapterData.decode(result.chaptersJson).shuffleChapters, isTrue);
        expect(
          ChapterData.decode(result.chaptersJson).active.first.title,
          'Local title',
        );
        expect((await imported.getAllPlaylists()).single.playChapters, isTrue);
      } finally {
        await imported.close();
      }
    },
  );

  test(
    'v9 migration keeps existing tracks playable without chapter metadata',
    () async {
      final file = File('${dir.path}/migration.sqlite');
      var database = AppDatabase.forTesting(NativeDatabase(file));
      final playlist = await insertTestPlaylist(database);
      final oldTrack = await insertTestTrack(
        database,
        playlistId: playlist.id,
        status: 'complete',
        filePath: media.path,
      );
      await database.customStatement(
        'ALTER TABLE playlists DROP COLUMN play_chapters',
      );
      await database.customStatement(
        'ALTER TABLE tracks DROP COLUMN chapters_json',
      );
      await database.customStatement(
        'ALTER TABLE tracks DROP COLUMN chapters_enabled',
      );
      // Added in schema 12; a real v9 database does not have it either.
      await database.customStatement(
        'ALTER TABLE tracks DROP COLUMN replace_requested',
      );
      // Added in schema 13: the change counters and the update-attempt
      // stamp (the triggers read that column, so they go first).
      final triggers =
          await database
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type = 'trigger'",
              )
              .get();
      for (final trigger in triggers) {
        await database.customStatement(
          'DROP TRIGGER ${trigger.read<String>('name')}',
        );
      }
      await database.customStatement('DROP TABLE playlist_revisions');
      await database.customStatement(
        'ALTER TABLE playlists DROP COLUMN last_update_attempt',
      );
      await database.customStatement('PRAGMA user_version = 9');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      try {
        final migrated = (await database.getTrack(oldTrack.id))!;
        expect(migrated.status, 'complete');
        expect(migrated.filePath, media.path);
        expect(migrated.chaptersJson, isNull);
        expect(migrated.chaptersEnabled, isNull);
        expect((await database.getPlaylist(playlist.id)).playChapters, isNull);
      } finally {
        await database.close();
      }
    },
  );

  group('chapter editing and recognition', () {
    MediaChapter chapter(
      String id,
      int startMs,
      int endMs, {
      ChapterOrigin origin = ChapterOrigin.user,
      bool manuallyEdited = false,
      List<String> reviewReasons = const [],
    }) => MediaChapter(
      id: id,
      title: id,
      startMs: startMs,
      endMs: endMs,
      origin: origin,
      manuallyEdited: manuallyEdited,
      reviewReasons: reviewReasons,
    );

    Future<ChapterData> data() async =>
        ChapterData.decode((await db.getTrack(track.id))!.chaptersJson);

    Future<void> seed(List<MediaChapter> chapters, {int durationMs = 60000}) =>
        db.writeTrackChapters(
          track.id,
          ChapterData(custom: chapters, durationMs: durationMs),
        );

    test('rename marks the chapter edited and clears name reviews', () async {
      await seed([
        chapter(
          'a',
          0,
          30000,
          origin: ChapterOrigin.auto,
          reviewReasons: ['Name: low confidence', 'Timing: guessed'],
        ),
        chapter('b', 30000, 60000),
      ]);
      await service.rename(track, 'a', '  Real title ');
      final renamed = (await data()).active.first;
      expect(renamed.title, 'Real title');
      expect(renamed.manuallyEdited, isTrue);
      expect(renamed.protectedFromRecognition, isTrue);
      expect(renamed.reviewReasons, ['Timing: guessed']);
      await expectLater(
        service.rename(track, 'missing', 'x'),
        throwsStateError,
      );
    });

    test(
      'moveBoundary shifts both neighbours and rejects stale edges',
      () async {
        await seed([
          chapter('a', 0, 30000, origin: ChapterOrigin.auto),
          chapter(
            'b',
            30000,
            60000,
            origin: ChapterOrigin.auto,
            reviewReasons: ['Timing: guessed'],
          ),
        ]);
        await service.moveBoundary(track, 'a', 'b', 30000, 25000);
        final moved = (await data()).active;
        expect(moved.map((c) => (c.startMs, c.endMs)), [
          (0, 25000),
          (25000, 60000),
        ]);
        expect(moved.every((c) => c.manuallyEdited), isTrue);
        expect(moved.last.reviewReasons, isEmpty);
        await expectLater(
          service.moveBoundary(track, 'a', 'b', 30000, 20000),
          throwsStateError,
        );
        await expectLater(
          service.moveBoundary(track, 'a', 'b', 25000, 70000),
          throwsFormatException,
        );
      },
    );

    test('merge keeps the chosen survivor over the combined range', () async {
      final left = chapter(
        'a',
        0,
        30000,
        origin: ChapterOrigin.auto,
        reviewReasons: ['Timing: guessed', 'Name: low confidence'],
      );
      final right = chapter('b', 30000, 60000, origin: ChapterOrigin.original);
      await seed([left, right]);
      await service.merge(
        track,
        left,
        right,
        keepEarlier: false,
        title: 'Both',
      );
      final merged = (await data()).active.single;
      expect(merged.id, 'b');
      expect(merged.origin, ChapterOrigin.original);
      expect((merged.startMs, merged.endMs), (0, 60000));
      expect(merged.title, 'Both');
      expect(merged.manuallyEdited, isTrue);
      expect(merged.reviewReasons, ['Timing: guessed']);
      await expectLater(
        service.merge(track, left, right, keepEarlier: true, title: 'x'),
        throwsStateError,
      );
    });

    test(
      'delete and restore keep an undo snapshot that undo applies',
      () async {
        await service.refresh(track);
        final before = (await data()).active;
        await service.delete(track, before.first.id);
        var current = await data();
        expect(current.active.map((c) => c.id), [before.last.id]);
        expect(current.undoChapters!.map((c) => c.id), before.map((c) => c.id));

        await service.undo(track);
        current = await data();
        expect(current.active.map((c) => c.id), before.map((c) => c.id));
        expect(current.undoChapters, isNull);
        expect(current.recognitionEpoch, 1);

        await service.save(
          track,
          MediaChapter(
            id: before.first.id,
            title: 'Mine',
            startMs: 0,
            endMs: 30000,
          ),
        );
        await service.restore(track);
        current = await data();
        expect(current.custom, isNull);
        expect(current.active.first.title, 'First');
        expect(current.undoChapters!.first.title, 'Mine');
        // Undo reverts the restore; a second undo has nothing left to apply.
        await service.undo(track);
        current = await data();
        expect(current.active.first.title, 'Mine');
        expect(current.undoChapters, isNull);
        await service.undo(track);
        expect((await data()).active.first.title, 'Mine');
      },
    );

    test('undo of recognition on a file without YouTube chapters follows '
        'YouTube again', () async {
      // As seen on a device: nothing downloaded, nothing custom.
      await db.writeTrackChapters(
        track.id,
        const ChapterData(durationMs: 60000),
      );
      expect(
        await service.applyRecognition(
          track,
          runId: 'run-1',
          epoch: 0,
          durationMs: 60000,
          fileKey: null,
          proposals: [chapter('song', 0, 60000)],
        ),
        isTrue,
      );
      final applied = await data();
      expect(applied.custom, hasLength(1));
      expect(applied.undoChapters, isEmpty);
      expect(applied.undoFollowsDownloaded, isTrue);

      await service.undo(track);
      final undone = await data();
      expect(undone.custom, isNull);
      expect(undone.undoChapters, isNull);
      expect(undone.undoFollowsDownloaded, isFalse);
      expect(undone.recognitionEpoch, 1);
      final sidecar =
          jsonDecode(
                await File('${dir.path}/woolytube_meta.json').readAsString(),
              )
              as Map;
      final stored =
          ((sidecar['tracks'] as List).single as Map)['chapters'] as Map;
      expect(stored.containsKey('custom'), isTrue);
      expect(stored['custom'], isNull);
      expect(stored.containsKey('undoFollowsDownloaded'), isFalse);

      // A later YouTube fetch shows, as it would have without the scan.
      await service.refresh(track);
      expect((await data()).active.map((c) => c.title), ['First', 'Second']);
    });

    test('every change made while following YouTube undoes back to '
        'following it', () async {
      final youtube = ChapterData.fromVideoInfo(await ytdlp.getVideoInfo('x'));
      final first = youtube.downloaded.first;
      final second = youtube.downloaded.last;
      final changes = <String, Future<void> Function()>{
        'save':
            () => service.save(
              track,
              first.copyWith(title: 'Mine'),
              durationMs: 60000,
            ),
        'rename': () => service.rename(track, first.id, 'Mine'),
        'moveBoundary':
            () =>
                service.moveBoundary(track, first.id, second.id, 30000, 20000),
        'merge':
            () => service.merge(
              track,
              first,
              second,
              keepEarlier: true,
              title: 'Both',
            ),
        'delete': () => service.delete(track, first.id),
        'removeAutomatic': () => service.removeAutomatic(track),
        'restore': () => service.restore(track),
        'applyRecognition':
            () => service.applyRecognition(
              track,
              runId: 'run-1',
              epoch: 0,
              durationMs: 60000,
              fileKey: null,
              proposals: [chapter('song', 0, 60000)],
            ),
      };
      for (final MapEntry(key: name, value: change) in changes.entries) {
        await db.writeTrackChapters(
          track.id,
          ChapterData(
            downloaded: youtube.downloaded,
            durationMs: 60000,
            checkedAt: youtube.checkedAt,
          ),
        );
        await change();
        final changed = await data();
        expect(changed.undoChapters, isNotNull, reason: name);
        expect(changed.undoFollowsDownloaded, isTrue, reason: name);
        expect(
          (jsonDecode(changed.encode()) as Map)['undoFollowsDownloaded'],
          isTrue,
          reason: name,
        );
        // YouTube's list changes before the undo; undo follows it.
        await db.writeTrackChapters(
          track.id,
          changed.copyWith(downloaded: [first.copyWith(endMs: 60000)]),
        );
        await service.undo(track);
        final undone = await data();
        expect(undone.custom, isNull, reason: name);
        expect(undone.active.map((c) => c.id), [first.id], reason: name);
        expect(undone.undoChapters, isNull, reason: name);
      }
    });

    test(
      'undo of a change to an own (even empty) list restores that list',
      () async {
        await db.writeTrackChapters(
          track.id,
          ChapterData(
            downloaded: [
              chapter('yt', 0, 60000, origin: ChapterOrigin.original),
            ],
            custom: const [],
            durationMs: 60000,
          ),
        );
        await service.save(track, chapter('mine', 0, 30000), durationMs: 60000);
        final changed = await data();
        expect(changed.undoFollowsDownloaded, isFalse);
        expect(
          (jsonDecode(changed.encode()) as Map).containsKey(
            'undoFollowsDownloaded',
          ),
          isFalse,
        );
        await service.undo(track);
        final undone = await data();
        expect(undone.custom, isEmpty);
        expect(undone.active, isEmpty);
      },
    );

    test('removeAutomatic keeps edited and user-made chapters', () async {
      await seed([
        chapter('auto', 0, 20000, origin: ChapterOrigin.auto),
        chapter(
          'edited',
          20000,
          40000,
          origin: ChapterOrigin.auto,
          manuallyEdited: true,
        ),
        chapter('mine', 40000, 60000),
      ]);
      await service.removeAutomatic(track);
      final current = await data();
      expect(current.active.map((c) => c.id), ['edited', 'mine']);
      expect(current.recognitionEpoch, 1);
      expect(current.undoChapters, hasLength(3));
    });

    test('applyRecognition cuts around protected chapters and replaces old '
        'results', () async {
      await seed([
        chapter('old-auto', 0, 30000, origin: ChapterOrigin.auto),
        chapter('mine', 30000, 40000),
        chapter(
          'edited',
          40000,
          50000,
          origin: ChapterOrigin.auto,
          manuallyEdited: true,
        ),
      ]);
      final applied = await service.applyRecognition(
        track,
        runId: 'run-1',
        epoch: 0,
        durationMs: 60000,
        fileKey: null,
        proposals: [
          chapter('song-1', 0, 28000),
          chapter('song-2', 28000, 55000),
        ],
      );
      expect(applied, isTrue);
      final current = await data();
      expect(current.lastRecognitionRunId, 'run-1');
      expect(
        current.active
            .map((c) => (c.id, c.startMs, c.endMs, c.origin))
            .toList(),
        [
          ('song-1-0-28000', 0, 28000, ChapterOrigin.auto),
          // The 2 s remainder of the old result is noise and is dropped.
          ('mine', 30000, 40000, ChapterOrigin.user),
          ('edited', 40000, 50000, ChapterOrigin.auto),
          ('song-2-50000-55000', 50000, 55000, ChapterOrigin.auto),
        ],
      );
      expect(
        current.active
            .where((c) => c.id.startsWith('song'))
            .every((c) => !c.manuallyEdited),
        isTrue,
      );
    });

    test('applyRecognition clips overlapping and overlong proposals', () async {
      await seed(const []);
      await service.applyRecognition(
        track,
        runId: 'run-1',
        epoch: 0,
        durationMs: 60000,
        fileKey: null,
        proposals: [
          chapter('b', 25000, 70000),
          chapter('a', 0, 30000),
          chapter('tiny', 29000, 31000),
        ],
      );
      expect((await data()).active.map((c) => (c.startMs, c.endMs)).toList(), [
        (0, 30000),
        (30000, 60000),
      ]);
    });

    test('applyRecognition ignores stale epochs and repeated runs', () async {
      await seed([chapter('mine', 0, 10000)]);
      final proposals = [chapter('song', 10000, 60000)];
      expect(
        await service.applyRecognition(
          track,
          runId: 'run-1',
          epoch: 3,
          durationMs: 60000,
          proposals: proposals,
          fileKey: null,
        ),
        isFalse,
      );
      expect(
        await service.applyRecognition(
          track,
          runId: 'run-1',
          epoch: 0,
          durationMs: 60000,
          proposals: proposals,
          fileKey: null,
        ),
        isTrue,
      );
      expect(
        await service.applyRecognition(
          track,
          runId: 'run-1',
          epoch: 0,
          durationMs: 60000,
          proposals: proposals,
          fileKey: null,
        ),
        isFalse,
      );
      // An edit bumps the epoch, so an in-flight scan from before it is dropped.
      await service.rename(track, 'mine', 'Renamed');
      await service.removeAutomatic(track);
      expect(
        await service.applyRecognition(
          track,
          runId: 'run-2',
          epoch: 0,
          durationMs: 60000,
          proposals: proposals,
          fileKey: null,
        ),
        isFalse,
      );
      expect((await data()).active.map((c) => c.id), ['mine']);
    });

    test(
      'applyRecognition refuses a run made from other file content',
      () async {
        await seed([chapter('mine', 0, 10000)]);
        final before = (await db.getTrack(track.id))!.chaptersJson;
        final key = (await SongRecognitionService.currentFileKey(track))!;
        expect(key, startsWith('${track.id}-'));
        Future<bool> apply(String runId) => service.applyRecognition(
          track,
          runId: runId,
          epoch: 0,
          durationMs: 60000,
          fileKey: key,
          proposals: [
            chapter('song', 10000, 60000, origin: ChapterOrigin.auto),
          ],
        );

        // The file was replaced at the same path after the scan.
        await media.writeAsBytes([9, 9, 9, 9, 9]);
        await expectLater(apply('run-1'), throwsA(isA<StaleRecognitionRun>()));
        expect((await db.getTrack(track.id))!.chaptersJson, before);

        // Gone altogether.
        await media.delete();
        await expectLater(apply('run-1'), throwsA(isA<StaleRecognitionRun>()));
        expect((await db.getTrack(track.id))!.chaptersJson, before);

        // The original content back (a byte-identical redownload) applies.
        await media.writeAsBytes([0, 1, 2, 3, 255]);
        expect(await apply('run-1'), isTrue);
        expect((await data()).active.map((c) => c.id), [
          'mine',
          'song-10000-60000',
        ]);
      },
    );

    test('applyRecognition keeps protected chapters that end past the probed '
        'length', () async {
      // YouTube chapters end at the whole-second length; the file probes
      // 20 ms shorter.
      await service.refresh(track);
      await db.writeTrackChapters(
        track.id,
        (await data()).copyWith(
          custom: [
            chapter('youtube-0-0', 0, 30000, origin: ChapterOrigin.original),
            chapter('old-auto', 30000, 45000, origin: ChapterOrigin.auto),
            chapter('youtube-1-45000', 45000, 60000),
          ],
        ),
      );
      expect(
        await service.applyRecognition(
          track,
          runId: 'run-1',
          epoch: 0,
          durationMs: 59980,
          fileKey: null,
          proposals: [chapter('song', 0, 60000, origin: ChapterOrigin.auto)],
        ),
        isTrue,
      );
      final current = await data();
      expect(current.active.map((c) => (c.id, c.startMs, c.endMs)).toList(), [
        ('youtube-0-0', 0, 30000),
        ('song-30000-45000', 30000, 45000),
        ('youtube-1-45000', 45000, 60000),
      ]);
      expect(current.durationMs, 60000);
      // Later edits still work on it.
      await service.delete(track, 'song-30000-45000');
      await service.undo(track);
      expect((await data()).active, hasLength(3));

      // A proposal past the probed length is clipped to the real file.
      await seed(const [], durationMs: 70000);
      await service.applyRecognition(
        track,
        runId: 'run-2',
        epoch: (await data()).recognitionEpoch,
        durationMs: 59980,
        fileKey: null,
        proposals: [chapter('song', 0, 70000, origin: ChapterOrigin.auto)],
      );
      expect((await data()).active.single.endMs, 59980);
    });

    test('edits after a shorter YouTube length still delete, undo, remove '
        'and rename', () async {
      // Recognition stored the probed length; a later YouTube refresh
      // stores its whole-second length, 512 ms shorter.
      await seed([
        chapter('a', 0, 30000, origin: ChapterOrigin.auto),
        chapter('b', 30000, 45000, origin: ChapterOrigin.auto),
        chapter('c', 45000, 60512, origin: ChapterOrigin.auto),
      ], durationMs: 60512);
      await service.refresh(track);
      expect((await data()).durationMs, 60000);
      expect((await data()).active.last.endMs, 60512);

      await service.delete(track, 'b');
      expect((await data()).active.map((c) => c.id), ['a', 'c']);
      await service.undo(track);
      expect((await data()).active.map((c) => c.id), ['a', 'b', 'c']);
      await service.rename(track, 'c', 'Last song');
      expect((await data()).active.last.title, 'Last song');
      await service.removeAutomatic(track);
      expect((await data()).active.map((c) => c.id), ['c']);
      await service.undo(track);
      expect((await data()).active, hasLength(3));
      // Retitling the last chapter keeps its stored end.
      await service.save(
        track,
        const MediaChapter(
          id: 'a',
          title: 'First song',
          startMs: 0,
          endMs: 30000,
        ),
      );
      await service.restore(track);
      expect((await data()).custom, isNull);
      await service.undo(track);
      expect((await data()).active.first.title, 'First song');
      // A new end past the length is still refused.
      await service.delete(track, 'c');
      await expectLater(
        service.save(
          track,
          const MediaChapter(
            id: 'new',
            title: 'Too long',
            startMs: 45000,
            endMs: 60600,
          ),
        ),
        throwsFormatException,
      );
    });

    test(
      'renamed and merged review proposals apply as the user\'s work',
      () async {
        ChapterProposal draft(String id, int startMs, int endMs) =>
            ChapterProposal(
              id: id,
              title: 'Unrecognized section',
              startMs: startMs,
              endMs: endMs,
              trackKey: null,
              referenceId: null,
              sampleCount: 1,
              referenceSampleCount: 0,
              referenceStartMs: null,
              referenceSpreadMs: null,
              boundaryMethod: 'sample-bracket',
              selectedQuietIntervalMs: null,
              nearestSilenceMs: null,
              distanceFromSilenceEndMs: null,
              consistentReference: false,
              notes: const [
                ChapterProposal.unrecognizedNote,
                ChapterProposal.provisionalBoundaryNote,
              ],
              firstSampleMs: startMs,
              lastSampleMs: startMs,
            );
        final renamed = draft('a', 0, 20000).renamed('Real song');
        expect(renamed.notes, [ChapterProposal.provisionalBoundaryNote]);
        expect(
          ChapterProposal.fromJson(renamed.toJson()).edited,
          isTrue,
          reason: 'review edits survive a restart',
        );
        final merged = draft('b', 20000, 40000).copyWith(edited: true);
        final untouched = draft('c', 40000, 60000);
        await seed(const []);
        await service.applyRecognition(
          track,
          runId: 'run-1',
          epoch: 0,
          durationMs: 60000,
          fileKey: null,
          proposals: [
            for (final p in [renamed, merged, untouched]) p.toChapter(),
          ],
        );
        var current = (await data()).active;
        expect(current.map((c) => c.manuallyEdited), [true, true, false]);
        expect(current.first.title, 'Real song');
        expect(
          current.first.reviewReasons.where((r) => r.startsWith('Name:')),
          isEmpty,
        );
        expect(current.first.protectedFromRecognition, isTrue);

        // A later scan replaces only the untouched one.
        await service.applyRecognition(
          track,
          runId: 'run-2',
          epoch: 0,
          durationMs: 60000,
          fileKey: null,
          proposals: [chapter('again', 0, 60000, origin: ChapterOrigin.auto)],
        );
        current = (await data()).active;
        expect(current.map((c) => c.title), [
          'Real song',
          'Unrecognized section',
          'again',
        ]);
        expect(current.last.startMs, 40000);
        await service.removeAutomatic(track);
        expect((await data()).active.map((c) => c.title), [
          'Real song',
          'Unrecognized section',
        ]);
      },
    );

    test('legacy custom chapters infer origin and edits from downloads', () {
      final parsed = ChapterData.fromJson({
        'downloaded': [
          {'id': 'youtube-0-0', 'title': 'First', 'startMs': 0, 'endMs': 30000},
          {
            'id': 'youtube-1-30',
            'title': 'Second',
            'startMs': 30000,
            'endMs': 60000,
          },
        ],
        'custom': [
          {'id': 'youtube-0-0', 'title': 'First', 'startMs': 0, 'endMs': 30000},
          {
            'id': 'youtube-1-30',
            'title': 'Renamed',
            'startMs': 30000,
            'endMs': 60000,
          },
          {'id': 'local', 'title': 'Mine', 'startMs': 60000, 'endMs': 70000},
        ],
      });
      expect(
        parsed.downloaded.every((c) => c.origin == ChapterOrigin.original),
        isTrue,
      );
      final custom = parsed.custom!;
      expect(custom[0].origin, ChapterOrigin.original);
      expect(custom[0].manuallyEdited, isFalse);
      expect(custom[1].origin, ChapterOrigin.original);
      expect(custom[1].manuallyEdited, isTrue);
      expect(custom[2].origin, ChapterOrigin.user);
      expect(custom[2].protectedFromRecognition, isTrue);
      final roundTrip = ChapterData.fromJson(parsed.toJson());
      expect(roundTrip.custom![1].manuallyEdited, isTrue);
      expect(roundTrip.recognitionEpoch, 0);
    });
  });
}
