import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/audio_focus_controller.dart';

import 'playback_fakes.dart';

void main() {
  late FakeAudioSession session;
  late bool isPlaying;
  late int pauseCount;
  late int resumeCount;
  late AudioFocusController controller;

  setUp(() {
    session = FakeAudioSession();
    isPlaying = false;
    pauseCount = 0;
    resumeCount = 0;
    controller = AudioFocusController(
      session: session,
      pausePlayback: () async {
        pauseCount++;
        isPlaying = false;
      },
      resumePlayback: () async {
        resumeCount++;
        isPlaying = true;
      },
      isPlaying: () => isPlaying,
    );
  });

  tearDown(() async {
    await controller.dispose();
    await session.dispose();
  });

  test('permanent focus loss pauses, abandons focus, never resumes', () async {
    await controller.initialize(enabled: true);
    isPlaying = true;

    expect(await controller.requestFocus(), isTrue);
    session.interrupt(begin: true, type: AudioInterruptionType.unknown);
    await pumpEventQueue();

    expect(session.activeChanges, [true, false]);
    expect(pauseCount, 1);

    session.interrupt(begin: false, type: AudioInterruptionType.pause);
    await pumpEventQueue();
    expect(resumeCount, 0);
  });

  test('transient loss pauses, keeps focus, and resumes on end', () async {
    await controller.initialize(enabled: true);
    isPlaying = true;
    await controller.requestFocus();

    session.interrupt(begin: true, type: AudioInterruptionType.pause);
    await pumpEventQueue();
    expect(pauseCount, 1);
    expect(session.activeChanges, [true], reason: 'focus must be kept');

    session.interrupt(begin: false, type: AudioInterruptionType.pause);
    await pumpEventQueue();
    expect(resumeCount, 1);
    expect(isPlaying, isTrue);
  });

  test('transient loss while paused does not resume on end', () async {
    await controller.initialize(enabled: true);
    isPlaying = false;
    await controller.requestFocus();

    session.interrupt(begin: true, type: AudioInterruptionType.pause);
    session.interrupt(begin: false, type: AudioInterruptionType.pause);
    await pumpEventQueue();

    expect(pauseCount, 0);
    expect(resumeCount, 0);
  });

  test(
    'a manual focus request during a call cancels the auto-resume',
    () async {
      await controller.initialize(enabled: true);
      isPlaying = true;
      await controller.requestFocus();

      session.interrupt(begin: true, type: AudioInterruptionType.pause);
      await pumpEventQueue();
      expect(pauseCount, 1);

      // The user pressed play again while the call was still active.
      await controller.requestFocus();
      isPlaying = true;
      session.interrupt(begin: false, type: AudioInterruptionType.pause);
      await pumpEventQueue();

      expect(resumeCount, 0);
    },
  );

  test('duck events never pause playback', () async {
    await controller.initialize(enabled: true);
    isPlaying = true;
    await controller.requestFocus();

    session.interrupt(begin: true, type: AudioInterruptionType.duck);
    session.interrupt(begin: false, type: AudioInterruptionType.duck);
    await pumpEventQueue();

    expect(pauseCount, 0);
    expect(resumeCount, 0);
    expect(session.activeChanges, [true]);
  });

  test('disabled option allows playback without taking focus', () async {
    await controller.initialize(enabled: false);
    isPlaying = true;

    expect(await controller.requestFocus(), isTrue);
    session.interrupt(begin: true, type: AudioInterruptionType.unknown);
    session.interrupt(begin: true, type: AudioInterruptionType.pause);
    await pumpEventQueue();

    expect(session.activeChanges, isEmpty);
    expect(pauseCount, 0);
  });

  test('becoming noisy pauses even when the option is disabled', () async {
    await controller.initialize(enabled: false);
    isPlaying = true;

    session.becomeNoisy();
    await pumpEventQueue();

    expect(pauseCount, 1);
    expect(isPlaying, isFalse);
  });

  test('becoming noisy pauses, abandons focus, and cancels resume', () async {
    await controller.initialize(enabled: true);
    isPlaying = true;
    await controller.requestFocus();

    session.interrupt(begin: true, type: AudioInterruptionType.pause);
    await pumpEventQueue();
    session.becomeNoisy();
    await pumpEventQueue();
    session.interrupt(begin: false, type: AudioInterruptionType.pause);
    await pumpEventQueue();

    expect(pauseCount, 2);
    expect(resumeCount, 0);
    expect(session.activeChanges, [true, false]);
  });

  test('changing the option applies while playback is active', () async {
    await controller.initialize(enabled: false);
    isPlaying = true;

    await controller.setEnabled(true);
    await controller.setEnabled(false);

    expect(session.activeChanges, [true, false]);
  });
}
