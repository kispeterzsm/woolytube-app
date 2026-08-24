import 'dart:async';

import 'package:audio_session/audio_session.dart';

/// The small portion of [AudioSession] used by [AudioFocusController].
///
/// Keeping this behind an interface makes the focus policy testable without
/// Android platform channels.
abstract interface class PlaybackAudioSession {
  Stream<void> get interruptionStartStream;

  Future<void> configureForMediaPlayback();

  Future<bool> setActive(bool active);
}

class PlatformPlaybackAudioSession implements PlaybackAudioSession {
  PlatformPlaybackAudioSession(this._session);

  final AudioSession _session;

  static Future<PlatformPlaybackAudioSession> create() async {
    return PlatformPlaybackAudioSession(await AudioSession.instance);
  }

  @override
  Stream<void> get interruptionStartStream => _session.interruptionEventStream
      .where((event) => event.begin)
      .map((_) {});

  @override
  Future<void> configureForMediaPlayback() {
    return _session.configure(
      const AudioSessionConfiguration.music().copyWith(
        androidWillPauseWhenDucked: true,
      ),
    );
  }

  @override
  Future<bool> setActive(bool active) => _session.setActive(active);
}

/// Owns platform audio focus while WoolyTube is playing.
///
/// Focus-loss interruptions pause playback but deliberately do not resume it
/// automatically when the other app stops.
class AudioFocusController {
  AudioFocusController({
    required PlaybackAudioSession session,
    required Future<void> Function() pausePlayback,
    required bool Function() isPlaying,
  }) : _session = session,
       _pausePlayback = pausePlayback,
       _isPlaying = isPlaying;

  final PlaybackAudioSession _session;
  final Future<void> Function() _pausePlayback;
  final bool Function() _isPlaying;

  StreamSubscription<void>? _interruptionSubscription;
  bool _enabled = true;
  bool _hasFocus = false;

  bool get enabled => _enabled;

  Future<void> initialize({required bool enabled}) async {
    _enabled = enabled;
    await _session.configureForMediaPlayback();
    _interruptionSubscription = _session.interruptionStartStream.listen((_) {
      if (!_enabled) return;
      unawaited(_pauseForInterruption());
    });
  }

  Future<void> _pauseForInterruption() async {
    await _pausePlayback();
    await abandonFocus();
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    if (!enabled) {
      await abandonFocus();
    } else if (_isPlaying()) {
      if (!await requestFocus()) await _pausePlayback();
    }
  }

  Future<bool> requestFocus() async {
    if (!_enabled || _hasFocus) return true;
    _hasFocus = await _session.setActive(true);
    return _hasFocus;
  }

  Future<void> abandonFocus() async {
    if (!_hasFocus) return;
    _hasFocus = false;
    await _session.setActive(false);
  }

  Future<void> dispose() async {
    await _interruptionSubscription?.cancel();
    await abandonFocus();
  }
}
