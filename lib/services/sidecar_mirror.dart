import 'dart:async';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

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
    // Edits made while the app was last closing, or by the background
    // worker, have no table event in this engine: write once now.
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  /// Operations that move or empty a playlist folder. While one runs, the
  /// mirror waits, so it never puts a sidecar back into a folder being
  /// emptied or left. Downloads and syncs write their own sidecars.
  static const _folderChangingOperations = {
    'playlist deletion',
    'format switch',
    'startup check',
  };

  /// Writes all sidecars that changed. Unchanged files are not rewritten.
  Future<void> flush() async {
    if (_running) {
      _pending = true;
      return;
    }
    if (_folderChangingOperations.contains(_gate.activeOperation)) {
      _schedule();
      return;
    }
    _running = true;
    try {
      final playlists = await _db.getAllPlaylists();
      final perFolder = <String, int>{};
      for (final playlist in playlists) {
        final key = p.normalize(p.absolute(playlist.outputPath)).toLowerCase();
        perFolder[key] = (perFolder[key] ?? 0) + 1;
      }
      for (final playlist in playlists) {
        final key = p.normalize(p.absolute(playlist.outputPath)).toLowerCase();
        if ((perFolder[key] ?? 0) > 1) {
          // Two playlists in one folder would overwrite each other's file;
          // the startup check gives each its own folder first.
          continue;
        }
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
