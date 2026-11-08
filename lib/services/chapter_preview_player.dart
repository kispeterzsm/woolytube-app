import 'dart:async';
import 'dart:math';

import 'package:media_kit/media_kit.dart';

/// The stretch of the file a preview is playing. [endMs] is null when it
/// plays on to the end of the file.
typedef PreviewRange = ({int startMs, int? endMs, bool loop});

/// A second, audio-only player for the chapter editor and the recognition
/// review. It plays one file on its own and never touches the main queue,
/// the notification or the playback service, except to pause the main
/// player when a preview starts, and to pause itself when the main player
/// starts again, so the two are never heard together.
///
/// Positions are on the file timeline in milliseconds. The player is owned
/// by this object and disposed with it.
class ChapterPreviewPlayer {
  /// How close to the end of a range playback is stopped.
  static const _stopEarlyMs = 15;

  /// Position reports this far from a seek target are left over from
  /// before the seek.
  static const _staleSeekMs = 250;

  /// A report that is behind the estimate by less than this is eased in
  /// instead of shown, so the playhead never runs backwards while playing.
  static const _slewMs = 80;

  final String filePath;
  final Future<void> Function()? _pauseMainPlayer;
  final Stream<bool> Function()? _mainPlaying;
  StreamSubscription<bool>? _mainPlayingSubscription;
  final Duration _openTimeout;
  final int Function() _nowMs;
  Player? _player;

  final _duration = _Value<Duration>(Duration.zero);
  final _position = StreamController<int>.broadcast();
  final _playing = _Value<bool>(false);
  final _range = _Value<PreviewRange?>(null);
  Completer<void>? _durationKnown;
  final _subscriptions = <StreamSubscription<Object?>>[];

  Future<void>? _opening;
  bool _disposed = false;

  /// Bumped by every command, so stop timers and loops of an older command
  /// never act.
  int _generation = 0;
  Timer? _stopTimer;

  /// Last reported position (or seek) and when it came.
  int _reportedMs = 0;
  int _reportedAt = 0;

  /// What [positionMs] estimates from while playing: the playhead shown at
  /// [_anchorAt], and how far it is ahead of the reports ([_lagMs], paid
  /// back at half speed). While paused, [_anchorMs] is the position.
  int _anchorMs = 0;
  int _anchorAt = 0;
  int _lagMs = 0;

  /// Where the active range comes to rest when it ends; null rests on its
  /// end.
  int? _restMs;
  bool _parked = false;

  /// A seek whose position has not been reported yet.
  int? _seekTarget;
  int _seekAt = 0;
  Completer<void>? _seekSettled;

  ChapterPreviewPlayer({
    required this.filePath,
    Player? player,
    Future<void> Function()? pauseMainPlayer,
    Stream<bool> Function()? mainPlaying,
    Duration openTimeout = const Duration(seconds: 8),
    int Function()? nowMs,
  }) : _player = player,
       _pauseMainPlayer = pauseMainPlayer,
       _mainPlaying = mainPlaying,
       _openTimeout = openTimeout,
       _nowMs = nowMs ?? _stopwatchMs();

  static int Function() _stopwatchMs() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  // Streams send changes only; the getters give the current value.

  /// The real length of the file; zero until it is open.
  Duration get duration => _duration.value;
  Stream<Duration> get durationStream => _duration.stream;

  int get _durationMs => _duration.value.inMilliseconds;

  /// The best estimate of the playhead, between position reports too.
  /// While playing it never runs backwards: small corrections are eased in.
  int get positionMs {
    final target = _seekTarget;
    if (target != null) return target;
    if (!isPlaying) return _anchorMs;
    final elapsed = (_nowMs() - _anchorAt).clamp(0, 1000);
    return _clampToFile(_anchorMs + elapsed - min(_lagMs, elapsed ~/ 2));
  }

  /// The playhead from the last report alone, for the stop timer.
  int get _rawPositionMs {
    final target = _seekTarget;
    if (target != null) return target;
    if (!isPlaying) return _anchorMs;
    final elapsed = (_nowMs() - _reportedAt).clamp(0, 1000);
    return _clampToFile(_reportedMs + elapsed);
  }

  int _clampToFile(int ms) => _durationMs > 0 ? min(ms, _durationMs) : ms;

  /// True after a range preview ended and the playhead came to rest at the
  /// spot the preview chose (see [playRange]'s restMs), or after a seek
  /// with `park`. False again once anything else moves or plays it, so a
  /// position the user picked is never mistaken for a parked one.
  bool get parked => _parked;

  /// Where the active range will come to rest, or null without a range.
  int? get restMs => _range.value == null ? null : _restMs;

  /// Positions as the player reports them (and seek targets right away).
  Stream<int> get positionMsStream => _position.stream;

  bool get isPlaying => _playing.value;
  Stream<bool> get playingStream => _playing.stream;

  /// The range being previewed, or null during free play or when paused.
  PreviewRange? get activeRange => _range.value;
  Stream<PreviewRange?> get activeRangeStream => _range.stream;

  /// Opens the file (paused) if it is not open yet. Completes once the
  /// player knows the file's length.
  Future<void> ensureOpen() {
    if (_disposed) return Future.error(StateError('Preview player closed'));
    return _opening ??= _open().catchError((Object error) {
      _opening = null;
      throw error;
    });
  }

  Future<void> _open() async {
    final player = _player ??= Player();
    _listen(player);
    await _configure(player);
    final started = _nowMs();
    try {
      await player
          .open(Media(Uri.file(filePath).toString()), play: false)
          .timeout(_openTimeout);
      _setDuration(player.state.duration);
      // The length is reported once the file has loaded; seeks sent before
      // that are dropped by the player. [_listen] already feeds [_duration].
      if (_duration.value <= Duration.zero) {
        final left = _openTimeout - Duration(milliseconds: _nowMs() - started);
        final known = _durationKnown = Completer<void>();
        await known.future.timeout(left > Duration.zero ? left : Duration.zero);
      }
    } catch (_) {
      if (_disposed) throw StateError('Preview player closed');
      throw StateError('Could not open the file');
    }
  }

  void _listen(Player player) {
    if (_subscriptions.isNotEmpty) return;
    _subscriptions.addAll([
      player.stream.duration.listen(_setDuration),
      player.stream.position.listen(_onPosition),
      player.stream.playing.listen(_onPlaying),
      player.stream.completed.listen((done) {
        if (done) _onEnd(_generation);
      }),
    ]);
  }

  /// Audio only, sample-exact seeks. Not available in tests.
  Future<void> _configure(Player player) async {
    try {
      final native = player.platform;
      if (native is! NativePlayer) return;
      await native.setProperty('vid', 'no');
      await native.setProperty('hr-seek', 'yes');
      await native.setProperty('audio-display', 'no');
    } catch (_) {}
  }

  void _setDuration(Duration value) {
    if (_disposed || value <= Duration.zero || value == _duration.value) {
      return;
    }
    _duration.add(value);
    _durationKnown?.complete();
    _durationKnown = null;
  }

  void _onPosition(Duration position) {
    if (_disposed) return;
    final ms = position.inMilliseconds;
    final target = _seekTarget;
    if (target != null) {
      final stale =
          (ms - target).abs() > _staleSeekMs && _nowMs() - _seekAt < 1000;
      if (stale) return;
      _seekTarget = null;
      _seekSettled?.complete();
      _seekSettled = null;
    }
    final now = _nowMs();
    final shown = isPlaying && target == null ? positionMs : null;
    final behind = shown == null ? 0 : shown - ms;
    if (behind > 0 && behind < _slewMs) {
      // Slightly behind what is shown: keep going from there, more slowly.
      _anchorMs = shown!;
      _lagMs = behind;
    } else {
      _anchorMs = ms;
      _lagMs = 0;
    }
    _anchorAt = now;
    _reportedMs = ms;
    _reportedAt = now;
    _position.add(ms);
    final range = _range.value;
    final end = range?.endMs;
    if (range != null && end != null && isPlaying) {
      if (ms >= end - _stopEarlyMs) {
        _onEnd(_generation);
      } else {
        _armStop(_generation);
      }
    }
  }

  void _onPlaying(bool playing) {
    if (_disposed || playing == _playing.value) return;
    final now = _nowMs();
    if (playing) {
      _parked = false;
      // Restart the estimate from where it rests.
      _anchorMs = _reportedMs = _seekTarget ?? _anchorMs;
    } else {
      // Rest on the last real position, not on a guess past it: the pause
      // reaches us late, and the player sends no report when it pauses.
      _anchorMs = _seekTarget ?? _reportedMs;
    }
    _anchorAt = _reportedAt = now;
    _lagMs = 0;
    _playing.add(playing);
    if (!playing) _stopTimer?.cancel();
  }

  /// Plays [startMs] to [endMs] (or to the end of the file) and pauses
  /// there, with the playhead resting on [restMs] (the boundary being
  /// listened to), or on [endMs] without one; [parked] is then true. With
  /// [loop] it starts over at [startMs] instead.
  Future<void> playRange(
    int startMs, {
    int? endMs,
    bool loop = false,
    int? restMs,
  }) async {
    final generation = _newCommand();
    await _pauseMain();
    await ensureOpen();
    if (generation != _generation) return;
    final length = _durationMs;
    final start = startMs.clamp(0, length);
    final end = endMs?.clamp(0, length);
    final rest = restMs?.clamp(0, length);
    if (end != null && end - start <= _stopEarlyMs) {
      // Nothing to play: rest where it would have.
      _parked = true;
      await _player?.pause();
      await _seek(rest ?? start);
      return;
    }
    _restMs = rest;
    _range.add((startMs: start, endMs: end, loop: loop));
    await _seek(start, settle: true);
    if (generation != _generation) return;
    await _player?.play();
    if (generation != _generation) return;
    _armStop(generation);
  }

  /// Plays on from the current position with no end.
  Future<void> play() async {
    final generation = _newCommand();
    await _pauseMain();
    await ensureOpen();
    if (generation != _generation) return;
    if (!isPlaying) {
      // The audio output drops what it had queued when it pauses, so a
      // plain resume skips ~0.3 s. A seek to the paused spot first starts
      // exactly there.
      await _seek(positionMs);
      if (generation != _generation) return;
    }
    await _player?.play();
  }

  Future<void> pause() async {
    final generation = _newCommand();
    final player = _player;
    if (player == null || _opening == null) return;
    await player.pause();
    await _readPausedPosition(generation);
  }

  /// Moves the playhead to [ms] (clamped to the file) without changing
  /// whether it plays. Any range preview ends. With [park] the playhead
  /// counts as [parked] there (a spot the app chose, not the user).
  Future<void> seek(int ms, {bool park = false}) async {
    final generation = _newCommand();
    _parked = park;
    await ensureOpen();
    if (generation != _generation) return;
    await _seek(ms.clamp(0, _durationMs));
  }

  /// Changes where the active range comes to rest when it ends, e.g. when
  /// the boundary it plays moved. It keeps playing as it was.
  void moveRest(int ms) {
    if (_disposed || _range.value == null) return;
    _restMs = _durationMs > 0 ? ms.clamp(0, _durationMs) : max(0, ms);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _newCommand();
    _disposed = true;
    _seekSettled?.complete();
    _seekSettled = null;
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(_mainPlayingSubscription?.cancel());
    _mainPlayingSubscription = null;
    final player = _player;
    _player = null;
    final known = _durationKnown;
    _durationKnown = null;
    known?.completeError(StateError('Preview player closed'));
    // Not awaited: a close waits for listeners that may never cancel.
    unawaited(_duration.close());
    unawaited(_position.close());
    unawaited(_playing.close());
    unawaited(_range.close());
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  int _newCommand() {
    _stopTimer?.cancel();
    _stopTimer = null;
    _parked = false;
    _restMs = null;
    if (!_disposed && _range.value != null) _range.add(null);
    return ++_generation;
  }

  /// The paused position as the player has it, which is exact; the last
  /// report can be one report interval behind.
  Future<void> _readPausedPosition(int generation) async {
    final native = _player?.platform;
    if (native is! NativePlayer) return;
    try {
      final seconds = double.tryParse(await native.getProperty('time-pos'));
      if (seconds == null ||
          _disposed ||
          generation != _generation ||
          _seekTarget != null) {
        return;
      }
      final ms = _clampToFile(max(0, (seconds * 1000).round()));
      _anchorMs = _reportedMs = ms;
      _anchorAt = _reportedAt = _nowMs();
      _lagMs = 0;
      _position.add(ms);
    } catch (_) {}
  }

  Future<void> _pauseMain() async {
    try {
      await _pauseMainPlayer?.call();
    } catch (_) {}
    _followMainPlayer();
  }

  /// From the first preview on, a start of the main player (its mini
  /// player, the notification, a headset) pauses the preview. Only a change
  /// to playing counts, not the state reported when listening starts.
  void _followMainPlayer() {
    final mainPlaying = _mainPlaying;
    if (_disposed || mainPlaying == null || _mainPlayingSubscription != null) {
      return;
    }
    bool? last;
    try {
      _mainPlayingSubscription = mainPlaying().listen((playing) {
        final started = playing && last == false;
        last = playing;
        if (started && !_disposed && isPlaying) unawaited(pause());
      });
    } catch (_) {}
  }

  /// Seeks and shows the target right away. With [settle] it also waits
  /// (briefly) for the player to report the new position, so the stop timer
  /// starts from where playback really is.
  Future<void> _seek(int ms, {bool settle = false}) async {
    final player = _player;
    if (player == null || _disposed) return;
    final alreadyThere = _seekTarget == null && (positionMs - ms).abs() < 5;
    _seekSettled?.complete();
    _seekSettled = null;
    _anchorMs = _reportedMs = ms;
    _anchorAt = _reportedAt = _nowMs();
    _lagMs = 0;
    if (!alreadyThere) {
      _seekTarget = ms;
      _seekAt = _nowMs();
    }
    if (!_position.isClosed) _position.add(ms);
    final settled = alreadyThere ? null : (_seekSettled = Completer<void>());
    await player.seek(Duration(milliseconds: ms));
    if (settle && settled != null && !settled.isCompleted) {
      try {
        await settled.future.timeout(const Duration(milliseconds: 300));
      } on TimeoutException {
        // Play anyway; position reports will correct the stop timer.
      }
    }
  }

  void _armStop(int generation) {
    final end = _range.value?.endMs;
    if (end == null || generation != _generation || !isPlaying) return;
    _stopTimer?.cancel();
    final remaining = end - _rawPositionMs;
    if (remaining <= _stopEarlyMs) {
      _onEnd(generation);
      return;
    }
    _stopTimer = Timer(Duration(milliseconds: remaining), () {
      if (generation != _generation) return;
      _armStop(generation);
    });
  }

  /// The range (or the file) reached its end.
  void _onEnd(int generation) {
    final range = _range.value;
    if (_disposed || generation != _generation || range == null) return;
    _stopTimer?.cancel();
    if (range.loop) {
      unawaited(_restartLoop(generation, range));
      return;
    }
    final rest = _restMs ?? range.endMs ?? _durationMs;
    // A new generation, so the reports that follow do not end it again.
    _newCommand();
    // Before the pause, so listeners see it with the stop.
    _parked = true;
    unawaited(_stopAt(rest));
  }

  Future<void> _restartLoop(int generation, PreviewRange range) async {
    await _seek(range.startMs, settle: true);
    if (generation != _generation) return;
    if (!isPlaying) await _player?.play();
    if (generation != _generation) return;
    _armStop(generation);
  }

  Future<void> _stopAt(int ms) async {
    final player = _player;
    if (player == null) return;
    await player.pause();
    await _seek(ms);
  }
}

/// A current value plus a stream of its changes.
class _Value<T> {
  T value;
  final _changes = StreamController<T>.broadcast();

  _Value(this.value);

  Stream<T> get stream => _changes.stream;

  void add(T next) {
    value = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  Future<void> close() => _changes.close();
}
