import 'dart:async';

import '../database/database.dart';
import 'folder_write_errors.dart';
import 'library_export_service.dart';
import 'log_service.dart';
import 'settings_changes.dart';

/// Keeps `Music/WoolyTube/.woolytube_backup/woolytube_settings.json` in step
/// with the owner's settings, so copying the library folders to a computer
/// or another phone always takes the settings along.
///
/// The file is written a moment after settings stop changing (see
/// [SettingsChanges]) and once after [start]. Unchanged content is not
/// rewritten.
///
/// A fresh install must not replace the settings file of a library copied
/// from another phone with its own defaults before that library is
/// restored: while the database has no playlist, playlists found in the
/// folders wait to be restored ([libraryWaitsForRestore]) and a settings
/// file is there, nothing is written. Dismissing the restore starts the
/// mirror writing.
class SettingsMirror {
  SettingsMirror(
    this._db,
    this._exporter, {
    LogService? log,
    bool Function()? libraryWaitsForRestore,
    Stream<void>? changes,
    this.delay = const Duration(seconds: 2),
    this.startDelay = const Duration(seconds: 5),
  }) : _log = log,
       _libraryWaitsForRestore = libraryWaitsForRestore ?? _never,
       _changes = changes ?? SettingsChanges.stream;

  final AppDatabase _db;
  final LibraryExportService _exporter;
  final LogService? _log;
  final bool Function() _libraryWaitsForRestore;
  final Stream<void> _changes;

  static bool _never() => false;

  /// Quiet time after the last change before the file is written.
  final Duration delay;

  /// Wait before the first write after [start], so it does not compete with
  /// the app opening.
  final Duration startDelay;

  /// The [FolderWriteErrors] key of the settings file.
  static const errorKey = 'settings';

  StreamSubscription<void>? _subscription;
  Timer? _timer;
  bool _running = false;
  bool _pending = false;
  String? _lastError;

  void start() {
    if (_subscription != null) return;
    _subscription = _changes.listen((_) => _schedule());
    _schedule(startDelay);
  }

  void _schedule([Duration? after]) {
    _timer?.cancel();
    _timer = Timer(after ?? delay, () => unawaited(flush()));
  }

  /// Writes the settings file now, unless it is unchanged or held back for
  /// a library still to be restored.
  Future<void> flush() async {
    if (_running) {
      _pending = true;
      return;
    }
    _running = true;
    try {
      if (await _waitsForRestore()) return;
      await _exporter.writeSettingsFile();
      _lastError = null;
      FolderWriteErrors.succeeded(errorKey);
    } catch (e) {
      FolderWriteErrors.failed(errorKey, 'Settings file', e);
      // Said once until it works again: it is tried after every change.
      final error = '$e';
      if (error != _lastError) {
        _lastError = error;
        _log?.warn('Could not save the settings file: $e');
      }
    } finally {
      _running = false;
      if (_pending) {
        _pending = false;
        _schedule();
      }
    }
  }

  Future<bool> _waitsForRestore() async {
    if (!_libraryWaitsForRestore()) return false;
    if ((await _db.getAllPlaylists()).isNotEmpty) return false;
    return _exporter.settingsFileExists();
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
  }
}
