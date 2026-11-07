import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/services/log_service.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('woolytube_log_test_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File logFile() => File(p.join(dir.path, 'logs', 'woolytube.log'));
  LogFileSink sink({int maxBytes = 512 * 1024}) =>
      LogFileSink(() async => logFile(), maxBytes: maxBytes);

  test('a line survives the trip to the file and back', () {
    final entry = LogEntry(
      timestamp: DateTime(2026, 11, 7, 9, 5, 3, 120),
      level: 'warn',
      message: 'two\nlines with a \\ and a\ttab',
      source: LogService.backgroundSource,
    );
    final parsed = LogEntry.parseLine(entry.toLine())!;
    expect(parsed.timestamp, entry.timestamp);
    expect(parsed.level, 'warn');
    expect(parsed.message, entry.message);
    expect(parsed.source, LogService.backgroundSource);
    expect(parsed.key, entry.key);
    expect(
      parsed.formattedWithDate,
      contains('7 Nov 09:05:03 WARN (background)'),
    );
    expect(LogEntry.parseLine('garbage'), isNull);
  });

  test('the app and the background worker share one saved log', () async {
    final app = LogService(sink: sink());
    final background = LogService(
      sink: sink(),
      source: LogService.backgroundSource,
    );
    background.info('Background update started');
    await background.flush();
    app.warn('Sync failed');

    final history = await app.history();
    expect(history.map((e) => e.message), [
      'Background update started',
      'Sync failed',
    ]);
    expect(history.first.source, LogService.backgroundSource);
    expect(history.last.level, 'warn');

    // A new run reads what earlier runs saved.
    final later = LogService(sink: sink());
    expect((await later.history()).length, 2);

    await later.clear();
    expect(await later.history(), isEmpty);
    expect(await logFile().exists(), isFalse);
    app.dispose();
    background.dispose();
    later.dispose();
  });

  test(
    'the file is bounded: a large log moves to .1 and a new one starts',
    () async {
      final big = LogService(sink: sink(maxBytes: 200));
      for (var i = 0; i < 10; i++) {
        big.info('line $i ${'x' * 40}');
      }
      await big.flush();
      expect(await logFile().length(), greaterThan(200));
      big.dispose();

      // The size is checked when the file is opened by the next run.
      final next = LogService(sink: sink(maxBytes: 200));
      next.info('fresh');
      await next.flush();
      expect(await File('${logFile().path}.1').exists(), isTrue);
      expect(await logFile().readAsString(), contains('fresh'));
      expect(await logFile().readAsString(), isNot(contains('line 0')));
      // Both parts are still shown.
      expect((await next.history()).length, 11);
      next.dispose();
    },
  );

  test('without a file the log keeps this run in memory', () async {
    final log = LogService.memoryOnly();
    final seen = <String>[];
    log.onEntry.listen((e) => seen.add(e.message));
    log.error('boom');
    await pumpEventQueue();
    expect(log.persists, isFalse);
    expect(seen, ['boom']);
    expect((await log.history()).single.level, 'error');
    await log.clear();
    expect(log.entries, isEmpty);
    log.dispose();
  });

  test('a log file that cannot be opened never breaks logging', () async {
    final log = LogService(
      sink: LogFileSink(() async => throw const FileSystemException('no')),
    );
    log.info('still fine');
    await log.flush();
    expect((await log.history()).single.message, 'still fine');
    log.dispose();
  });
}
