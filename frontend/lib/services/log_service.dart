import 'dart:async';
import 'package:intl/intl.dart';

class LogEntry {
  final DateTime timestamp;
  final String level; // info | error | warn
  final String message;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  String get formatted {
    final ts = DateFormat('HH:mm:ss').format(timestamp);
    return '[$ts] ${level.toUpperCase()}: $message';
  }
}

class LogService {
  static const int maxEntries = 500;

  final List<LogEntry> _entries = [];
  List<LogEntry> get entries => List.unmodifiable(_entries);

  final _controller = StreamController<List<LogEntry>>.broadcast();
  Stream<List<LogEntry>> get stream => _controller.stream;

  void _add(String level, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
    );
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    _controller.add(entries);
  }

  void info(String message) => _add('info', message);
  void warn(String message) => _add('warn', message);
  void error(String message) => _add('error', message);

  void clear() {
    _entries.clear();
    _controller.add(entries);
  }

  void dispose() {
    _controller.close();
  }
}
