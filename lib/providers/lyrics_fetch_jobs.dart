import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/lyrics/lyrics_models.dart';
import 'providers.dart';

/// A running "fetch lyrics" job of one playlist.
class LyricsFetchJobProgress {
  final int done;
  final int total;
  final bool cancelling;

  const LyricsFetchJobProgress({
    required this.done,
    required this.total,
    this.cancelling = false,
  });

  double? get fraction => total <= 0 ? null : done / total;
}

/// Runs a playlist's lyrics backfill outside of any page, so it keeps going
/// (and can be cancelled) after the owner leaves Playlist settings and
/// shows its progress again when they come back.
class LyricsFetchJobs extends Notifier<Map<int, LyricsFetchJobProgress>> {
  final _cancellations = <int, LyricsCancellation>{};
  final _runs = <int, Future<void>>{};

  /// Playlists whose job was ended with [stop]; their result is dropped.
  final _discarded = <int>{};

  @override
  Map<int, LyricsFetchJobProgress> build() => const {};

  bool isRunning(int playlistId) => state.containsKey(playlistId);

  /// Fetches the lyrics or transcripts that are due in the playlist.
  /// Throws [StateError] when a job for the playlist is running. Returns
  /// null when the job was ended with [stop] (its playlist is being
  /// deleted), whatever happened to it after that.
  Future<LyricsBackfillResult?> start(int playlistId) async {
    if (isRunning(playlistId)) {
      throw StateError('Lyrics are already being fetched.');
    }
    final service = ref.read(lyricsServiceProvider);
    final cancellation = LyricsCancellation();
    final finished = Completer<void>();
    _cancellations[playlistId] = cancellation;
    _runs[playlistId] = finished.future;
    _discarded.remove(playlistId);
    _set(playlistId, const LyricsFetchJobProgress(done: 0, total: 0));
    try {
      final result = await service.backfillPlaylist(
        playlistId,
        cancellation: cancellation,
        onProgress:
            (progress) => _set(
              playlistId,
              LyricsFetchJobProgress(
                done: progress.done,
                total: progress.total,
                cancelling: cancellation.isCancelled,
              ),
            ),
      );
      if (_discarded.contains(playlistId)) return null;
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
  /// track it is working on). Its caller gets null instead of a result.
  /// Use it before deleting the playlist.
  Future<void> stop(int playlistId) async {
    final run = _runs[playlistId];
    if (run == null) return;
    _discarded.add(playlistId);
    cancel(playlistId);
    await run;
  }

  /// Stops the job after the track it is working on.
  void cancel(int playlistId) {
    final cancellation = _cancellations[playlistId];
    final progress = state[playlistId];
    if (cancellation == null || progress == null) return;
    cancellation.cancel();
    _set(
      playlistId,
      LyricsFetchJobProgress(
        done: progress.done,
        total: progress.total,
        cancelling: true,
      ),
    );
  }

  void _set(int playlistId, LyricsFetchJobProgress progress) {
    if (!_cancellations.containsKey(playlistId)) return;
    state = {...state, playlistId: progress};
  }
}

final lyricsFetchJobsProvider =
    NotifierProvider<LyricsFetchJobs, Map<int, LyricsFetchJobProgress>>(
      LyricsFetchJobs.new,
    );

/// Plain summary of a finished run, for a snack bar. [mode] picks the
/// wording (lyrics or transcripts).
String lyricsFetchSummary(LyricsBackfillResult result, {LyricsMode? mode}) {
  final what = mode == LyricsMode.transcript ? 'transcripts' : 'lyrics';
  if (result.due == 0) {
    return result.cancelled
        ? 'Stopped.'
        : 'Nothing to fetch: every track was checked recently.';
  }
  final parts = <String>[
    'Found $what for ${result.found} of ${result.due}',
    if (result.missing > 0) '${result.missing} without',
    if (result.failed > 0) '${result.failed} failed',
  ];
  final summary = parts.join(' · ');
  if (result.cancelled) return 'Stopped. $summary';
  if (result.outOfTime) return '$summary. The rest follow at the next update.';
  return summary;
}
