import 'dart:async';

import 'package:media_kit/media_kit.dart' as kit;
import 'package:woolytube/services/audio_focus_controller.dart';

/// Minimal media_kit stream surface for [FakePlayer].
class FakePlayerStreams implements kit.PlayerStream {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration>.broadcast(sync: true);
  final completions = StreamController<bool>.broadcast(sync: true);
  final playingChanges = StreamController<bool>.broadcast(sync: true);
  @override
  Stream<Duration> get position => positions.stream;
  @override
  Stream<Duration> get duration => durations.stream;
  @override
  Stream<bool> get completed => completions.stream;
  @override
  Stream<bool> get playing => playingChanges.stream;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// An in-memory stand-in for the native player that records what the
/// playback service asked it to do.
class FakePlayer implements kit.Player {
  @override
  final FakePlayerStreams stream = FakePlayerStreams();
  @override
  kit.PlayerState state = const kit.PlayerState(
    duration: Duration(seconds: 60),
  );
  final opened = <kit.Media>[];
  final seeks = <Duration>[];
  int plays = 0;
  int stops = 0;

  /// When set, [open] waits for it so tests can act while a load is in flight.
  Completer<void>? openGate;

  @override
  Future<void> open(kit.Playable playable, {bool play = true}) async {
    final gate = openGate;
    if (gate != null) await gate.future;
    final media = playable as kit.Media;
    opened.add(media);
    state = state.copyWith(
      position: media.start ?? Duration.zero,
      completed: false,
      playing: play,
    );
    stream.playingChanges.add(play);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    stream.playingChanges.add(false);
  }

  @override
  Future<void> play() async {
    plays++;
    state = state.copyWith(playing: true);
    stream.playingChanges.add(true);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    state = state.copyWith(position: position);
    // The native player reports the new position asynchronously; emitting it
    // in the same turn would re-enter the sync position stream.
    scheduleMicrotask(() {
      if (!stream.positions.isClosed) stream.positions.add(position);
    });
  }

  void tick(Duration position) {
    state = state.copyWith(position: position);
    stream.positions.add(position);
  }

  void finish() {
    state = state.copyWith(completed: true, playing: false);
    stream.completions.add(true);
  }

  @override
  Future<void> stop() async {
    stops++;
    await pause();
  }

  @override
  Future<void> dispose() async {
    await stream.positions.close();
    await stream.durations.close();
    await stream.completions.close();
    await stream.playingChanges.close();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// A scriptable audio session: [grantFocus] decides whether focus requests
/// succeed, and interruptions can be injected.
class FakeAudioSession implements PlaybackAudioSession {
  final _interruptions = StreamController<AudioInterruptionEvent>.broadcast();
  final _noisy = StreamController<void>.broadcast();
  final activeChanges = <bool>[];
  bool grantFocus = true;

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      _interruptions.stream;

  @override
  Stream<void> get becomingNoisyStream => _noisy.stream;

  @override
  Future<void> configureForMediaPlayback() async {}

  @override
  Future<bool> setActive(bool active) async {
    if (active && !grantFocus) return false;
    activeChanges.add(active);
    return true;
  }

  void interrupt({required bool begin, required AudioInterruptionType type}) =>
      _interruptions.add(AudioInterruptionEvent(begin, type));

  void becomeNoisy() => _noisy.add(null);

  Future<void> dispose() async {
    await _interruptions.close();
    await _noisy.close();
  }
}
