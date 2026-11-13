import 'dart:async';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../database/database.dart';
import 'library_gate.dart';
import 'log_service.dart';
import 'loudness_file.dart';
import 'sidecar_mirror.dart';

/// Keeps every playlist folder's `.woolytube_info/loudness.json` (see
/// `loudness_file.dart`) in step with the loudness measurements.
///
/// Measuring the library stores a new measurement every few seconds for
/// hours, so the files are not rewritten after each one like the sidecar:
/// they are written at most every [interval], or as soon as [batch]
/// measurements have come in. Only files whose content changed are
/// rewritten.
///
/// Once after [start], measurements kept in the folders are first taken
/// back for songs that have none (a reinstall, or folders copied from
/// another phone), then the files are written.
class LoudnessMirror {
  LoudnessMirror(
    this._db,
    this._gate, {
    LogService? log,
    this.interval = const Duration(seconds: 60),
    this.batch = 50,
    this.startDelay = const Duration(seconds: 30),
    this.onSeeded,
  }) : _log = log;

  final AppDatabase _db;
  final LibraryGate _gate;
  final LogService? _log;

  /// Longest time a new measurement waits before it reaches the folder.
  final Duration interval;

  /// This many new measurements are written without waiting for
  /// [interval].
  final int batch;

  /// Wait before the first pass after [start], so it does not compete with
  /// the app opening.
  final Duration startDelay;

  /// Called with how many measurements the first pass took back from the
  /// folders, when it took any.
  final void Function(int seeded)? onSeeded;

  StreamSubscription<Set<TableUpdate>>? _subscription;
  Timer? _timer;
  Duration? _dueAt;
  final _clock = Stopwatch()..start();
  int _changes = 0;
  bool _seeded = false;
  bool _running = false;
  bool _pending = false;
  String? _lastError;

  void start() {
    if (_subscription != null) return;
    _subscription = _db
        .tableUpdates(TableUpdateQuery.onAllTables([_db.loudnessMeasurements]))
        .listen((_) => _changed());
    _schedule(startDelay);
  }

  void _changed() {
    _changes++;
    // Never pushed back by later changes: measuring the library never
    // pauses long enough for a quiet-time wait to end.
    _schedule(_changes >= batch ? Duration.zero : interval);
  }

  /// Flushes after [after], unless a flush is already due sooner.
  void _schedule(Duration after) {
    final due = _clock.elapsed + after;
    final pending = _dueAt;
    if (_timer?.isActive == true && pending != null && pending <= due) return;
    _timer?.cancel();
    _dueAt = due;
    _timer = Timer(after, () {
      _dueAt = null;
      unawaited(flush());
    });
  }

  /// Takes measurements back from the folders (first call only), then
  /// writes every playlist's loudness file whose content changed.
  Future<void> flush() async {
    if (_running) {
      _pending = true;
      return;
    }
    if (SidecarMirror.folderChangingOperations.contains(
      _gate.activeOperation,
    )) {
      _schedule(interval);
      return;
    }
    _running = true;
    _changes = 0;
    try {
      if (!_seeded) {
        _seeded = true;
        await _seed();
      }
      final playlists = await _db.getAllPlaylists();
      final perFolder = <String, int>{};
      for (final playlist in playlists) {
        final key = _folderKey(playlist.outputPath);
        perFolder[key] = (perFolder[key] ?? 0) + 1;
      }
      final tracks = await _db.getAllTracks();
      final byPlaylist = <int, List<Track>>{};
      for (final track in tracks) {
        byPlaylist.putIfAbsent(track.playlistId, () => []).add(track);
      }
      final measurements = await _db.getLoudnessMeasurements();
      for (final playlist in playlists) {
        // Two playlists in one folder would overwrite each other's file;
        // the startup check gives each its own folder first.
        if ((perFolder[_folderKey(playlist.outputPath)] ?? 0) > 1) continue;
        if (SidecarMirror.folderChangingOperations.contains(
          _gate.activeOperation,
        )) {
          // Started meanwhile; finish after it.
          _pending = true;
          break;
        }
        try {
          await writeLoudnessFile(
            _db,
            playlist,
            tracks: byPlaylist[playlist.id] ?? const [],
            measurements: measurements,
          );
          _lastError = null;
        } catch (e) {
          // Said once until it works again: it is tried after every batch.
          final error = '$e';
          if (error != _lastError) {
            _lastError = error;
            _log?.warn('Could not save the loudness of "${playlist.name}": $e');
          }
        }
      }
    } catch (e) {
      _log?.warn('Loudness mirror failed: $e');
    } finally {
      _running = false;
      if (_pending) {
        _pending = false;
        _schedule(interval);
      }
    }
  }

  Future<void> _seed() async {
    var seeded = 0;
    for (final playlist in await _db.getAllPlaylists()) {
      try {
        seeded += await seedLoudnessFromFolder(_db, playlist);
      } catch (e) {
        _log?.warn('Could not read the loudness of "${playlist.name}": $e');
      }
    }
    if (seeded > 0) {
      _log?.info('loudness: took back $seeded measurements from the folders');
      onSeeded?.call(seeded);
    }
  }

  static String _folderKey(String path) =>
      p.normalize(p.absolute(path)).toLowerCase();

  Future<void> dispose() async {
    _timer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
  }
}
