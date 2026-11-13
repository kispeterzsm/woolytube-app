import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapter_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/recognition/audio_window_decoder.dart';
import 'package:woolytube/services/recognition/decoder_accuracy.dart';
import 'package:woolytube/services/recognition/recognition_files.dart';
import 'package:woolytube/services/recognition/shazam_client.dart';
import 'package:woolytube/services/recognition/shazam_signature.dart';
import 'package:woolytube/services/recognition/song_recognition_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';

import '../helpers/test_database.dart';

/// A 300 s file: a tone everywhere except one second of silence at 130 s.
class FakeDecoder implements AudioWindowDecoder {
  int decodeCalls = 0;
  int lastStartMs = 0;
  @override
  Future<Int16List> decode(
    String path, {
    required Duration start,
    required Duration duration,
  }) async {
    decodeCalls++;
    lastStartMs = start.inMilliseconds;
    final startSample = start.inMilliseconds * 16;
    return pcmFromGenerator(duration.inMilliseconds * 16, (i) {
      final t = (startSample + i) / 16000;
      if (t >= 130 && t < 131) return 0;
      return (8000 * sin(2 * pi * 440 * (startSample + i) / 16000)).round();
    });
  }

  @override
  Future<Duration?> probeDuration(String path) async =>
      const Duration(seconds: 300);
}

class FakeRecognizer implements ShazamRecognizer {
  FakeRecognizer(this.decoder, this.byStartMs);
  final FakeDecoder decoder;
  final Map<int, Map<String, dynamic>> byStartMs;
  final List<int> calls = [];

  /// Every lookup, failed ones included, by sample start.
  final List<int> attempts = [];
  int? failAtCall;

  /// Errors thrown by the lookup with that sequence number.
  final Map<int, Object> failures = {};

  /// Decides per sequence number whether the lookup fails, after
  /// [failures].
  Object? Function(int index)? failWhen;
  Completer<void>? gate;
  int _sequence = 0;

  @override
  Future<ShazamResult> recognize(
    ShazamSignature signature, {
    Future<void>? cancelled,
  }) async {
    final index = _sequence++;
    if (gate != null) await gate!.future;
    // The service decodes a window right before recognizing it.
    final start = decoder.lastStartMs;
    attempts.add(start);
    if (failAtCall == index) {
      throw const ShazamHttpException(400, 'bad request');
    }
    final failure = failures[index] ?? failWhen?.call(index);
    if (failure != null) throw failure;
    calls.add(start);
    return ShazamResult.fromJson(byStartMs[start]!);
  }
}

class FakeNotifier implements ScanForegroundNotifier {
  final events = <String>[];
  @override
  Future<void> start(String label) async => events.add('start');
  @override
  Future<void> update(
    String label,
    int current,
    int total, {
    String? detail,
  }) async => events.add(
    detail == null
        ? 'update $current/$total'
        : 'update $current/$total $detail',
  );
  @override
  Future<void> stop() async => events.add('stop');
}

/// Answers like Shazam behind the real [ShazamPacer], so the time the
/// client spends pacing passes on the test clock too.
class PacedRecognizer implements ShazamRecognizer {
  PacedRecognizer(this.pacer, this.clock, this.respond);
  final ShazamPacer pacer;
  final DateTime Function() clock;

  /// The answer to the request with that sequence number; may throw.
  final Map<String, dynamic> Function(int index) respond;

  /// When each request went out.
  final List<DateTime> sentAt = [];

  @override
  Future<ShazamResult> recognize(
    ShazamSignature signature, {
    Future<void>? cancelled,
  }) async {
    await pacer.waitTurn(cancelled: cancelled);
    sentAt.add(clock());
    try {
      return ShazamResult.fromJson(respond(sentAt.length - 1));
    } on ShazamHttpException catch (e) {
      if (e.isRateLimited) pacer.slowDown();
      rethrow;
    }
  }
}

Map<String, dynamic> song(String key, String title, double offset) => {
  'track': {'key': key, 'title': title, 'subtitle': 'Artist'},
  'matches': [
    {'id': 'ref-$key', 'offset': offset},
  ],
};

void main() {
  late AppDatabase db;
  late Directory dir;
  late Track track;
  late FakeDecoder decoder;
  late FakeRecognizer recognizer;
  late FakeNotifier notifier;
  late SongRecognitionService service;

  /// Every wait the service asked for; none of them really sleeps unless a
  /// test swaps [delayImpl].
  late List<Duration> waits;
  late Future<void> Function(Duration) delayImpl;
  final now = DateTime.utc(2026, 11, 7, 12);

  /// The test clock: starts at [now] and moves on with every wait, the
  /// service's and a [PacedRecognizer]'s alike.
  late DateTime clockNow;

  SongRecognitionService serviceWith(
    ShazamRecognizer recognizer, {
    List<Duration>? rateLimitBackoff,
    Duration? rateLimitBudget,
  }) => SongRecognitionService(
    db,
    decoder: decoder,
    recognizer: recognizer,
    rootDirectory: () async => dir,
    notifier: notifier,
    rateLimitBackoff:
        rateLimitBackoff ??
        const [
          Duration(seconds: 30),
          Duration(seconds: 60),
          Duration(seconds: 120),
          Duration(seconds: 240),
          Duration(seconds: 300),
        ],
    rateLimitBudget: rateLimitBudget ?? const Duration(minutes: 20),
    delay: (d) {
      waits.add(d);
      clockNow = clockNow.add(d);
      return delayImpl(d);
    },
    clock: () => clockNow,
  );

  setUp(() async {
    db = openTestDatabase();
    dir = await Directory.systemTemp.createTemp('woolytube-recognition-');
    final media = await File(
      '${dir.path}/00001_mix.m4a',
    ).writeAsBytes(List.filled(4096, 7));
    final playlist = await insertTestPlaylist(db, outputPath: dir.path);
    track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      status: 'complete',
      filePath: media.path,
      durationSeconds: 300,
    );
    decoder = FakeDecoder();
    // Grid for 300 s: 30, 90, 150, 210, 270 and the last window at 288.
    recognizer = FakeRecognizer(decoder, {
      30000: song('A', 'First song', 30),
      90000: song('A', 'First song', 90),
      150000: song('B', 'Second song', 19.5),
      210000: song('B', 'Second song', 79.5),
      270000: song('B', 'Second song', 139.5),
      288000: song('B', 'Second song', 157.5),
    });
    notifier = FakeNotifier();
    waits = [];
    delayImpl = (_) async {};
    clockNow = now;
    service = serviceWith(recognizer);
  });

  tearDown(() async {
    service.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  test('plans the prototype sampling grid', () {
    expect(service.sampleStartsMs(300000), [
      30000,
      90000,
      150000,
      210000,
      270000,
      288000,
    ]);
    expect(service.sampleStartsMs(20000), [8000]);
    expect(service.sampleStartsMs(3217000).length, 54);
  });

  test(
    'scans, snaps the boundary to the quiet gap, and caches lookups',
    () async {
      final progress = <RecognitionProgress>[];
      final sub = service.progressStream.listen(progress.add);
      final run = await service.scan(track);
      await sub.cancel();

      expect(run.proposals.length, 2);
      expect(run.proposals.first.title, 'Artist — First song');
      expect(run.proposals.first.startMs, 0);
      expect(run.proposals.last.title, 'Artist — Second song');
      expect(run.proposals.last.boundaryMethod, 'quiet-transition');
      expect(run.proposals.last.startMs, 130900);
      expect(run.proposals.last.endMs, 300000);
      expect(run.sampleCount, 6);
      expect(run.matchedSamples, 6);
      expect(run.epoch, 0);
      expect(recognizer.calls.length, 6);
      expect(progress.first.phase, RecognitionPhase.sampling);
      expect(progress.last.phase, RecognitionPhase.done);
      expect(notifier.events.first, 'start');
      expect(notifier.events.last, 'stop');
      expect(service.isScanning, isFalse);

      // A second scan is served entirely from the cache.
      final decodesBefore = decoder.decodeCalls;
      final again = await service.scan(track);
      expect(recognizer.calls.length, 6);
      expect(decoder.decodeCalls, decodesBefore);
      expect(again.proposals.last.startMs, 130900);
      expect((await service.loadRun(track))!.runId, again.runId);

      // The run applies through the chapter service.
      final chapters = ChapterService(db, YtDlpService());
      expect(
        await chapters.applyRecognition(
          track,
          runId: again.runId,
          epoch: again.epoch,
          fileKey: again.fileKey,
          durationMs: again.durationMs,
          proposals: again.proposals.map((c) => c.toChapter()).toList(),
        ),
        isTrue,
      );
      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.active.map((c) => c.title), [
        'Artist — First song',
        'Artist — Second song',
      ]);
      expect(data.active.every((c) => c.origin == ChapterOrigin.auto), isTrue);
    },
  );

  test('a failed lookup keeps earlier results and resumes later', () async {
    recognizer.failAtCall = 3;
    await expectLater(service.scan(track), throwsA(isA<ShazamHttpException>()));
    expect(service.currentProgress!.phase, RecognitionPhase.failed);
    expect(notifier.events.last, 'stop');
    expect(recognizer.calls.length, 3);
    // An error retrying cannot fix is not retried.
    expect(waits, isEmpty);

    recognizer.failAtCall = null;
    final run = await service.scan(track);
    expect(run.proposals.length, 2);
    // Only the three missing windows were looked up again.
    expect(recognizer.calls.length, 6);
  });

  test('cancel stops between lookups and reports it', () async {
    recognizer.gate = Completer<void>();
    final future = service.scan(track);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.isScanning, isTrue);
    service.cancel();
    recognizer.gate!.complete();
    await expectLater(future, throwsA(isA<RecognitionCancelled>()));
    expect(service.currentProgress!.phase, RecognitionPhase.cancelled);
    expect(service.isScanning, isFalse);
    expect(await service.loadRun(track), isNull);
  });

  group('rate limits and network errors', () {
    const tooMany = ShazamHttpException(429, '');

    test('a 429 waits, then retries the same sample and finishes', () async {
      recognizer.failures[2] = tooMany;
      final progress = <RecognitionProgress>[];
      final sub = service.progressStream.listen(progress.add);
      final run = await service.scan(track);
      await sub.cancel();

      expect(run.proposals.length, 2);
      expect(run.sampleCount, 6);
      expect(recognizer.attempts, [
        30000,
        90000,
        150000,
        150000,
        210000,
        270000,
        288000,
      ]);
      expect(waits, [const Duration(seconds: 30)]);
      final waiting = progress.singleWhere(
        (e) => e.phase == RecognitionPhase.waiting,
      );
      expect(waiting.running, isTrue);
      expect(waiting.completed, 2);
      expect(waiting.total, 6);
      expect(waiting.waitReason, RecognitionWaitReason.rateLimited);
      expect(waiting.resumeAt, now.add(const Duration(seconds: 30)));
      // Back to sampling once the wait is over.
      final after = progress[progress.indexOf(waiting) + 1];
      expect(after.phase, RecognitionPhase.sampling);
      expect(after.completed, 2);
      expect(progress.last.phase, RecognitionPhase.done);
      final waitEvent = notifier.events.indexWhere(
        (e) => e.startsWith('update 2/6 Shazam asked us to slow down.'),
      );
      expect(waitEvent, isNot(-1));
      // Android keeps the last detail while the sample number stays, so the
      // retry replaces the stale "Retrying at" with a detail of its own.
      expect(
        notifier.events[waitEvent + 1],
        'update 2/6 Retrying sample 3 of 6…',
      );
      expect(notifier.events.sublist(waitEvent), isNot(contains('update 2/6')));
      expect(notifier.events[waitEvent + 2], 'update 3/6');
    });

    test('a Retry-After longer than the backoff is honoured', () async {
      recognizer.failures[1] = const ShazamHttpException(
        429,
        '',
        retryAfter: Duration(seconds: 45),
      );
      recognizer.failures[3] = const ShazamHttpException(
        503,
        '',
        retryAfter: Duration(seconds: 90),
      );
      // A shorter one never undercuts the backoff, which keeps growing:
      // "retry now" is backed off like a 429 without a header.
      recognizer.failures[5] = const ShazamHttpException(
        429,
        '',
        retryAfter: Duration.zero,
      );
      recognizer.failures[6] = const ShazamHttpException(
        429,
        '',
        retryAfter: Duration(seconds: 10),
      );
      recognizer.failures[7] = tooMany;
      final run = await service.scan(track);
      expect(run.sampleCount, 6);
      expect(waits, const [
        Duration(seconds: 45),
        Duration(seconds: 90),
        Duration(seconds: 30),
        Duration(seconds: 60),
        Duration(seconds: 120),
      ]);
    });

    test('the backoff grows, repeats its last step, and resets after a '
        'success', () async {
      // Six 429s in a row on the second sample, then one on the third.
      for (var i = 1; i <= 6; i++) {
        recognizer.failures[i] = tooMany;
      }
      recognizer.failures[8] = tooMany;
      final run = await service.scan(track);
      expect(run.sampleCount, 6);
      expect(waits, const [
        Duration(seconds: 30),
        Duration(seconds: 60),
        Duration(seconds: 120),
        Duration(seconds: 240),
        Duration(seconds: 300),
        Duration(seconds: 300),
        Duration(seconds: 30),
      ]);
      expect(recognizer.calls.length, 6);
    });

    test('gives up after the waiting budget, keeping the lookups so a '
        'rescan resumes', () async {
      recognizer.failWhen = (index) => index >= 2 ? tooMany : null;
      await expectLater(
        service.scan(track),
        throwsA(isA<RecognitionRateLimited>()),
      );
      // 30 + 60 + 120 + 240 + 300 + 300 s; another 300 s would pass 20 min.
      expect(waits.length, 6);
      expect(
        waits.fold<Duration>(Duration.zero, (a, b) => a + b),
        const Duration(seconds: 1050),
      );
      expect(service.currentProgress!.phase, RecognitionPhase.failed);
      expect(
        service.currentProgress!.message,
        'Shazam is limiting requests right now. Progress is saved; '
        'try again later.',
      );
      expect(notifier.events.last, 'stop');
      expect(service.isScanning, isFalse);
      expect(recognizer.calls, [30000, 90000]);
      expect(await service.loadRun(track), isNull);

      recognizer.failWhen = null;
      final run = await service.scan(track);
      expect(run.sampleCount, 6);
      // Only the four missing samples were looked up again.
      expect(recognizer.calls.length, 6);
      expect(recognizer.calls.sublist(2), [150000, 210000, 270000, 288000]);
    });

    test('sustained "retry now" answers give up like plain 429s', () async {
      final pacer = ShazamPacer(
        minimumInterval: const Duration(seconds: 4),
        clock: () => clockNow,
        delay: (d) async => clockNow = clockNow.add(d),
      );
      final paced = PacedRecognizer(
        pacer,
        () => clockNow,
        (index) =>
            index < 2
                ? song('A', 'First song', 30)
                : throw const ShazamHttpException(
                  429,
                  '',
                  retryAfter: Duration.zero,
                ),
      );
      final service = serviceWith(paced);
      addTearDown(service.dispose);
      await expectLater(
        service.scan(track),
        throwsA(isA<RecognitionRateLimited>()),
      );
      // Seven tries in 17.5 min, not one every few seconds.
      final limited = paced.sentAt.sublist(2);
      expect(limited.length, 7);
      expect(
        limited.last.difference(limited.first),
        const Duration(seconds: 1050),
      );
      expect(pacer.interval, const Duration(seconds: 20));
    });

    test('the budget counts pacing time, not just the service waits', () async {
      // A pace slower than the backoff: most of the time goes to pacing.
      final pacer = ShazamPacer(
        minimumInterval: const Duration(seconds: 30),
        clock: () => clockNow,
        delay: (d) async => clockNow = clockNow.add(d),
      );
      final paced = PacedRecognizer(
        pacer,
        () => clockNow,
        (index) =>
            index < 1
                ? song('A', 'First song', 30)
                : throw const ShazamHttpException(429, ''),
      );
      final service = serviceWith(
        paced,
        rateLimitBackoff: const [Duration(seconds: 1)],
        rateLimitBudget: const Duration(minutes: 2),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.scan(track),
        throwsA(isA<RecognitionRateLimited>()),
      );
      // One try every 30 s: 0, 30, 60, 90, 120 s after the first 429;
      // counting the 1 s waits alone would allow 120 tries.
      expect(paced.sentAt.length - 1, 5);
      expect(waits.length, 4);
    });

    test('cancel during the pacing wait ends the scan before another '
        'request', () async {
      final blocked = Completer<void>();
      final pacer = ShazamPacer(
        minimumInterval: const Duration(seconds: 20),
        clock: () => clockNow,
        delay: (d) {
          if (!blocked.isCompleted) blocked.complete();
          return Completer<void>().future;
        },
      );
      final paced = PacedRecognizer(
        pacer,
        () => clockNow,
        (_) => song('A', 'First song', 30),
      );
      final service = serviceWith(paced);
      addTearDown(service.dispose);
      final future = service.scan(track);
      await blocked.future;
      expect(paced.sentAt.length, 1);
      service.cancel();
      await expectLater(future, throwsA(isA<RecognitionCancelled>()));
      expect(service.currentProgress!.phase, RecognitionPhase.cancelled);
      expect(service.isScanning, isFalse);
      expect(paced.sentAt.length, 1);
      expect(notifier.events.last, 'stop');
    });

    test('network errors are retried three times, then fail', () async {
      recognizer.failures[2] = const SocketException('offline');
      recognizer.failures[3] = TimeoutException('slow');
      recognizer.failures[4] = const ShazamHttpException(502, '');
      final run = await service.scan(track);
      expect(run.sampleCount, 6);
      expect(waits, const [
        Duration(seconds: 10),
        Duration(seconds: 30),
        Duration(seconds: 60),
      ]);
      expect(recognizer.attempts.where((s) => s == 150000).length, 4);

      // A fresh file whose third sample never gets through.
      await File(track.filePath!).writeAsBytes(List.filled(4096, 3));
      waits.clear();
      recognizer.failures.clear();
      final base = recognizer.attempts.length;
      recognizer.failWhen =
          (index) =>
              index >= base + 2 ? const ShazamHttpException(500, '') : null;
      final progress = <RecognitionProgress>[];
      final sub = service.progressStream.listen(progress.add);
      await expectLater(
        service.scan(track),
        throwsA(
          isA<ShazamHttpException>().having((e) => e.statusCode, 'status', 500),
        ),
      );
      await sub.cancel();
      expect(waits, const [
        Duration(seconds: 10),
        Duration(seconds: 30),
        Duration(seconds: 60),
      ]);
      expect(
        progress
            .where((e) => e.phase == RecognitionPhase.waiting)
            .map((e) => e.waitReason)
            .toSet(),
        {RecognitionWaitReason.network},
      );
      expect(service.currentProgress!.phase, RecognitionPhase.failed);
      expect(service.currentProgress!.message, 'Shazam returned HTTP 500');
    });

    test('cancel during a wait ends the scan at once as cancelled', () async {
      final never = Completer<void>();
      delayImpl = (_) => never.future;
      recognizer.failures[2] = tooMany;
      final waiting = service.progressStream.firstWhere(
        (e) => e.phase == RecognitionPhase.waiting,
      );
      final future = service.scan(track);
      await waiting;
      expect(service.isScanning, isTrue);
      service.cancel();
      await expectLater(future, throwsA(isA<RecognitionCancelled>()));
      expect(never.isCompleted, isFalse);
      expect(service.currentProgress!.phase, RecognitionPhase.cancelled);
      expect(service.isScanning, isFalse);
      expect(notifier.events.last, 'stop');
      expect(recognizer.attempts, [30000, 90000, 150000]);

      // The next scan starts with a fresh cancel signal and resumes.
      delayImpl = (_) async {};
      final run = await service.scan(track);
      expect(run.sampleCount, 6);
      expect(recognizer.calls.length, 6);
    });
  });

  test(
    'a replaced file gets its own cache and a stale run is dropped',
    () async {
      await service.scan(track);
      expect(await service.loadRun(track), isNotNull);
      await File(track.filePath!).writeAsBytes(List.filled(4096, 9));
      expect(await service.loadRun(track), isNull);
      expect(await service.pruneCache([track]), 1);
    },
  );

  test('a second scan is refused before the first one awaits', () async {
    final first = service.scan(track);
    // Claimed synchronously, before the duration probe answers.
    expect(service.isScanning, isTrue);
    expect(service.scanningTrackId, track.id);
    await expectLater(service.scan(track), throwsA(isA<StateError>()));
    final run = await first;
    expect(run.proposals.length, 2);
    // Every window was looked up once, by the first scan only.
    expect(recognizer.calls.length, 6);
    expect(service.isScanning, isFalse);
    expect(service.scanningTrackId, isNull);
    // The claim is released, so a new scan can start.
    await service.scan(track);
  });

  group('recognizing one chapter', () {
    test('plans new windows inside the chapter, away from the grid', () {
      final grid = service.sampleStartsMs(300000);
      expect(service.rangeSampleStartsMs(60000, 150000, 300000), [
        63000,
        90000,
        102000,
        135000,
      ]);
      for (final (start, end) in [
        (0, 300000),
        (60000, 150000),
        (31000, 89000),
        (200000, 260000),
      ]) {
        final starts = service.rangeSampleStartsMs(start, end, 300000);
        expect(starts, isNotEmpty, reason: '$start-$end');
        expect(starts.length, lessThanOrEqualTo(8 + grid.length));
        for (final s in starts.where((s) => !grid.contains(s))) {
          expect(s, greaterThanOrEqualTo(start + 3000), reason: '$s');
          expect(s + 12000, lessThanOrEqualTo(end - 3000), reason: '$s');
          for (final g in grid) {
            expect((s - g).abs(), greaterThanOrEqualTo(12000), reason: '$s');
          }
        }
        for (final s in starts.where(grid.contains)) {
          expect(s >= start && s + 12000 <= end, isTrue, reason: '$s');
        }
      }
      // Shorter than a window: one window over its middle.
      expect(service.rangeSampleStartsMs(100000, 110000, 300000), [99000]);
      // At the very end only the grid's last window fits.
      expect(service.rangeSampleStartsMs(280000, 300000, 300000), [288000]);
      // Just past the grid window at 30 s, too short to keep clear of it
      // and not holding it whole: one window, as far from it as fits.
      expect(service.rangeSampleStartsMs(31000, 56000, 300000), [41000]);
      for (var start = 0; start < 288000; start += 1000) {
        for (final length in [12000, 18000, 25000, 40000]) {
          final end = min(start + length, 300000);
          expect(
            service.rangeSampleStartsMs(start, end, 300000),
            isNotEmpty,
            reason: '$start-$end',
          );
        }
      }
    });

    test('looks up only new windows, reuses the scan\'s, and changes '
        'nothing', () async {
      final run = await service.scan(track);
      expect(recognizer.calls.length, 6);
      final stored = (await db.getTrack(track.id))!.chaptersJson;
      recognizer.byStartMs.addAll({
        63000: song('A', 'First song', 63),
        102000: song('A', 'First song', 102),
        135000: song('B', 'Second song', 4.5),
      });
      final events = <RecognitionProgress>[];
      final streamed = <RecognitionProgress>[];
      final sub = service.progressStream.listen(streamed.add);
      final result = await service.recognizeRange(
        track,
        startMs: 60000,
        endMs: 150000,
        onProgress: events.add,
      );
      await sub.cancel();

      expect(recognizer.calls.sublist(6), [63000, 102000, 135000]);
      expect(result.sampleCount, 4);
      expect(result.checkedSamples, 4);
      expect(result.limited, isFalse);
      expect(result.mixed, isTrue);
      expect(result.candidates.map((c) => c.title), [
        'Artist — First song',
        'Artist — Second song',
      ]);
      final first = result.candidates.first;
      expect(first.matchedAtMs, [63000, 90000, 102000]);
      expect(first.songStartMs, 0);
      expect(first.consistent, isTrue);
      expect(result.candidates.last.songStartMs, 130500);
      expect(result.candidates.last.consistent, isFalse);
      expect(events.last.completed, 4);
      expect(events.last.total, 4);
      // The scan's progress, run, chapters and epoch are left alone.
      expect(streamed, isEmpty);
      expect((await service.loadRun(track))!.runId, run.runId);
      expect((await db.getTrack(track.id))!.chaptersJson, stored);
      expect(service.isScanning, isFalse);

      // Asked again, everything comes from the cache.
      await service.recognizeRange(track, startMs: 60000, endMs: 150000);
      expect(recognizer.calls.length, 9);
    });

    test('shares the scan\'s lock and can be cancelled', () async {
      recognizer.byStartMs[63000] = song('A', 'First song', 63);
      recognizer.gate = Completer<void>();
      final scan = service.scan(track);
      await expectLater(
        service.recognizeRange(track, startMs: 60000, endMs: 150000),
        throwsA(isA<StateError>()),
      );
      recognizer.gate!.complete();
      await scan;

      recognizer.gate = Completer<void>();
      final range = service.recognizeRange(
        track,
        startMs: 60000,
        endMs: 150000,
      );
      expect(service.isScanning, isTrue);
      await expectLater(service.scan(track), throwsA(isA<StateError>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      service.cancel();
      recognizer.gate!.complete();
      await expectLater(range, throwsA(isA<RecognitionCancelled>()));
      expect(service.isScanning, isFalse);
    });

    test('a lasting rate limit returns what was found so far', () async {
      recognizer.byStartMs[63000] = song('A', 'First song', 63);
      recognizer.failWhen =
          (index) => index >= 1 ? const ShazamHttpException(429, '') : null;
      final result = await service.recognizeRange(
        track,
        startMs: 60000,
        endMs: 150000,
        rateLimitBudget: Duration.zero,
      );
      expect(result.limited, isTrue);
      expect(result.checkedSamples, 1);
      expect(result.sampleCount, 4);
      expect(result.candidates.single.matchedAtMs, [63000]);
      expect(service.isScanning, isFalse);
    });
  });

  test('cancel right after starting stops before any lookup', () async {
    final future = service.scan(track);
    service.cancel();
    await expectLater(future, throwsA(isA<RecognitionCancelled>()));
    expect(recognizer.calls, isEmpty);
    expect(service.isScanning, isFalse);
  });

  test('the silence pass decodes long stretches in bounded chunks', () async {
    // 600 s where every sample finds a different song than the one before,
    // so all change brackets merge into one 574 s stretch. A 0.3 s gap
    // straddles the edge between the second and third chunk (146 s); each
    // side alone is shorter than the detector's 0.2 s minimum.
    final gapDecoder = _GapDecoder(
      durationMs: 600000,
      gaps: const [(145850, 146150)],
    );
    final starts = service.sampleStartsMs(600000);
    final gapService = SongRecognitionService(
      db,
      decoder: gapDecoder,
      recognizer: FakeRecognizer(gapDecoder, {
        for (var i = 0; i < starts.length; i++)
          starts[i]: song(i.isEven ? 'A' : 'B', 'Song $i', 10),
      }),
      rootDirectory: () async => dir,
    );
    addTearDown(gapService.dispose);

    await gapService.scan(track);

    final silenceCalls = gapDecoder.calls.where((c) => c.$2 != 12000).toList();
    expect(silenceCalls, isNotEmpty);
    for (final (_, durationMs) in gapDecoder.calls) {
      expect(
        durationMs,
        lessThanOrEqualTo(
          SongRecognitionService.silenceChunkMs +
              SongRecognitionService.silencePrerollMs,
        ),
      );
    }
    // 26 s .. 600 s in 60 s chunks; later chunks start a second early.
    expect(silenceCalls.length, 10);
    expect(silenceCalls.first, (26000, 60000));
    expect(silenceCalls[1], (85000, 61000));
    expect(silenceCalls.last, (565000, 35000));

    final cached = File(
      p.join(
        (await _runDirs(dir)).single.path,
        'silences',
        '26000-600000.json',
      ),
    );
    final stored = jsonDecode(await cached.readAsString()) as Map;
    expect(stored['decoderVersion'], decoderAccuracyVersion);
    final intervals = [
      for (final s in stored['intervals'] as List)
        ((s[0] as num).toDouble(), (s[1] as num).toDouble()),
    ];
    expect(intervals.length, 1);
    expect(intervals.single.$1, closeTo(145.85, 0.001));
    expect(intervals.single.$2, closeTo(146.15, 0.001));
  });

  test('a scan removes lookups of deleted tracks and replaced files', () async {
    final other = await insertTestTrack(
      db,
      playlistId: track.playlistId,
      index: 2,
      videoId: 'video-2',
      filePath: track.filePath,
      status: 'complete',
    );
    final root = Directory(p.join(dir.path, 'recognition'));
    Future<Directory> folder(String name) async {
      final d = Directory(p.join(root.path, name));
      await File(
        p.join(d.path, 'samples', '30000.json'),
      ).create(recursive: true);
      return d;
    }

    final deletedTrack = await folder('9999-4096-0123456789abcdef');
    final oldContent = await folder('${track.id}-10-0123456789abcdef');
    final otherTrack = await folder('${other.id}-10-0123456789abcdef');
    final foreign = await folder('notes');
    final looseFile = File(p.join(root.path, '9999-1-0123456789abcdef'));
    await looseFile.writeAsString('x');

    await service.scan(track);

    expect(await deletedTrack.exists(), isFalse);
    expect(await oldContent.exists(), isFalse);
    expect(await otherTrack.exists(), isTrue);
    expect(await foreign.exists(), isTrue);
    expect(await looseFile.exists(), isTrue);
    expect(await File(track.filePath!).exists(), isTrue);
    expect(await service.loadRun(track), isNotNull);
  });

  test('a run is never stored for or loaded from a replaced file', () async {
    final run = await service.scan(track);
    expect(await SongRecognitionService.currentFileKey(track), run.fileKey);
    await File(track.filePath!).writeAsBytes(List.filled(4096, 9));
    expect(
      await SongRecognitionService.currentFileKey(track),
      isNot(run.fileKey),
    );
    // Review edits saved after the replacement must not land in the new
    // file's cache, where they would be offered as its own.
    await service.saveRun(run.copyWith(proposals: const []), track);
    expect(await service.loadRun(track), isNull);
    // A run file that names other content is ignored, too.
    final newKey = (await SongRecognitionService.currentFileKey(track))!;
    final misplaced = File(p.join(dir.path, 'recognition', newKey, 'run.json'));
    await misplaced.parent.create(recursive: true);
    await misplaced.writeAsString(jsonEncode(run.toJson()));
    expect(await service.loadRun(track), isNull);
  });

  test('after an undo, Recognize again gives a fresh run that applies, '
      'from the saved lookups', () async {
    final chapters = ChapterService(db, YtDlpService());
    Future<bool> apply(RecognitionRun run) => chapters.applyRecognition(
      track,
      runId: run.runId,
      epoch: run.epoch,
      fileKey: run.fileKey,
      durationMs: run.durationMs,
      proposals: run.proposals.map((c) => c.toChapter()).toList(),
    );
    Future<ChapterData> data() async =>
        ChapterData.decode((await db.getTrack(track.id))!.chaptersJson);

    final first = await service.scan(track);
    expect(await apply(first), isTrue);
    await chapters.undo(track);
    var current = await data();
    // The file had no chapters of its own and follows YouTube again.
    expect(current.custom, isNull);
    expect(current.recognitionEpoch, first.epoch + 1);
    expect(current.lastRecognitionRunId, first.runId);
    // The undone run never applies again.
    expect(await apply(first), isFalse);

    final lookups = recognizer.calls.length;
    final decodes = decoder.decodeCalls;
    final again = await service.scan(track);
    expect(recognizer.calls.length, lookups);
    expect(decoder.decodeCalls, decodes);
    expect(again.runId, isNot(first.runId));
    expect(again.epoch, current.recognitionEpoch);
    expect((await service.loadRun(track))!.runId, again.runId);
    expect(again.proposals.length, first.proposals.length);

    expect(await apply(again), isTrue);
    current = await data();
    expect(current.lastRecognitionRunId, again.runId);
    expect(current.active.map((c) => c.title), [
      'Artist — First song',
      'Artist — Second song',
    ]);
    // Applied once per epoch: the same run is not applied twice.
    expect(await apply(again), isFalse);
  });

  test('the epoch is read when the scan starts', () async {
    recognizer.gate = Completer<void>();
    final future = service.scan(track);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // An undo while the scan runs bumps the epoch.
    await db.writeTrackChapters(
      track.id,
      const ChapterData(custom: [], recognitionEpoch: 1),
    );
    recognizer.gate!.complete();
    final run = await future;
    expect(run.epoch, 0);
    final chapters = ChapterService(db, YtDlpService());
    expect(
      await chapters.applyRecognition(
        track,
        runId: run.runId,
        epoch: run.epoch,
        fileKey: run.fileKey,
        durationMs: run.durationMs,
        proposals: run.proposals.map((c) => c.toChapter()).toList(),
      ),
      isFalse,
    );
    expect(
      ChapterData.decode((await db.getTrack(track.id))!.chaptersJson).custom,
      isEmpty,
    );
  });

  group('playlist folder copy', () {
    File folderFile() =>
        File(LibraryLayout.recognitionJsonPath(dir.path, track.videoId));

    Future<Map<String, dynamic>> folderJson() async =>
        jsonDecode(await folderFile().readAsString()) as Map<String, dynamic>;

    /// Another phone: an empty database and app storage, the same playlist
    /// folder. A track is added first, so the song gets another id.
    Future<(AppDatabase, Track, SongRecognitionService, FakeRecognizer)>
    reinstall() async {
      final fresh = openTestDatabase();
      addTearDown(fresh.close);
      final playlist = await insertTestPlaylist(fresh, outputPath: dir.path);
      await insertTestTrack(fresh, playlistId: playlist.id, videoId: 'other');
      final moved = await insertTestTrack(
        fresh,
        playlistId: playlist.id,
        index: 2,
        status: 'complete',
        filePath: track.filePath,
        durationSeconds: 300,
      );
      expect(moved.id, isNot(track.id));
      final root = await Directory(
        p.join(dir.path, 'other-phone'),
      ).create(recursive: true);
      final freshRecognizer = FakeRecognizer(decoder, recognizer.byStartMs);
      final service = SongRecognitionService(
        fresh,
        decoder: decoder,
        recognizer: freshRecognizer,
        rootDirectory: () async => root,
      );
      addTearDown(service.dispose);
      return (fresh, moved, service, freshRecognizer);
    }

    test('a scan and its review edits are kept in the playlist folder, '
        'keyed by the file content instead of the track id', () async {
      final run = await service.scan(track);
      final contentKey = await SongRecognitionService.fileKey(track.filePath!);
      expect(run.fileKey, '${track.id}-$contentKey');

      var json = await folderJson();
      expect(json['version'], 1);
      expect(json['videoId'], track.videoId);
      expect(json['contentKey'], contentKey);
      final stored = json['run'] as Map<String, dynamic>;
      expect(stored.containsKey('trackId'), isFalse);
      expect(stored['fileKey'], contentKey);
      expect(stored['runId'], run.runId);
      expect((json['samples'] as List).map((s) => (s as Map)['startMs']), [
        30000,
        90000,
        150000,
        210000,
        270000,
        288000,
      ]);
      expect((json['samples'] as List).first, {
        'startMs': 30000,
        'durationMs': 12000,
        'decoderVersion': decoderAccuracyVersion,
        'recordedAt': isA<String>(),
        'key': 'A',
        'title': 'First song',
        'artist': 'Artist',
        'matches': [
          ['ref-A', 30],
        ],
      });
      expect(json['silences'], isNotEmpty);

      final edited = run.copyWith(
        proposals: [run.proposals.first.copyWith(title: 'Renamed')],
      );
      await service.saveRun(edited, track);
      json = await folderJson();
      final proposals = (json['run'] as Map)['proposals'] as List;
      expect(proposals, hasLength(1));
      expect((proposals.single as Map)['title'], 'Renamed');
    });

    test('after a reinstall the run comes back for the same file, with its '
        'review edits, and a new scan needs no lookups', () async {
      final run = await service.scan(track);
      final edited = run.copyWith(
        proposals: [run.proposals.first.copyWith(title: 'Renamed')],
      );
      await service.saveRun(edited, track);

      final (_, moved, other, otherRecognizer) = await reinstall();
      final loaded = (await other.loadRun(moved))!;
      expect(loaded.trackId, moved.id);
      expect(
        loaded.fileKey,
        await SongRecognitionService.currentFileKey(moved),
      );
      expect(loaded.runId, run.runId);
      expect(loaded.epoch, run.epoch);
      expect(loaded.decoderOutdated, isFalse);
      expect(
        loaded.proposals.map((c) => c.toJson()).toList(),
        edited.proposals.map((c) => c.toJson()).toList(),
      );

      final decodes = decoder.decodeCalls;
      final again = await other.scan(moved);
      expect(otherRecognizer.attempts, isEmpty);
      // Neither the windows nor the quiet gaps are decoded again.
      expect(decoder.decodeCalls, decodes);
      expect(
        again.proposals.map((c) => (c.title, c.startMs, c.endMs)).toList(),
        run.proposals.map((c) => (c.title, c.startMs, c.endMs)).toList(),
      );
    });

    test('a copy made from other file content is never taken over', () async {
      await service.scan(track);
      await File(track.filePath!).writeAsBytes(List.filled(4096, 9));
      final (_, moved, other, otherRecognizer) = await reinstall();
      expect(await other.loadRun(moved), isNull);
      await other.scan(moved);
      expect(otherRecognizer.calls, hasLength(6));
    });

    test('the copy never replaces a run this app has', () async {
      final run = await service.scan(track);
      final local = run.copyWith(
        proposals: [run.proposals.last.copyWith(title: 'Mine')],
      );
      // Saved here only, as an older version of the app did.
      await File(
        p.join(dir.path, 'recognition', run.fileKey, 'run.json'),
      ).writeAsString(jsonEncode(local.toJson()));
      final loaded = (await service.loadRun(track))!;
      expect(loaded.proposals.single.title, 'Mine');
    });

    test('discarding the run also forgets the folder copy', () async {
      await service.scan(track);
      expect(await folderFile().exists(), isTrue);
      await service.discardRun(track);
      expect(await folderFile().exists(), isFalse);
      expect(await service.loadRun(track), isNull);
    });

    test('a broken or newer copy is ignored and a newer one kept', () async {
      await Directory(p.dirname(folderFile().path)).create(recursive: true);
      await folderFile().writeAsString('{not json');
      expect(await service.loadRun(track), isNull);
      await service.scan(track);
      expect((await folderJson())['version'], 1);

      final newer = {...await folderJson(), 'version': 2, 'future': true};
      await folderFile().writeAsString(jsonEncode(newer));
      final run = (await service.loadRun(track))!;
      await service.saveRun(
        run.copyWith(proposals: [run.proposals.first]),
        track,
      );
      expect((await folderJson())['future'], isTrue);
    });

    test('compact lookups read back as the same Shazam result', () {
      final cached = {
        'sampleStartMs': 60000,
        'sampleDurationMs': 12000,
        'recordedAt': '2026-11-13T10:00:00.000Z',
        'decoderVersion': 2,
        'response': {
          'track': {
            'key': '41037976',
            'title': 'Fly-day Chinatown',
            'subtitle': 'Yasuha',
            'images': {'coverart': 'https://example.com/a.jpg'},
          },
          'matches': [
            {'id': '608157095', 'offset': 60.378, 'timeskew': 0.1},
            {'id': '632179612', 'offset': 60.577},
          ],
          'tagid': 'x',
        },
      };
      final compact = compactSample(cached)!;
      final back = expandSample(jsonDecode(jsonEncode(compact)))!;
      expect(back['sampleStartMs'], 60000);
      expect(back['sampleDurationMs'], 12000);
      expect(back['recordedAt'], cached['recordedAt']);
      expect(back['decoderVersion'], 2);
      final a = ShazamResult.fromJson(
        cached['response'] as Map<String, dynamic>,
      );
      final b = ShazamResult.fromJson(back['response'] as Map<String, dynamic>);
      expect(b.trackKey, a.trackKey);
      expect(b.title, a.title);
      expect(b.artist, a.artist);
      expect(
        b.offsets.map((o) => (o.referenceId, o.offsetSeconds)).toList(),
        a.offsets.map((o) => (o.referenceId, o.offsetSeconds)).toList(),
      );

      final silent =
          compactSample({'sampleStartMs': 0, 'response': <String, dynamic>{}})!;
      expect(silent, {'startMs': 0});
      final silentBack = expandSample(silent)!;
      expect(
        ShazamResult.fromJson(
          silentBack['response'] as Map<String, dynamic>,
        ).recognized,
        isFalse,
      );
    });
  });

  group('decoder accuracy version', () {
    /// Rewrites the run, lookups and quiet gaps cached for [of] the way
    /// builds before decoder versions stored them.
    Future<void> makeVersion1(Track of) async {
      final folder = (await _runDirs(
        dir,
      )).singleWhere((d) => p.basename(d.path).startsWith('${of.id}-'));
      final run = File(p.join(folder.path, 'run.json'));
      final json = jsonDecode(await run.readAsString()) as Map;
      expect(json['decoderVersion'], decoderAccuracyVersion);
      json.remove('decoderVersion');
      await run.writeAsString(jsonEncode(json));
      await for (final f in Directory(p.join(folder.path, 'samples')).list()) {
        final file = f as File;
        final lookup = jsonDecode(await file.readAsString()) as Map;
        expect(lookup['decoderVersion'], decoderAccuracyVersion);
        lookup.remove('decoderVersion');
        await file.writeAsString(jsonEncode(lookup));
      }
      var silences = 0;
      await for (final f in Directory(p.join(folder.path, 'silences')).list()) {
        final file = f as File;
        final stored = jsonDecode(await file.readAsString()) as Map;
        await file.writeAsString(jsonEncode(stored['intervals']));
        silences++;
      }
      expect(silences, greaterThan(0));
    }

    Future<Track> mp3Track(
      List<int> bytes, {
      String name = '00002_mix.mp3',
    }) async {
      final media = await File(p.join(dir.path, name)).writeAsBytes(bytes);
      return insertTestTrack(
        db,
        playlistId: track.playlistId,
        index: 2,
        videoId: 'video-mp3',
        status: 'complete',
        filePath: media.path,
        durationSeconds: 300,
      );
    }

    test('an MP3 scan from the old decoder is stale and nothing it cached '
        'is reused', () async {
      final mp3 = await mp3Track(List.filled(4096, 7));
      final first = await service.scan(mp3);
      expect(first.decoderVersion, decoderAccuracyVersion);
      expect((await service.loadRun(mp3))!.decoderOutdated, isFalse);
      await makeVersion1(mp3);

      final old = (await service.loadRun(mp3))!;
      expect(old.decoderVersion, 1);
      expect(old.decoderOutdated, isTrue);
      expect(old.runId, first.runId);
      // Review edits keep it stale: the version is stored unchanged.
      await service.saveRun(old.copyWith(proposals: const []), mp3);
      final edited = (await service.loadRun(mp3))!;
      expect(edited.decoderOutdated, isTrue);
      expect(edited.proposals, isEmpty);

      // Recognize again decodes and looks up every window anew, and
      // measures the quiet gaps again.
      final lookups = recognizer.calls.length;
      final decodes = decoder.decodeCalls;
      final again = await service.scan(mp3);
      expect(recognizer.calls.length - lookups, 6);
      expect(decoder.decodeCalls - decodes, greaterThan(6));
      expect(again.decoderVersion, decoderAccuracyVersion);
      expect(again.proposals.last.startMs, 130900);
      final loaded = (await service.loadRun(mp3))!;
      expect(loaded.runId, again.runId);
      expect(loaded.decoderOutdated, isFalse);

      // What it stored now carries the version, so a third scan reuses it.
      final lookups2 = recognizer.calls.length;
      final decodes2 = decoder.decodeCalls;
      await service.scan(mp3);
      expect(recognizer.calls.length, lookups2);
      expect(decoder.decodeCalls, decodes2);
    });

    test('a scan of another format from the old decoder stays valid and '
        'its lookups are reused', () async {
      await service.scan(track);
      await makeVersion1(track);
      final old = (await service.loadRun(track))!;
      expect(old.decoderVersion, 1);
      expect(old.decoderOutdated, isFalse);

      final lookups = recognizer.calls.length;
      final decodes = decoder.decodeCalls;
      final again = await service.scan(track);
      expect(recognizer.calls.length, lookups);
      expect(decoder.decodeCalls, decodes);
      expect(again.proposals.last.startMs, 130900);
    });

    test('an MP3 is told by its content, whatever its name', () async {
      // ID3v2 tag of 20 bytes, then an MPEG-1 layer III frame header.
      final tagged = await mp3Track([
        0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 20, //
        ...List.filled(20, 0),
        0xff, 0xfb, 0x90, 0x64, ...List.filled(4000, 0),
      ], name: '00002_mix.bin');
      await service.scan(tagged);
      await makeVersion1(tagged);
      expect((await service.loadRun(tagged))!.decoderOutdated, isTrue);
    });

    test('content sniffing', () async {
      Future<bool> sniff(String name, List<int> bytes) async {
        final file = File(p.join(dir.path, name));
        await file.writeAsBytes(bytes);
        return isMpegAudioFile(file.path);
      }

      // A bare MPEG-1 and an MPEG-2 layer III frame.
      expect(await sniff('a', [0xff, 0xfb, 0x90, 0x64]), isTrue);
      expect(await sniff('b', [0xff, 0xf3, 0x48, 0xc4]), isTrue);
      // ID3v2 with a footer (flag 0x10): 10 + 5 + 10 bytes before the frame.
      expect(
        await sniff('c', [
          0x49, 0x44, 0x33, 4, 0, 0x10, 0, 0, 0, 5, //
          ...List.filled(15, 0),
          0xff, 0xfb, 0x90, 0x64,
        ]),
        isTrue,
      );
      // AAC in ADTS has a sync word but layer 0.
      expect(await sniff('d.aac', [0xff, 0xf1, 0x50, 0x80]), isFalse);
      // MP4 and WebM/Matroska.
      expect(
        await sniff('e.m4a', [0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70]),
        isFalse,
      );
      expect(await sniff('f.webm', [0x1a, 0x45, 0xdf, 0xa3]), isFalse);
      expect(await sniff('g.opus', 'OggS'.codeUnits), isFalse);
      // An ID3 tag over something that is not MP3.
      expect(
        await sniff('h', [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, 0xff, 0xf1]),
        isFalse,
      );
      // The name alone is enough for .mp3; a missing file is not MP3.
      expect(await sniff('i.MP3', const []), isTrue);
      expect(await isMpegAudioFile(p.join(dir.path, 'missing.m4a')), isFalse);
    });

    test('runs without a version read as version 1', () {
      final run = RecognitionRun(
        runId: 'r',
        trackId: 1,
        fileKey: 'k',
        epoch: 0,
        durationMs: 1000,
        completedAt: DateTime.utc(2026),
        sampleCount: 1,
        matchedSamples: 0,
        proposals: const [],
      );
      expect(run.decoderVersion, decoderAccuracyVersion);
      final json = run.toJson();
      expect(json['decoderVersion'], decoderAccuracyVersion);
      expect(
        RecognitionRun.fromJson(jsonDecode(jsonEncode(json))).decoderVersion,
        decoderAccuracyVersion,
      );
      json.remove('decoderVersion');
      expect(RecognitionRun.fromJson(json).decoderVersion, 1);
      // Never stored: it is worked out again on every load.
      expect(
        run.copyWith(decoderOutdated: true).toJson().keys,
        isNot(contains('decoderOutdated')),
      );
      expect(decoderVersionTrusted(null, mpegAudio: true), isFalse);
      expect(decoderVersionTrusted(1, mpegAudio: true), isFalse);
      expect(decoderVersionTrusted(2, mpegAudio: true), isTrue);
      expect(decoderVersionTrusted(null, mpegAudio: false), isTrue);
    });
  });

  group('YtDlpScanForegroundNotifier', () {
    test('never stops the service while a download owns it', () async {
      final ytdlp = _ServiceRecorder();
      var downloading = false;
      final notifier = YtDlpScanForegroundNotifier(
        ytdlp,
        downloadActive: () => downloading,
      );

      // Scan alone: it starts, updates and stops the service.
      await notifier.start('scan');
      await notifier.update('scan', 1, 4);
      await notifier.stop();
      expect(ytdlp.events, ['start scan', 'update 1/4', 'stop']);

      // A download starts during the scan: the scan leaves the service and
      // its notification to the download, also when the scan ends.
      ytdlp.events.clear();
      await notifier.start('scan');
      downloading = true;
      await notifier.update('scan', 2, 4);
      await notifier.stop();
      expect(ytdlp.events, ['start scan']);

      // A scan that starts while the download still runs: once the
      // download has ended (and stopped the service), the scan takes the
      // service back and stops it at the end.
      ytdlp.events.clear();
      await notifier.start('scan');
      await notifier.update('scan', 1, 4);
      downloading = false;
      await notifier.update('scan', 2, 4);
      await notifier.stop();
      expect(ytdlp.events, ['start scan', 'update 2/4', 'stop']);
    });

    test('a wait shows its detail in the notification', () async {
      final ytdlp = _ServiceRecorder();
      final notifier = YtDlpScanForegroundNotifier(ytdlp);
      await notifier.start('scan');
      await notifier.update('scan', 2, 4, detail: 'Retrying at 12:05');
      await notifier.update('scan', 2, 4, detail: 'Retrying sample 3 of 4…');
      await notifier.update('scan', 3, 4);
      await notifier.stop();
      expect(ytdlp.events, [
        'start scan',
        'update 2/4 Retrying at 12:05',
        'update 2/4 Retrying sample 3 of 4…',
        'update 3/4',
        'stop',
      ]);
    });

    test('a scan started during a download never touches it', () async {
      final ytdlp = _ServiceRecorder();
      final notifier = YtDlpScanForegroundNotifier(
        ytdlp,
        downloadActive: () => true,
      );
      await notifier.start('scan');
      await notifier.update('scan', 1, 4);
      await notifier.stop();
      expect(ytdlp.events, isEmpty);
    });
  });
}

/// The recognition cache folders under [root].
Future<List<Directory>> _runDirs(Directory root) async => [
  await for (final e in Directory(p.join(root.path, 'recognition')).list())
    if (e is Directory) e,
];

/// A tone with silent [gaps] (in ms) that records every decode request as
/// (startMs, durationMs).
class _GapDecoder extends FakeDecoder {
  _GapDecoder({required this.durationMs, required this.gaps});
  final int durationMs;
  final List<(int, int)> gaps;
  final calls = <(int, int)>[];

  @override
  Future<Int16List> decode(
    String path, {
    required Duration start,
    required Duration duration,
  }) async {
    decodeCalls++;
    lastStartMs = start.inMilliseconds;
    calls.add((start.inMilliseconds, duration.inMilliseconds));
    final startSample = start.inMilliseconds * 16;
    return pcmFromGenerator(duration.inMilliseconds * 16, (i) {
      final ms = (startSample + i) / 16;
      for (final (from, to) in gaps) {
        if (ms >= from && ms < to) return 0;
      }
      return (8000 * sin(2 * pi * 440 * (startSample + i) / 16000)).round();
    });
  }

  @override
  Future<Duration?> probeDuration(String path) async =>
      Duration(milliseconds: durationMs);
}

class _ServiceRecorder extends YtDlpService {
  final events = <String>[];

  @override
  Future<void> startDownloadService(String playlistName) async =>
      events.add('start $playlistName');

  @override
  Future<void> updateDownloadServiceProgress({
    required String playlistName,
    required int currentTrack,
    required int totalTracks,
    required int progress,
    String? trackTitle,
  }) async => events.add(
    trackTitle == null
        ? 'update $currentTrack/$totalTracks'
        : 'update $currentTrack/$totalTracks $trackTitle',
  );

  @override
  Future<void> stopDownloadService() async => events.add('stop');
}
