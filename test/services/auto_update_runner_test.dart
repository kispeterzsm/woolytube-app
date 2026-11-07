import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/auto_update_runner.dart';
import 'package:woolytube/services/background_worker.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

Playlist _playlist(
  int id, {
  bool autoUpdate = true,
  int frequencyHours = 1,
  DateTime? lastUpdated,
}) => Playlist(
  id: id,
  url: 'https://www.youtube.com/playlist?list=$id',
  name: 'Playlist $id',
  audioOnly: false,
  autoUpdate: autoUpdate,
  updateFrequencyHours: frequencyHours,
  includeThumbnails: true,
  sponsorBlockEnabled: false,
  sponsorBlockCategories: '[]',
  sponsorBlockCategoryActions: '{}',
  lastUpdated: lastUpdated,
  createdAt: DateTime(2024),
  outputPath: '/tmp/none',
);

/// yt-dlp that starts without a platform channel and counts the start.
class _ReadyYtDlp extends FakeYtDlpService {
  int initializeCalls = 0;

  @override
  Future<void> initialize() async => initializeCalls++;
}

/// Keeps attempts in memory, so fake-time tests do no real file IO.
class _MemoryAttempts extends AutoUpdateAttemptLog {
  final attempts = <int, DateTime>{};

  @override
  Future<Map<int, DateTime>> read() async => {...attempts};

  @override
  Future<void> record(
    int playlistId,
    DateTime at, {
    Iterable<int>? knownIds,
  }) async => attempts[playlistId] = at;
}

/// Records what an [AutoUpdateRunner] did, with hooks to hold a download.
class _Recorder {
  final events = <String>[];
  final syncErrors = <int, Object>{};
  final downloadGates = <int, Completer<void>>{};
  int cancels = 0;
  int? activeTrack;
  String? blocked;

  Future<void> sync(Playlist playlist) async {
    events.add('sync ${playlist.id}');
    final error = syncErrors[playlist.id];
    if (error != null) throw error;
  }

  Future<void> download(
    Playlist playlist, {
    required bool sourceChecked,
  }) async {
    events.add('download ${playlist.id} checked=$sourceChecked');
    final gate = downloadGates[playlist.id];
    if (gate != null) await gate.future;
  }

  Future<void> cancel() async {
    cancels++;
    for (final gate in downloadGates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AutoUpdateAttemptLog attempts;
  late LogService log;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('woolytube_auto_update_');
    attempts = AutoUpdateAttemptLog(
      directoryProvider: () async => tempDir.path,
    );
    log = LogService();
  });

  tearDown(() async {
    log.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  AutoUpdateRunner runnerFor(
    _Recorder recorder, {
    Duration soft = const Duration(minutes: 7),
    Duration hard = const Duration(minutes: 8),
    DateTime Function()? clock,
    AutoUpdateAttemptLog? attemptLog,
  }) => AutoUpdateRunner(
    syncPlaylist: recorder.sync,
    reloadPlaylist: (id) async => _playlist(id),
    downloadPlaylist: recorder.download,
    cancelDownload: recorder.cancel,
    activeTrackId: () => recorder.activeTrack,
    blockedReason: () async => recorder.blocked,
    attempts: attemptLog ?? attempts,
    log: log,
    softBudget: soft,
    hardBudget: hard,
    clock: clock,
  );

  group('due check', () {
    final now = DateTime(2026, 1, 1, 12);

    test('a playlist never updated is due', () {
      expect(isDueForAutoUpdate(_playlist(1), now), isTrue);
    });

    test('a playlist with auto-update off is never due', () {
      expect(isDueForAutoUpdate(_playlist(1, autoUpdate: false), now), isFalse);
    });

    test('an hourly playlist stamped 55 minutes ago is due', () {
      // The old whole-hour check skipped it, so hourly became two-hourly.
      final playlist = _playlist(
        1,
        lastUpdated: now.subtract(const Duration(minutes: 55)),
      );
      expect(isDueForAutoUpdate(playlist, now), isTrue);
    });

    test('an hourly playlist stamped 40 minutes ago is not due', () {
      final playlist = _playlist(
        1,
        lastUpdated: now.subtract(const Duration(minutes: 40)),
      );
      expect(isDueForAutoUpdate(playlist, now), isFalse);
    });

    test('a daily playlist is due a little before 24 hours', () {
      final playlist = _playlist(
        1,
        frequencyHours: 24,
        lastUpdated: now.subtract(const Duration(hours: 23, minutes: 55)),
      );
      expect(isDueForAutoUpdate(playlist, now), isTrue);
    });

    test('never-attempted playlists come first, then the oldest attempt', () {
      final ordered = duePlaylistsInOrder(
        [_playlist(1), _playlist(2), _playlist(3), _playlist(4)],
        {
          1: DateTime(2026, 1, 1, 11),
          2: DateTime(2026, 1, 1, 9),
          // 3 was never attempted.
          4: DateTime(2026, 1, 1, 10),
        },
        now,
      );
      expect([for (final p in ordered) p.id], [3, 2, 4, 1]);
    });

    test('playlists that are not due are left out', () {
      final ordered = duePlaylistsInOrder(
        [
          _playlist(1, autoUpdate: false),
          _playlist(2, lastUpdated: now),
          _playlist(3),
        ],
        const {},
        now,
      );
      expect([for (final p in ordered) p.id], [3]);
    });
  });

  group('attempt log', () {
    test('records and reads back attempt times', () async {
      final at = DateTime(2026, 2, 3, 4, 5);
      await attempts.record(7, at);
      expect(await attempts.read(), {7: at});
    });

    test('drops playlists that no longer exist', () async {
      await attempts.record(1, DateTime(2026));
      await attempts.record(2, DateTime(2026));
      await attempts.record(3, DateTime(2026), knownIds: [2, 3]);
      expect((await attempts.read()).keys, unorderedEquals([2, 3]));
    });

    test('a damaged file reads as empty', () async {
      await File(
        p.join(tempDir.path, AutoUpdateAttemptLog.fileName),
      ).writeAsString('{not json');
      expect(await attempts.read(), isEmpty);
    });
  });

  group('runner', () {
    test('syncs and downloads every due playlist in order', () async {
      final recorder = _Recorder();
      final report = await runnerFor(
        recorder,
      ).run([_playlist(2), _playlist(1)]);

      expect(recorder.events, [
        'sync 2',
        'download 2 checked=true',
        'sync 1',
        'download 1 checked=true',
      ]);
      expect(report.status, AutoUpdateStatus.finished);
      expect(report.handled, 2);
      expect((await attempts.read()).keys, unorderedEquals([1, 2]));
    });

    test('nothing due reports nothingDue', () async {
      final report = await runnerFor(_Recorder()).run(const []);
      expect(report.status, AutoUpdateStatus.nothingDue);
    });

    test('a failed sync still downloads the known tracks', () async {
      final recorder = _Recorder()..syncErrors[1] = Exception('private');
      await runnerFor(recorder).run([_playlist(1)]);
      expect(recorder.events, ['sync 1', 'download 1 checked=false']);
    });

    test('a busy library stops the run instead of trying every playlist', () {
      final recorder =
          _Recorder()..syncErrors[1] = const LibraryBusyException('busy');
      return runnerFor(recorder).run([_playlist(1), _playlist(2)]).then((
        report,
      ) {
        expect(recorder.events, ['sync 1']);
        expect(report.status, AutoUpdateStatus.busy);
      });
    });

    test('does nothing while the other engine holds the library', () async {
      final recorder = _Recorder()..blocked = 'the app is downloading';
      final report = await runnerFor(recorder).run([_playlist(1)]);
      expect(recorder.events, isEmpty);
      expect(report.status, AutoUpdateStatus.busy);
    });

    test('a stop cancels the download and starts nothing new', () async {
      final recorder = _Recorder();
      recorder.downloadGates[1] = Completer<void>();
      final runner = runnerFor(recorder);
      final run = runner.run([_playlist(1), _playlist(2)]);
      await pumpEventQueue();
      expect(recorder.events.last, 'download 1 checked=true');

      await runner.requestStop();
      final report = await run;

      expect(recorder.cancels, 1);
      expect(recorder.events, ['sync 1', 'download 1 checked=true']);
      expect(report.status, AutoUpdateStatus.stopped);
    });

    test('a stop before the run starts runs nothing', () async {
      final recorder = _Recorder();
      final runner = runnerFor(recorder);
      await runner.requestStop();
      final report = await runner.run([_playlist(1)]);
      expect(recorder.events, isEmpty);
      expect(report.status, AutoUpdateStatus.stopped);
    });

    test('after the soft budget no new playlist starts', () {
      fakeAsync((async) {
        final recorder = _Recorder();
        recorder.downloadGates[1] = Completer<void>();
        AutoUpdateReport? report;
        runnerFor(
          recorder,
          soft: const Duration(minutes: 1),
          hard: const Duration(minutes: 5),
          clock: () => DateTime(2026),
          attemptLog: _MemoryAttempts(),
        ).run([_playlist(1), _playlist(2)]).then((r) => report = r);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 2));
        // The running download may finish.
        expect(recorder.cancels, 0);
        recorder.downloadGates[1]!.complete();
        async.flushMicrotasks();

        expect(recorder.events, ['sync 1', 'download 1 checked=true']);
        expect(report?.status, AutoUpdateStatus.outOfTime);
      });
    });

    test('after the soft budget a newly started track is stopped', () {
      fakeAsync((async) {
        final recorder = _Recorder()..activeTrack = 10;
        recorder.downloadGates[1] = Completer<void>();
        runnerFor(
          recorder,
          soft: const Duration(minutes: 1),
          hard: const Duration(minutes: 5),
          clock: () => DateTime(2026),
          attemptLog: _MemoryAttempts(),
        ).run([_playlist(1)]);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 1, seconds: 3));
        expect(recorder.cancels, 0, reason: 'track 10 may finish');

        recorder.activeTrack = 11;
        async.elapse(const Duration(seconds: 2));
        expect(recorder.cancels, 1);
      });
    });

    test('at the hard budget the running track is stopped', () {
      fakeAsync((async) {
        final recorder = _Recorder();
        recorder.downloadGates[1] = Completer<void>();
        AutoUpdateReport? report;
        runnerFor(
          recorder,
          soft: const Duration(minutes: 1),
          hard: const Duration(minutes: 2),
          clock: () => DateTime(2026),
          attemptLog: _MemoryAttempts(),
        ).run([_playlist(1)]).then((r) => report = r);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 2, seconds: 1));
        async.flushMicrotasks();

        expect(recorder.cancels, 1);
        expect(report?.status, AutoUpdateStatus.outOfTime);
      });
    });
  });

  group('app engine bridge', () {
    late AppDatabase db;
    late _ReadyYtDlp ytdlp;
    late DownloadLock lock;
    late DownloadService downloads;
    late PlaylistService playlists;
    late ForegroundAutoUpdateBridge bridge;
    late String folder;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = openTestDatabase();
      ytdlp = _ReadyYtDlp();
      folder = p.join(tempDir.path, 'Music', 'Test Playlist');
      await Directory(folder).create(recursive: true);
      lock = DownloadLock(directoryProvider: () async => tempDir.path);
      final gate = LibraryGate(lock: lock, owner: DownloadLock.foregroundOwner);
      final thumbnails = FakeMediaThumbnailService();
      playlists = PlaylistService(
        db,
        ytdlp,
        MetadataService(db),
        thumbnails,
        null,
        gate,
      );
      downloads = DownloadService(
        db,
        ytdlp,
        log,
        MetadataService(db),
        null,
        null,
        null,
        lock,
        DownloadLock.foregroundOwner,
        gate,
        thumbnails,
      );
      bridge = ForegroundAutoUpdateBridge(
        db: db,
        ytdlp: ytdlp,
        playlists: playlists,
        downloads: downloads,
        log: log,
        lock: lock,
        attempts: attempts,
      );
    });

    tearDown(() async {
      downloads.dispose();
      await db.close();
    });

    test('answers the worker\'s ping', () async {
      expect(await bridge.handleWorkerCall(const MethodCall('ping')), isTrue);
    });

    test('with nothing due it does not start yt-dlp', () async {
      await insertTestPlaylist(
        db,
        outputPath: folder,
        lastUpdated: DateTime.now(),
      );
      final reply = await bridge.handleWorkerCall(
        const MethodCall('runAutoUpdate', {'budgetMs': 540000}),
      );
      expect((reply as Map)['status'], 'nothingDue');
      expect(ytdlp.initializeCalls, 0);
    });

    test('runs a due playlist through the app\'s own services', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      ytdlp.playlistInfo = {
        'title': 'Test Playlist',
        'entries': [
          {'id': 'abc', 'title': 'Song', 'playlist_index': 1},
        ],
      };

      final reply = await bridge.handleWorkerCall(
        const MethodCall('runAutoUpdate', {'budgetMs': 540000}),
      );

      expect((reply as Map)['status'], 'finished');
      expect(ytdlp.requestedPlaylistUrls, [playlist.url]);
      final tracks = await db.getTracksForPlaylist(playlist.id);
      expect(tracks.single.status, 'complete');
      expect((await db.getPlaylist(playlist.id)).lastUpdated, isNotNull);
      // The run kept the app's lock, never the background one.
      expect(
        File(p.join(tempDir.path, DownloadLock.fileName)).existsSync(),
        isFalse,
      );
    });

    test('stays out while the background engine holds the library', () async {
      await insertTestPlaylist(db, outputPath: folder);
      await lock.acquire(DownloadLock.backgroundOwner);

      final report = await bridge.runScheduledUpdate();

      expect(report.status, AutoUpdateStatus.busy);
      expect(ytdlp.requestedPlaylistUrls, isEmpty);
    });

    test('refreshes live queries after the worker engine wrote', () async {
      final emitted = <int>[];
      final sub = db.watchAllPlaylists().listen((l) => emitted.add(l.length));
      await pumpEventQueue();
      await bridge.handleWorkerCall(
        const MethodCall('libraryChangedExternally'),
      );
      await pumpEventQueue();
      await sub.cancel();
      expect(emitted.length, 2);
    });

    test('the notification Cancel stops a user download', () async {
      final reply = await bridge.handleControlCall(
        const MethodCall('cancelRequestedByUser'),
      );
      expect(reply, isTrue);
    });
  });

  group('headless worker body', () {
    late AppDatabase db;

    setUp(() => db = openTestDatabase());
    tearDown(() => db.close());

    test('skips while the app holds the library', () async {
      final lock = DownloadLock(directoryProvider: () async => tempDir.path);
      await lock.acquire(DownloadLock.foregroundOwner);
      var opened = false;
      final report = await runBackgroundAutoUpdate(
        openDatabase: () {
          opened = true;
          return db;
        },
        isStopRequested: () => false,
        onRunner: (_) {},
        ytdlp: _ReadyYtDlp(),
        lock: lock,
        attempts: attempts,
        log: log,
      );
      expect(report.status, AutoUpdateStatus.busy);
      expect(opened, isFalse);
    });

    test('with nothing due it does not start yt-dlp', () async {
      await insertTestPlaylist(db, lastUpdated: DateTime.now());
      final ytdlp = _ReadyYtDlp();
      final report = await runBackgroundAutoUpdate(
        openDatabase: () => db,
        isStopRequested: () => false,
        onRunner: (_) {},
        ytdlp: ytdlp,
        lock: DownloadLock(directoryProvider: () async => tempDir.path),
        attempts: attempts,
        log: log,
      );
      expect(report.status, AutoUpdateStatus.nothingDue);
      expect(ytdlp.initializeCalls, 0);
    });
  });
}
