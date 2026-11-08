import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/chapter_preview_player.dart';

import 'playback_fakes.dart';

void main() {
  late FakePlayer player;
  late int mainPauses;

  ChapterPreviewPlayer preview(
    FakeAsync async, {
    Duration openTimeout = const Duration(seconds: 8),
  }) => ChapterPreviewPlayer(
    filePath: '/music/mix.mp3',
    player: player,
    pauseMainPlayer: () async => mainPauses++,
    openTimeout: openTimeout,
    nowMs: () => async.elapsed.inMilliseconds,
  );

  setUp(() {
    player = FakePlayer(duration: const Duration(minutes: 10));
    mainPauses = 0;
  });

  test('opens the file once, paused, and reports its length', () {
    fakeAsync((async) {
      final p = preview(async);
      expect(p.duration, Duration.zero);
      p.ensureOpen();
      p.ensureOpen();
      async.flushMicrotasks();
      expect(player.opened, hasLength(1));
      expect(player.opened.single.uri, endsWith('/music/mix.mp3'));
      expect(player.state.playing, isFalse);
      expect(p.duration, const Duration(minutes: 10));
      expect(mainPauses, 0, reason: 'opening alone does not pause the app');
    });
  });

  test('waits for the length when the player reports it late', () {
    fakeAsync((async) {
      player = FakePlayer(duration: Duration.zero);
      final p = preview(async);
      var done = false;
      p.ensureOpen().then((_) => done = true);
      async.elapse(const Duration(seconds: 1));
      expect(done, isFalse);
      player.stream.durations.add(const Duration(minutes: 3));
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(p.duration, const Duration(minutes: 3));
    });
  });

  test('gives up after the timeout and can try again', () {
    fakeAsync((async) {
      player = FakePlayer(duration: Duration.zero);
      final p = preview(async, openTimeout: const Duration(seconds: 2));
      Object? error;
      p.ensureOpen().catchError((Object e) => error = e);
      async.elapse(const Duration(seconds: 3));
      expect(error, isA<StateError>());
      expect((error as StateError).message, 'Could not open the file');
      var done = false;
      p.ensureOpen().then((_) => done = true);
      player.stream.durations.add(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(player.opened, hasLength(2));
    });
  });

  test('playRange seeks exactly, plays and stops at the end', () {
    fakeAsync((async) {
      final p = preview(async);
      final ranges = <PreviewRange?>[];
      p.activeRangeStream.listen(ranges.add);
      p.playRange(10000, endMs: 12000);
      async.flushMicrotasks();
      expect(mainPauses, 1);
      expect(player.seeks, [const Duration(seconds: 10)]);
      expect(p.isPlaying, isTrue);
      expect(p.activeRange, (startMs: 10000, endMs: 12000, loop: false));

      async.elapse(const Duration(milliseconds: 1000));
      expect(p.positionMs, 11000);
      player.tick(const Duration(milliseconds: 10990));
      async.elapse(const Duration(milliseconds: 900));
      expect(p.isPlaying, isTrue);
      async.elapse(const Duration(milliseconds: 200));
      expect(p.isPlaying, isFalse);
      expect(player.seeks.last, const Duration(seconds: 12));
      expect(p.positionMs, 12000);
      expect(p.activeRange, isNull);
      expect(ranges.last, isNull);
    });
  });

  test('a position report at the end stops before the timer', () {
    fakeAsync((async) {
      final p = preview(async);
      p.playRange(5000, endMs: 8000);
      async.flushMicrotasks();
      player.tick(const Duration(milliseconds: 7990));
      async.flushMicrotasks();
      expect(p.isPlaying, isFalse);
      expect(player.seeks.last, const Duration(seconds: 8));
    });
  });

  test('a stale stop timer never pauses a newer preview', () {
    fakeAsync((async) {
      final p = preview(async);
      p.playRange(0, endMs: 2000);
      async.elapse(const Duration(milliseconds: 500));
      p.playRange(30000, endMs: 40000);
      async.flushMicrotasks();
      final pauses = player.pauses;
      async.elapse(const Duration(seconds: 3));
      expect(player.pauses, pauses);
      expect(p.isPlaying, isTrue);
      expect(p.activeRange?.startMs, 30000);

      p.pause();
      async.flushMicrotasks();
      expect(p.activeRange, isNull);
      p.play();
      async.elapse(const Duration(seconds: 20));
      expect(p.isPlaying, isTrue, reason: 'free play has no end');
    });
  });

  test('loop jumps back to the start instead of stopping', () {
    fakeAsync((async) {
      final p = preview(async);
      p.playRange(1000, endMs: 3000, loop: true);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      player.tick(const Duration(milliseconds: 2000));
      async.elapse(const Duration(milliseconds: 1000));
      expect(p.isPlaying, isTrue);
      expect(player.seeks, hasLength(2));
      expect(player.seeks.last, const Duration(seconds: 1));
      expect(p.activeRange?.loop, isTrue);
      async.elapse(const Duration(milliseconds: 900));
      player.tick(const Duration(milliseconds: 2990));
      async.flushMicrotasks();
      expect(player.seeks, hasLength(3));
      expect(player.seeks.last, const Duration(seconds: 1));
      expect(p.isPlaying, isTrue);
      expect(player.pauses, 0, reason: 'a loop never pauses');
    });
  });

  test('ranges are clamped to the file', () {
    fakeAsync((async) {
      final p = preview(async);
      p.playRange(-4000, endMs: 0);
      async.flushMicrotasks();
      expect(p.isPlaying, isFalse, reason: 'nothing to play before 0');
      expect(p.positionMs, 0);
      p.playRange(9 * 60000, endMs: 11 * 60000);
      async.flushMicrotasks();
      expect(p.activeRange?.endMs, 10 * 60000);
    });
  });

  test('a range to the end of the file stops when the file ends', () {
    fakeAsync((async) {
      final p = preview(async);
      p.playRange(590000);
      async.flushMicrotasks();
      expect(p.activeRange?.endMs, isNull);
      player.finish();
      async.flushMicrotasks();
      expect(p.isPlaying, isFalse);
      expect(p.activeRange, isNull);
    });
  });

  test('seek clamps, ends a range and keeps the play state', () {
    fakeAsync((async) {
      final p = preview(async);
      final positions = <int>[];
      p.positionMsStream.listen(positions.add);
      p.playRange(1000, endMs: 5000);
      async.flushMicrotasks();
      p.seek(-50);
      async.flushMicrotasks();
      expect(player.seeks.last, Duration.zero);
      expect(p.activeRange, isNull);
      expect(p.isPlaying, isTrue);
      p.seek(999999999);
      async.flushMicrotasks();
      expect(player.seeks.last, const Duration(minutes: 10));
      expect(positions, containsAllInOrder([1000, 0, 600000]));
      async.elapse(const Duration(seconds: 10));
      expect(p.isPlaying, isTrue, reason: 'the old range end is gone');
    });
  });

  test('ignores position reports left over from before a seek', () {
    fakeAsync((async) {
      player = _LaggyPlayer(duration: const Duration(minutes: 10));
      final p = preview(async);
      p.seek(50000);
      async.flushMicrotasks();
      // A report from the old place arrives after the seek was sent.
      (player as _LaggyPlayer).staleMs = 50020;
      final positions = <int>[];
      p.positionMsStream.listen(positions.add);
      p.playRange(100000, endMs: 110000);
      async.flushMicrotasks();
      expect(p.positionMs, 100000);
      expect(positions, isNot(contains(50020)));
      expect(p.isPlaying, isTrue);
    });
  });

  test('estimates the position between reports while playing', () {
    fakeAsync((async) {
      final p = preview(async);
      p.seek(20000);
      async.flushMicrotasks();
      p.play();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 300));
      expect(p.positionMs, 20300);
      async.elapse(const Duration(seconds: 5));
      expect(p.positionMs, 21000, reason: 'no guessing far past reports');
      player.tick(const Duration(milliseconds: 25300));
      expect(p.positionMs, 25300);
      p.pause();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(p.positionMs, 25300);
    });
  });

  test('a range comes to rest on restMs and counts as parked', () {
    fakeAsync((async) {
      final p = preview(async);
      p.playRange(60000, endMs: 64000, restMs: 60000);
      async.flushMicrotasks();
      expect(p.restMs, 60000);
      expect(p.parked, isFalse);
      bool? parkedWhenPaused;
      p.playingStream.listen((playing) {
        if (!playing) parkedWhenPaused = p.parked;
      });
      player.tick(const Duration(milliseconds: 63990));
      async.flushMicrotasks();
      expect(p.isPlaying, isFalse);
      expect(parkedWhenPaused, isTrue, reason: 'already parked on the stop');
      expect(player.seeks.last, const Duration(seconds: 60));
      expect(p.positionMs, 60000);
      expect(p.parked, isTrue);
      expect(p.restMs, isNull, reason: 'no range any more');

      // Anything the user does next is a position they chose.
      p.play();
      async.flushMicrotasks();
      expect(p.parked, isFalse);
      p.pause();
      async.flushMicrotasks();
      expect(p.parked, isFalse);
      p.seek(1000, park: true);
      async.flushMicrotasks();
      expect(p.parked, isTrue);
      p.seek(2000);
      async.flushMicrotasks();
      expect(p.parked, isFalse);
    });
  });

  test('without restMs a range rests on its end', () {
    fakeAsync((async) {
      final p = preview(async);
      p.playRange(5000, endMs: 8000);
      async.flushMicrotasks();
      player.tick(const Duration(milliseconds: 7990));
      async.flushMicrotasks();
      expect(p.positionMs, 8000);
      expect(p.parked, isTrue);
    });
  });

  test('moveRest changes where a playing range rests', () {
    fakeAsync((async) {
      final p = preview(async);
      p.playRange(60000, endMs: 64000, restMs: 60000);
      async.flushMicrotasks();
      player.tick(const Duration(milliseconds: 61500));
      final seeks = player.seeks.length;
      p.moveRest(61500);
      expect(player.seeks, hasLength(seeks), reason: 'playing goes on');
      expect(p.isPlaying, isTrue);
      expect(p.activeRange?.endMs, 64000);
      player.tick(const Duration(milliseconds: 63990));
      async.flushMicrotasks();
      expect(p.positionMs, 61500);
      expect(p.parked, isTrue);
      p.moveRest(1000);
      expect(p.restMs, isNull, reason: 'nothing to move without a range');
    });
  });

  test('a pause rests on the last report, not on a guess past it', () {
    fakeAsync((async) {
      final p = preview(async);
      p.play();
      async.flushMicrotasks();
      player.tick(const Duration(milliseconds: 61000));
      async.elapse(const Duration(milliseconds: 110));
      expect(p.positionMs, 61110);
      p.pause();
      async.flushMicrotasks();
      expect(p.positionMs, 61000);
      async.elapse(const Duration(seconds: 2));
      expect(p.positionMs, 61000);
    });
  });

  test('resuming seeks to the paused spot before playing', () {
    fakeAsync((async) {
      final p = preview(async);
      p.play();
      async.flushMicrotasks();
      player.tick(const Duration(milliseconds: 42000));
      p.pause();
      async.flushMicrotasks();
      final order = <String>[];
      player.stream.positions.stream.listen((d) => order.add('seek $d'));
      player.stream.playingChanges.stream.listen((on) => order.add('$on'));
      p.play();
      async.flushMicrotasks();
      expect(player.seeks.last, const Duration(milliseconds: 42000));
      expect(order.first, startsWith('seek 0:00:42'));
      expect(order, contains('true'));
      expect(p.isPlaying, isTrue);
      expect(p.positionMs, 42000);
    });
  });

  test('the estimate never runs backwards over small corrections', () {
    fakeAsync((async) {
      final p = preview(async);
      p.play();
      async.flushMicrotasks();
      player.tick(const Duration(milliseconds: 61000));
      var last = p.positionMs;
      var real = 61000;
      for (var i = 0; i < 12; i++) {
        for (var f = 0; f < 4; f++) {
          async.elapse(const Duration(milliseconds: 16));
          expect(p.positionMs, greaterThanOrEqualTo(last));
          last = p.positionMs;
        }
        real += 64;
        // Late reports: up to 40 ms behind the time that passed.
        player.tick(Duration(milliseconds: real - (i.isOdd ? 40 : 0)));
        expect(p.positionMs, greaterThanOrEqualTo(last));
        last = p.positionMs;
      }
      expect((p.positionMs - real).abs(), lessThanOrEqualTo(40));
      // A big jump back (a real move) is shown at once.
      player.tick(const Duration(milliseconds: 30000));
      expect(p.positionMs, 30000);
    });
  });

  test('a failing main-player pause does not block the preview', () {
    fakeAsync((async) {
      final p = ChapterPreviewPlayer(
        filePath: '/music/mix.mp3',
        player: player,
        pauseMainPlayer: () => Future.error(StateError('no playback')),
        nowMs: () => async.elapsed.inMilliseconds,
      );
      p.playRange(0, endMs: 4000);
      async.flushMicrotasks();
      expect(p.isPlaying, isTrue);
    });
  });

  test('the main player starting again pauses the preview', () {
    fakeAsync((async) {
      final main = StreamController<bool>.broadcast(sync: true);
      final p = ChapterPreviewPlayer(
        filePath: '/music/mix.mp3',
        player: player,
        pauseMainPlayer: () async => main.add(false),
        mainPlaying: () => main.stream,
        nowMs: () => async.elapsed.inMilliseconds,
      );
      p.play();
      async.flushMicrotasks();
      expect(p.isPlaying, isTrue);
      main.add(false);
      async.flushMicrotasks();
      expect(p.isPlaying, isTrue, reason: 'only a start counts');
      main.add(true);
      async.flushMicrotasks();
      expect(p.isPlaying, isFalse);
      p.dispose();
      async.flushMicrotasks();
      main.close();
    });
  });

  test('dispose releases the player and later calls do nothing', () {
    fakeAsync((async) {
      final p = preview(async);
      p.playRange(0, endMs: 4000);
      async.flushMicrotasks();
      p.dispose();
      async.flushMicrotasks();
      expect(player.stream.positions.isClosed, isTrue);
      Object? error;
      p.ensureOpen().catchError((Object e) => error = e);
      p.pause();
      p.dispose();
      async.elapse(const Duration(seconds: 10));
      expect(error, isA<StateError>());
    });
  });
}

/// Reports a stale position while a seek is being sent, like mpv does
/// for a moment after a seek.
class _LaggyPlayer extends FakePlayer {
  _LaggyPlayer({super.duration});

  int? staleMs;

  @override
  Future<void> seek(Duration position) {
    final stale = staleMs;
    if (stale != null) stream.positions.add(Duration(milliseconds: stale));
    return super.seek(position);
  }
}
