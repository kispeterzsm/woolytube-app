import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/chapter_service.dart';
import 'playback_providers.dart';
import 'providers.dart';

/// A running "fetch missing chapters" job of one playlist.
class ChapterFetchProgress {
  final int done;
  final int total;
  final bool cancelling;

  const ChapterFetchProgress({
    required this.done,
    required this.total,
    this.cancelling = false,
  });

  double? get fraction => total <= 0 ? null : done / total;
}

/// Runs "fetch missing chapters" outside of any page, so it keeps going
/// (and can be cancelled) after the owner leaves Playlist settings and
/// shows its progress again when they come back.
class ChapterFetchJobs extends Notifier<Map<int, ChapterFetchProgress>> {
  final _cancellations = <int, ChapterFetchCancellation>{};
  final _runs = <int, Future<void>>{};

  /// Playlists whose job was ended with [stop]; their result is dropped.
  final _discarded = <int>{};

  @override
  Map<int, ChapterFetchProgress> build() => const {};

  bool isRunning(int playlistId) => state.containsKey(playlistId);

  /// Fetches chapter info for the playlist's downloaded videos that never
  /// had it. Throws [StateError] when a job for the playlist is running.
  /// Returns null when the job was ended with [stop] (its playlist is being
  /// deleted), whatever happened to it after that.
  Future<ChapterFetchResult?> start(int playlistId) async {
    if (isRunning(playlistId)) {
      throw StateError('Chapters are already being fetched.');
    }
    final service = ref.read(chapterServiceProvider);
    final cancellation = ChapterFetchCancellation();
    final finished = Completer<void>();
    _cancellations[playlistId] = cancellation;
    _runs[playlistId] = finished.future;
    _discarded.remove(playlistId);
    _set(playlistId, const ChapterFetchProgress(done: 0, total: 0));
    try {
      final result = await service.fetchMissingChapters(
        playlistId,
        cancellation: cancellation,
        onProgress:
            (done, total) => _set(
              playlistId,
              ChapterFetchProgress(
                done: done,
                total: total,
                cancelling: cancellation.isCancelled,
              ),
            ),
      );
      if (_discarded.contains(playlistId)) return null;
      if (result.updated > 0) await _tellPlayer(playlistId);
      return result;
    } catch (_) {
      // A job stopped for a deleted playlist may fail on the way out.
      if (_discarded.contains(playlistId)) return null;
      rethrow;
    } finally {
      _discarded.remove(playlistId);
      _cancellations.remove(playlistId);
      _runs.remove(playlistId);
      state = {...state}..remove(playlistId);
      finished.complete();
    }
  }

  /// Cancels the playlist's job and waits until it has ended (after the
  /// video it is working on). Its caller gets null instead of a result.
  /// Use it before deleting the playlist.
  Future<void> stop(int playlistId) async {
    final run = _runs[playlistId];
    if (run == null) return;
    _discarded.add(playlistId);
    cancel(playlistId);
    await run;
  }

  /// Stops the job after the video it is working on.
  void cancel(int playlistId) {
    final cancellation = _cancellations[playlistId];
    final progress = state[playlistId];
    if (cancellation == null || progress == null) return;
    cancellation.cancel();
    _set(
      playlistId,
      ChapterFetchProgress(
        done: progress.done,
        total: progress.total,
        cancelling: true,
      ),
    );
  }

  void _set(int playlistId, ChapterFetchProgress progress) {
    if (!_cancellations.containsKey(playlistId)) return;
    state = {...state, playlistId: progress};
  }

  /// Songs of this playlist that are queued but not started pick up the
  /// new chapters.
  Future<void> _tellPlayer(int playlistId) async {
    try {
      await ref
          .read(playbackServiceProvider)
          .playlistSettingsChanged(playlistId);
    } catch (_) {
      // No player (tests) or nothing playing from this playlist.
    }
  }
}

final chapterFetchJobsProvider =
    NotifierProvider<ChapterFetchJobs, Map<int, ChapterFetchProgress>>(
      ChapterFetchJobs.new,
    );

/// Plain summary of a finished run, for a snack bar.
String chapterFetchSummary(ChapterFetchResult result) {
  if (result.eligible == 0) {
    return 'All downloaded videos already have chapter info.';
  }
  final parts = <String>[
    'Updated ${result.updated} of ${result.eligible}',
    if (result.failed > 0) '${result.failed} failed',
    if (result.skipped > 0) '${result.skipped} skipped (file changed)',
  ];
  final summary = parts.join(' · ');
  return result.cancelled ? 'Stopped. $summary' : summary;
}
