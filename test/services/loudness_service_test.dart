import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/audio_processing.dart';
import 'package:woolytube/services/loudness_service.dart';

import '../helpers/test_database.dart';

/// Records which files were measured and answers from [results].
class _FakeAnalyzer implements LoudnessAnalyzer {
  final calls = <String>[];
  final results = <String, MeasuredLoudness>{};
  final failures = <String, Object>{};

  /// While set, every call waits for it.
  Completer<void>? gate;

  /// Runs during a call, before it answers.
  void Function(String path)? during;

  /// Files the plugin never answers for.
  final hanging = <String>{};

  @override
  Future<MeasuredLoudness> analyze(String path) async {
    calls.add(path);
    if (hanging.contains(path)) return Completer<MeasuredLoudness>().future;
    await gate?.future;
    during?.call(path);
    final failure = failures[path];
    if (failure != null) throw failure;
    return results[path] ??
        const MeasuredLoudness(integratedLufs: -12, cabinLufs: -15, peakDb: -1);
  }
}

Future<void> _until(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting${reason == null ? '' : ' for $reason'}');
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late _FakeAnalyzer analyzer;
  late Playlist playlist;
  final services = <LoudnessService>[];

  LoudnessService create({
    bool Function()? shouldPause,
    Future<bool> Function()? isCharging,
    bool onlyWhileCharging = true,
    Duration chargerPoll = const Duration(milliseconds: 50),
  }) {
    final service = LoudnessService(
      db,
      analyzer: analyzer,
      shouldPause: shouldPause,
      isCharging: isCharging ?? () async => true,
      onlyWhileCharging: onlyWhileCharging,
      pauseBetween: Duration.zero,
      pausePoll: const Duration(milliseconds: 20),
      chargerPoll: chargerPoll,
      analyzeTimeout: const Duration(milliseconds: 100),
      retryAfterError: const Duration(milliseconds: 50),
    );
    services.add(service);
    return service;
  }

  /// A downloaded track whose file exists.
  Future<(Track, String)> downloaded(int index, {String? status}) async {
    final path = p.join(tempDir.path, '${index}_song.m4a');
    File(path).writeAsBytesSync(List.filled(100 + index, 1));
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: index,
      videoId: 'v$index',
      title: 'Song $index',
      filePath: path,
      status: status ?? 'complete',
    );
    return (track, path);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('loudness_test_');
    db = openTestDatabase();
    analyzer = _FakeAnalyzer();
    playlist = await insertTestPlaylist(db, outputPath: tempDir.path);
  });

  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    await db.close();
    await tempDir.delete(recursive: true);
  });

  test('measures nothing while switched off', () async {
    final (track, path) = await downloaded(1);
    final service = create();
    service.prioritize([LoudnessJob(track.id, path)]);
    service.rescan();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(analyzer.calls, isEmpty);
    expect(await service.loudnessFor(track.id, path), isNull);
  });

  test(
    'measures every downloaded song once and hands the result out',
    () async {
      final (first, firstPath) = await downloaded(1);
      final (second, secondPath) = await downloaded(2);
      await downloaded(3, status: 'pending');
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 4,
        videoId: 'gone',
        filePath: p.join(tempDir.path, 'missing.m4a'),
        status: 'complete',
      );
      analyzer.results[firstPath] = const MeasuredLoudness(
        integratedLufs: -9.5,
        cabinLufs: -13,
        peakDb: -0.2,
      );
      final service = create();
      service.setEnabled(true);
      await _until(
        () => service.progress.measured == 2 && !service.progress.working,
        reason: 'both songs measured',
      );

      expect(analyzer.calls, unorderedEquals([firstPath, secondPath]));
      expect(service.progress.total, 2);
      expect(
        await service.loudnessFor(first.id, firstPath),
        const MeasuredLoudness(
          integratedLufs: -9.5,
          cabinLufs: -13,
          peakDb: -0.2,
        ),
      );
      expect(await service.loudnessFor(second.id, secondPath), isNotNull);

      // Nothing left to do on the next pass.
      service.rescan();
      await _until(() => !service.progress.working);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(analyzer.calls, hasLength(2));
    },
  );

  test('the songs the player asks for come before the rest', () async {
    await downloaded(1);
    await downloaded(2);
    final (wanted, wantedPath) = await downloaded(3);
    final service = create();
    service.setEnabled(true);
    service.prioritize([LoudnessJob(wanted.id, wantedPath)]);
    await _until(() => analyzer.calls.length == 3);
    expect(analyzer.calls.first, wantedPath);
  });

  test('a song measured on request is not measured again later', () async {
    final (track, path) = await downloaded(1);
    final service = create();
    analyzer.gate = Completer<void>();
    service.setEnabled(true);
    service.prioritize([LoudnessJob(track.id, path)]);
    await _until(() => analyzer.calls.isNotEmpty);
    analyzer.gate!.complete();
    await _until(() => !service.progress.working && service.progress.total > 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(analyzer.calls, [path]);
  });

  test('a replaced file is measured again', () async {
    final (track, path) = await downloaded(1);
    final service = create();
    service.setEnabled(true);
    await _until(() => service.progress.measured == 1);
    expect(await service.loudnessFor(track.id, path), isNotNull);

    File(path).writeAsBytesSync(List.filled(500, 2));
    File(path).setLastModifiedSync(DateTime(2030));
    expect(await service.loudnessFor(track.id, path), isNull);

    service.rescan();
    await _until(() => analyzer.calls.length == 2);
    await _until(() => !service.progress.working);
    expect(await service.loudnessFor(track.id, path), isNotNull);
  });

  test('a measurement of another file of the track is not used', () async {
    final (track, path) = await downloaded(1);
    final service = create();
    service.setEnabled(true);
    await _until(() => service.progress.measured == 1);
    final other = p.join(tempDir.path, 'other.webm');
    File(path).copySync(other);
    File(other).setLastModifiedSync(File(path).lastModifiedSync());
    expect(await service.loudnessFor(track.id, other), isNull);
  });

  test('a file that cannot be measured is not tried again', () async {
    final (_, brokenPath) = await downloaded(1);
    analyzer.failures[brokenPath] = PlatformException(code: 'ANALYZE_ERROR');
    final service = create();
    service.setEnabled(true);
    await _until(() => analyzer.calls.isNotEmpty && !service.progress.working);
    service.rescan();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await _until(() => !service.progress.working);
    expect(analyzer.calls, [brokenPath]);
  });

  test('stops for good when the platform cannot measure', () async {
    final (_, firstPath) = await downloaded(1);
    await downloaded(2);
    analyzer.failures[firstPath] = MissingPluginException();
    final service = create();
    service.setEnabled(true);
    await _until(() => analyzer.calls.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    service.rescan();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(analyzer.calls, hasLength(1));
  });

  test('a silent file counts as measured but has no loudness', () async {
    final (track, path) = await downloaded(1);
    analyzer.results[path] = const MeasuredLoudness();
    final service = create();
    service.setEnabled(true);
    await _until(() => service.progress.measured == 1);
    expect(await service.loudnessFor(track.id, path), const MeasuredLoudness());
    service.rescan();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(analyzer.calls, hasLength(1));
  });

  test('a file replaced while it is read is not stored', () async {
    final (track, path) = await downloaded(1);
    analyzer.during = (path) {
      File(path).writeAsBytesSync(List.filled(999, 3));
      File(path).setLastModifiedSync(DateTime(2031));
    };
    final service = create();
    service.setEnabled(true);
    await _until(() => analyzer.calls.isNotEmpty && !service.progress.working);
    expect(await db.getLoudnessMeasurement(track.id), isNull);
  });

  test('waits while the library is busy moving files', () async {
    await downloaded(1);
    var busy = true;
    final service = create(shouldPause: () => busy);
    service.setEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(analyzer.calls, isEmpty);
    busy = false;
    await _until(() => analyzer.calls.length == 1);
  });

  test('on battery only the songs the player asks for are measured', () async {
    await downloaded(1);
    await downloaded(2);
    final (wanted, wantedPath) = await downloaded(3);
    var charging = false;
    final service = create(isCharging: () async => charging);
    service.setEnabled(true);
    service.prioritize([LoudnessJob(wanted.id, wantedPath)]);
    await _until(() => service.progress.waitingForCharger);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(analyzer.calls, [wantedPath]);
    expect(service.progress.measured, 1);
    expect(service.progress.total, 3);

    // Plugged in: the rest of the library follows.
    charging = true;
    await _until(() => analyzer.calls.length == 3, reason: 'library measured');
    await _until(() => !service.progress.waitingForCharger);
    expect(service.progress.measured, 3);
  });

  test('files moved while the library was busy are found again', () async {
    final (track, path) = await downloaded(1);
    final (other, otherPath) = await downloaded(2);
    var busy = false;
    final service = create(shouldPause: () => busy);
    // The first file is being read when the library starts moving files.
    analyzer.gate = Completer<void>();
    service.setEnabled(true);
    await _until(() => analyzer.calls.isNotEmpty);
    expect(analyzer.calls.single, path);
    busy = true;
    final moved = p.join(tempDir.path, '7_song.m4a');
    File(path).renameSync(moved);
    await db.updateTrackFilePaths({track.id: moved});
    analyzer.gate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(analyzer.calls, hasLength(1), reason: 'waits while busy');
    busy = false;
    await _until(() => analyzer.calls.length == 3, reason: 'both files');
    expect(analyzer.calls.skip(1), unorderedEquals([moved, otherPath]));
    await _until(() => !service.progress.working);
    expect(await service.loudnessFor(track.id, moved), isNotNull);
    expect(await service.loudnessFor(other.id, otherPath), isNotNull);
  });

  test('switching off stops before the next song', () async {
    await downloaded(1);
    await downloaded(2);
    final service = create();
    analyzer.gate = Completer<void>();
    service.setEnabled(true);
    await _until(() => analyzer.calls.isNotEmpty);
    service.setEnabled(false);
    analyzer.gate!.complete();
    await _until(() => !service.progress.working);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(analyzer.calls, hasLength(1));
  });

  test('deleting a track deletes its measurement', () async {
    final (track, path) = await downloaded(1);
    final service = create();
    service.setEnabled(true);
    await _until(() => service.progress.measured == 1);
    expect(await db.getLoudnessMeasurement(track.id), isNotNull);
    await db.deleteTracks([track.id]);
    expect(await db.getLoudnessMeasurement(track.id), isNull);
    expect(await service.loudnessFor(track.id, path), isNull);
  });

  test(
    'a file the plugin never answers for fails and the rest goes on',
    () async {
      final (_, stuckPath) = await downloaded(1);
      final (other, otherPath) = await downloaded(2);
      analyzer.hanging.add(stuckPath);
      final service = create();
      service.setEnabled(true);
      await _until(
        () => service.progress.measured == 1 && !service.progress.working,
        reason: 'the other file measured',
      );
      expect(analyzer.calls, [stuckPath, otherPath]);
      expect(service.progress.failed, 1);
      expect(service.progress.total, 2);
      expect(service.progress.hasWorkLeft, isTrue);
      expect(await service.loudnessFor(other.id, otherPath), isNotNull);
    },
  );

  test('failures are counted, and Measure now tries them again', () async {
    final (track, brokenPath) = await downloaded(1);
    await downloaded(2);
    analyzer.failures[brokenPath] = PlatformException(code: 'ANALYZE_ERROR');
    final service = create();
    service.setEnabled(true);
    await _until(
      () => service.progress.measured == 1 && !service.progress.working,
    );
    expect(service.progress.failed, 1);

    analyzer.failures.clear();
    service.measureNow();
    expect(service.progress.failed, 0);
    expect(service.progress.forced, isTrue);
    await _until(
      () => service.progress.measured == 2 && !service.progress.forced,
      reason: 'the broken file measured on the second try',
    );
    expect(analyzer.calls.where((c) => c == brokenPath), hasLength(2));
    expect(await service.loudnessFor(track.id, brokenPath), isNotNull);
    expect(service.progress.hasWorkLeft, isFalse);
  });

  test('measuring starts again by itself after an error', () async {
    await downloaded(1);
    var calls = 0;
    final service = create(
      shouldPause: () {
        calls++;
        if (calls == 1) throw StateError('database busy');
        return false;
      },
    );
    service.setEnabled(true);
    await _until(() => analyzer.calls.length == 1, reason: 'retried');
    await _until(() => service.progress.measured == 1);
  });

  test('says while it waits for the library to move files', () async {
    await downloaded(1);
    var busy = true;
    final service = create(shouldPause: () => busy);
    service.setEnabled(true);
    await _until(() => service.progress.waitingForLibrary);
    busy = false;
    await _until(() => service.progress.measured == 1);
    expect(service.progress.waitingForLibrary, isFalse);
  });

  test(
    'Measure now measures the library on battery until it is done',
    () async {
      await downloaded(1);
      await downloaded(2);
      final service = create(
        isCharging: () async => false,
        chargerPoll: const Duration(hours: 1),
      );
      service.setEnabled(true);
      await _until(() => service.progress.waitingForCharger);
      expect(analyzer.calls, isEmpty);

      service.measureNow();
      await _until(
        () => service.progress.measured == 2 && !service.progress.forced,
        reason: 'all measured',
      );
      expect(service.progress.waitingForCharger, isFalse);

      // New downloads wait for the charger again.
      await downloaded(3);
      service.rescan();
      await _until(() => service.progress.waitingForCharger);
      expect(analyzer.calls, hasLength(2));
    },
  );

  test('Stop hands the library back to the charging rule', () async {
    await downloaded(1);
    await downloaded(2);
    await downloaded(3);
    final service = create(
      isCharging: () async => false,
      chargerPoll: const Duration(hours: 1),
    );
    analyzer.gate = Completer<void>();
    service.setEnabled(true);
    await _until(() => service.progress.waitingForCharger);
    service.measureNow();
    await _until(() => analyzer.calls.length == 1);
    service.stopMeasuringNow();
    expect(service.progress.forced, isFalse);
    analyzer.gate!.complete();
    await _until(() => service.progress.waitingForCharger);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(analyzer.calls, hasLength(1));
    expect(service.progress.measured, 1);
  });

  test('switching off stops Measure now', () async {
    await downloaded(1);
    final service = create(isCharging: () async => false);
    service.setEnabled(true);
    service.measureNow();
    expect(service.progress.forced, isTrue);
    service.setEnabled(false);
    expect(service.progress.forced, isFalse);
  });

  test(
    'without the charging rule the library is measured on battery',
    () async {
      await downloaded(1);
      await downloaded(2);
      final service = create(
        isCharging: () async => false,
        onlyWhileCharging: false,
      );
      service.setEnabled(true);
      await _until(() => service.progress.measured == 2);
      expect(service.progress.waitingForCharger, isFalse);

      // Turned on again: new songs wait.
      service.setOnlyWhileCharging(true);
      await downloaded(3);
      service.rescan();
      await _until(() => service.progress.waitingForCharger);
      expect(analyzer.calls, hasLength(2));

      // Turned off while waiting: measuring goes on at once.
      service.setOnlyWhileCharging(false);
      await _until(() => service.progress.measured == 3);
      expect(service.progress.waitingForCharger, isFalse);
    },
  );

  test('tells the player about each stored measurement', () async {
    final (track, path) = await downloaded(1);
    final (broken, brokenPath) = await downloaded(2);
    analyzer.failures[brokenPath] = PlatformException(code: 'ANALYZE_ERROR');
    final service = create();
    final measured = <LoudnessJob>[];
    final sub = service.measuredFiles.listen(measured.add);
    addTearDown(sub.cancel);
    service.setEnabled(true);
    await _until(
      () => service.progress.failed == 1 && service.progress.measured == 1,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(measured, [LoudnessJob(track.id, path)]);
    expect(measured, isNot(contains(LoudnessJob(broken.id, brokenPath))));
  });

  group('plugged in', () {
    const channel = MethodChannel('com.woolytube/ytdlp');
    late TestDefaultBinaryMessenger messenger;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('asks the plugin whether the phone is on a charger', () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return false;
      });
      expect(await platformIsPluggedIn(), isFalse);
      expect(methods, ['isPluggedIn']);
    });

    test('counts as plugged in when it cannot be told', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'ERR'),
      );
      expect(await platformIsPluggedIn(), isTrue);
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await platformIsPluggedIn(), isTrue);
    });
  });

  test('reads the plugin reply leniently', () {
    expect(
      measuredLoudnessFromMap({
        'integratedLufs': -14.25,
        'cabinLufs': -17,
        'peakDb': null,
        'durationMs': 1000,
      }),
      const MeasuredLoudness(integratedLufs: -14.25, cabinLufs: -17),
    );
    expect(
      measuredLoudnessFromMap({'integratedLufs': double.negativeInfinity}),
      const MeasuredLoudness(),
    );
  });
}
