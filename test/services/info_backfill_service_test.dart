import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/info_backfill_service.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/media_thumbnail_service.dart';

import '../helpers/test_database.dart';

/// A clock that only moves when the backfill sleeps.
class _Clock {
  DateTime now = DateTime.utc(2026, 11, 13, 12);
  final sleeps = <Duration>[];

  Future<void> sleep(Duration duration) async {
    sleeps.add(duration);
    now = now.add(duration);
    // Lets file and database work the fake yt-dlp waits for go on.
    await Future<void>.delayed(Duration.zero);
  }
}

/// Stands in for yt-dlp: answers with an info map, or throws what
/// [errors] says for a video.
class _YouTube {
  _YouTube(this.clock);

  final _Clock clock;
  final fetched = <String>[];
  final fetchedAt = <DateTime>[];
  final errors = <String, String>{};

  /// Runs while yt-dlp fetches a video: the library changing meanwhile.
  Future<void> Function(String id)? whileFetching;

  Future<Map<String, dynamic>> fetch(String url) async {
    final id = Uri.parse(url).queryParameters['v']!;
    fetched.add(id);
    fetchedAt.add(clock.now);
    await whileFetching?.call(id);
    final error = errors[id];
    if (error != null) {
      throw PlatformException(code: 'INFO_ERROR', message: error);
    }
    return {
      'id': id,
      'title': 'YouTube title of $id',
      'description': 'About $id',
      'upload_date': '20200101',
      'formats': [
        {'url': 'https://example.com/stream'},
      ],
      'chapters': [
        {'start_time': 0, 'end_time': 10, 'title': 'Intro'},
      ],
    };
  }
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late _Clock clock;
  late _YouTube youtube;
  late InfoBackfillStore store;
  late LogService log;
  var onWifi = true;
  var busy = false;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('woolytube_info_');
    db = openTestDatabase();
    clock = _Clock();
    youtube = _YouTube(clock);
    store = InfoBackfillStore(
      directoryProvider: () async => p.join(tempDir.path, 'app'),
    );
    log = LogService.memoryOnly();
    onWifi = true;
    busy = false;
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  InfoBackfillService service({
    InfoBackfillPacing pacing = const InfoBackfillPacing(),
    Future<bool> Function()? prepare,
  }) => InfoBackfillService(
    db,
    fetchInfo: youtube.fetch,
    isOnWifi: () async => onWifi,
    isBusy: () => busy,
    prepare: prepare,
    store: store,
    log: log,
    pacing: pacing,
    clock: () => clock.now,
    random: math.Random(7),
    sleep: clock.sleep,
  );

  /// A playlist folder with one downloaded track per video id.
  Future<(Playlist, String)> addPlaylist(
    String name,
    List<String> videoIds, {
    Set<String> withInfo = const {},
    Set<String> replaced = const {},
    Set<String> removed = const {},
  }) async {
    final folder = p.join(tempDir.path, 'Music', name);
    await Directory(LibraryLayout.infoDir(folder)).create(recursive: true);
    final playlist = await insertTestPlaylist(
      db,
      url: 'https://www.youtube.com/playlist?list=$name',
      name: name,
      outputPath: folder,
    );
    for (var i = 0; i < videoIds.length; i++) {
      final id = videoIds[i];
      final file = p.join(folder, '0000${i + 1}_$id.m4a');
      await File(file).writeAsBytes(const [1, 2, 3]);
      if (withInfo.contains(id)) {
        await File(
          LibraryLayout.infoJsonPath(folder, id),
        ).writeAsString('{"id": "$id", "description": "kept"}');
      }
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: i + 1,
        videoId: id,
        title: 'My title $id',
        filePath: file,
        status: 'complete',
        isLocalReplacement: replaced.contains(id),
        unavailableReason: removed.contains(id) ? 'Removed from YouTube' : null,
      );
    }
    return (playlist, folder);
  }

  bool hasInfo(String folder, String id) =>
      File(LibraryLayout.infoJsonPath(folder, id)).existsSync();

  group('pacing', () {
    test('waits 20 to 60 seconds between fetches', () {
      const pacing = InfoBackfillPacing();
      final random = math.Random(1);
      for (var i = 0; i < 200; i++) {
        final gap = pacing.gap(random);
        expect(gap, greaterThanOrEqualTo(const Duration(seconds: 20)));
        expect(gap, lessThanOrEqualTo(const Duration(seconds: 60)));
      }
    });

    test('pauses longer each time YouTube asks again, up to 12 hours', () {
      const pacing = InfoBackfillPacing();
      final random = math.Random(1);
      // Up to a fifth more at random.
      Duration base(int n) => pacing.pause(n, random);

      expect(base(1), _seconds(30 * 60, 36 * 60));
      expect(base(2), _seconds(60 * 60, 72 * 60));
      expect(base(3), _seconds(120 * 60, 144 * 60));
      expect(base(20), _seconds(12 * 3600, 12 * 3600 * 1.2));
    });

    test('sorts yt-dlp errors', () {
      expect(
        classifyInfoFetchError(
          "ERROR: [youtube] x: Sign in to confirm you're not a bot",
        ),
        InfoFetchProblem.slowDown,
      );
      expect(
        classifyInfoFetchError('HTTP Error 429: Too Many Requests'),
        InfoFetchProblem.slowDown,
      );
      expect(
        classifyInfoFetchError('ERROR: [youtube] x: Private video'),
        InfoFetchProblem.gone,
      );
      expect(
        classifyInfoFetchError(
          'ERROR: [youtube] x: This video has been removed by the uploader',
        ),
        InfoFetchProblem.gone,
      );
      expect(
        classifyInfoFetchError(
          '<urlopen error [Errno 7] No address associated with hostname>',
        ),
        InfoFetchProblem.offline,
      );
      // YouTube also says this for a temporary refusal.
      expect(
        classifyInfoFetchError('ERROR: [youtube] x: Video unavailable'),
        InfoFetchProblem.failed,
      );
    });
  });

  test('saves the trimmed info of every track without it, and touches '
      'nothing else', () async {
    final (playlist, folder) = await addPlaylist(
      'Mix',
      ['a', 'b', 'c', 'd', 'e'],
      withInfo: {'b'},
      replaced: {'c'},
      removed: {'d'},
    );
    final before = await db.getTracksForPlaylist(playlist.id);
    final mediaBefore = File(before.first.filePath!).lastModifiedSync();

    final run = await service().run();

    expect(run.end, InfoBackfillEnd.done);
    expect(run.saved, 2);
    // b has it, c is the owner's own file, d is gone from YouTube.
    expect(youtube.fetched, ['a', 'e']);
    expect(hasInfo(folder, 'a'), isTrue);
    expect(hasInfo(folder, 'c'), isFalse);
    expect(hasInfo(folder, 'd'), isFalse);
    final saved =
        jsonDecode(
              File(LibraryLayout.infoJsonPath(folder, 'a')).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(saved['description'], 'About a');
    expect(saved.containsKey('formats'), isFalse);
    expect(
      File(LibraryLayout.infoJsonPath(folder, 'b')).readAsStringSync(),
      contains('kept'),
    );
    // Titles, chapters and media stay as they were.
    final after = await db.getTracksForPlaylist(playlist.id);
    expect(
      [for (final t in after) (t.title, t.chaptersJson)],
      [for (final t in before) (t.title, t.chaptersJson)],
    );
    expect(File(before.first.filePath!).lastModifiedSync(), mediaBefore);
  });

  test('keeps 20 to 60 seconds between fetches, also across runs', () async {
    await addPlaylist('Mix', ['a', 'b', 'c']);
    await service().run();
    expect(youtube.fetched, ['a', 'b', 'c']);

    // A new run (another engine, a restart) still waits for the gap.
    await addPlaylist('More', ['d']);
    await service().run();
    expect(youtube.fetched, ['a', 'b', 'c', 'd']);
    for (var i = 1; i < youtube.fetchedAt.length; i++) {
      final gap = youtube.fetchedAt[i].difference(youtube.fetchedAt[i - 1]);
      expect(gap, _seconds(20, 60));
    }
  });

  test('a fetch that would start after the budget is not started', () async {
    await addPlaylist('Mix', ['a', 'b', 'c']);
    final run = await service().run(budget: const Duration(seconds: 10));
    expect(run.end, InfoBackfillEnd.outOfTime);
    expect(youtube.fetched, ['a']);
  });

  test('stops when asked, and the next run carries on', () async {
    final (_, folder) = await addPlaylist('Mix', ['a', 'b', 'c']);
    var stop = false;
    final first = service();
    final run = await first.run(
      shouldStop: () {
        // Stop once the first video is saved.
        stop = stop || hasInfo(folder, 'a');
        return stop;
      },
    );
    expect(run.end, InfoBackfillEnd.stopped);
    expect(youtube.fetched, ['a']);

    final next = await service().run();
    expect(next.end, InfoBackfillEnd.done);
    expect(youtube.fetched, ['a', 'b', 'c']);
  });

  test('waits without Wi-Fi, while the library is busy and until yt-dlp is '
      'ready', () async {
    await addPlaylist('Mix', ['a']);
    onWifi = false;
    expect((await service().run()).end, InfoBackfillEnd.noWifi);
    onWifi = true;
    busy = true;
    expect((await service().run()).end, InfoBackfillEnd.busy);
    busy = false;
    expect(
      (await service(prepare: () async => false).run()).end,
      InfoBackfillEnd.notReady,
    );
    expect(youtube.fetched, isEmpty);
    expect((await service().run()).end, InfoBackfillEnd.done);
    expect(youtube.fetched, ['a']);
  });

  test('skips removed and private videos for good', () async {
    final (_, folder) = await addPlaylist('Mix', ['gone', 'private', 'ok']);
    youtube.errors['gone'] =
        'ERROR: This video has been removed for '
        'violating YouTube\'s Terms of Service';
    youtube.errors['private'] = 'ERROR: [youtube] private: Private video';

    expect((await service().run()).end, InfoBackfillEnd.done);
    expect(hasInfo(folder, 'ok'), isTrue);

    clock.now = clock.now.add(const Duration(days: 30));
    await service().run();
    expect(youtube.fetched, ['gone', 'private', 'ok']);
    final status = await InfoBackfillStatus.read(store, now: clock.now);
    expect(status.givenUp, {'gone', 'private'});
  });

  test(
    'a failed video is tried again a day later, three times in all',
    () async {
      final (_, folder) = await addPlaylist('Mix', ['flaky', 'ok']);
      youtube.errors['flaky'] = 'ERROR: [youtube] flaky: Video unavailable';

      await service().run();
      expect(youtube.fetched, ['flaky', 'ok']);
      await service().run();
      expect(youtube.fetched, ['flaky', 'ok'], reason: 'not before a day');

      for (var day = 1; day <= 4; day++) {
        clock.now = clock.now.add(const Duration(days: 1));
        await service().run();
      }
      expect(youtube.fetched.where((id) => id == 'flaky').length, 3);
      expect((await InfoBackfillStatus.read(store, now: clock.now)).givenUp, {
        'flaky',
      });

      // Works on a later day after all: saved, and forgotten as a failure.
      final (_, other) = await addPlaylist('Other', ['flaky2']);
      youtube.errors['flaky2'] = 'ERROR: Video unavailable';
      await service().run();
      youtube.errors.remove('flaky2');
      clock.now = clock.now.add(const Duration(days: 1));
      await service().run();
      expect(hasInfo(other, 'flaky2'), isTrue);
      expect(hasInfo(folder, 'flaky'), isFalse);
      expect((await InfoBackfillStatus.read(store, now: clock.now)).givenUp, {
        'flaky',
      });
    },
  );

  test('backs off when YouTube asks to slow down, and resumes after the '
      'pause', () async {
    final (_, folder) = await addPlaylist('Mix', ['a', 'b', 'c']);
    youtube.errors['a'] = "Sign in to confirm you're not a bot";

    final run = await service().run();
    expect(run.end, InfoBackfillEnd.slowedDown);
    expect(youtube.fetched, ['a']);
    final until = run.pausedUntil!;
    expect(until.difference(clock.now), _seconds(30 * 60, 36 * 60));

    // Remembered: a new run does not ask YouTube before the pause ends.
    clock.now = until.subtract(const Duration(minutes: 1));
    expect((await service().run()).end, InfoBackfillEnd.slowedDown);
    expect(youtube.fetched, ['a']);
    expect(
      (await InfoBackfillStatus.read(store, now: clock.now)).pausedUntil,
      until,
    );

    // After it the others go first; the video that got the answer waits a
    // day, without counting as a failure.
    clock.now = until.add(const Duration(seconds: 1));
    youtube.errors.clear();
    expect((await service().run()).end, InfoBackfillEnd.done);
    expect(youtube.fetched, ['a', 'b', 'c']);
    clock.now = clock.now.add(const Duration(days: 1));
    await service().run();
    expect(youtube.fetched, ['a', 'b', 'c', 'a']);
    expect(hasInfo(folder, 'a'), isTrue);
  });

  test('many failures in a row pause like a slow-down request', () async {
    await addPlaylist('Mix', ['a', 'b', 'c', 'd']);
    for (final id in ['a', 'b', 'c', 'd']) {
      youtube.errors[id] = 'ERROR: something new broke';
    }
    final run =
        await service(
          pacing: const InfoBackfillPacing(failuresBeforePause: 3),
        ).run();
    expect(run.end, InfoBackfillEnd.slowedDown);
    expect(youtube.fetched, ['a', 'b', 'c']);
  });

  test('no network is not held against the video', () async {
    await addPlaylist('Mix', ['a', 'b']);
    youtube.errors['a'] = 'ERROR: <urlopen error timed out>';
    expect((await service().run()).end, InfoBackfillEnd.noWifi);
    youtube.errors.clear();
    expect((await service().run()).end, InfoBackfillEnd.done);
    expect(youtube.fetched, ['a', 'a', 'b']);
  });

  test('a video in two folders is fetched once, and a folder that has it '
      'gives it to the other without network', () async {
    final (_, audio) = await addPlaylist('Audio', ['a', 'b']);
    final (_, video) = await addPlaylist('Video', ['a', 'b'], withInfo: {'b'});

    final run = await service().run();
    expect(run.end, InfoBackfillEnd.done);
    expect(youtube.fetched, ['a']);
    expect(run.copied, 1);
    for (final folder in [audio, video]) {
      expect(hasInfo(folder, 'a'), isTrue);
      expect(hasInfo(folder, 'b'), isTrue);
    }
    expect(
      File(LibraryLayout.infoJsonPath(audio, 'b')).readAsStringSync(),
      contains('kept'),
    );
  });

  group('the library changing during a run', () {
    test('a file a download saved meanwhile is neither fetched again nor '
        'overwritten', () async {
      final (_, folder) = await addPlaylist('Mix', ['a', 'b', 'c']);
      const downloaded = '{"id": "a", "height": 1080}';
      youtube.whileFetching = (id) async {
        if (id != 'a') return;
        // "Download again" of a and b finish while a is fetched.
        for (final other in ['a', 'b']) {
          await File(
            LibraryLayout.infoJsonPath(folder, other),
          ).writeAsString(downloaded.replaceAll('"a"', '"$other"'));
        }
      };

      final run = await service().run();

      expect(run.end, InfoBackfillEnd.done);
      expect(youtube.fetched, ['a', 'c']);
      expect(run.saved, 1);
      expect(
        File(LibraryLayout.infoJsonPath(folder, 'a')).readAsStringSync(),
        downloaded,
      );
      expect(
        File(LibraryLayout.infoJsonPath(folder, 'b')).readAsStringSync(),
        contains('1080'),
      );
      expect(hasInfo(folder, 'c'), isTrue);
    });

    test('a track removed, replaced or moved meanwhile gets no file in its '
        'old place', () async {
      final (playlist, folder) = await addPlaylist('Mix', [
        'a',
        'gone',
        'mine',
        'moved',
        'later',
      ]);
      final (other, otherFolder) = await addPlaylist('Other', const []);
      youtube.whileFetching = (id) async {
        if (id == 'a') {
          // An update removes one track, moves another; the owner puts
          // their own file in place of a third.
          await (db.delete(db.tracks)
            ..where((t) => t.videoId.equals('gone'))).go();
          await (db.update(db.tracks)..where(
            (t) => t.videoId.equals('mine'),
          )).write(const TracksCompanion(isLocalReplacement: Value(true)));
          await (db.update(db.tracks)..where(
            (t) => t.videoId.equals('moved'),
          )).write(TracksCompanion(playlistId: Value(other.id)));
        }
        if (id == 'later') {
          // Removed while its own info is fetched.
          await (db.delete(db.tracks)
            ..where((t) => t.videoId.equals('later'))).go();
        }
      };

      final run = await service().run();

      expect(run.end, InfoBackfillEnd.done);
      expect(youtube.fetched, ['a', 'moved', 'later']);
      expect(hasInfo(folder, 'a'), isTrue);
      for (final id in ['gone', 'mine', 'moved', 'later']) {
        expect(hasInfo(folder, id), isFalse, reason: id);
      }
      expect(hasInfo(otherFolder, 'moved'), isTrue);
      expect(run.saved, 2);
      expect(playlist.id, isNot(other.id));
    });

    test('a description another folder got meanwhile is copied instead of '
        'fetched', () async {
      final (_, audio) = await addPlaylist('Audio', ['a', 'b']);
      final (_, video) = await addPlaylist('Video', ['b']);
      youtube.whileFetching = (id) async {
        if (id == 'a') {
          await File(
            LibraryLayout.infoJsonPath(video, 'b'),
          ).writeAsString('{"id": "b", "description": "downloaded"}');
        }
      };

      final run = await service().run();

      expect(youtube.fetched, ['a']);
      expect(run.copied, 1);
      expect(
        File(LibraryLayout.infoJsonPath(audio, 'b')).readAsStringSync(),
        contains('downloaded'),
      );
    });
  });

  test('never creates a playlist folder that is gone', () async {
    final (_, folder) = await addPlaylist('Mix', ['a']);
    await Directory(folder).delete(recursive: true);
    await service().run();
    expect(youtube.fetched, isEmpty);
    expect(Directory(folder).existsSync(), isFalse);
  });

  test('inserted local files have no YouTube info', () async {
    final (playlist, _) = await addPlaylist('Mix', const []);
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: '${forcedInsertVideoIdPrefix}x',
      filePath: p.join(playlist.outputPath, 'x.m4a'),
      status: 'complete',
    );
    await service().run();
    expect(youtube.fetched, isEmpty);
  });

  group('scheduler', () {
    test('tries again after waiting, and stops for good', () async {
      await addPlaylist('Mix', ['a']);
      onWifi = false;
      final scheduler = InfoBackfillScheduler(
        service(),
        firstDelay: Duration.zero,
        retryDelay: const Duration(milliseconds: 10),
      );
      scheduler.start();
      await _until(() => scheduler.lastRun != null);
      expect(scheduler.lastRun?.end, InfoBackfillEnd.noWifi);
      onWifi = true;
      await _until(() => scheduler.lastRun?.end == InfoBackfillEnd.done);
      expect(youtube.fetched, ['a']);

      // Nothing left: coming back to the app soon after does not look again.
      scheduler.wake();
      scheduler.stop();
      await scheduler.runNow();
      expect(youtube.fetched, ['a']);
    });
  });
}

/// A duration from [low] to [high] seconds, both included.
Matcher _seconds(num low, num high) => predicate<Duration>(
  (d) => d.inMilliseconds >= low * 1000 && d.inMilliseconds <= high * 1000,
  'between $low and $high seconds',
);

/// Waits (in real time) until [condition] holds.
Future<void> _until(bool Function() condition) async {
  final waited = Stopwatch()..start();
  while (!condition()) {
    if (waited.elapsed > const Duration(seconds: 5)) {
      fail('timed out waiting');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
