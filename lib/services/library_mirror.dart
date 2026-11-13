import 'dart:async';

import 'package:drift/drift.dart';

import '../database/database.dart';
import 'library_file.dart';
import 'log_service.dart';
import 'settings_changes.dart';

/// Keeps `woolytube_library.json` (see [LibraryFileService]) in step with
/// the home page order and the player's "where I was" point.
///
/// The file is written a few seconds after the playlists change, and once
/// after [start]. The "where I was" point changes every few seconds while
/// something plays, so it is written at most every [resumeInterval]; a
/// pause or stop reaches the file within that time. Unchanged content is
/// not rewritten.
class LibraryMirror {
  LibraryMirror(
    this._db,
    this._file, {
    LogService? log,
    Stream<void>? resumeChanges,
    this.delay = const Duration(seconds: 4),
    this.startDelay = const Duration(seconds: 20),
    this.resumeInterval = const Duration(seconds: 30),
  }) : _log = log,
       _resumeChanges = resumeChanges ?? ResumePointChanges.stream;

  final AppDatabase _db;
  final LibraryFileService _file;
  final LogService? _log;
  final Stream<void> _resumeChanges;

  /// Quiet time after the last change before the file is written.
  final Duration delay;

  /// Wait before the first write after [start], so it does not compete
  /// with the app opening.
  final Duration startDelay;

  /// Shortest time between two writes for a new "where I was" point.
  final Duration resumeInterval;

  final _subscriptions = <StreamSubscription<Object?>>[];
  final _clock = Stopwatch()..start();
  Timer? _timer;
  Duration? _dueAt;
  Duration? _lastWriteAt;
  bool _running = false;
  bool _pending = false;
  String? _lastError;

  void start() {
    if (_subscriptions.isNotEmpty) return;
    _subscriptions
      ..add(
        _db
            .tableUpdates(TableUpdateQuery.onAllTables([_db.playlists]))
            .listen((_) => _schedule(delay)),
      )
      ..add(_resumeChanges.listen((_) => _scheduleResume()));
    _schedule(startDelay);
  }

  void _schedule(Duration after) {
    _timer?.cancel();
    _dueAt = _clock.elapsed + after;
    _timer = Timer(after, _fire);
  }

  void _scheduleResume() {
    final now = _clock.elapsed;
    var due = now + delay;
    final last = _lastWriteAt;
    if (last != null && last + resumeInterval > due) {
      due = last + resumeInterval;
    }
    final pending = _dueAt;
    if (_timer?.isActive == true && pending != null && pending <= due) return;
    _schedule(due - now);
  }

  void _fire() {
    _dueAt = null;
    unawaited(flush());
  }

  /// Writes the library file now, unless its content is unchanged.
  Future<void> flush() async {
    if (_running) {
      _pending = true;
      return;
    }
    _running = true;
    try {
      await _file.write();
      _lastWriteAt = _clock.elapsed;
      _lastError = null;
    } catch (e) {
      // Said once until it works again: it is tried after every change.
      final error = '$e';
      if (error != _lastError) {
        _lastError = error;
        _log?.warn('Could not save the library file: $e');
      }
    } finally {
      _running = false;
      if (_pending) {
        _pending = false;
        _schedule(delay);
      }
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}
