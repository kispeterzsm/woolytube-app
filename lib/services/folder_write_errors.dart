/// A file the app keeps in the library folders that could not be written.
class FolderWriteError {
  const FolderWriteError({
    required this.key,
    required this.what,
    required this.message,
    required this.firstAt,
    required this.lastAt,
    required this.count,
    required this.resolved,
  });

  /// Which file, as [FolderWriteErrors.failed] named it.
  final String key;

  /// The file in the owner's words, such as `Metadata file of "Mix"`.
  final String what;

  /// The last error.
  final String message;

  final DateTime firstAt;
  final DateTime lastAt;

  /// How many writes failed since the app started.
  final int count;

  /// A later write of the same file worked.
  final bool resolved;
}

/// The files in the library folders that could not be written since the
/// app started, for "Check backup".
///
/// The mirrors that keep the library folders up to date (metadata,
/// settings, library, loudness and lyrics files) write in the background
/// and could only log a failure, which nobody reads. They report each
/// failure here, and each later success of the same file, so the owner
/// sees when the folders stopped being a complete backup.
///
/// It is static, like `SettingsChanges`, because the writers are created
/// in different places; it lives only as long as the app runs.
abstract final class FolderWriteErrors {
  static final _errors = <String, FolderWriteError>{};

  /// The clock for the times. Tests only.
  static DateTime Function() clock = DateTime.now;

  /// Notes that writing [key] (described as [what]) failed with [error].
  static void failed(String key, String what, Object error) {
    final now = clock();
    final earlier = _errors[key];
    _errors[key] = FolderWriteError(
      key: key,
      what: what,
      message: '$error',
      firstAt: earlier?.firstAt ?? now,
      lastAt: now,
      count: (earlier?.count ?? 0) + 1,
      resolved: false,
    );
  }

  /// Notes that [key] was written: an earlier failure is marked resolved.
  static void succeeded(String key) {
    final earlier = _errors[key];
    if (earlier == null || earlier.resolved) return;
    _errors[key] = FolderWriteError(
      key: earlier.key,
      what: earlier.what,
      message: earlier.message,
      firstAt: earlier.firstAt,
      lastAt: earlier.lastAt,
      count: earlier.count,
      resolved: true,
    );
  }

  /// Every failure since the app started, the newest first.
  static List<FolderWriteError> get all =>
      _errors.values.toList()..sort((a, b) => b.lastAt.compareTo(a.lastAt));

  /// The failures not followed by a successful write.
  static List<FolderWriteError> get unresolved =>
      all.where((error) => !error.resolved).toList();

  /// Forgets every failure. Tests only.
  static void clearForTesting() {
    _errors.clear();
    clock = DateTime.now;
  }
}
