import 'dart:async';

/// Says that a setting the owner chose was just stored, so the settings
/// file in the library folder is written again (see `SettingsMirror`).
///
/// Every setter of a backed-up setting calls [notify]. It is a static
/// signal because settings are stored by several small services that are
/// created in different places; the mirror listens in the app engine only.
abstract final class SettingsChanges {
  static final _controller = StreamController<void>.broadcast();

  static Stream<void> get stream => _controller.stream;

  static void notify() {
    if (_controller.hasListener) _controller.add(null);
  }
}

/// Says that the player stored a new "where I was" point (see
/// `PlaybackSettingsStore.saveSession`), so the library file in the library
/// folders takes it along (see `LibraryMirror`). The player stores it about
/// every 15 s while playing and on pause, stop and track changes; the
/// mirror writes it far less often.
abstract final class ResumePointChanges {
  static final _controller = StreamController<void>.broadcast();

  static Stream<void> get stream => _controller.stream;

  static void notify() {
    if (_controller.hasListener) _controller.add(null);
  }
}
