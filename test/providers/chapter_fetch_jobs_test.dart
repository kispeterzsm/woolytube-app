import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/providers/chapter_fetch_jobs.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapter_service.dart';

void main() {
  test(
    'reports progress, can be cancelled and forgets the job at the end',
    () async {
      final service = _Chapters();
      final container = ProviderContainer(
        overrides: [chapterServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      final jobs = container.read(chapterFetchJobsProvider.notifier);

      final run = jobs.start(7);
      expect(jobs.isRunning(7), isTrue);
      await pumpEventQueue();
      expect(container.read(chapterFetchJobsProvider)[7]!.total, 3);

      service.step();
      await pumpEventQueue();
      final progress = container.read(chapterFetchJobsProvider)[7]!;
      expect((progress.done, progress.total), (1, 3));
      expect(() => jobs.start(7), throwsStateError);

      jobs.cancel(7);
      expect(container.read(chapterFetchJobsProvider)[7]!.cancelling, isTrue);
      service.step();
      final result = await run;

      expect(service.cancellation!.isCancelled, isTrue);
      expect(result.cancelled, isTrue);
      expect(container.read(chapterFetchJobsProvider), isEmpty);
      expect(chapterFetchSummary(result), 'Stopped. Updated 2 of 3');
    },
  );

  test('summary wording', () {
    expect(
      chapterFetchSummary(
        const ChapterFetchResult(
          eligible: 0,
          updated: 0,
          failed: 0,
          skipped: 0,
          cancelled: false,
        ),
      ),
      'All downloaded videos already have chapter info.',
    );
    expect(
      chapterFetchSummary(
        const ChapterFetchResult(
          eligible: 17,
          updated: 12,
          failed: 3,
          skipped: 2,
          cancelled: false,
        ),
      ),
      'Updated 12 of 17 · 3 failed · 2 skipped (file changed)',
    );
  });
}

/// Fetches one file per [step], with three files to do.
class _Chapters implements ChapterService {
  ChapterFetchCancellation? cancellation;
  final _steps = StreamController<void>();

  void step() => _steps.add(null);

  @override
  Future<ChapterFetchResult> fetchMissingChapters(
    int playlistId, {
    void Function(int done, int total)? onProgress,
    ChapterFetchCancellation? cancellation,
    int persistEvery = 25,
  }) async {
    this.cancellation = cancellation;
    const total = 3;
    var done = 0;
    onProgress?.call(0, total);
    await for (final _ in _steps.stream) {
      done++;
      onProgress?.call(done, total);
      if (done == total || (cancellation?.isCancelled ?? false)) break;
    }
    return ChapterFetchResult(
      eligible: total,
      updated: done,
      failed: 0,
      skipped: 0,
      cancelled: cancellation?.isCancelled ?? false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
