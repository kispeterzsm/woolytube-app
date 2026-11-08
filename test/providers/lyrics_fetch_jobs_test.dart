import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/providers/lyrics_fetch_jobs.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';

import '../pages/lyrics_fakes.dart';

void main() {
  test('reports progress, can be cancelled and forgets the job at the '
      'end', () async {
    final service = FakeLyricsService();
    final container = ProviderContainer(
      overrides: [lyricsServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final jobs = container.read(lyricsFetchJobsProvider.notifier);

    final run = jobs.start(7);
    expect(jobs.isRunning(7), isTrue);
    await pumpEventQueue();
    expect(container.read(lyricsFetchJobsProvider)[7]!.total, 3);

    service.step();
    await pumpEventQueue();
    final progress = container.read(lyricsFetchJobsProvider)[7]!;
    expect((progress.done, progress.total), (1, 3));
    expect(progress.fraction, closeTo(1 / 3, 1e-9));
    expect(() => jobs.start(7), throwsStateError);

    jobs.cancel(7);
    expect(container.read(lyricsFetchJobsProvider)[7]!.cancelling, isTrue);
    service.step();
    final result = (await run)!;

    expect(service.cancellation!.isCancelled, isTrue);
    expect(result.cancelled, isTrue);
    expect(container.read(lyricsFetchJobsProvider), isEmpty);
    expect(lyricsFetchSummary(result), 'Stopped. Found lyrics for 2 of 3');
  });

  test('stop cancels the job, waits for it to end and drops its result, '
      'also when it fails on the way out', () async {
    final service = FakeLyricsService()..failWhenStopped = true;
    final container = ProviderContainer(
      overrides: [lyricsServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final jobs = container.read(lyricsFetchJobsProvider.notifier);

    final run = jobs.start(7);
    await pumpEventQueue();
    var stopped = false;
    final stopping = jobs.stop(7).then((_) => stopped = true);
    await pumpEventQueue();
    expect(service.cancellation!.isCancelled, isTrue);
    expect(stopped, isFalse, reason: 'the current track is still checked');

    service.step();
    await stopping;
    expect(await run, isNull);
    expect(jobs.isRunning(7), isFalse);
    // Nothing to stop.
    await jobs.stop(7);
  });

  test('summary wording', () {
    expect(
      lyricsFetchSummary(const LyricsBackfillResult()),
      'Nothing to fetch: every track was checked recently.',
    );
    expect(
      lyricsFetchSummary(
        const LyricsBackfillResult(due: 10, found: 6, missing: 3, failed: 1),
      ),
      'Found lyrics for 6 of 10 · 3 without · 1 failed',
    );
    expect(
      lyricsFetchSummary(
        const LyricsBackfillResult(due: 4, found: 2, outOfTime: true),
        mode: LyricsMode.transcript,
      ),
      'Found transcripts for 2 of 4. The rest follow at the next update.',
    );
  });
}
