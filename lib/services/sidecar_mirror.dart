import 'dart:async';
import 'dart:io';

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
/// edits stop.
///
/// Only playlists that changed are rewritten: SQLite counts the changes of
/// each playlist (see [AppDatabase.playlistRevisions]), and a playlist whose
/// files were last written from its current count is skipped without being
/// read. The files themselves are built off the UI isolate and unchanged
/// files are not rewritten.
class SidecarMirror {
  SidecarMirror(
    this._db,
    this._metadata,
    this._gate, {
    LogService? log,
    this.delay = const Duration(seconds: 4),
    Duration? startDelay,
  }) : _log = log,
       startDelay = startDelay ?? delay * 4;

  final AppDatabase _db;
  final MetadataService _metadata;
  final LibraryGate _gate;
  final LogService? _log;

  /// Quiet time after the last change before the files are written.
  final Duration delay;

  /// Wait before the first pass after [start], so it does not compete with
  /// the app opening.
  final Duration startDelay;

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
            // Pinned docs go into the sidecar as lyricsPins.
            _db.lyricsDocs,
          ]),
        )
        .listen((_) => _schedule());
    // Edits made while the app was last closing, or by the background
    // worker, have no table event in this engine: check every playlist once.
    _schedule(startDelay);
  }

  void _schedule([Duration? after]) {
    _timer?.cancel();
    _timer = Timer(after ?? delay, () => unawaited(flush()));
  }

  /// Operations that move or empty a playlist folder. While one runs, the
  /// mirror waits, so it never puts a sidecar back into a folder being
  /// emptied or left. Downloads and syncs write their own sidecars.
  static const folderChangingOperations = {
    'playlist deletion',
    'format switch',
    'startup check',
  };

  /// Writes the files of every playlist that changed since they were last
  /// written. Unchanged files are not rewritten.
  Future<void> flush() async {
    if (_running) {
      _pending = true;
      return;
    }
    if (folderChangingOperations.contains(_gate.activeOperation)) {
      _schedule();
      return;
    }
    _running = true;
    try {
      final playlists = await _db.getAllPlaylists();
      final revisions = await _db.playlistRevisions();
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
        if (folderChangingOperations.contains(_gate.activeOperation)) {
          // Started meanwhile; finish after it.
          _pending = true;
          break;
        }
        final revision = revisions[playlist.id] ?? 0;
        if (_metadata.writtenRevision(playlist.id) == revision &&
            await File(
              p.join(playlist.outputPath, MetadataService.metaFileName),
            ).exists()) {
          continue;
        }
        try {
          await _metadata.writeMetadataFor(playlist.id);
        } catch (e) {
          _log?.warn('Could not update metadata of "${playlist.name}": $e');
        }
      }
    } catch (e) {
      _log?.warn('Metadata mirror failed: $e');
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
