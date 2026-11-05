import 'dart:async';

import 'package:drift/drift.dart';

import '../database/database.dart';
import 'library_gate.dart';
import 'log_service.dart';
import 'metadata_service.dart';

/// Keeps every playlist folder's `woolytube_meta.json` and `.m3u8` in step
/// with the database.
///
/// Many small edits (Always skip, skip segments marked in the player,
/// segment edits, chapter edits) change the database without writing the
/// sidecar, and the sidecar is what a reinstall or another device restores
/// from. Instead of relying on every edit site to remember, this watches the
/// tables the sidecar mirrors and rewrites the files a few seconds after the
/// edits stop. Unchanged files are not rewritten.
class SidecarMirror {
  SidecarMirror(
    this._db,
    this._metadata,
    this._gate, {
    LogService? log,
    this.delay = const Duration(seconds: 4),
  }) : _log = log;

  final AppDatabase _db;
  final MetadataService _metadata;
  final LibraryGate _gate;
  final LogService? _log;
  final Duration delay;

  StreamSubscription<Set<TableUpdate>>? _subscription;
  Timer? _timer;
  bool _running = false;
  bool _pending = false;

  void start() {
    if (_subscription != null) return;
    _subscription = _db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            _db.playlists,
            _db.tracks,
            _db.sponsorBlockSegments,
          ]),
        )
        .listen((_) => _schedule());
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  /// Writes all sidecars now. While another operation holds the library
  /// gate (a download, or a playlist being deleted with its files) the write
  /// waits, so it never puts a sidecar back into a folder being emptied.
  Future<void> flush() async {
    if (_running) {
      _pending = true;
      return;
    }
    if (_gate.isBusy) {
      _schedule();
      return;
    }
    _running = true;
    try {
      for (final playlist in await _db.getAllPlaylists()) {
        try {
          await _metadata.writeMetadataFor(playlist.id);
        } catch (e) {
          _log?.warn('Could not update metadata of "${playlist.name}": $e');
        }
      }
    } finally {
      _running = false;
      if (_pending) {
        _pending = false;
        _schedule();
      }
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
  }
}
