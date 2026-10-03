import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/notification_service.dart';
import 'package:woolytube/services/sponsorblock_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';

import '../helpers/test_database.dart';

class FakeYtDlpService extends YtDlpService {
  final downloadedUrls = <String>[];
  final outputTemplates = <String>[];
  final subtitleRequests = <(bool, String)>[];
  Completer<void>? downloadCompleter;
  Completer<void>? downloadStarted;
  Object? downloadError;
  bool cancelCalled = false;

  /// Mirrors yt-dlp leaving a media file at the output template.
  bool createOutputFile = true;

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
    bool downloadSubtitles = false,
    String subtitleLanguages = 'en',
    String? outputTemplate,
  }) async {
    downloadedUrls.add(url);
    outputTemplates.add(outputTemplate ?? '');
    subtitleRequests.add((downloadSubtitles, subtitleLanguages));
    downloadStarted?.complete();
    if (downloadError != null) throw downloadError!;
    if (downloadCompleter != null) await downloadCompleter!.future;
    if (createOutputFile && outputTemplate != null) {
      final path = outputTemplate
          .replaceAll('%(title)s', 'Title')
          .replaceAll('%(ext)s', audioOnly ? 'm4a' : 'mp4')
          .replaceAll('%%', '%');
      await File(path).parent.create(recursive: true);
      await File(path).writeAsString('media');
    }
  }

  @override
  Future<void> cancelDownloads() async {
    cancelCalled = true;
    if (downloadCompleter != null && !downloadCompleter!.isCompleted) {
      downloadCompleter!.completeError(StateError('cancelled'));
    }
  }

  @override
  Future<bool> hasActiveDownloads() async => false;

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

class FakeDownloadNotificationService extends DownloadNotificationService {
  final playlistNames = <String>[];
  final downloadedCounts = <int>[];
  final notificationIds = <int>[];

  @override
  Future<void> showDownloadComplete(
    String playlistName, {
    int downloadedCount = 1,
    int notificationId = 1001,
  }) async {
    playlistNames.add(playlistName);
    downloadedCounts.add(downloadedCount);
    notificationIds.add(notificationId);
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
  late LogService log;
  late FakeYtDlpService ytdlp;
  late FakeSponsorBlockService sponsorBlock;
  late FakeDownloadNotificationService notifications;
  late DownloadLock lock;
  late DownloadService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_download_test_');
    log = LogService();
    ytdlp = FakeYtDlpService();
    sponsorBlock = FakeSponsorBlockService(db, log);
    notifications = FakeDownloadNotificationService();
    lock = DownloadLock(directoryProvider: () async => tempDir.path);
    service = DownloadService(
      db,
      ytdlp,
      log,
      MetadataService(db),
      notifications,
      sponsorBlock,
      null,
      lock,
    );
  });

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
          outputPath: tempDir.path,
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
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await insertTestTrack(db, playlistId: playlist.id);
    await service.downloadPlaylist(playlist);
    expect(ytdlp.subtitleRequests, [(false, 'en')]);
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
      outputPath: tempDir.path,
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
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
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
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await insertTestTrack(db, playlistId: playlist.id);
    ytdlp.downloadError = StateError('permanent failure');

    await service.downloadPlaylist(playlist);

    expect(notifications.playlistNames, isEmpty);
  });

  test('SponsorBlock backfill leaves local replacements alone', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: tempDir.path,
      audioOnly: true,
    );
    final filePath = p.join(tempDir.path, '00001_Local_Audio.m4a');
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

  test('explicit update recovers a stale downloading row', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: tempDir.path,
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
    'cancelling returns the active track to pending and removes partials',
    () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: tempDir.path,
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
      final partial = File(p.join(tempDir.path, '00001_Cancelled.m4a.part'));
      await partial.writeAsString('partial');

      await service.cancelActiveDownloads();
      await download;

      expect(ytdlp.cancelCalled, isTrue);
      expect((await db.getTrack(track.id))!.status, 'pending');
      expect(await partial.exists(), isFalse);
    },
  );

  test('lastUpdated is stamped without replacing the playlist row', () async {
    final stale = await insertTestPlaylist(db, outputPath: tempDir.path);
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
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
    await insertTestTrack(db, playlistId: playlist.id);
    ytdlp.downloadError = StateError('permanent failure');

    await service.downloadPlaylist(playlist);

    expect((await db.getPlaylist(playlist.id)).lastUpdated, isNull);
  });

  test('a reused file counts as progress for the update stamp', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: tempDir.path,
      audioOnly: true,
    );
    await insertTestTrack(db, playlistId: playlist.id, index: 1);
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'video-2',
    );
    await File(p.join(tempDir.path, '00001_Present.m4a')).writeAsString('a');
    ytdlp.downloadError = StateError('permanent failure');

    await service.downloadPlaylist(playlist);

    expect(ytdlp.downloadedUrls, hasLength(1));
    expect((await db.getPlaylist(playlist.id)).lastUpdated, isNotNull);
  });

  test(
    'a download that leaves no media file is recorded as an error',
    () async {
      final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
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
    final folder = Directory(p.join(tempDir.path, '100% Hits'));
    await folder.create();
    final playlist = await insertTestPlaylist(db, outputPath: folder.path);
    final track = await insertTestTrack(db, playlistId: playlist.id);

    await service.downloadPlaylist(playlist);

    expect(
      ytdlp.outputTemplates.single,
      '${tempDir.path}/100%% Hits/00001_%(title)s.%(ext)s',
    );
    final updated = (await db.getTrack(track.id))!;
    expect(updated.status, 'complete');
    expect(updated.filePath, p.join(folder.path, '00001_Title.mp4'));
  });

  test('completion is reported only after the SponsorBlock backfill', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: tempDir.path,
      audioOnly: true,
    );
    final donePath = p.join(tempDir.path, '00001_Done.m4a');
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
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
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
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
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
      final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
      await insertTestTrack(db, playlistId: playlist.id);
      await lockFile().writeAsString(
        '${DownloadLock.backgroundOwner} ${DateTime.now().toIso8601String()}',
      );
      final background = DownloadService(
        db,
        ytdlp,
        log,
        MetadataService(db),
        notifications,
        sponsorBlock,
        null,
        lock,
        DownloadLock.backgroundOwner,
      );

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
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
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
    final playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
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
}
