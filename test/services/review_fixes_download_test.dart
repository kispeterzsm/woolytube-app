import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart'
    show
        ApplyInterceptor,
        QueryExecutor,
        QueryInterceptor,
        Value,
        driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/sponsorblock_service.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

/// Regression tests for the download-side fixes of the final review
/// (commit 365e1e4: R03, R08, R12, R14, R18, R19, R24).

class _FakeSponsorBlockService extends SponsorBlockService {
  final AppDatabase db;
  final refreshedTracks = <Track>[];
  final fetchedVideoIds = <String>[];
  final segmentsByVideoId = <String, List<SponsorBlockSegmentsCompanion>>{};

  _FakeSponsorBlockService(this.db, LogService log) : super(db, log);

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

/// Lets local replacements through the "tracks to download" query, the way
/// it selected them before R12. Since R12 the real query never hands a local
/// replacement to the download's reuse path, so this is the only way to
/// check that the reuse path itself keeps the local-file flag (R03).
class _PendingIncludesLocalFiles extends QueryInterceptor {
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    const filter = '"is_local_replacement" = ?';
    if (statement.contains(filter) && statement.contains('"status" = ?')) {
      // Same number of arguments, but the condition always holds.
      statement = statement.replaceFirst(filter, '? IS NOT NULL');
    }
    return executor.runSelect(statement, args);
  }
}

SponsorBlockSegmentsCompanion _remoteSegment(Track track) =>
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
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory tempDir;
  late String folder;
  late LogService log;
  late FakeYtDlpService ytdlp;
  late FakeMediaThumbnailService thumbnails;
  late _FakeSponsorBlockService sponsorBlock;
  late DownloadService service;

  DownloadService newService({bool withSponsorBlock = true}) => DownloadService(
    db,
    ytdlp,
    log,
    MetadataService(db),
    null,
    withSponsorBlock ? sponsorBlock : null,
    null,
    DownloadLock(directoryProvider: () async => tempDir.path),
    DownloadLock.foregroundOwner,
    null,
    thumbnails,
  );

  Future<void> useDatabase(AppDatabase database) async {
    service.dispose();
    await db.close();
    db = database;
    sponsorBlock = _FakeSponsorBlockService(db, log);
    service = newService();
  }

  setUpAll(() {
    // R03 swaps in a second, intercepted in-memory database.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_review_dl_');
    // One level below a library root, as on the device.
    folder = p.join(tempDir.path, 'Music', 'Review');
    await Directory(folder).create(recursive: true);
    log = LogService();
    ytdlp = FakeYtDlpService();
    thumbnails = FakeMediaThumbnailService();
    sponsorBlock = _FakeSponsorBlockService(db, log);
    service = newService();
  });

  tearDown(() async {
    service.dispose();
    log.dispose();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> write(String name, String content) async {
    final path = p.join(folder, name);
    await File(path).writeAsString(content);
    return path;
  }

  PlatformException ytdlpError(String message) =>
      PlatformException(code: 'DOWNLOAD_ERROR', message: message);

  test('R03: the reuse path keeps a reappeared local file a local file and '
      'fetches no SponsorBlock segments for it', () async {
    await useDatabase(
      AppDatabase.forTesting(
        NativeDatabase.memory().interceptWith(_PendingIncludesLocalFiles()),
      ),
    );
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    // The owner's file was missing (being copied back) and is back now.
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'mine',
      title: 'My Version',
      status: 'pending',
      isLocalReplacement: true,
    );
    final mine = await write('00001_My Version.m4a', 'local');
    sponsorBlock.segmentsByVideoId[track.videoId] = [_remoteSegment(track)];
    expect(
      (await db.getPendingTracks(playlist.id)).map((t) => t.id),
      [track.id],
      reason: 'the interceptor must hand the track to the reuse path',
    );

    await service.downloadPlaylist(playlist);

    final updated = (await db.getTrack(track.id))!;
    expect(updated.status, 'complete');
    expect(updated.filePath, mine);
    expect(updated.isLocalReplacement, isTrue);
    expect(await File(mine).readAsString(), 'local');
    expect(ytdlp.calls, isEmpty);
    // Its timeline is not the YouTube video's.
    expect(sponsorBlock.refreshedTracks, isEmpty);
    expect(sponsorBlock.fetchedVideoIds, isEmpty);
    expect(await db.getSegmentsForTrack(track.id), isEmpty);
  });

  group('R08', () {
    test('a failed "Conversion failed!" post-processing step is retried '
        'once without cover, tags and kept thumbnail', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.errorFor =
          (call) =>
              call.embedMetadata || call.writeThumbnail || call.embedThumbnail
                  ? ytdlpError('ERROR: Postprocessing: Conversion failed!')
                  : null;

      await service.downloadPlaylist(playlist);

      expect(ytdlp.calls, hasLength(2));
      final first = ytdlp.calls.first;
      expect(first.embedThumbnail, isTrue);
      expect(first.embedMetadata, isTrue);
      expect(first.writeThumbnail, isTrue);
      final retry = ytdlp.calls.last;
      expect(retry.embedThumbnail, isFalse);
      expect(retry.embedMetadata, isFalse);
      expect(retry.writeThumbnail, isFalse);
      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'complete');
      expect(updated.lastError, isNull);
      expect(updated.filePath, p.join(folder, '00001_Title.m4a'));
      expect(await File(updated.filePath!).readAsString(), 'media');
    });

    test('a failed audio conversion is not retried without extras', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.downloadError = ytdlpError(
        'ERROR: Postprocessing: audio conversion failed: '
        'Error opening output files: Invalid argument',
      );

      await service.downloadPlaylist(playlist);

      final call = ytdlp.calls.single;
      expect(call.embedMetadata, isTrue);
      expect(call.writeThumbnail, isTrue);
      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'error');
      expect(updated.filePath, isNull);
      expect(updated.lastError, contains('audio conversion failed'));
    });

    test('the stored error is the ERROR line even after 600 characters of '
        'warnings', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'abc',
      );
      final warnings = StringBuffer();
      while (warnings.length < 600) {
        warnings.writeln(
          'WARNING: [youtube] abc: Some web client formats are missing; '
          'falling back to another client',
        );
      }
      ytdlp.downloadError = ytdlpError(
        '${warnings}ERROR: [youtube] abc: Video unavailable',
      );

      await service.downloadPlaylist(playlist);

      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'error');
      expect(updated.lastError, 'Video unavailable');
    });
  });

  test('R12: an update never downloads YouTube\'s version over a local file '
      'that is still missing', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    final missingLocal = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'mine',
      status: 'pending',
      isLocalReplacement: true,
    );
    final failedLocal = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'mine-too',
      status: 'error',
      lastError: 'Downloaded file not found',
      isLocalReplacement: true,
    );
    final normal = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 3,
      videoId: 'normal',
    );

    expect((await db.getPendingTracks(playlist.id)).map((t) => t.id), [
      normal.id,
    ]);

    await service.downloadPlaylist(playlist);

    expect(ytdlp.calls.map((c) => c.videoId), ['normal']);
    for (final before in [missingLocal, failedLocal]) {
      final after = (await db.getTrack(before.id))!;
      expect(after.status, before.status, reason: before.videoId);
      expect(after.filePath, isNull, reason: before.videoId);
      expect(after.isLocalReplacement, isTrue, reason: before.videoId);
    }
    expect((await db.getTrack(normal.id))!.status, 'complete');
  });

  test('R12: Download original for a local file that is missing is downloaded '
      'by the next update', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    // The reconcile already demoted it: its file is gone.
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'mine',
      status: 'pending',
      isLocalReplacement: true,
    );
    // The track menu offers Download original for any local file.
    await PlaylistService(
      db,
      ytdlp,
      MetadataService(db),
      thumbnails,
    ).requestOriginalDownload(track);

    await service.downloadPlaylist(playlist);

    expect(ytdlp.calls.map((c) => c.videoId), ['mine']);
    final after = (await db.getTrack(track.id))!;
    expect(after.status, 'complete');
    expect(after.filePath, p.join(folder, '00001_Title.m4a'));
    expect(after.isLocalReplacement, isFalse);
    expect(after.replaceRequested, isFalse);
  });

  test('R14: Download Original drops chapters and skip marks made for the '
      'local file and keeps the ones made for the video', () async {
    service.dispose();
    service = newService(withSponsorBlock: false);
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    // Both files were replaced by the owner on this date.
    final replacedAt = DateTime(2025, 6, 1);
    const localChapters = ChapterData(
      custom: [
        MediaChapter(id: 'l', title: 'Local part', startMs: 0, endMs: 30000),
      ],
    );
    final madeForLocal = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'made-for-local',
      title: 'First',
      filePath: await write('00001_First local.m4a', 'local 1'),
      status: 'complete',
      isLocalReplacement: true,
      replaceRequested: true,
      downloadedAt: replacedAt,
      sponsorBlockCheckedAt: replacedAt,
      // Made (and so enabled) while the local file played.
      chaptersJson: localChapters.encode(),
    );
    const videoChapters = ChapterData(
      custom: [
        MediaChapter(id: 'v', title: 'Video part', startMs: 0, endMs: 20000),
      ],
    );
    final madeForVideo = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'made-for-video',
      title: 'Second',
      filePath: await write('00002_Second local.m4a', 'local 2'),
      status: 'complete',
      isLocalReplacement: true,
      replaceRequested: true,
      downloadedAt: replacedAt,
      sponsorBlockCheckedAt: replacedAt,
      // Made for the video; the replacement only disabled them.
      chaptersJson: videoChapters.invalidate().encode(),
    );
    Future<int> localMark(Track track, DateTime createdAt, int startMs) =>
        db.insertSegment(
          SponsorBlockSegmentsCompanion.insert(
            trackId: track.id,
            videoId: track.videoId,
            source: 'local',
            category: 'sponsor',
            startMs: startMs,
            endMs: startMs + 1000,
            createdAt: createdAt,
          ),
        );
    final olderMark = await localMark(madeForLocal, DateTime(2025, 1, 1), 1000);
    await localMark(madeForLocal, DateTime(2025, 7, 1), 5000);
    await localMark(madeForLocal, replacedAt, 9000);
    final olderMark2 = await localMark(
      madeForVideo,
      DateTime(2025, 1, 1),
      1000,
    );
    await localMark(madeForVideo, DateTime(2025, 8, 1), 5000);
    ytdlp.infoFor =
        (call) => {
          ...ytdlp.defaultInfo(call),
          'chapters': [
            {'title': 'Intro', 'start_time': 0, 'end_time': 20},
            {'title': 'Song', 'start_time': 20, 'end_time': 60},
          ],
        };

    await service.downloadPlaylist(playlist);

    expect(ytdlp.calls.map((c) => c.videoId), [
      'made-for-local',
      'made-for-video',
    ]);
    final first = (await db.getTrack(madeForLocal.id))!;
    expect(first.isLocalReplacement, isFalse);
    expect(first.replaceRequested, isFalse);
    final firstChapters = ChapterData.decode(first.chaptersJson);
    expect(firstChapters.custom, isNull);
    expect(firstChapters.active.map((c) => c.title), ['Intro', 'Song']);
    expect((await db.getSegmentsForTrack(first.id)).map((s) => s.id), [
      olderMark,
    ]);

    final second = (await db.getTrack(madeForVideo.id))!;
    expect(second.isLocalReplacement, isFalse);
    final secondChapters = ChapterData.decode(second.chaptersJson);
    expect(secondChapters.custom!.map((c) => c.title), ['Video part']);
    expect(secondChapters.downloaded.map((c) => c.title), ['Intro', 'Song']);
    expect(secondChapters.active.map((c) => c.title), ['Video part']);
    expect((await db.getSegmentsForTrack(second.id)).map((s) => s.id), [
      olderMark2,
    ]);
  });

  test('Download Original makes song recognition results timed to the local '
      'file stale', () async {
    service.dispose();
    service = newService(withSponsorBlock: false);
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    const localChapters = ChapterData(
      custom: [
        MediaChapter(
          id: 'l',
          title: 'Local part',
          startMs: 0,
          endMs: 30000,
          origin: ChapterOrigin.auto,
        ),
      ],
      undoChapters: [],
      recognitionEpoch: 3,
      lastRecognitionRunId: 'run-1',
    );
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'made-for-local',
      title: 'First',
      filePath: await write('00001_First local.m4a', 'local 1'),
      status: 'complete',
      isLocalReplacement: true,
      replaceRequested: true,
      downloadedAt: DateTime(2025, 6, 1),
      sponsorBlockCheckedAt: DateTime(2025, 6, 1),
      chaptersJson: localChapters.encode(),
    );

    await service.downloadPlaylist(playlist);

    final after = (await db.getTrack(track.id))!;
    expect(after.isLocalReplacement, isFalse);
    final data = ChapterData.decode(after.chaptersJson);
    expect(data.custom, isNull);
    // The undo step would bring back chapters made for the local file.
    expect(data.undoChapters, isNull);
    // A scan of the local file can no longer be applied.
    expect(data.recognitionEpoch, 4);
    expect(data.lastRecognitionRunId, 'run-1');
  });

  group('R18', () {
    /// Gives [path] a second name, like case-insensitive shared storage
    /// does for every letter-case variant: two names, one file. Returns
    /// false when hard links cannot be made here.
    Future<bool> secondName(String path, String other) async {
      try {
        final result = await Process.run('ln', [path, other]);
        return result.exitCode == 0;
      } on ProcessException {
        return false;
      }
    }

    test('a target that differs from the old file only in letter case is '
        'the same file', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final old = await write('00001_song.m4a', 'old');
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        title: 'song',
        filePath: old,
        status: 'complete',
        downloadedAt: DateTime(2024),
        sponsorBlockCheckedAt: DateTime.now(),
      );
      final target = p.join(folder, '00001_Song.m4a');
      if (!await secondName(old, target)) {
        markTestSkipped('hard links are not available here');
        return;
      }
      ytdlp.title = 'Song';
      ytdlp.mediaContent = 'new';

      expect(await service.downloadTrack(playlist, track), isTrue);

      final updated = (await db.getTrack(track.id))!;
      expect(updated.filePath, target);
      expect(await File(target).readAsString(), 'new');
      // Replaced in place: never set aside as an unknown file of that name.
      expect(
        await Directory(p.join(folder, '.woolytube_replaced')).exists(),
        isFalse,
      );
    });

    test('samePath compares names the way the storage does', () async {
      final lower = await write('00002_track.m4a', 'one');
      final linked = p.join(folder, '00002_TRACK.m4a');
      if (!await secondName(lower, linked)) {
        markTestSkipped('hard links are not available here');
        return;
      }
      final first = await write('00003_a.m4a', 'a');
      final second = await write('00003_A.m4a', 'A');

      expect(await MetadataService.samePath(lower, linked), isTrue);
      expect(await MetadataService.samePath(first, second), isFalse);
      expect(await MetadataService.samePath(lower, first), isFalse);
      expect(
        await MetadataService.samePath(
          p.join(folder, '..', 'Review', '00002_track.m4a'),
          lower,
        ),
        isTrue,
      );
    });
  });

  test('R19: Stop after the file was saved never un-marks the track', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    final track = await insertTestTrack(db, playlistId: playlist.id);
    ytdlp.downloadCompleter = Completer<void>();
    ytdlp.downloadStarted = Completer<void>();

    final download = service.downloadTrack(playlist, track);
    await ytdlp.downloadStarted!.future;
    // The track finishes just as the owner presses Stop.
    final saved = await write('00001_Title.m4a', 'media');
    await db.markTrackDownloaded(
      track.id,
      filePath: saved,
      thumbnailPath: null,
    );
    await service.cancelActiveDownloads();
    await download;

    final after = (await db.getTrack(track.id))!;
    expect(after.status, 'complete');
    expect(after.filePath, saved);
    expect(after.downloadedAt, isNotNull);
    expect(await File(saved).readAsString(), 'media');

    // The database guard on its own.
    final downloading = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'video-2',
      status: 'downloading',
      isLocalReplacement: true,
    );
    await db.resetInterruptedTrack(after.id, onlyIfDownloading: true);
    await db.resetInterruptedTrack(downloading.id, onlyIfDownloading: true);
    expect(await db.getTrack(after.id), after);
    final reset = (await db.getTrack(downloading.id))!;
    expect(reset.status, 'pending');
    // An interrupted download replaced nothing.
    expect(reset.isLocalReplacement, isTrue);
  });

  test('R24: downloadTrack says whether it saved a file', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    final first = await insertTestTrack(db, playlistId: playlist.id);
    final second = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'video-2',
    );

    expect(await service.downloadTrack(playlist, first), isTrue);
    expect((await db.getTrack(first.id))!.status, 'complete');

    ytdlp.downloadCompleter = Completer<void>();
    ytdlp.downloadStarted = Completer<void>();
    final stopped = service.downloadTrack(playlist, second);
    await ytdlp.downloadStarted!.future;
    await service.cancelActiveDownloads();

    expect(await stopped, isFalse);
    final after = (await db.getTrack(second.id))!;
    expect(after.status, 'pending');
    expect(after.filePath, isNull);
  });
}
