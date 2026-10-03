import 'dart:async';

import 'package:audio_session/audio_session.dart';

export 'package:audio_session/audio_session.dart'
    show AudioInterruptionEvent, AudioInterruptionType;

/// The small portion of [AudioSession] used by [AudioFocusController].
///
/// Keeping this behind an interface makes the focus policy testable without
/// Android platform channels.
abstract interface class PlaybackAudioSession {
  /// Raw focus interruptions: begin/end plus how the platform wants us to
  /// react (pause for a transient loss, duck, or an indefinite loss).
  Stream<AudioInterruptionEvent> get interruptionEventStream;

  /// Fires when the output route disappears, such as a headphone unplug or a
  /// Bluetooth disconnect.
  Stream<void> get becomingNoisyStream;

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
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      _session.interruptionEventStream;

  @override
  Stream<void> get becomingNoisyStream => _session.becomingNoisyEventStream;

  @override
  Future<void> configureForMediaPlayback() {
    // Android lowers the volume itself during a duck, so a notification or a
    // navigation prompt must not stop playback.
    return _session.configure(
      const AudioSessionConfiguration.music().copyWith(
        androidWillPauseWhenDucked: false,
      ),
    );
  }

  @override
  Future<bool> setActive(bool active) => _session.setActive(active);
}

/// Owns platform audio focus while WoolyTube is playing.
///
/// Policy:
/// * A transient loss (phone call, assistant) pauses and resumes when the
///   interruption ends, provided playback was running when it began. Focus is
///   kept during the loss, otherwise the end event would never arrive.
/// * A duck is left to the platform's volume reduction and never pauses.
/// * A permanent loss pauses for good and abandons focus.
/// * Becoming noisy (headphones unplugged) always pauses, even when the
///   "pause for other apps" option is disabled.
class AudioFocusController {
  AudioFocusController({
    required PlaybackAudioSession session,
    required Future<void> Function() pausePlayback,
    required Future<void> Function() resumePlayback,
    required bool Function() isPlaying,
  }) : _session = session,
       _pausePlayback = pausePlayback,
       _resumePlayback = resumePlayback,
       _isPlaying = isPlaying;

  final PlaybackAudioSession _session;
  final Future<void> Function() _pausePlayback;
  final Future<void> Function() _resumePlayback;
  final bool Function() _isPlaying;

  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _noisySubscription;
  bool _enabled = true;
  bool _hasFocus = false;
  bool _resumeAfterInterruption = false;

  bool get enabled => _enabled;

  Future<void> initialize({required bool enabled}) async {
    _enabled = enabled;
    await _session.configureForMediaPlayback();
    _interruptionSubscription = _session.interruptionEventStream.listen((
      event,
    ) {
      if (!_enabled) return;
      unawaited(_handleInterruption(event));
    });
    _noisySubscription = _session.becomingNoisyStream.listen((_) {
      unawaited(_pauseForNoisyRoute());
    });
  }

  Future<void> _handleInterruption(AudioInterruptionEvent event) async {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          return;
        case AudioInterruptionType.pause:
          _resumeAfterInterruption = _isPlaying();
          if (_resumeAfterInterruption) await _pausePlayback();
        case AudioInterruptionType.unknown:
          _resumeAfterInterruption = false;
          await _pausePlayback();
          await abandonFocus();
      }
      return;
    }
    switch (event.type) {
      case AudioInterruptionType.duck:
      case AudioInterruptionType.unknown:
        return;
      case AudioInterruptionType.pause:
        if (!_resumeAfterInterruption) return;
        _resumeAfterInterruption = false;
        await _resumePlayback();
    }
  }

  Future<void> _pauseForNoisyRoute() async {
    _resumeAfterInterruption = false;
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
    // An explicit request means playback is taking charge again, so a stale
    // interruption must not resume it later on its own.
    _resumeAfterInterruption = false;
    if (!_enabled || _hasFocus) return true;
    _hasFocus = await _session.setActive(true);
    return _hasFocus;
  }

  Future<void> abandonFocus() async {
    _resumeAfterInterruption = false;
    if (!_hasFocus) return;
    _hasFocus = false;
    await _session.setActive(false);
  }

  Future<void> dispose() async {
    await _interruptionSubscription?.cancel();
    await _noisySubscription?.cancel();
    await abandonFocus();
  }
}
