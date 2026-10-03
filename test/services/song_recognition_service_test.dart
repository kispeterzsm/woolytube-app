import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapter_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/recognition/audio_window_decoder.dart';
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
  int? failAtCall;
  Completer<void>? gate;
  int _sequence = 0;

  @override
  Future<ShazamResult> recognize(ShazamSignature signature) async {
    final index = _sequence++;
    if (gate != null) await gate!.future;
    if (failAtCall == index) throw const SocketException('offline');
    // The service decodes a window right before recognizing it.
    final start = decoder.lastStartMs;
    calls.add(start);
    return ShazamResult.fromJson(byStartMs[start]!);
  }
}

class FakeNotifier implements ScanForegroundNotifier {
  final events = <String>[];
  @override
  Future<void> start(String label) async => events.add('start');
  @override
  Future<void> update(String label, int current, int total) async =>
      events.add('update $current/$total');
  @override
  Future<void> stop() async => events.add('stop');
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
    service = SongRecognitionService(
      db,
      decoder: decoder,
      recognizer: recognizer,
      rootDirectory: () async => dir,
      notifier: notifier,
    );
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
    await expectLater(service.scan(track), throwsA(isA<SocketException>()));
    expect(service.currentProgress!.phase, RecognitionPhase.failed);
    expect(notifier.events.last, 'stop');
    expect(recognizer.calls.length, 3);

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
}
