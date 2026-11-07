import 'dart:math' as math;

import '../database/database.dart';
import 'chapters.dart';
import 'metadata_service.dart';
import 'ytdlp_service.dart';
import 'playlist_service.dart';

/// Lets the caller stop [ChapterService.fetchMissingChapters] between files.
class ChapterFetchCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Outcome of [ChapterService.fetchMissingChapters].
class ChapterFetchResult {
  /// Files that needed chapter info.
  final int eligible;

  /// Files whose chapter info was fetched (with or without chapters).
  final int updated;

  /// Files where yt-dlp failed (offline, video removed, ...).
  final int failed;

  /// Files that changed while their info loaded, so nothing was written.
  final int skipped;

  /// Whether the run stopped early because it was cancelled.
  final bool cancelled;

  const ChapterFetchResult({
    required this.eligible,
    required this.updated,
    required this.failed,
    required this.skipped,
    required this.cancelled,
  });

  int get done => updated + failed + skipped;
}

/// Owns chapter edits and durable metadata; it never opens media for writing.
///
/// After an edit that changes what plays, also call
/// `PlaybackService.trackChaptersChanged(track)` so a running queue picks
/// the change up.
class ChapterService {
  final AppDatabase db;
  final YtDlpService ytdlp;
  final MetadataService? _metadata;
  Future<void> _ownWrites = Future<void>.value();

  /// Pass the app's shared [metadata] service (one long-lived instance) so
  /// chapter writes are ordered with every other sidecar write.
  ChapterService(this.db, this.ytdlp, {MetadataService? metadata})
    : _metadata = metadata;

  /// Rewrites the playlist's sidecar from the database.
  ///
  /// Without a shared [MetadataService], every write uses a fresh one: a
  /// long-lived private instance would remember what it wrote last and skip
  /// a write after downloads or sync changed the file behind its back. Such
  /// writes still run one after another.
  Future<void> persist(int playlistId) {
    final shared = _metadata;
    if (shared != null) return shared.writeMetadataFor(playlistId);
    final write = _ownWrites.then(
      (_) => MetadataService(db).writeMetadataFor(playlistId),
    );
    _ownWrites = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  Future<void> setOverride(Track track, bool? enabled) async {
    await db.setTrackChapterOverride(track.id, enabled);
    await persist(track.playlistId);
  }

  Future<void> setShuffleChapters(Track track, bool enabled) async {
    final fresh = await db.getTrack(track.id);
    if (fresh == null) return;
    await db.writeTrackChapters(
      track.id,
      ChapterData.decode(fresh.chaptersJson).withShuffleChapters(enabled),
    );
    await persist(track.playlistId);
  }

  static bool _needsChapterInfo(Track track) {
    final old = ChapterData.decode(track.chaptersJson);
    return track.status == 'complete' &&
        track.filePath != null &&
        !track.isLocalReplacement &&
        !PlaylistService.isForcedInsertVideoId(track.videoId) &&
        old.valid &&
        old.checkedAt == null;
  }

  /// Number of downloaded files in the playlist whose chapter info was never
  /// fetched; lets the UI say "all done" without starting a run.
  Future<int> countMissing(int playlistId) async =>
      (await db.getTracksForPlaylist(
        playlistId,
      )).where(_needsChapterInfo).length;

  /// Older form of [fetchMissingChapters]: (files checked, files failed).
  Future<(int, int)> fetchMissing(int playlistId) async {
    final result = await fetchMissingChapters(playlistId);
    return (result.updated, result.failed);
  }

  /// Fetches YouTube chapter info for every downloaded file of the playlist
  /// that never had it checked.
  ///
  /// [onProgress] is called with (done, total) before the first file and
  /// after each one. [cancellation] is checked between files. The playlist's
  /// sidecar is written every [persistEvery] updated files and once at the
  /// end, not once per file.
  Future<ChapterFetchResult> fetchMissingChapters(
    int playlistId, {
    void Function(int done, int total)? onProgress,
    ChapterFetchCancellation? cancellation,
    int persistEvery = 25,
  }) async {
    final tracks = [
      for (final t in await db.getTracksForPlaylist(playlistId))
        if (_needsChapterInfo(t)) t,
    ];
    var updated = 0, failed = 0, skipped = 0, sincePersist = 0;
    var cancelled = false;
    final results = <String, ChapterData>{};
    onProgress?.call(0, tracks.length);
    try {
      for (final track in tracks) {
        if (cancellation?.isCancelled ?? false) {
          cancelled = true;
          break;
        }
        try {
          final remote = results[track.videoId];
          if (remote != null) {
            // The same video twice in the playlist: reuse the first answer.
            final old = ChapterData.decode(
              (await db.getTrack(track.id))?.chaptersJson,
            );
            // copyWith keeps the edit history and recognition state.
            await db.writeTrackChapters(
              track.id,
              old.copyWith(
                downloaded: remote.downloaded,
                checkedAt: remote.checkedAt,
                durationMs: remote.durationMs,
              ),
            );
          } else {
            await _refreshTrack(track);
            results[track.videoId] = ChapterData.decode(
              (await db.getTrack(track.id))?.chaptersJson,
            );
          }
          updated++;
          if (++sincePersist >= persistEvery) {
            sincePersist = 0;
            await persist(playlistId);
          }
        } on _MediaChanged {
          skipped++;
        } catch (_) {
          failed++;
        }
        onProgress?.call(updated + failed + skipped, tracks.length);
      }
    } finally {
      // The database is the source of truth; the sidecar only needs to
      // catch up once, also when the run stopped early.
      if (sincePersist > 0) await persist(playlistId);
    }
    return ChapterFetchResult(
      eligible: tracks.length,
      updated: updated,
      failed: failed,
      skipped: skipped,
      cancelled: cancelled,
    );
  }

  /// Fetches YouTube chapters for one file and saves them (including the
  /// playlist's sidecar unless [persistAfter] is false).
  Future<void> refresh(Track track, {bool persistAfter = true}) async {
    try {
      await _refreshTrack(track);
    } on _MediaChanged catch (error) {
      throw StateError(error.message);
    }
    if (persistAfter) await persist(track.playlistId);
  }

  Future<void> _refreshTrack(Track track) async {
    if (track.isLocalReplacement ||
        PlaylistService.isForcedInsertVideoId(track.videoId)) {
      throw StateError('Use custom chapters for local files.');
    }
    final info = await ytdlp.getVideoInfo(
      'https://www.youtube.com/watch?v=${track.videoId}',
    );
    final fresh = await db.getTrack(track.id);
    if (fresh == null ||
        fresh.filePath != track.filePath ||
        fresh.isLocalReplacement) {
      throw const _MediaChanged();
    }
    final old = ChapterData.decode(fresh.chaptersJson);
    final remote = ChapterData.fromVideoInfo(info);
    await db.writeTrackChapters(
      track.id,
      old.copyWith(
        downloaded: remote.downloaded,
        custom: old.valid ? old.custom : null,
        valid: true,
        checkedAt: remote.checkedAt,
        durationMs: remote.durationMs,
      ),
    );
  }

  Future<bool> _change(
    Track track,
    ChapterData Function(ChapterData, Track) action,
  ) async {
    var changed = false;
    await db.transaction(() async {
      final fresh = await db.getTrack(track.id);
      if (fresh == null || fresh.filePath != track.filePath) {
        throw StateError('The media changed. Reopen its chapters.');
      }
      final old = ChapterData.decode(fresh.chaptersJson);
      final next = action(old, fresh);
      if (identical(old, next)) return;
      validateChapters(next.active, durationMs: next.durationMs);
      await db.writeTrackChapters(track.id, next);
      changed = true;
    });
    if (changed) await persist(track.playlistId);
    return changed;
  }

  ChapterData _edited(
    ChapterData old,
    List<MediaChapter> entries, {
    int? durationMs,
  }) {
    entries.sort((a, b) => a.startMs.compareTo(b.startMs));
    // Built in full rather than with copyWith: after the file was replaced,
    // the old check time and length must not carry over, so the new file
    // still gets its chapter info fetched.
    return ChapterData(
      downloaded: old.valid ? old.downloaded : const [],
      custom: entries,
      checkedAt: old.valid ? old.checkedAt : null,
      durationMs: durationMs ?? (old.valid ? old.durationMs : null),
      shuffleChapters: old.shuffleChapters,
      undoChapters: old.active,
      recognitionEpoch: old.recognitionEpoch,
      lastRecognitionRunId: old.lastRecognitionRunId,
    );
  }

  Future<void> save(
    Track track,
    MediaChapter chapter, {
    int? durationMs,
  }) async {
    await _change(track, (old, fresh) {
      final previous = old.active.where((c) => c.id == chapter.id).firstOrNull;
      final duration = knownDurationMs(fresh, durationMs: durationMs);
      if (duration == null || duration <= 0) {
        throw StateError('Play the file first to determine its duration.');
      }
      final edited =
          previous != null &&
          (chapter.title != previous.title ||
              chapter.startMs != previous.startMs ||
              chapter.endMs != previous.endMs);
      final saved = chapter.copyWith(
        origin: previous?.origin ?? ChapterOrigin.user,
        manuallyEdited: (previous?.manuallyEdited ?? false) || edited,
        alternativeTitles: previous?.alternativeTitles ?? const [],
        reviewReasons:
            previous?.reviewReasons
                .where(
                  (reason) =>
                      !(reason.startsWith('Name:') &&
                          chapter.title != previous.title) &&
                      !(reason.startsWith('Timing:') &&
                          chapter.startMs != previous.startMs),
                )
                .toList() ??
            const [],
      );
      return _edited(old, [
        ...old.active.where((c) => c.id != chapter.id),
        saved,
      ], durationMs: duration);
    });
  }

  /// The length of [track]'s file in milliseconds as far as it is known
  /// without opening it: [durationMs] (for example from the player), the
  /// stored chapter info, or the YouTube length of a downloaded video.
  static int? knownDurationMs(Track track, {int? durationMs}) {
    final data = ChapterData.decode(track.chaptersJson);
    return durationMs ??
        (data.valid ? data.durationMs : null) ??
        (track.isLocalReplacement || track.durationSeconds == null
            ? null
            : track.durationSeconds! * 1000);
  }

  Future<void> rename(Track track, String id, String title) async {
    await _change(track, (old, _) {
      if (!old.active.any((c) => c.id == id)) {
        throw StateError('The chapter changed. Reopen it.');
      }
      return _edited(
        old,
        old.active
            .map(
              (c) =>
                  c.id == id
                      ? c.copyWith(
                        title: title.trim(),
                        manuallyEdited: true,
                        reviewReasons:
                            c.reviewReasons
                                .where((r) => !r.startsWith('Name:'))
                                .toList(),
                      )
                      : c,
            )
            .toList(),
      );
    });
  }

  Future<void> moveBoundary(
    Track track,
    String leftId,
    String rightId,
    int originalBoundaryMs,
    int boundaryMs,
  ) async {
    await _change(track, (old, _) {
      final entries = [...old.active];
      final index = entries.indexWhere((c) => c.id == leftId);
      if (index < 0 ||
          index + 1 >= entries.length ||
          entries[index + 1].id != rightId ||
          entries[index].endMs != originalBoundaryMs ||
          entries[index + 1].startMs != originalBoundaryMs) {
        throw StateError('These chapters changed. Reopen the boundary editor.');
      }
      entries[index] = entries[index].copyWith(
        endMs: boundaryMs,
        manuallyEdited: true,
      );
      entries[index + 1] = entries[index + 1].copyWith(
        startMs: boundaryMs,
        manuallyEdited: true,
        reviewReasons:
            entries[index + 1].reviewReasons
                .where((r) => !r.startsWith('Timing:'))
                .toList(),
      );
      return _edited(old, entries);
    });
  }

  Future<void> merge(
    Track track,
    MediaChapter left,
    MediaChapter right, {
    required bool keepEarlier,
    required String title,
  }) async {
    await _change(track, (old, _) {
      final entries = [...old.active];
      final index = entries.indexWhere((c) => c.id == left.id);
      if (index < 0 ||
          index + 1 >= entries.length ||
          entries[index + 1].id != right.id ||
          entries[index].startMs != left.startMs ||
          entries[index].endMs != left.endMs ||
          entries[index + 1].startMs != right.startMs ||
          entries[index + 1].endMs != right.endMs) {
        throw StateError('These chapters changed. Reopen the merge dialog.');
      }
      final survivor = entries[index + (keepEarlier ? 0 : 1)];
      final merged = survivor.copyWith(
        title: title.trim(),
        startMs: left.startMs,
        endMs: right.endMs,
        manuallyEdited: true,
        reviewReasons:
            entries[index].reviewReasons
                .where((r) => r.startsWith('Timing:'))
                .toList(),
      );
      entries.replaceRange(index, index + 2, [merged]);
      return _edited(old, entries);
    });
  }

  /// Removes one chapter. Returns the chapter info from before, so the
  /// caller can offer Undo through [replaceChapters]; the removal is also
  /// kept as the [undo] snapshot.
  Future<ChapterData?> delete(Track track, String chapterId) async {
    ChapterData? before;
    await _change(track, (old, _) {
      before = old;
      return _edited(old, old.active.where((c) => c.id != chapterId).toList());
    });
    return before;
  }

  /// Writes [data] back as the track's chapter info (Undo of an edit).
  ///
  /// Like the other edits it is refused when the file changed since, so old
  /// timings never land on a different file. It counts as an undo for
  /// recognition: a scan started before it is not applied afterwards.
  Future<void> replaceChapters(Track track, ChapterData data) async {
    await db.transaction(() async {
      final fresh = await db.getTrack(track.id);
      if (fresh == null || fresh.filePath != track.filePath) {
        throw StateError('The media changed. Reopen its chapters.');
      }
      final current = ChapterData.decode(fresh.chaptersJson);
      await db.writeTrackChapters(
        track.id,
        data.copyWith(
          recognitionEpoch:
              math.max(current.recognitionEpoch, data.recognitionEpoch) + 1,
        ),
      );
    });
    await persist(track.playlistId);
  }

  /// Drops recognised chapters the user never touched. Edited ones count as
  /// the user's own work and stay, like everything else recognition protects.
  Future<void> removeAutomatic(Track track) async {
    await _change(
      track,
      (old, _) => _edited(
        old,
        old.active.where((c) => c.protectedFromRecognition).toList(),
      ).copyWith(recognitionEpoch: old.recognitionEpoch + 1),
    );
  }

  Future<void> undo(Track track) async {
    await _change(
      track,
      (old, _) =>
          old.undoChapters == null
              ? old
              : old.copyWith(
                custom: old.undoChapters,
                undoChapters: null,
                recognitionEpoch: old.recognitionEpoch + 1,
              ),
    );
  }

  Future<void> restore(Track track) async {
    await _change(track, (old, _) {
      if (!old.valid) {
        throw StateError('The media changed. Fetch new chapters first.');
      }
      return old.copyWith(
        custom: null,
        undoChapters: old.active,
        recognitionEpoch: old.recognitionEpoch + 1,
      );
    });
  }

  /// Leftover pieces shorter than this come from clipping, not from a song,
  /// and are dropped instead of becoming chapters of their own.
  static const minimumChapterMs = 5000;

  /// Rebases a completed scan onto the current edits.
  ///
  /// Chapters the user created or edited are never moved; proposals are cut
  /// around them. Earlier untouched recognition results are replaced wherever
  /// a new proposal covers them. Proposals that overlap each other or run past
  /// the file are clipped rather than rejected, so one odd match cannot throw
  /// away a whole run. A run is applied once per [epoch], which edits bump.
  Future<bool> applyRecognition(
    Track track, {
    required String runId,
    required int epoch,
    required int durationMs,
    required List<MediaChapter> proposals,
  }) => _change(track, (old, _) {
    if (old.recognitionEpoch != epoch ||
        old.lastRecognitionRunId == runId ||
        proposals.isEmpty) {
      return old;
    }
    final protected =
        old.active.where((c) => c.protectedFromRecognition).toList();
    final protectedRanges = protected.map((c) => (c.startMs, c.endMs)).toList();

    final added = <MediaChapter>[];
    var cursor = 0;
    final ordered = [...proposals]
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    for (final proposal in ordered) {
      final start = math.max(proposal.startMs, cursor);
      final end = math.min(proposal.endMs, durationMs);
      if (end <= start) continue;
      cursor = end;
      for (final range in _subtractAll((start, end), protectedRanges)) {
        if (range.$2 - range.$1 < minimumChapterMs) continue;
        added.add(
          proposal.copyWith(
            id: '${proposal.id}-${range.$1}-${range.$2}',
            startMs: range.$1,
            endMs: range.$2,
            origin: ChapterOrigin.auto,
            manuallyEdited: false,
          ),
        );
      }
    }

    final addedRanges = added.map((c) => (c.startMs, c.endMs)).toList();
    final retained = <MediaChapter>[...protected];
    for (final previous in old.active.where(
      (c) => !c.protectedFromRecognition,
    )) {
      final whole = (previous.startMs, previous.endMs);
      for (final range in _subtractAll(whole, addedRanges)) {
        if (range.$2 - range.$1 < minimumChapterMs) continue;
        retained.add(
          previous.copyWith(
            id:
                range == whole
                    ? previous.id
                    : '${previous.id}-${range.$1}-${range.$2}',
            startMs: range.$1,
            endMs: range.$2,
          ),
        );
      }
    }
    return _edited(old, [
      ...retained,
      ...added,
    ], durationMs: durationMs).copyWith(lastRecognitionRunId: runId);
  });

  static List<(int, int)> _subtractAll(
    (int, int) range,
    List<(int, int)> removed,
  ) {
    var pieces = [range];
    for (final r in removed) {
      pieces =
          pieces.expand((piece) => subtractChapterRange(piece, r)).toList();
    }
    return pieces;
  }
}

List<(int, int)> subtractChapterRange((int, int) range, (int, int) removed) {
  if (removed.$2 <= range.$1 || removed.$1 >= range.$2) return [range];
  return [
    if (removed.$1 > range.$1) (range.$1, removed.$1),
    if (removed.$2 < range.$2) (removed.$2, range.$2),
  ];
}

class _MediaChanged implements Exception {
  const _MediaChanged();
  String get message => 'The media changed while chapters were loading.';
}
