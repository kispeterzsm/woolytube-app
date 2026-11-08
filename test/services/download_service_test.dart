import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/download_errors.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/notification_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/sponsorblock_service.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

class FakeDownloadNotificationService extends DownloadNotificationService {
  final playlistNames = <String>[];
  final downloadedCounts = <int>[];
  final notificationIds = <int>[];
  final trackTitles = <String?>[];
  final failures = <(String, int, String)>[];

  @override
  Future<void> showDownloadComplete(
    String playlistName, {
    int downloadedCount = 1,
    int notificationId = 1001,
    String? trackTitle,
    bool audioOnly = false,
    int failedCount = 0,
  }) async {
    playlistNames.add(playlistName);
    downloadedCounts.add(downloadedCount);
    notificationIds.add(notificationId);
    trackTitles.add(trackTitle);
  }

  @override
  Future<void> showDownloadsFailed(
    String playlistName, {
    required int failedCount,
    required String reason,
    int notificationId = 1001,
  }) async {
    failures.add((playlistName, failedCount, reason));
  }
}

class FakeSponsorBlockService extends SponsorBlockService {
  final AppDatabase db;
  final refreshedTracks = <Track>[];
  final fetchedVideoIds = <String>[];
  final segmentsByVideoId = <String, List<SponsorBlockSegmentsCompanion>>{};
  void Function()? onFetch;

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
    onFetch?.call();
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
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory tempDir;
  late String libraryDir;
  late String folder;
  late LogService log;
  late FakeYtDlpService ytdlp;
  late FakeMediaThumbnailService thumbnails;
  late FakeSponsorBlockService sponsorBlock;
  late FakeDownloadNotificationService notifications;
  late DownloadLock lock;
  late DownloadService service;

  DownloadService newService({String owner = DownloadLock.foregroundOwner}) =>
      DownloadService(
        db,
        ytdlp,
        log,
        MetadataService(db),
        notifications,
        sponsorBlock,
        null,
        lock,
        owner,
        null,
        thumbnails,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_download_test_');
    // The playlist folder sits one level below a library root, as on the
    // device, so nothing is written outside the temp folder.
    libraryDir = p.join(tempDir.path, 'Music');
    folder = p.join(libraryDir, 'Test Playlist');
    await Directory(folder).create(recursive: true);
    log = LogService();
    ytdlp = FakeYtDlpService();
    thumbnails = FakeMediaThumbnailService();
    sponsorBlock = FakeSponsorBlockService(db, log);
    notifications = FakeDownloadNotificationService();
    lock = DownloadLock(directoryProvider: () async => tempDir.path);
    service = newService();
  });

  String staged(Track track) =>
      p.join(folder, '.woolytube-staging', 'track-${track.id}');

  File lockFile() => File(p.join(tempDir.path, DownloadLock.fileName));

  tearDown(() async {
    service.dispose();
    log.dispose();
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  for (final audioOnly in [false, true]) {
    test(
      'subtitle setting reaches downloads only for video (audioOnly=$audioOnly)',
      () async {
        final settings = AppSettingsService();
        await settings.setDownloadSubtitles(true);
        await settings.setSubtitleLanguages('en, hu');
        final playlist = await insertTestPlaylist(
          db,
          outputPath: folder,
          audioOnly: audioOnly,
        );
        final track = await insertTestTrack(db, playlistId: playlist.id);

        await service.downloadPlaylist(playlist);
        await service.downloadTrack(playlist, track);

        expect(ytdlp.subtitleRequests, [
          (!audioOnly, audioOnly ? 'en' : 'en,hu'),
          (!audioOnly, audioOnly ? 'en' : 'en,hu'),
        ]);
      },
    );
  }

  test('video subtitle downloads are opt-in', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    await insertTestTrack(db, playlistId: playlist.id);
    await service.downloadPlaylist(playlist);
    expect(ytdlp.subtitleRequests, [(false, 'en')]);
  });

  test(
    'reused indexed file is treated as a downloaded YouTube track',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'reused-video',
        title: 'Reused Audio',
        status: 'pending',
      );
      final existingPath = p.join(folder, '00001_Reused_Audio.m4a');
      await File(existingPath).writeAsString('audio');
      sponsorBlock.segmentsByVideoId[track.videoId] = [remoteSegment(track)];

      await service.downloadPlaylist(playlist);

      expect(ytdlp.downloadedUrls, isEmpty);
      expect(notifications.playlistNames, isEmpty);
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

  test('an unchanged playlist starts a new auto-update interval', () async {
    final oldUpdate = DateTime.now().subtract(const Duration(days: 2));
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      lastUpdated: oldUpdate,
    );

    await service.downloadPlaylist(playlist);

    final updated = await db.getPlaylist(playlist.id);
    expect(updated.lastUpdated, isNotNull);
    expect(updated.lastUpdated!.isAfter(oldUpdate), isTrue);
    expect(
      DateTime.now().difference(updated.lastUpdated!),
      lessThan(const Duration(seconds: 2)),
    );
    expect(notifications.playlistNames, isEmpty);
  });

  test('playlist completion notification counts actual downloads', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'new-video-1',
    );
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'new-video-2',
    );

    await service.downloadPlaylist(playlist);

    expect(ytdlp.downloadedUrls, hasLength(2));
    expect(notifications.playlistNames, [playlist.name]);
    expect(notifications.downloadedCounts, [2]);
    expect(notifications.notificationIds, [playlist.id]);
  });

  test('a failed playlist download does not notify', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    await insertTestTrack(db, playlistId: playlist.id);
    ytdlp.downloadError = StateError('permanent failure');

    await service.downloadPlaylist(playlist);

    expect(notifications.playlistNames, isEmpty);
  });

  test('SponsorBlock backfill leaves local replacements alone', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    final filePath = p.join(folder, '00001_Local_Audio.m4a');
    await File(filePath).writeAsString('audio');
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'local-video',
      title: 'Local Audio',
      filePath: filePath,
      status: 'complete',
      isLocalReplacement: true,
    );
    sponsorBlock.segmentsByVideoId[track.videoId] = [remoteSegment(track)];

    await service.downloadPlaylist(playlist);

    expect(ytdlp.downloadedUrls, isEmpty);
    // The file is not the YouTube video; its segments would cut the wrong
    // audio, and the flag must survive so the sync can ask the user.
    expect(sponsorBlock.fetchedVideoIds, isEmpty);
    final updated = (await db.getTracksForPlaylist(playlist.id)).single;
    expect(updated.isLocalReplacement, isTrue);
    expect(await db.getSegmentsForTrack(track.id), isEmpty);
  });

  test(
    'playlist update backfills SponsorBlock for already complete tracks',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final filePath = p.join(folder, '00001_Complete_Audio.m4a');
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
      outputPath: folder,
      audioOnly: true,
    );
    final filePath = p.join(folder, '00001_Checked_Audio.m4a');
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

  test('explicit update recovers a stale downloading row', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'stale-download',
      status: 'downloading',
    );

    await service.downloadPlaylist(playlist);

    expect(ytdlp.downloadedUrls, hasLength(1));
    expect((await db.getTrack(track.id))!.status, 'complete');
  });

  test(
    'cancelling returns the active track to pending and drops its staging folder',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'cancelled-download',
      );
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final download = service.downloadTrack(playlist, track);
      await ytdlp.downloadStarted!.future;
      // yt-dlp only ever writes into the track's staging folder.
      final staging = Directory(staged(track));
      expect(await staging.exists(), isTrue);
      await File(
        p.join(staging.path, '00001_Cancelled.m4a.part'),
      ).writeAsString('partial');

      await service.cancelActiveDownloads();
      await download;

      expect(ytdlp.cancelCalled, isTrue);
      expect((await db.getTrack(track.id))!.status, 'pending');
      expect(await staging.exists(), isFalse);
      expect(
        Directory(
          folder,
        ).listSync().whereType<File>().map((f) => p.basename(f.path)),
        isNot(contains(endsWith('.part'))),
      );
    },
  );

  test('lastUpdated is stamped without replacing the playlist row', () async {
    final stale = await insertTestPlaylist(db, outputPath: folder);
    await insertTestTrack(db, playlistId: stale.id);
    await db.updatePlaylistFields(
      stale.id,
      const PlaylistsCompanion(name: Value('Renamed meanwhile')),
    );

    await service.downloadPlaylist(stale);

    final updated = await db.getPlaylist(stale.id);
    expect(updated.name, 'Renamed meanwhile');
    expect(updated.lastUpdated, isNotNull);
  });

  test('a run in which every download failed is not stamped', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    await insertTestTrack(db, playlistId: playlist.id);
    ytdlp.downloadError = StateError('permanent failure');

    await service.downloadPlaylist(playlist);

    expect((await db.getPlaylist(playlist.id)).lastUpdated, isNull);
  });

  test('a reused file counts as progress for the update stamp', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    await insertTestTrack(db, playlistId: playlist.id, index: 1);
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'video-2',
    );
    await File(p.join(folder, '00001_Present.m4a')).writeAsString('a');
    ytdlp.downloadError = StateError('permanent failure');

    await service.downloadPlaylist(playlist);

    expect(ytdlp.downloadedUrls, hasLength(1));
    expect((await db.getPlaylist(playlist.id)).lastUpdated, isNotNull);
  });

  test(
    'a download that leaves no media file is recorded as an error',
    () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.createOutputFile = false;

      await service.downloadPlaylist(playlist);

      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'error');
      expect(updated.lastError, 'Downloaded file not found');
      expect(updated.filePath, isNull);
      expect(sponsorBlock.refreshedTracks, isEmpty);
      expect(notifications.playlistNames, isEmpty);
    },
  );

  test('a percent sign in the playlist folder is escaped for yt-dlp', () async {
    final percentFolder = Directory(p.join(libraryDir, '100% Hits'));
    await percentFolder.create();
    final playlist = await insertTestPlaylist(
      db,
      outputPath: percentFolder.path,
    );
    final track = await insertTestTrack(db, playlistId: playlist.id);

    await service.downloadPlaylist(playlist);

    // yt-dlp writes into the track's staging folder; the title is cut to
    // 150 bytes so long non-Latin titles still make a valid file name.
    expect(
      ytdlp.outputTemplates.single,
      '$libraryDir/100%% Hits/.woolytube-staging/track-${track.id}/'
      '00001_%(title).150B.%(ext)s',
    );
    final updated = (await db.getTrack(track.id))!;
    expect(updated.status, 'complete');
    expect(updated.filePath, p.join(percentFolder.path, '00001_Title.mp4'));
  });

  test('completion is reported only after the SponsorBlock backfill', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    final donePath = p.join(folder, '00001_Done.m4a');
    await File(donePath).writeAsString('audio');
    final done = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'done',
      filePath: donePath,
      status: 'complete',
    );
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'pending',
    );
    sponsorBlock.segmentsByVideoId[done.videoId] = [remoteSegment(done)];
    final events = <String>[];
    sponsorBlock.onFetch = () => events.add('fetch');
    final subscription = service.progressStream.listen((progress) {
      if (progress.status == 'complete') events.add('complete');
    });

    await service.downloadPlaylist(playlist);
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(events, ['fetch', 'complete']);
  });

  test('a live background lock blocks foreground downloads', () async {
    await lockFile().writeAsString(
      '${DownloadLock.backgroundOwner} ${DateTime.now().toIso8601String()}',
    );
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    final track = await insertTestTrack(db, playlistId: playlist.id);
    final events = <DownloadProgress>[];
    final subscription = service.progressStream.listen(events.add);

    await service.downloadPlaylist(playlist);
    await expectLater(
      service.downloadTrack(playlist, track),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          DownloadService.lockHeldMessage,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(ytdlp.downloadedUrls, isEmpty);
    expect(service.isDownloading, isFalse);
    // The playlist run raises the global error event; the single-track run
    // throws to its caller instead and only clears the progress state.
    expect(events.map((event) => event.status), ['error', 'idle']);
    expect(events.first.error, DownloadService.lockHeldMessage);
    expect(await lockFile().exists(), isTrue);
    expect((await db.getTrack(track.id))!.status, 'pending');
  });

  test('abandoned locks are taken over and released afterwards', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    final track = await insertTestTrack(db, playlistId: playlist.id);
    await lockFile().writeAsString(
      '${DownloadLock.backgroundOwner} ${DateTime.now().toIso8601String()}',
    );
    await lockFile().setLastModified(
      DateTime.now().subtract(
        DownloadLock.backgroundStaleAfter + const Duration(minutes: 1),
      ),
    );

    await service.downloadPlaylist(playlist);

    expect(ytdlp.downloadedUrls, hasLength(1));
    expect(await lockFile().exists(), isFalse);

    // A lock left by a killed foreground process is ours to reuse.
    await lockFile().writeAsString(
      '${DownloadLock.foregroundOwner} ${DateTime.now().toIso8601String()}',
    );
    await service.downloadTrack(playlist, track);

    expect(ytdlp.downloadedUrls, hasLength(2));
    expect(await lockFile().exists(), isFalse);
  });

  test(
    'a background-owned service downloads behind a fresh background lock',
    () async {
      // The worker checks the lock up front; its own service must then be able
      // to take and release the lock as the background owner.
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(db, playlistId: playlist.id);
      await lockFile().writeAsString(
        '${DownloadLock.backgroundOwner} ${DateTime.now().toIso8601String()}',
      );
      final background = newService(owner: DownloadLock.backgroundOwner);

      await background.downloadPlaylist(playlist);

      expect(ytdlp.downloadedUrls, hasLength(1));
      expect(await lockFile().exists(), isFalse);

      // A live foreground lock still blocks it.
      await lockFile().writeAsString(
        '${DownloadLock.foregroundOwner} ${DateTime.now().toIso8601String()}',
      );
      await background.downloadPlaylist(playlist);
      expect(ytdlp.downloadedUrls, hasLength(1));
      expect(await lockFile().exists(), isTrue);
      background.dispose();
    },
  );

  test('the foreground holds the shared lock while downloading', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    await insertTestTrack(db, playlistId: playlist.id);
    ytdlp.downloadCompleter = Completer<void>();
    ytdlp.downloadStarted = Completer<void>();

    final download = service.downloadPlaylist(playlist);
    await ytdlp.downloadStarted!.future;

    expect(
      await lock.isHeldByOther(DownloadLock.backgroundOwner),
      isTrue,
      reason: 'the background worker must not start mid-download',
    );
    expect(await lock.acquire(DownloadLock.backgroundOwner), isFalse);

    ytdlp.downloadCompleter!.complete();
    await download;
    expect(await lockFile().exists(), isFalse);
  });

  test('progress after dispose is dropped instead of throwing', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    final track = await insertTestTrack(db, playlistId: playlist.id);
    ytdlp.downloadCompleter = Completer<void>();
    ytdlp.downloadStarted = Completer<void>();

    final download = service.downloadPlaylist(playlist);
    await ytdlp.downloadStarted!.future;
    service.dispose();
    ytdlp.downloadCompleter!.complete();
    await download;

    expect((await db.getTrack(track.id))!.status, 'complete');
  });

  group('download pipeline', () {
    Future<Track> completeTrack(
      Playlist playlist, {
      String name = '00001_Old.m4a',
      String content = 'old',
      bool isLocalReplacement = false,
      bool replaceRequested = false,
      String? chaptersJson,
    }) async {
      final path = p.join(folder, name);
      await File(path).writeAsString(content);
      return insertTestTrack(
        db,
        playlistId: playlist.id,
        title: 'Song',
        filePath: path,
        status: 'complete',
        downloadedAt: DateTime(2024, 1, 2, 3, 4, 5),
        sponsorBlockCheckedAt: DateTime.now(),
        isLocalReplacement: isLocalReplacement,
        replaceRequested: replaceRequested,
        chaptersJson: chaptersJson,
      );
    }

    test(
      'a download is staged, then published with its cover and YouTube info',
      () async {
        final playlist = await insertTestPlaylist(
          db,
          name: 'Road Trip',
          outputPath: folder,
          audioOnly: true,
        );
        final track = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 3,
          videoId: 'abc-123',
          title: 'Song',
        );

        await service.downloadPlaylist(playlist);

        final call = ytdlp.calls.single;
        expect(call.outputTemplate, startsWith('${staged(track)}/'));
        expect(call.writeThumbnail, isTrue);
        expect(call.embedMetadata, isTrue);
        expect(call.metadataAlbum, 'Road Trip');
        // No track-number tag: it would go stale when videos are inserted
        // above; the file name and the .m3u8 carry the order.
        expect(call.metadataTrackNumber, isNull);

        final updated = (await db.getTrack(track.id))!;
        final mediaPath = p.join(folder, '00003_Title.m4a');
        expect(updated.status, 'complete');
        expect(updated.filePath, mediaPath);
        expect(await File(mediaPath).readAsString(), 'media');
        expect(
          await Directory(p.join(folder, '.woolytube-staging')).exists(),
          isFalse,
        );

        final cover = p.join(folder, '.woolytube_thumbnails', 'abc-123.jpg');
        expect(updated.thumbnailPath, cover);
        expect(await File(cover).exists(), isTrue);

        final info =
            jsonDecode(
                  await File(
                    p.join(folder, '.woolytube_info', 'abc-123.info.json'),
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        expect(info['uploader'], 'Uploader');
        expect(info['upload_date'], '20240101');
        expect(info.keys, isNot(contains('formats')));
        expect(info.keys, isNot(contains('thumbnails')));
        expect(info.keys, isNot(contains('http_headers')));

        // yt-dlp's side files never end up beside the media.
        final rootFiles = [
          for (final entity in Directory(folder).listSync())
            if (entity is File) p.basename(entity.path),
        ];
        expect(rootFiles, contains('00003_Title.m4a'));
        expect(rootFiles.where((n) => n.endsWith('.jpg')), isEmpty);
        expect(rootFiles.where((n) => n.endsWith('.info.json')), isEmpty);
      },
    );

    test(
      'a failed redownload leaves the old file and the track untouched',
      () async {
        final playlist = await insertTestPlaylist(
          db,
          outputPath: folder,
          audioOnly: true,
        );
        final track = await completeTrack(playlist);
        final before = await db.getTrack(track.id);
        ytdlp.downloadError = PlatformException(
          code: 'DOWNLOAD_ERROR',
          message:
              'ERROR: [youtube] video-1: Requested format is not available',
        );

        await expectLater(
          service.downloadTrack(playlist, track),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Requested format is not available',
            ),
          ),
        );

        expect(await File(track.filePath!).readAsString(), 'old');
        expect(await db.getTrack(track.id), before);
        expect(ytdlp.calls, hasLength(1));
      },
    );

    test('a successful redownload sets aside an old file whose name does '
        'not match the video', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await completeTrack(playlist, name: '00001_Old Name.m4a');
      ytdlp.mediaContent = 'new';

      await service.downloadTrack(playlist, track);

      final updated = (await db.getTrack(track.id))!;
      expect(updated.filePath, p.join(folder, '00001_Title.m4a'));
      // Matched only by its number, it may be another recording: kept.
      expect(await File(track.filePath!).exists(), isFalse);
      expect(
        await File(
          p.join(folder, '.woolytube_replaced', '00001_Old Name.m4a'),
        ).readAsString(),
        'old',
      );
    });

    test('a successful redownload replaces the old file', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await completeTrack(playlist, name: '00001_Song.mp3');
      ytdlp.mediaContent = 'new';

      await service.downloadTrack(playlist, track);

      final updated = (await db.getTrack(track.id))!;
      final newPath = p.join(folder, '00001_Title.m4a');
      expect(updated.status, 'complete');
      expect(updated.filePath, newPath);
      expect(await File(newPath).readAsString(), 'new');
      // A copy of the same video is superseded, not kept.
      expect(await File(track.filePath!).exists(), isFalse);
      expect(
        await Directory(p.join(folder, '.woolytube_replaced')).exists(),
        isFalse,
      );
    });

    test('a requested original replaces a local file only once it is '
        'downloaded, and the local file is kept aside', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await completeTrack(
        playlist,
        name: '00001_My Version.m4a',
        content: 'local',
        isLocalReplacement: true,
        replaceRequested: true,
      );

      // A failure that is not final keeps the local file and the request.
      ytdlp.downloadError = StateError('Requested format is not available');
      await service.downloadPlaylist(playlist);

      var updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'complete');
      expect(updated.filePath, track.filePath);
      expect(updated.isLocalReplacement, isTrue);
      expect(updated.replaceRequested, isTrue);
      expect(await File(track.filePath!).readAsString(), 'local');

      ytdlp.downloadError = null;
      ytdlp.mediaContent = 'original';
      await service.downloadPlaylist(playlist);

      updated = (await db.getTrack(track.id))!;
      final originalPath = p.join(folder, '00001_Title.m4a');
      expect(updated.status, 'complete');
      expect(updated.filePath, originalPath);
      expect(updated.isLocalReplacement, isFalse);
      expect(updated.replaceRequested, isFalse);
      expect(await File(originalPath).readAsString(), 'original');
      expect(await File(track.filePath!).exists(), isFalse);
      expect(
        await File(
          p.join(folder, '.woolytube_replaced', '00001_My Version.m4a'),
        ).readAsString(),
        'local',
      );
    });

    test('a video YouTube no longer has drops the request and keeps the '
        'local file', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await completeTrack(
        playlist,
        name: '00001_My Version.m4a',
        content: 'local',
        isLocalReplacement: true,
        replaceRequested: true,
      );
      ytdlp.downloadError = PlatformException(
        code: 'DOWNLOAD_ERROR',
        message:
            'ERROR: [youtube] video-1: Video unavailable. '
            'This video has been removed by the uploader',
      );

      await service.downloadPlaylist(playlist);

      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'complete');
      expect(updated.filePath, track.filePath);
      expect(updated.isLocalReplacement, isTrue);
      expect(updated.replaceRequested, isFalse);
      expect(await File(track.filePath!).readAsString(), 'local');

      // Nothing is left to ask YouTube for.
      await service.downloadPlaylist(playlist);
      expect(ytdlp.calls, hasLength(1));
    });

    test('a failed embedding step keeps the complete file', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.errorAfterOutput = PlatformException(
        code: 'DOWNLOAD_ERROR',
        message:
            'ERROR: Postprocessing: Supported filetypes for thumbnail '
            'embedding are: mp3, mkv/mka, ogg/opus/flac, m4a/mp4/m4b/mov',
      );

      await service.downloadPlaylist(playlist);

      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'complete');
      expect(updated.filePath, p.join(folder, '00001_Title.mp4'));
      expect(await File(updated.filePath!).exists(), isTrue);
    });

    test('a failed audio conversion is not accepted as a download', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.errorAfterOutput = PlatformException(
        code: 'DOWNLOAD_ERROR',
        message:
            'ERROR: Postprocessing: audio conversion failed: '
            'Error opening output files: Invalid argument',
      );

      await service.downloadPlaylist(playlist);

      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'error');
      expect(updated.filePath, isNull);
      expect(updated.lastError, contains('audio conversion failed'));
      expect(await File(p.join(folder, '00001_Title.m4a')).exists(), isFalse);
      expect(await Directory(staged(track)).exists(), isFalse);
    });

    test('a subtitle failure retries the video without subtitles', () async {
      await AppSettingsService().setDownloadSubtitles(true);
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.errorFor =
          (call) =>
              call.downloadSubtitles
                  ? PlatformException(
                    code: 'DOWNLOAD_ERROR',
                    message:
                        "ERROR: Unable to download video subtitles for 'en': "
                        'HTTP Error 429: Too Many Requests',
                  )
                  : null;

      await service.downloadPlaylist(playlist);

      expect(ytdlp.subtitleRequests, [(true, 'en'), (false, 'en')]);
      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'complete');
      expect(await File(updated.filePath!).exists(), isTrue);
    });

    test('custom chapters survive a redownload', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await completeTrack(
        playlist,
        chaptersJson:
            const ChapterData(
              custom: [
                MediaChapter(
                  id: 'mine',
                  title: 'My part',
                  startMs: 0,
                  endMs: 30000,
                ),
              ],
            ).encode(),
      );
      ytdlp.infoFor =
          (call) => {
            ...ytdlp.defaultInfo(call),
            'chapters': [
              {'title': 'Intro', 'start_time': 0, 'end_time': 20},
              {'title': 'Song', 'start_time': 20, 'end_time': 60},
            ],
          };

      await service.downloadTrack(playlist, track);

      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.custom!.map((c) => c.title), ['My part']);
      expect(data.downloaded.map((c) => c.title), ['Intro', 'Song']);
      expect(data.active.map((c) => c.title), ['My part']);
    });

    test(
      'a video whose title ends like a yt-dlp temp name still downloads',
      () async {
        final playlist = await insertTestPlaylist(
          db,
          outputPath: folder,
          audioOnly: true,
        );
        final track = await insertTestTrack(db, playlistId: playlist.id);
        ytdlp.title = 'Formula.f1';

        await service.downloadPlaylist(playlist);

        final updated = (await db.getTrack(track.id))!;
        expect(updated.status, 'complete');
        // The saved name loses the dot so it never looks like a leftover.
        expect(updated.filePath, p.join(folder, '00001_Formula_f1.m4a'));
        expect(await File(updated.filePath!).exists(), isTrue);
      },
    );

    test('a download never moves aside a file another track uses', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      // Track 3 still carries number 2 in its name (a rename that could not
      // happen yet); track 2 is a different upload with the same title.
      final otherPath = p.join(folder, '00002_Song.m4a');
      await File(otherPath).writeAsString('other');
      final other = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 3,
        videoId: 'other',
        title: 'Song',
        filePath: otherPath,
        status: 'complete',
      );
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'reupload',
        title: 'Song',
      );
      ytdlp.title = 'Song';

      await service.downloadPlaylist(playlist);

      final otherAfter = (await db.getTrack(other.id))!;
      expect(otherAfter.status, 'complete');
      expect(await File(otherAfter.filePath!).readAsString(), 'other');
      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'complete');
      expect(updated.filePath, isNot(otherAfter.filePath));
      expect(await File(updated.filePath!).readAsString(), 'media');
    });

    test('cancelling a redownload keeps the existing file', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await completeTrack(playlist);
      final before = await db.getTrack(track.id);
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final download = service.downloadTrack(playlist, track);
      await ytdlp.downloadStarted!.future;
      await service.cancelActiveDownloads();
      await download;

      expect(await db.getTrack(track.id), before);
      expect(await File(track.filePath!).readAsString(), 'old');
    });

    test(
      'a redownload never removes a file another track still uses',
      () async {
        final playlist = await insertTestPlaylist(
          db,
          outputPath: folder,
          audioOnly: true,
        );
        // Older versions could point two tracks at one file.
        final track = await completeTrack(playlist, name: '00001_Shared.m4a');
        final other = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 2,
          videoId: 'other',
          filePath: track.filePath,
          status: 'complete',
        );

        await service.downloadTrack(playlist, track);

        expect((await db.getTrack(track.id))!.filePath, isNot(track.filePath));
        expect((await db.getTrack(other.id))!.filePath, track.filePath);
        expect(await File(track.filePath!).readAsString(), 'old');
      },
    );

    test('a single-track download while another runs is refused', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final running = service.downloadPlaylist(playlist);
      await ytdlp.downloadStarted!.future;

      await expectLater(
        service.downloadTrack(playlist, track),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'A download is already in progress.',
          ),
        ),
      );
      ytdlp.downloadCompleter!.complete();
      await running;
      expect(ytdlp.calls, hasLength(1));
    });

    test(
      'a run without a fresh YouTube check does not count as an update',
      () async {
        final playlist = await insertTestPlaylist(db, outputPath: folder);
        final track = await insertTestTrack(db, playlistId: playlist.id);

        await service.downloadPlaylist(playlist, sourceChecked: false);

        expect((await db.getTrack(track.id))!.status, 'complete');
        expect((await db.getPlaylist(playlist.id)).lastUpdated, isNull);

        // Nothing left to do: still not stamped.
        await service.downloadPlaylist(playlist, sourceChecked: false);
        expect((await db.getPlaylist(playlist.id)).lastUpdated, isNull);
      },
    );
  });

  group('videos removed from YouTube', () {
    const guidelines =
        "ERROR: [youtube] gone-1: Video unavailable. This video has been "
        "removed for violating YouTube's Community Guidelines";
    const copyright =
        'ERROR: [youtube] gone-2: Video unavailable. It was removed '
        'following a copyright removal request';

    test(
      'are marked, not retried, and do not block the update stamp',
      () async {
        final playlist = await insertTestPlaylist(db, outputPath: folder);
        final first = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 1,
          videoId: 'gone-1',
        );
        final second = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 2,
          videoId: 'gone-2',
        );
        ytdlp.errorFor =
            (call) => PlatformException(
              code: 'DOWNLOAD_ERROR',
              message: call.videoId == 'gone-1' ? guidelines : copyright,
            );
        final events = <DownloadProgress>[];
        final sub = service.progressStream.listen(events.add);

        await service.downloadPlaylist(playlist);
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        for (final id in [first.id, second.id]) {
          final track = (await db.getTrack(id))!;
          expect(track.status, 'unavailable');
          expect(track.unavailableReason, removedFromYouTubeReason);
        }
        expect((await db.getPlaylist(playlist.id)).lastUpdated, isNotNull);
        expect(events.last.status, 'complete');
        expect(events.last.removedCount, 2);
        expect(friendlyDownloadError(guidelines), 'Removed from YouTube');

        // The next update does not ask YouTube for them again.
        await service.downloadPlaylist(playlist);
        expect(ytdlp.calls, hasLength(2));
      },
    );

    test('a manual retry that works makes the track normal again', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'gone-1',
        status: 'unavailable',
        unavailableReason: removedFromYouTubeReason,
      );

      expect(await service.downloadTrack(playlist, track), isTrue);

      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'complete');
      expect(updated.unavailableReason, isNull);
      // A single track is not a playlist update.
      expect((await db.getPlaylist(playlist.id)).lastUpdated, isNull);
    });

    test('a retry that fails or is stopped keeps the removed mark', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'gone-1',
        status: 'unavailable',
        unavailableReason: removedFromYouTubeReason,
      );
      await db.markTrackRemovedFromYouTube(track.id, guidelines);

      // A bot check during the retry.
      ytdlp.downloadError = PlatformException(
        code: 'DOWNLOAD_ERROR',
        message: "ERROR: [youtube] gone-1: Sign in to confirm you're not a bot",
      );
      await expectLater(
        service.downloadTrack(playlist, track),
        throwsA(isA<StateError>()),
      );
      var updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'unavailable');
      expect(updated.unavailableReason, removedFromYouTubeReason);
      expect(updated.lastError, guidelines);

      // Stopped during the retry.
      ytdlp.downloadError = null;
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();
      final running = service.downloadTrack(playlist, updated);
      await ytdlp.downloadStarted!.future;
      expect((await db.getTrack(track.id))!.status, 'downloading');
      await service.cancelActiveDownloads();
      expect(await running, isFalse);
      updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'unavailable');
      expect(updated.unavailableReason, removedFromYouTubeReason);

      // A killed process leaves it 'downloading'; the repair restores it.
      await db.updateTrackStatus(track.id, 'downloading');
      await db.resetInterruptedTrack(track.id);
      expect((await db.getTrack(track.id))!.status, 'unavailable');
      expect(await db.getPendingTracks(playlist.id), isEmpty);
    });

    test('a bot check is not mistaken for a removal', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.downloadError = PlatformException(
        code: 'DOWNLOAD_ERROR',
        message:
            "ERROR: [youtube] video-1: Sign in to confirm you're not a bot. "
            'This helps protect our community.',
      );
      final events = <DownloadProgress>[];
      final sub = service.progressStream.listen(events.add);

      await service.downloadPlaylist(playlist);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect((await db.getTrack(track.id))!.status, 'error');
      expect((await db.getPlaylist(playlist.id)).lastUpdated, isNull);
      // A run in which everything failed is reported, not "complete".
      expect(events.last.status, 'error');
      expect(events.last.failedCount, 1);
      expect(friendlyDownloadError(events.last.error!), contains('not a bot'));
      expect(isAgeGateDownloadError(events.last.error!), isFalse);
      expect(isPermanentDownloadError('Video unavailable'), isFalse);
    });
  });

  group('progress', () {
    test('reports count the tracks of this run and compare by value', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      for (var i = 1; i <= 5; i++) {
        await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: i,
          videoId: 'v$i',
          status: i <= 3 ? 'complete' : 'pending',
          filePath: i <= 3 ? p.join(folder, '0000${i}_x.mp4') : null,
        );
        if (i <= 3) {
          await File(p.join(folder, '0000${i}_x.mp4')).writeAsString('x');
        }
      }
      final events = <DownloadProgress>[];
      final sub = service.progressStream.listen(events.add);

      await service.downloadPlaylist(playlist);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      final downloading = events.where(
        (e) => e.phase == DownloadPhase.downloading,
      );
      expect(downloading.map((e) => e.totalTracks).toSet(), {2});
      expect(downloading.map((e) => e.currentTrackIndex).toSet(), {1, 2});
      expect(downloading.first.currentTitle, isNotNull);
      expect(events.first.phase, DownloadPhase.preparing);
      expect(events.any((e) => e.phase == DownloadPhase.finishing), isTrue);
      // No two reports in a row are the same.
      for (var i = 1; i < events.length; i++) {
        expect(events[i], isNot(events[i - 1]));
      }
      expect(
        const DownloadProgress(
          playlistId: 1,
          currentTrackIndex: 1,
          totalTracks: 2,
          trackProgress: 50,
          status: 'downloading',
          phase: DownloadPhase.downloading,
        ).overallFraction,
        0.25,
      );
    });
  });

  group('video quality', () {
    test(
      'the playlist cap reaches yt-dlp and is recorded on the track',
      () async {
        final playlist = await insertTestPlaylist(
          db,
          outputPath: folder,
          videoQuality: 720,
        );
        final track = await insertTestTrack(db, playlistId: playlist.id);

        await service.downloadPlaylist(playlist);

        expect(ytdlp.calls.single.maxHeight, 720);
        expect((await db.getTrack(track.id))!.downloadedMaxHeight, 720);
      },
    );

    test("a track's own quality wins over the playlist's", () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        videoQuality: 720,
      );
      final capped = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'a',
        videoQuality: 480,
      );
      final best = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
        videoQuality: 0,
      );

      await service.downloadPlaylist(playlist);

      expect(
        {for (final c in ytdlp.calls) c.videoId: c.maxHeight},
        {'a': 480, 'b': null},
      );
      expect((await db.getTrack(capped.id))!.downloadedMaxHeight, 480);
      // 0 records "no cap", unlike an unknown (null) one.
      expect((await db.getTrack(best.id))!.downloadedMaxHeight, 0);
    });

    test('audio-only playlists never send a cap', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
        videoQuality: 720,
      );
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoQuality: 480,
      );

      await service.downloadPlaylist(playlist);
      await service.downloadTrack(playlist, track);

      expect(ytdlp.calls.map((c) => c.maxHeight), [null, null]);
      expect((await db.getTrack(track.id))!.downloadedMaxHeight, isNull);
    });

    test('single-track and reupload downloads use the current cap', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await insertTestTrack(db, playlistId: playlist.id);
      // Changed after the caller read the rows.
      await db.updatePlaylistFields(
        playlist.id,
        const PlaylistsCompanion(videoQuality: Value(480)),
      );

      await service.downloadTrack(playlist, track);
      await service.downloadReupload(
        playlist,
        track,
        'https://www.youtube.com/watch?v=reup-1',
        adopt: (_) async {},
      );

      expect(ytdlp.calls.map((c) => c.maxHeight), [480, 480]);
    });

    test('a cap chosen during a run applies to the next track', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'a',
      );
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
      );
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final running = service.downloadPlaylist(playlist);
      await ytdlp.downloadStarted!.future;
      await db.updatePlaylistFields(
        playlist.id,
        const PlaylistsCompanion(videoQuality: Value(360)),
      );
      ytdlp.downloadCompleter!.complete();
      await running;

      expect(ytdlp.calls.map((c) => c.maxHeight), [null, 360]);
    });
  });

  group('busy service', () {
    test('asking for the running playlist again downloads what was added '
        'meanwhile', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'a',
      );
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final running = service.downloadPlaylist(playlist);
      await ytdlp.downloadStarted!.future;
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
      );
      expect(
        await service.downloadPlaylist(playlist),
        DownloadStart.alreadyQueued,
      );
      expect(
        await service.downloadPlaylist(playlist),
        DownloadStart.alreadyQueued,
      );

      ytdlp.downloadCompleter!.complete();
      await running;
      for (var i = 0; i < 50 && ytdlp.calls.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await service.runFinished;

      // One more pass, for the new track only.
      expect(ytdlp.calls.map((c) => c.videoId), ['a', 'b']);
      expect(service.queuedPlaylistIds, isEmpty);
      expect(service.isDownloading, isFalse);
    });

    test('stopping drops a requested second pass', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 1,
        videoId: 'a',
      );
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final running = service.downloadPlaylist(playlist);
      await ytdlp.downloadStarted!.future;
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
      );
      await service.downloadPlaylist(playlist);
      await service.cancelActiveDownloads();
      await running;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.runFinished;

      expect(ytdlp.calls.map((c) => c.videoId), ['a']);
      expect(service.isDownloading, isFalse);
    });

    test('a second playlist waits in the queue and then runs', () async {
      final first = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(db, playlistId: first.id, videoId: 'a');
      final secondFolder = p.join(libraryDir, 'Second');
      await Directory(secondFolder).create(recursive: true);
      final second = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=second',
        name: 'Second',
        outputPath: secondFolder,
      );
      await insertTestTrack(db, playlistId: second.id, videoId: 'b');
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final running = service.downloadPlaylist(first);
      await ytdlp.downloadStarted!.future;
      expect(await service.downloadPlaylist(second), DownloadStart.queued);
      expect(
        await service.downloadPlaylist(second),
        DownloadStart.alreadyQueued,
      );
      expect(service.queuedPlaylistIds, [second.id]);

      ytdlp.downloadCompleter!.complete();
      await running;
      await service.runFinished;
      for (var i = 0; i < 50 && ytdlp.calls.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await service.runFinished;
      expect(ytdlp.calls.map((c) => c.videoId), ['a', 'b']);
      expect(service.queuedPlaylistIds, isEmpty);
    });

    test('a request while a run tidies up is queued, not refused', () async {
      final first = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(db, playlistId: first.id, videoId: 'a');
      final secondFolder = p.join(libraryDir, 'Second');
      await Directory(secondFolder).create(recursive: true);
      final second = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=second',
        name: 'Second',
        outputPath: secondFolder,
      );
      await insertTestTrack(db, playlistId: second.id, videoId: 'b');
      final stopEntered = Completer<void>();
      final stopHeld = Completer<void>();
      ytdlp.onStopDownloadService = () {
        if (!stopEntered.isCompleted) stopEntered.complete();
        return stopHeld.future;
      };
      final events = <DownloadProgress>[];
      final sub = service.progressStream.listen(events.add);

      final running = service.downloadPlaylist(first);
      await stopEntered.future;
      var finished = false;
      unawaited(service.runFinished.then((_) => finished = true));

      expect(service.isDownloading, isTrue);
      expect(await service.downloadPlaylist(second), DownloadStart.queued);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(finished, isFalse);

      ytdlp.onStopDownloadService = null;
      stopHeld.complete();
      await running;
      for (var i = 0; i < 50 && ytdlp.calls.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await service.runFinished;
      await sub.cancel();

      expect(finished, isTrue);
      expect(ytdlp.calls.map((c) => c.videoId), ['a', 'b']);
      expect(events.where((e) => e.status == 'error'), isEmpty);
    });

    test('a single track asked for during the tidy-up waits for it', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(db, playlistId: playlist.id, videoId: 'a');
      final retry = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'b',
        status: 'complete',
      );
      final stopEntered = Completer<void>();
      final stopHeld = Completer<void>();
      ytdlp.onStopDownloadService = () {
        if (!stopEntered.isCompleted) stopEntered.complete();
        return stopHeld.future;
      };

      final running = service.downloadPlaylist(playlist);
      await stopEntered.future;
      ytdlp.onStopDownloadService = null;
      final single = service.downloadTrack(playlist, retry);
      stopHeld.complete();
      await running;

      expect(await single, isTrue);
      expect(ytdlp.calls.map((c) => c.videoId), ['a', 'b']);
    });

    test('a playlist deleted during its download stops it', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(db, playlistId: playlist.id, index: 1);
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'video-2',
      );
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final running = service.downloadPlaylist(playlist);
      await ytdlp.downloadStarted!.future;
      await db.deletePlaylist(playlist.id);
      ytdlp.downloadCompleter!.complete();
      await running;

      expect(ytdlp.calls, hasLength(1));
      expect(notifications.playlistNames, isEmpty);
      expect(service.isDownloading, isFalse);
    });

    test('stop ends a retry wait at once', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      await insertTestTrack(db, playlistId: playlist.id);
      ytdlp.downloadError = StateError('Connection reset by peer');

      final watch = Stopwatch()..start();
      final running = service.downloadPlaylist(playlist);
      while (ytdlp.calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.cancelActiveDownloads();
      await running;

      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(service.isDownloading, isFalse);
    });

    test(
      'a time budget stops before the next track and keeps it due',
      () async {
        final playlist = await insertTestPlaylist(db, outputPath: folder);
        await insertTestTrack(db, playlistId: playlist.id, index: 1);
        await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 2,
          videoId: 'video-2',
        );

        await service.downloadPlaylist(
          playlist,
          shouldStop: () => ytdlp.calls.isNotEmpty,
        );

        expect(ytdlp.calls, hasLength(1));
        expect((await db.getPlaylist(playlist.id)).lastUpdated, isNull);
        expect(await db.getPendingTracks(playlist.id), hasLength(1));
      },
    );
  });

  group('lock', () {
    test('only one of two simultaneous owners gets a free lock', () async {
      final results = await Future.wait([
        lock.acquire(DownloadLock.foregroundOwner),
        lock.acquire(DownloadLock.backgroundOwner),
      ]);
      expect(results.where((r) => r), hasLength(1));
    });
  });

  test('SponsorBlock rechecks are spread over two days', () {
    final now = DateTime(2024, 6, 10);
    Track track(int id, DateTime checkedAt) => Track(
      id: id,
      playlistId: 1,
      index: id,
      videoId: 'v$id',
      title: 't',
      status: 'complete',
      isLocalReplacement: false,
      alwaysSkip: false,
      replaceRequested: false,
      sponsorBlockCheckedAt: checkedAt,
    );
    final weekAgo = now.subtract(const Duration(days: 7));
    expect(
      DownloadService.shouldRecheckSponsorBlock(track(48, weekAgo), now),
      isTrue,
    );
    expect(
      DownloadService.shouldRecheckSponsorBlock(track(47, weekAgo), now),
      isFalse,
    );
  });

  group('replace with a reupload', () {
    const reuploadUrl = 'https://www.youtube.com/watch?v=reup-1';

    PlaylistService playlistService() => PlaylistService(
      db,
      ytdlp,
      MetadataService(db),
      thumbnails,
      null,
      service.gate,
    );

    Future<Track> removedTrack(Playlist playlist) => insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 59,
      videoId: 'gone-1',
      title: 'vibe mix 59',
      status: 'unavailable',
      unavailableReason: removedFromYouTubeReason,
      lastError: 'ERROR: Video unavailable. This video has been removed',
    );

    test('downloads the link and uses it as the track file', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await removedTrack(playlist);
      ytdlp.title = 'vibe mix 59 (reupload)';

      final done = await service.downloadReupload(
        playlist,
        track,
        reuploadUrl,
        adopt:
            (media) => playlistService().replaceWithReuploadFile(
              trackId: track.id,
              downloadedPath: media.path,
            ),
      );

      expect(done, isTrue);
      expect(ytdlp.calls.single.url, reuploadUrl);
      final updated = (await db.getTrack(track.id))!;
      expect(updated.status, 'complete');
      expect(updated.isLocalReplacement, isTrue);
      // It still stands for the original video.
      expect(updated.videoId, 'gone-1');
      expect(updated.title, 'vibe mix 59');
      expect(updated.unavailableReason, removedFromYouTubeReason);
      expect(p.basename(updated.filePath!), '00059_vibe mix 59.m4a');
      expect(await File(updated.filePath!).readAsString(), 'media');
      expect(
        await Directory(p.join(folder, '.woolytube-staging')).exists(),
        isFalse,
      );
      // The gate is free again.
      expect(service.gate.isBusy, isFalse);
      expect(service.isDownloading, isFalse);
    });

    test('a failed reupload download changes nothing', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await removedTrack(playlist);
      ytdlp.downloadError = PlatformException(
        code: 'DOWNLOAD_ERROR',
        message: 'ERROR: Unsupported URL',
      );
      var adopted = false;

      await expectLater(
        service.downloadReupload(
          playlist,
          track,
          reuploadUrl,
          adopt: (_) async => adopted = true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(adopted, isFalse);
      expect(await db.getTrack(track.id), track);
      expect(service.gate.isBusy, isFalse);
    });

    test('stopping a reupload download changes nothing', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await removedTrack(playlist);
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();
      var adopted = false;

      final download = service.downloadReupload(
        playlist,
        track,
        reuploadUrl,
        adopt: (_) async => adopted = true,
      );
      await ytdlp.downloadStarted!.future;
      await service.cancelActiveDownloads();

      expect(await download, isFalse);
      expect(adopted, isFalse);
      expect(await db.getTrack(track.id), track);
    });

    test('adopting a reupload outside the gate is refused', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final track = await removedTrack(playlist);
      final source = File(p.join(tempDir.path, 'x.m4a'))
        ..writeAsStringSync('x');

      await expectLater(
        playlistService().replaceWithReuploadFile(
          trackId: track.id,
          downloadedPath: source.path,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the archived copy is read from the Wayback Machine', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        audioOnly: true,
      );
      final track = await removedTrack(playlist);
      final url = PlaylistService.archivedCopyUrl(track.videoId);
      expect(url, endsWith('wayback-fakeurl.archive.org/yt/gone-1'));

      await service.downloadReupload(
        playlist,
        track,
        url,
        adopt:
            (media) => playlistService().replaceWithReuploadFile(
              trackId: track.id,
              downloadedPath: media.path,
            ),
      );

      expect(ytdlp.calls.single.url, url);
      expect((await db.getTrack(track.id))!.isLocalReplacement, isTrue);
      expect(
        friendlyDownloadError(
          'ERROR: [web.archive:youtube] gone-1: The requested video is not '
          'archived or indexed',
        ),
        'No archived copy was found',
      );
    });

    test('only links to one video are accepted', () {
      for (final ok in [
        'https://www.youtube.com/watch?v=abc&list=PL1',
        ' https://youtu.be/abc ',
        'https://m.youtube.com/watch?v=abc',
        'https://music.youtube.com/watch?v=abc',
        'https://www.youtube.com/shorts/abc',
        'https://vimeo.com/12345',
      ]) {
        expect(PlaylistService.parseReuploadUrl(ok), isNotNull, reason: ok);
      }
      for (final bad in [
        '',
        'not a link',
        'youtube.com/watch?v=abc',
        'ftp://example.com/a.mp3',
        'https://www.youtube.com/playlist?list=PL1',
        'https://www.youtube.com/@channel',
        'https://www.youtube.com/watch',
      ]) {
        expect(PlaylistService.parseReuploadUrl(bad), isNull, reason: bad);
      }
    });
  });
}
