import 'download_service.dart' show DownloadLock;

/// Thrown when a library change is refused because another one is running.
class LibraryBusyException implements Exception {
  final String message;

  const LibraryBusyException(this.message);

  @override
  String toString() => message;
}

/// Lets only one operation change the library files at a time.
///
/// Downloads, playlist sync, force insert, local replacement, renames, mode
/// switches and file deletion all rename or write files inside playlist
/// folders, and several of them derive file names from track indices. Any
/// two of them running together can attach a file to the wrong track or
/// delete the only copy of a song, so each one enters this gate first.
///
/// Within one Flutter engine the gate is a simple in-process flag. Across
/// engines (the app and the hourly background worker) it holds the shared
/// [DownloadLock] file for the whole operation.
class LibraryGate {
  LibraryGate({DownloadLock? lock, required this.owner}) : _lock = lock;

  /// A gate without a lock file, for tests and tools that run alone.
  LibraryGate.unlocked() : _lock = null, owner = DownloadLock.foregroundOwner;

  final DownloadLock? _lock;
  final String owner;
  String? _activeOperation;

  bool get isBusy => _activeOperation != null;

  /// Name of the operation that currently holds the gate in this engine.
  String? get activeOperation => _activeOperation;

  /// Message shown when another engine holds the lock.
  String get _otherEngineMessage =>
      owner == DownloadLock.backgroundOwner
          ? 'A download started from the app is running.'
          : 'A scheduled update is running in the background. '
              'Try again in a few minutes.';

  /// Enters the gate, or returns the reason it is busy.
  Future<String?> tryEnter(String operation) async {
    final active = _activeOperation;
    if (active != null) {
      return 'Wait until the current $active finishes.';
    }
    // Reserve before the first await so two callers cannot both get in.
    _activeOperation = operation;
    final lock = _lock;
    if (lock == null) return null;
    try {
      if (await lock.acquire(owner)) return null;
    } catch (_) {
      // Treat an unreadable lock directory as busy rather than proceed
      // unprotected.
    }
    _activeOperation = null;
    return _otherEngineMessage;
  }

  /// Keeps a long operation from being mistaken for an abandoned one.
  Future<void> refresh() async {
    if (_activeOperation == null) return;
    await _lock?.refresh(owner);
  }

  Future<void> exit() async {
    if (_activeOperation == null) return;
    _activeOperation = null;
    try {
      await _lock?.release(owner);
    } catch (_) {
      // A lock that cannot be removed goes stale on its own.
    }
  }

  /// Runs [action] inside the gate, or throws [LibraryBusyException].
  Future<T> run<T>(String operation, Future<T> Function() action) async {
    final busy = await tryEnter(operation);
    if (busy != null) throw LibraryBusyException(busy);
    try {
      return await action();
    } finally {
      await exit();
    }
  }
}
