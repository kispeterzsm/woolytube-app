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
  sortOrder: id,
  isTemporary: false,
  downloadSubtitles: false,
);

/// yt-dlp that starts without a platform channel and counts the start.
class _ReadyYtDlp extends FakeYtDlpService {
  int initializeCalls = 0;

  @override
  Future<void> initialize() async => initializeCalls++;
}

/// Keeps attempts in memory, so fake-time tests do no real file IO.
class _MemoryAttempts extends AutoUpdateAttemptLog {
  var attempts = <int, AutoUpdateAttempt>{};

  @override
  Future<Map<int, AutoUpdateAttempt>> read() async => {...attempts};

  @override
  Future<void> save(Map<int, AutoUpdateAttempt> attempts) async =>
      this.attempts = {...attempts};
}

/// Records what an [AutoUpdateRunner] did, with hooks to hold a download.
class _Recorder {
  final events = <String>[];
  final syncErrors = <int, Object>{};
  final downloadGates = <int, Completer<void>>{};

  /// Playlists whose downloads cannot reach YouTube: never stamped.
  final unreachable = <int>{};
  final stamps = <int, DateTime>{};
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
    // Like DownloadService: a run that reached YouTube counts.
    if (sourceChecked && !unreachable.contains(playlist.id) && gate == null) {
      stamps[playlist.id] = DateTime.now();
    }
  }

  Future<Playlist> reload(int id) async =>
      _playlist(id, lastUpdated: stamps[id]);

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
    reloadPlaylist: recorder.reload,
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

    test('the temporary playlist is never due', () {
      expect(
        isDueForAutoUpdate(_playlist(1).copyWith(isTemporary: true), now),
        isFalse,
      );
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
          1: AutoUpdateAttempt(at: DateTime(2026, 1, 1, 11)),
          2: AutoUpdateAttempt(at: DateTime(2026, 1, 1, 9)),
          // 3 was never attempted.
          4: AutoUpdateAttempt(at: DateTime(2026, 1, 1, 10)),
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

    test('failed videos do not make a playlist due before its interval', () {
      // The update reached YouTube and counted, so a video that failed
      // waits for the next daily update instead of coming back hourly.
      final playlist = _playlist(
        1,
        frequencyHours: 24,
        lastUpdated: now.subtract(const Duration(hours: 1)),
      );
      expect(
        isDueForAutoUpdate(
          playlist,
          now,
          attempt: AutoUpdateAttempt(
            at: now.subtract(const Duration(hours: 1)),
            failureKeys: const {'59:Video unavailable'},
          ),
        ),
        isFalse,
      );
    });

    test('runs that could not reach YouTube are retried after 1, 2, 4 ... '
        'hours, never later than the interval', () {
      final lastUpdated = DateTime(2025, 12, 1);
      final playlist = _playlist(
        1,
        frequencyHours: 24,
        lastUpdated: lastUpdated,
      );
      bool dueAfter(int unreachable, Duration sinceTry) => isDueForAutoUpdate(
        playlist,
        now,
        attempt: AutoUpdateAttempt(
          at: now.subtract(sinceTry),
          unreachable: unreachable,
        ),
      );

      expect(dueAfter(1, const Duration(minutes: 55)), isTrue);
      expect(dueAfter(2, const Duration(minutes: 55)), isFalse);
      expect(dueAfter(2, const Duration(hours: 2)), isTrue);
      expect(dueAfter(3, const Duration(hours: 3)), isFalse);
      expect(dueAfter(3, const Duration(hours: 4)), isTrue);
      expect(dueAfter(6, const Duration(hours: 23)), isFalse);
      // 32 hours, capped at the daily interval.
      expect(dueAfter(6, const Duration(hours: 24)), isTrue);
      expect(dueAfter(40, const Duration(hours: 24)), isTrue);

      expect(
        autoUpdateRetryDelay(5, const Duration(hours: 12)),
        const Duration(hours: 12),
      );
      expect(
        autoUpdateRetryDelay(1, const Duration(hours: 168)),
        const Duration(hours: 1),
      );
      expect(autoUpdateRetryDelay(0, const Duration(hours: 24)), Duration.zero);
    });

    test('unreachable runs from before the last update do not delay it', () {
      final playlist = _playlist(
        1,
        frequencyHours: 1,
        lastUpdated: now.subtract(const Duration(hours: 1)),
      );
      expect(
        isDueForAutoUpdate(
          playlist,
          now,
          attempt: AutoUpdateAttempt(
            at: now.subtract(const Duration(hours: 2)),
            unreachable: 5,
          ),
        ),
        isTrue,
      );
    });

    test('back-off leaves out a playlist that is waiting', () {
      final ordered = duePlaylistsInOrder(
        [_playlist(1, frequencyHours: 24), _playlist(2)],
        {
          1: AutoUpdateAttempt(
            at: now.subtract(const Duration(hours: 1)),
            unreachable: 3,
          ),
        },
        now,
      );
      expect([for (final p in ordered) p.id], [2]);
    });
  });

  group('attempt log', () {
    test('records and reads back attempt times', () async {
      final at = DateTime(2026, 2, 3, 4, 5);
      await attempts.record(7, at);
      expect((await attempts.read())[7]!.at, at);
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

    test('reads the old format of bare attempt times', () async {
      await File(
        p.join(tempDir.path, AutoUpdateAttemptLog.fileName),
      ).writeAsString('{"3": "2026-02-03T04:05:00.000"}');
      final attempt = (await attempts.read())[3]!;
      expect(attempt.at, DateTime(2026, 2, 3, 4, 5));
      expect(attempt.unreachable, 0);
      expect(attempt.failureKeys, isEmpty);
    });

    test('counts unreachable runs until an update counts', () async {
      final at = DateTime(2026, 2, 3);
      await attempts.record(4, at);
      await attempts.recordOutcome(4, updated: false);
      await attempts.recordOutcome(4, updated: false);
      expect((await attempts.read())[4]!.unreachable, 2);
      // A new attempt keeps the count; it is about the runs in a row.
      await attempts.record(4, at.add(const Duration(hours: 2)));
      expect((await attempts.read())[4]!.unreachable, 2);
      expect((await attempts.read())[4]!.at, at.add(const Duration(hours: 2)));

      await attempts.recordOutcome(4, updated: true);
      expect((await attempts.read())[4]!.unreachable, 0);
    });

    test(
      'tells only failures the previous scheduled run did not have',
      () async {
        expect(await attempts.takeNewFailures(5, ['1:Video unavailable']), {
          '1:Video unavailable',
        });
        // The same failure again: nothing new.
        expect(
          await attempts.takeNewFailures(5, ['1:Video unavailable']),
          isEmpty,
        );
        // Another track, and the same track for another reason, are new.
        expect(
          await attempts.takeNewFailures(5, [
            '1:Video unavailable',
            '2:Private video',
          ]),
          {'2:Private video'},
        );
        expect(await attempts.takeNewFailures(5, ['1:Network error']), {
          '1:Network error',
        });
        // A run without failures forgets them, so a later one is new again.
        expect(await attempts.takeNewFailures(5, const []), isEmpty);
        expect(await attempts.takeNewFailures(5, ['1:Network error']), {
          '1:Network error',
        });
        // Other playlists are separate, and a new attempt keeps the keys.
        await attempts.record(5, DateTime(2026), knownIds: [5, 6]);
        expect(await attempts.takeNewFailures(6, ['1:Network error']), {
          '1:Network error',
        });
        expect((await attempts.read())[5]!.failureKeys, {'1:Network error'});
      },
    );
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

    test('counts runs that could not reach YouTube, and forgets them once '
        'an update counts', () async {
      final recorder =
          _Recorder()
            ..syncErrors[1] = Exception('Unable to download webpage')
            ..unreachable.add(2);
      await runnerFor(recorder).run([_playlist(1), _playlist(2), _playlist(3)]);
      var log = await attempts.read();
      expect(log[1]!.unreachable, 1);
      expect(log[2]!.unreachable, 1);
      expect(log[3]!.unreachable, 0);

      await runnerFor(recorder).run([_playlist(1), _playlist(2)]);
      log = await attempts.read();
      expect(log[1]!.unreachable, 2);
      expect(log[2]!.unreachable, 2);

      recorder.syncErrors.clear();
      recorder.unreachable.clear();
      await runnerFor(recorder).run([_playlist(1)]);
      log = await attempts.read();
      expect(log[1]!.unreachable, 0);
      expect(log[2]!.unreachable, 2);
    });

    test('a stopped run is not counted as unreachable', () async {
      final recorder = _Recorder();
      recorder.downloadGates[1] = Completer<void>();
      final runner = runnerFor(recorder);
      final run = runner.run([_playlist(1)]);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!recorder.events.contains('download 1 checked=true') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await runner.requestStop();
      await run;
      expect((await attempts.read())[1]!.unreachable, 0);
    });

    test('keeps what it knows about playlists that were not due', () async {
      await attempts.takeNewFailures(9, ['1:Video unavailable']);
      await runnerFor(_Recorder()).run([_playlist(1)], knownIds: [1, 9]);
      final log = await attempts.read();
      expect(log.keys, unorderedEquals([1, 9]));
      expect(log[9]!.failureKeys, {'1:Video unavailable'});

      // A deleted playlist is forgotten.
      await runnerFor(_Recorder()).run([_playlist(1)], knownIds: [1]);
      expect((await attempts.read()).keys, [1]);
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
      // The run does real database work first; wait until it is downloading
      // instead of for a fixed number of event-loop turns.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!recorder.events.contains('download 1 checked=true') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
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
        lock,
        DownloadLock.foregroundOwner,
        gate,
        thumbnails,
        null,
        attempts,
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

    test('a scheduled run marks its reports, counts despite a failed video '
        'and is not due again within its interval', () async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: folder,
        updateFrequencyHours: 24,
      );
      ytdlp.playlistInfo = {
        'title': 'Test Playlist',
        'entries': [
          {'id': 'abc', 'title': 'Song', 'playlist_index': 1},
        ],
      };
      ytdlp.downloadError = PlatformException(
        code: 'DOWNLOAD_ERROR',
        message: 'ERROR: [youtube] abc: Video unavailable',
      );
      final events = <DownloadProgress>[];
      final sub = downloads.progressStream.listen(events.add);

      final report = await bridge.runScheduledUpdate();
      await sub.cancel();

      expect(report.status, AutoUpdateStatus.finished);
      expect(events, isNotEmpty);
      expect(events.every((e) => e.scheduled), isTrue);
      expect(events.last.failures.single.title, 'Song');
      expect((await db.getPlaylist(playlist.id)).lastUpdated, isNotNull);
      expect((await attempts.read())[playlist.id]!.unreachable, 0);

      // An hour later the worker runs again: nothing is due.
      final later = await bridge.runScheduledUpdate();
      expect(later.status, AutoUpdateStatus.nothingDue);
      expect(ytdlp.requestedPlaylistUrls, [playlist.url]);
    });

    test('stays out while the background engine holds the library', () async {
      await insertTestPlaylist(db, outputPath: folder);
      await lock.acquire(DownloadLock.backgroundOwner);

      final report = await bridge.runScheduledUpdate();

      expect(report.status, AutoUpdateStatus.busy);
      expect(ytdlp.requestedPlaylistUrls, isEmpty);
    });

    test('refreshes live queries after the worker engine wrote', () async {
      final playlist = await insertTestPlaylist(db, outputPath: folder);
      final emitted = <String>[];
      final sub = db.watchAllPlaylists().listen(
        (l) => emitted.add(l.single.name),
      );
      await pumpEventQueue();
      // A write drift is not told about, like one from the worker's engine.
      await db.customStatement('UPDATE playlists SET name = ? WHERE id = ?', [
        'Renamed elsewhere',
        playlist.id,
      ]);
      await pumpEventQueue();
      expect(emitted, ['Test Playlist']);

      await bridge.handleWorkerCall(
        const MethodCall('libraryChangedExternally'),
      );
      await pumpEventQueue();
      await sub.cancel();
      expect(emitted, ['Test Playlist', 'Renamed elsewhere']);
    });

    test('the notification Cancel stops a user download', () async {
      final reply = await bridge.handleControlCall(
        const MethodCall('cancelRequestedByUser'),
      );
      expect(reply, isTrue);
    });

    test('the notification Cancel stops a song scan', () async {
      var scanCancels = 0;
      final scanBridge = ForegroundAutoUpdateBridge(
        db: db,
        ytdlp: ytdlp,
        playlists: playlists,
        downloads: downloads,
        log: log,
        lock: lock,
        attempts: attempts,
        cancelSongScan: () => scanCancels++,
      );
      final reply = await scanBridge.handleControlCall(
        const MethodCall('cancelRequestedByUser'),
      );
      expect(reply, isTrue);
      expect(scanCancels, 1);
    });

    test('answers the native Cancel-button probe', () async {
      expect(await bridge.handleControlCall(const MethodCall('ping')), isTrue);
    });

    test('the app\'s Stop button ends the whole scheduled run', () async {
      final first = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=one',
        name: 'One',
        outputPath: folder,
      );
      final second = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=two',
        name: 'Two',
        outputPath: p.join(tempDir.path, 'Music', 'Two'),
      );
      ytdlp.playlistInfo = {
        'title': 'Playlist',
        'entries': [
          {'id': 'abc', 'title': 'Song', 'playlist_index': 1},
        ],
      };
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final run = bridge.runScheduledUpdate();
      await ytdlp.downloadStarted!.future;
      // What home_page/playlist_detail_page do on Stop.
      await downloads.cancelActiveDownloads();
      final report = await run;

      expect(report.status, AutoUpdateStatus.stopped);
      expect(report.handled, 1);
      expect(ytdlp.requestedPlaylistUrls, [first.url]);
      expect(ytdlp.requestedPlaylistUrls, isNot(contains(second.url)));
      final tracks = await db.getTracksForPlaylist(first.id);
      expect(tracks.single.status, 'pending');
    });

    test('Cancel is acknowledged before the clean-up finishes', () async {
      await insertTestPlaylist(db, outputPath: folder);
      ytdlp.playlistInfo = {
        'title': 'Playlist',
        'entries': [
          {'id': 'abc', 'title': 'Song', 'playlist_index': 1},
        ],
      };
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final run = bridge.runScheduledUpdate();
      await ytdlp.downloadStarted!.future;
      final runner = bridge.activeRun!;

      final reply = bridge.handleControlCall(
        const MethodCall('cancelRequestedByUser'),
      );
      // The stop flag is set synchronously, before any clean-up await.
      expect(runner.stopRequested, isTrue);
      expect(await reply, isTrue);
      expect((await run).status, AutoUpdateStatus.stopped);
    });

    test('Cancel during a scheduled run leaves a song scan alone', () async {
      var scanCancels = 0;
      final scanBridge = ForegroundAutoUpdateBridge(
        db: db,
        ytdlp: ytdlp,
        playlists: playlists,
        downloads: downloads,
        log: log,
        lock: lock,
        attempts: attempts,
        cancelSongScan: () => scanCancels++,
      );
      await insertTestPlaylist(db, outputPath: folder);
      ytdlp.playlistInfo = {
        'title': 'Playlist',
        'entries': [
          {'id': 'abc', 'title': 'Song', 'playlist_index': 1},
        ],
      };
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();

      final run = scanBridge.runScheduledUpdate();
      await ytdlp.downloadStarted!.future;
      expect(
        await scanBridge.handleControlCall(
          const MethodCall('cancelRequestedByUser'),
        ),
        isTrue,
      );
      expect((await run).status, AutoUpdateStatus.stopped);
      // The download owned the notification, so its Cancel was for it.
      expect(scanCancels, 0);
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
      expect(
        log.entries.map((e) => e.message),
        contains('Scheduled update skipped: the app is downloading'),
      );
    });

    test('the log is saved before the run is reported, and marked as from '
        'the background', () async {
      final logs = Directory(p.join(tempDir.path, 'logs'));
      final background = LogService(
        sink: LogFileSink(() async => logs, name: LogService.backgroundSource),
        source: LogService.backgroundSource,
      );
      addTearDown(background.dispose);
      background.info('Scheduled update ended: 1 updated');
      final calls = <String>[];
      var closed = false;
      var savedWhenReported = '';

      await finishBackgroundRun(
        const AutoUpdateReport(AutoUpdateStatus.finished),
        log: background,
        closeDatabase: () async => closed = true,
        reportToNative: (method, arguments) async {
          calls.add(method);
          // The worker destroys the engine right after this reply.
          savedWhenReported =
              await File(
                p.join(logs.path, 'woolytube-background.log'),
              ).readAsString();
          return null;
        },
      );

      expect(closed, isTrue);
      expect(calls, ['taskComplete']);
      expect(savedWhenReported, contains('Scheduled update ended'));
      expect(
        LogEntry.parseLine(savedWhenReported.trim())!.formattedWithDate,
        contains('(background)'),
      );

      background.error('Scheduled update failed: boom');
      await finishBackgroundRun(
        const AutoUpdateReport(AutoUpdateStatus.failed, error: 'boom'),
        log: background,
        closeDatabase: () async => throw StateError('already closed'),
        reportToNative: (method, arguments) async {
          calls.add('$method $arguments');
          savedWhenReported =
              await File(
                p.join(logs.path, 'woolytube-background.log'),
              ).readAsString();
          return null;
        },
      );
      expect(calls.last, 'taskFailed {error: boom}');
      expect(savedWhenReported, contains('Scheduled update failed: boom'));
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
