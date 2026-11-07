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
    final intervals = [
      for (final s in jsonDecode(await cached.readAsString()) as List)
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
  }) async => events.add('update $currentTrack/$totalTracks');

  @override
  Future<void> stopDownloadService() async => events.add('stop');
}
