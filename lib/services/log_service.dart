import 'dart:async';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LogEntry {
  final DateTime timestamp;
  final String level; // info | error | warn
  final String message;

  /// Which part of the app wrote the line: 'app', or 'background' for the
  /// scheduled update worker.
  final String source;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.source = LogService.appSource,
  });

  static final _timeFormat = DateFormat('HH:mm:ss');
  static final _dateTimeFormat = DateFormat('d MMM HH:mm:ss');

  /// Time and message, for a log that only covers the current run.
  String get formatted {
    return '[${_timeFormat.format(timestamp)}] ${level.toUpperCase()}: '
        '$message';
  }

  /// Date, time, source and message, for the saved log that spans runs.
  String get formattedWithDate {
    final from = source == LogService.appSource ? '' : ' ($source)';
    return '${_dateTimeFormat.format(timestamp)} ${level.toUpperCase()}$from: '
        '$message';
  }

  /// One line of the log file: tab-separated, line breaks escaped.
  String toLine() =>
      '${timestamp.toIso8601String()}\t$level\t$source\t'
      '${message.replaceAll('\\', '\\\\').replaceAll('\n', '\\n')}';

  /// Reads a line written by [toLine]; null for anything else.
  static LogEntry? parseLine(String line) {
    final parts = line.split('\t');
    if (parts.length < 4) return null;
    final timestamp = DateTime.tryParse(parts[0]);
    if (timestamp == null) return null;
    final escaped = parts.sublist(3).join('\t');
    final message = escaped.replaceAllMapped(
      RegExp(r'\\(.)'),
      (match) => match[1] == 'n' ? '\n' : match[1]!,
    );
    return LogEntry(
      timestamp: timestamp,
      level: parts[1],
      source: parts[2],
      message: message,
    );
  }

  /// Identity across a write to the file and a read back.
  String get key => '${timestamp.microsecondsSinceEpoch}|$level|$message';
}

/// Appends log lines to a file that the app and the background update
/// worker share, so a scheduled run's log can be read in the app later.
///
/// Lines logged together are written with one append right after (on the
/// next microtask), so a background engine that is shut down soon after
/// its last line still saves it. Each write is a single short append, so
/// two engines writing at once only interleave whole batches. The file is bounded: once it is larger than
/// [maxBytes] it becomes `<name>.1` (replacing the older one) and a new
/// file starts, so at most about twice [maxBytes] is kept.
class LogFileSink {
  LogFileSink(this._resolveFile, {this.maxBytes = 512 * 1024});

  /// `<app documents>/logs/woolytube.log`.
  factory LogFileSink.appDocuments() => LogFileSink(() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(p.join(documents.path, 'logs', 'woolytube.log'));
  });

  final Future<File> Function() _resolveFile;
  final int maxBytes;

  static const _writesBetweenSizeChecks = 40;

  File? _file;
  bool _unavailable = false;
  final _pending = <String>[];
  bool _flushScheduled = false;
  Future<void> _writes = Future<void>.value();
  int _writesSinceSizeCheck = 0;

  void add(String line) {
    if (_unavailable) return;
    _pending.add(line);
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() => unawaited(flush()));
  }

  /// Writes everything added so far; completes when it is on disk.
  Future<void> flush() {
    _flushScheduled = false;
    if (_pending.isNotEmpty) {
      final chunk = '${_pending.join('\n')}\n';
      _pending.clear();
      _writes = _writes.then((_) => _append(chunk));
    }
    return _writes;
  }

  Future<void> _append(String chunk) async {
    try {
      final file = await _open();
      if (file == null) return;
      await file.writeAsString(chunk, mode: FileMode.append, flush: true);
      if (++_writesSinceSizeCheck >= _writesBetweenSizeChecks) {
        _writesSinceSizeCheck = 0;
        await _rotateIfLarge(file);
      }
    } catch (_) {
      // Logging must never break the app; a lost batch is acceptable.
    }
  }

  Future<File?> _open() async {
    if (_unavailable) return null;
    final known = _file;
    if (known != null) return known;
    try {
      final file = await _resolveFile();
      await file.parent.create(recursive: true);
      await _rotateIfLarge(file);
      return _file = file;
    } catch (_) {
      _unavailable = true;
      _pending.clear();
      return null;
    }
  }

  Future<void> _rotateIfLarge(File file) async {
    try {
      if (await file.exists() && await file.length() > maxBytes) {
        await file.rename('${file.path}.1');
      }
    } catch (_) {
      // The other engine may have rotated it at the same moment.
    }
  }

  /// The saved lines, oldest first (the rotated file, then the current one).
  Future<List<String>> readLines() async {
    await flush();
    final file = await _open();
    if (file == null) return const [];
    final lines = <String>[];
    for (final path in ['${file.path}.1', file.path]) {
      try {
        final part = File(path);
        if (!await part.exists()) continue;
        lines.addAll(
          (await part.readAsString()).split('\n').where((l) => l.isNotEmpty),
        );
      } catch (_) {
        // A half-written or unreadable part is skipped.
      }
    }
    return lines;
  }

  /// Deletes the saved log, including the rotated part.
  Future<void> clear() async {
    _pending.clear();
    await flush();
    final file = await _open();
    if (file == null) return;
    for (final path in [file.path, '${file.path}.1']) {
      try {
        final part = File(path);
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }

  void dispose() {
    unawaited(flush());
  }
}

class LogService {
  static const int maxEntries = 500;
  static const appSource = 'app';
  static const backgroundSource = 'background';

  /// Without a [sink], the log is saved to the shared file on Android (see
  /// [LogFileSink.appDocuments]) and kept in memory only elsewhere, such as
  /// in tests. [source] marks the lines this instance writes.
  LogService({LogFileSink? sink, this.source = appSource})
    : _sink = sink ?? (Platform.isAndroid ? LogFileSink.appDocuments() : null);

  /// A log that is kept in memory only.
  LogService.memoryOnly({this.source = appSource}) : _sink = null;

  final String source;
  final LogFileSink? _sink;

  /// Whether lines are also saved to the shared log file.
  bool get persists => _sink != null;

  final List<LogEntry> _entries = [];

  /// The most recent entries of this run, oldest first.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  final _controller = StreamController<LogEntry>.broadcast();

  /// Every new entry of this instance as it is logged.
  Stream<LogEntry> get onEntry => _controller.stream;

  void _add(String level, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      source: source,
    );
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    _sink?.add(entry.toLine());
    if (!_controller.isClosed) _controller.add(entry);
  }

  void info(String message) => _add('info', message);
  void warn(String message) => _add('warn', message);
  void error(String message) => _add('error', message);

  /// The saved log of this and earlier runs, including the background
  /// worker's lines, oldest first. Without a log file, this run's entries.
  Future<List<LogEntry>> history() async {
    final sink = _sink;
    if (sink == null) return entries;
    final lines = await sink.readLines();
    final parsed = <LogEntry>[];
    for (final line in lines) {
      final entry = LogEntry.parseLine(line);
      if (entry != null) parsed.add(entry);
    }
    if (parsed.isEmpty) return entries;
    return parsed;
  }

  /// Forgets this run's entries and deletes the saved log.
  Future<void> clear() async {
    _entries.clear();
    await _sink?.clear();
  }

  /// Writes pending lines to the log file.
  Future<void> flush() => _sink?.flush() ?? Future<void>.value();

  void dispose() {
    _sink?.dispose();
    _controller.close();
  }
}
