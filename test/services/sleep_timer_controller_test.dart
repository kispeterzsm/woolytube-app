import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/sleep_timer_controller.dart';

void main() {
  test('counts down and invokes the elapsed callback once', () {
    fakeAsync((async) {
      final startedAt = DateTime(2026, 1, 1);
      var elapsedCalls = 0;
      final controller = SleepTimerController(
        onElapsed: () async => elapsedCalls++,
        now: () => startedAt.add(async.elapsed),
      );
      addTearDown(controller.dispose);

      controller.start(const Duration(seconds: 3));
      expect(controller.remaining, const Duration(seconds: 3));

      async.elapse(const Duration(seconds: 1));
      expect(controller.remaining, const Duration(seconds: 2));
      expect(elapsedCalls, 0);

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(controller.remaining, isNull);
      expect(elapsedCalls, 1);

      async.elapse(const Duration(seconds: 10));
      expect(elapsedCalls, 1);
    });
  });

  test('starting a new timer replaces the previous deadline', () {
    fakeAsync((async) {
      final startedAt = DateTime(2026, 1, 1);
      var elapsedCalls = 0;
      final controller = SleepTimerController(
        onElapsed: () async => elapsedCalls++,
        now: () => startedAt.add(async.elapsed),
      );
      addTearDown(controller.dispose);

      controller.start(const Duration(seconds: 5));
      async.elapse(const Duration(seconds: 3));
      controller.start(const Duration(seconds: 5));

      async.elapse(const Duration(seconds: 2));
      expect(controller.remaining, const Duration(seconds: 3));
      expect(elapsedCalls, 0);

      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(controller.remaining, isNull);
      expect(elapsedCalls, 1);
    });
  });

  test('cancel clears the countdown and prevents expiry', () {
    fakeAsync((async) {
      var elapsedCalls = 0;
      final controller = SleepTimerController(
        onElapsed: () async => elapsedCalls++,
      );
      addTearDown(controller.dispose);

      controller.start(const Duration(seconds: 2));
      controller.cancel();
      expect(controller.remaining, isNull);

      async.elapse(const Duration(seconds: 5));
      expect(elapsedCalls, 0);
    });
  });

  test('rejects non-positive durations', () {
    final controller = SleepTimerController(onElapsed: () async {});
    addTearDown(controller.dispose);

    expect(() => controller.start(Duration.zero), throwsArgumentError);
    expect(
      () => controller.start(const Duration(seconds: -1)),
      throwsArgumentError,
    );
  });
}
