import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/audio_focus_controller.dart';

void main() {
  late _FakeAudioSession session;
  late bool isPlaying;
  late int pauseCount;
  late AudioFocusController controller;

  setUp(() {
    session = _FakeAudioSession();
    isPlaying = false;
    pauseCount = 0;
    controller = AudioFocusController(
      session: session,
      pausePlayback: () async {
        pauseCount++;
        isPlaying = false;
      },
      isPlaying: () => isPlaying,
    );
  });

  tearDown(() async {
    await controller.dispose();
    await session.dispose();
  });

  test('requests focus and pauses when another app interrupts', () async {
    await controller.initialize(enabled: true);
    isPlaying = true;

    expect(await controller.requestFocus(), isTrue);
    session.interrupt();
    await pumpEventQueue();

    expect(session.activeChanges, [true, false]);
    expect(pauseCount, 1);
  });

  test('disabled option allows playback without taking focus', () async {
    await controller.initialize(enabled: false);
    isPlaying = true;

    expect(await controller.requestFocus(), isTrue);
    session.interrupt();
    await pumpEventQueue();

    expect(session.activeChanges, isEmpty);
    expect(pauseCount, 0);
  });

  test('changing the option applies while playback is active', () async {
    await controller.initialize(enabled: false);
    isPlaying = true;

    await controller.setEnabled(true);
    await controller.setEnabled(false);

    expect(session.activeChanges, [true, false]);
  });
}

class _FakeAudioSession implements PlaybackAudioSession {
  final _interruptions = StreamController<void>.broadcast();
  final activeChanges = <bool>[];

  @override
  Stream<void> get interruptionStartStream => _interruptions.stream;

  @override
  Future<void> configureForMediaPlayback() async {}

  @override
  Future<bool> setActive(bool active) async {
    activeChanges.add(active);
    return true;
  }

  void interrupt() => _interruptions.add(null);

  Future<void> dispose() => _interruptions.close();
}
