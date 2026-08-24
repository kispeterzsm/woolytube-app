import 'dart:async';

import 'package:rxdart/rxdart.dart';

/// A wall-clock timer that exposes a once-per-second countdown.
///
/// Keeping this independent from the media player makes the timer lifecycle
/// deterministic and lets playback decide what "sleep" means when it expires.
class SleepTimerController {
  final Future<void> Function() _onElapsed;
  final DateTime Function() _now;

  final _remaining = BehaviorSubject<Duration?>.seeded(null);
  Timer? _expiryTimer;
  Timer? _countdownTimer;
  DateTime? _deadline;

  SleepTimerController({
    required Future<void> Function() onElapsed,
    DateTime Function()? now,
  }) : _onElapsed = onElapsed,
       _now = now ?? DateTime.now;

  Stream<Duration?> get remainingStream => _remaining.stream;
  Duration? get remaining => _remaining.value;

  void start(Duration duration) {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'Must be positive');
    }

    _cancelTimers();
    _deadline = _now().add(duration);
    _remaining.add(duration);

    _expiryTimer = Timer(duration, _expire);
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshRemaining(),
    );
  }

  void cancel() {
    _cancelTimers();
    _deadline = null;
    if (_remaining.value != null) {
      _remaining.add(null);
    }
  }

  void _refreshRemaining() {
    final deadline = _deadline;
    if (deadline == null) return;

    final remaining = deadline.difference(_now());
    if (remaining > Duration.zero) {
      _remaining.add(remaining);
    }
  }

  Future<void> _expire() async {
    _cancelTimers();
    _deadline = null;
    _remaining.add(null);
    await _onElapsed();
  }

  void _cancelTimers() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  void dispose() {
    _cancelTimers();
    _remaining.close();
  }
}
