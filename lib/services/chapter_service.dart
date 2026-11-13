import 'dart:math' as math;

import '../database/database.dart';
import 'chapters.dart';
import 'lyrics/lyrics_service.dart';
import 'metadata_service.dart';
import 'recognition/song_recognition_service.dart';
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

  /// Writes a track's chapters and drops lyrics of chapters that are gone
  /// or changed.
  Future<void> _writeChapters(int trackId, ChapterData data) async {
    final previous = ChapterData.decode(
      (await db.getTrack(trackId))?.chaptersJson,
    );
    await db.writeTrackChapters(trackId, data);
    await syncLyricsChapterDocs(db, trackId, data, previous: previous);
  }

  Future<void> setOverride(Track track, bool? enabled) async {
    await db.setTrackChapterOverride(track.id, enabled);
    await persist(track.playlistId);
  }

  /// [enabled] null follows the playlist's "Shuffle chapters".
  Future<void> setShuffleChapters(Track track, bool? enabled) async {
    final fresh = await db.getTrack(track.id);
    if (fresh == null) return;
    await _writeChapters(
      track.id,
      ChapterData.decode(fresh.chaptersJson).withShuffleChapters(enabled),
    );
    await persist(track.playlistId);
  }

  /// Marks one chapter "Always skip" (or not). Automatic playback passes
  /// over a skipped chapter; tapping it still plays it. This is a setting,
  /// not a chapter edit, so it leaves the undo step alone. Works for followed
  /// YouTube chapters too, without copying them into a custom list.
  ///
  /// Call `PlaybackService.trackChaptersChanged(track)` afterwards.
  Future<void> setChapterSkip(Track track, String chapterId, bool skip) async {
    var changed = false;
    await db.transaction(() async {
      final fresh = await db.getTrack(track.id);
      if (fresh == null) return;
      final old = ChapterData.decode(fresh.chaptersJson);
      final next = old.withChapterSkip(chapterId, skip);
      if (identical(old, next)) return;
      await _writeChapters(track.id, next);
      changed = true;
    });
    if (changed) await persist(track.playlistId);
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
            await _writeChapters(
              track.id,
              _withFetched(
                old,
                remote.downloaded,
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
    await _writeChapters(
      track.id,
      _withFetched(
        old,
        remote.downloaded,
        checkedAt: remote.checkedAt,
        durationMs: remote.durationMs,
      ),
    );
  }

  /// [old] with YouTube's chapter list [downloaded] as fetched now.
  ///
  /// The user's own list stays in use. A file that follows YouTube shows the
  /// new list, and when that differs from the list it showed, the old one
  /// becomes the Undo step (as a copy: Undo must bring back what was shown,
  /// not follow YouTube to the new list again), unless the Undo step already
  /// holds a list of its own: the user's chapters that "Use YouTube chapters
  /// again" set aside must stay recoverable, so that step is kept.
  static ChapterData _withFetched(
    ChapterData old,
    List<MediaChapter> downloaded, {
    required DateTime? checkedAt,
    required int? durationMs,
  }) {
    final next = old.copyWith(
      downloaded: downloaded,
      custom: old.valid ? old.custom : null,
      valid: true,
      checkedAt: checkedAt,
      durationMs: durationMs,
    );
    final shownBefore = old.active;
    if (old.custom != null ||
        shownBefore.isEmpty ||
        sameChapters(shownBefore, next.active) ||
        (old.undoChapters != null && !old.undoFollowsDownloaded)) {
      return next;
    }
    return next.copyWith(
      undoChapters: shownBefore,
      undoFollowsDownloaded: false,
    );
  }

  /// Whether [a] and [b] list the same chapters (ids, titles and times).
  static bool sameChapters(List<MediaChapter> a, List<MediaChapter> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].title != b[i].title ||
          a[i].startMs != b[i].startMs ||
          a[i].endMs != b[i].endMs) {
        return false;
      }
    }
    return true;
  }

  /// Runs [action] on the stored chapters in one transaction. [verify], when
  /// given, runs first inside the same transaction and can refuse by
  /// throwing.
  Future<bool> _change(
    Track track,
    ChapterData Function(ChapterData, Track) action, {
    Future<void> Function(Track fresh)? verify,
  }) async {
    var changed = false;
    await db.transaction(() async {
      final fresh = await db.getTrack(track.id);
      if (fresh == null || fresh.filePath != track.filePath) {
        throw StateError('The media changed. Reopen its chapters.');
      }
      if (verify != null) await verify(fresh);
      final old = ChapterData.decode(fresh.chaptersJson);
      final next = action(old, fresh);
      if (identical(old, next)) return;
      _validateEdit(old, next);
      await _writeChapters(track.id, next);
      changed = true;
    });
    if (changed) await persist(track.playlistId);
    return changed;
  }

  /// Checks the chapters an edit leaves behind.
  ///
  /// Order, overlaps, titles and IDs are always checked. The media length is
  /// only checked for chapter ends the edit introduces: an end that is
  /// already stored (or in the undo snapshot) was accepted before, and a
  /// later, shorter length estimate (a YouTube refresh rounds to whole
  /// seconds) must never stop the user from deleting, undoing or removing
  /// chapters.
  static void _validateEdit(ChapterData old, ChapterData next) {
    validateChapters(next.active);
    final durationMs = next.durationMs;
    if (durationMs == null || durationMs <= 0) return;
    final knownEnds = <int>{
      if (old.valid)
        for (final c in [
          ...old.downloaded,
          ...?old.custom,
          ...?old.undoChapters,
        ])
          c.endMs,
    };
    for (final chapter in next.active) {
      if (chapter.endMs > durationMs && !knownEnds.contains(chapter.endMs)) {
        throw const FormatException(
          'Chapters must stay within the media duration.',
        );
      }
    }
  }

  /// [old] with [entries] as its chapters. Undo goes back to [old]'s
  /// chapters, or with [keepUndo] to where [old]'s Undo goes (when it has
  /// one), so a later save of the same editing session adds no undo step.
  ChapterData _edited(
    ChapterData old,
    List<MediaChapter> entries, {
    int? durationMs,
    bool keepUndo = false,
  }) {
    entries.sort((a, b) => a.startMs.compareTo(b.startMs));
    final keep = keepUndo && old.undoChapters != null;
    final undo = keep ? old.undoChapters! : old.active;
    // Skip marks follow chapter ids. Marks of chapters that are gone are
    // dropped, except those in the undo snapshot, so Undo brings a removed
    // chapter back with its mark.
    final keptIds = {for (final c in entries) c.id, for (final c in undo) c.id};
    // Built in full rather than with copyWith: after the file was replaced,
    // the old check time and length must not carry over, so the new file
    // still gets its chapter info fetched.
    return ChapterData(
      downloaded: old.valid ? old.downloaded : const [],
      custom: entries,
      checkedAt: old.valid ? old.checkedAt : null,
      durationMs: durationMs ?? (old.valid ? old.durationMs : null),
      shuffleChapters: old.shuffleChapters,
      undoChapters: undo,
      // Undo goes back to following YouTube, not to a frozen copy of it.
      undoFollowsDownloaded:
          keep ? old.undoFollowsDownloaded : old.custom == null,
      recognitionEpoch: old.recognitionEpoch,
      lastRecognitionRunId: old.lastRecognitionRunId,
      skippedChapterIds: Set.unmodifiable(
        old.skippedChapterIds.where(keptIds.contains),
      ),
      // Labels follow chapter ids too, and are dropped when written once
      // their chapter is in none of the lists (see `keptChapterLabels`).
      chapterLabels: old.chapterLabels,
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
  /// Zero or negative lengths count as unknown (a local replacement file
  /// can have a stored length of 0).
  static int? knownDurationMs(Track track, {int? durationMs}) {
    int? positive(int? ms) => ms != null && ms > 0 ? ms : null;
    final data = ChapterData.decode(track.chaptersJson);
    final seconds = track.durationSeconds;
    return positive(durationMs) ??
        (data.valid ? positive(data.durationMs) : null) ??
        (track.isLocalReplacement || seconds == null || seconds <= 0
            ? null
            : seconds * 1000);
  }

  /// Saves [chapters] as the file's whole chapter list in one step (one
  /// Undo takes it all back), as the chapter editor produces it.
  ///
  /// A chapter whose id is already in the list keeps its origin and
  /// alternative titles; it counts as edited when its title or timing
  /// changed, and the review notes that change resolves are dropped (like
  /// [save]). New ids are the user's own chapters. [durationMs] is the
  /// file's real length when known (for example from the preview player).
  /// With [keepUndo] (a later save of an editing session that already
  /// saved), Undo keeps going back to before the session's first save.
  /// Returns false, writing nothing, when nothing changed.
  Future<bool> replaceActive(
    Track track,
    List<MediaChapter> chapters, {
    int? durationMs,
    bool keepUndo = false,
  }) => _change(track, (old, fresh) {
    final previous = {for (final c in old.active) c.id: c};
    final sameAsBefore =
        chapters.length == old.active.length &&
        chapters.every((c) {
          final p = previous[c.id];
          return p != null &&
              p.title == c.title.trim() &&
              p.startMs == c.startMs &&
              p.endMs == c.endMs;
        });
    if (sameAsBefore) return old;
    final duration = knownDurationMs(fresh, durationMs: durationMs);
    final saved = [
      for (final chapter in chapters)
        _savedChapter(chapter, previous[chapter.id]),
    ];
    return _edited(old, saved, durationMs: duration, keepUndo: keepUndo);
  });

  /// [chapter] as it is stored after an edit, given the [previous] version
  /// with the same id (null for a new chapter).
  static MediaChapter _savedChapter(
    MediaChapter chapter,
    MediaChapter? previous,
  ) {
    final title = chapter.title.trim();
    if (previous == null) {
      return MediaChapter(
        id: chapter.id,
        title: title,
        startMs: chapter.startMs,
        endMs: chapter.endMs,
      );
    }
    final renamed = title != previous.title;
    final moved = chapter.startMs != previous.startMs;
    final edited = renamed || moved || chapter.endMs != previous.endMs;
    return previous.copyWith(
      title: title,
      startMs: chapter.startMs,
      endMs: chapter.endMs,
      manuallyEdited: previous.manuallyEdited || edited,
      reviewReasons:
          previous.reviewReasons
              .where(
                (reason) =>
                    !(reason.startsWith('Name:') && renamed) &&
                    !(reason.startsWith('Timing:') && moved),
              )
              .toList(),
    );
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
      await _writeChapters(
        track.id,
        data.copyWith(
          recognitionEpoch:
              math.max(current.recognitionEpoch, data.recognitionEpoch) + 1,
          // Labelling is not a chapter edit: labels given since [data] was
          // taken stay, and chapters it brings back get theirs back.
          chapterLabels: {...data.chapterLabels, ...current.chapterLabels},
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
                // A file that followed its YouTube chapters before the
                // change follows them again, including later fetches.
                custom: old.undoFollowsDownloaded ? null : old.undoChapters,
                undoChapters: null,
                undoFollowsDownloaded: false,
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
        undoFollowsDownloaded: old.custom == null,
        recognitionEpoch: old.recognitionEpoch + 1,
      );
    });
  }

  /// Leftover pieces shorter than this come from clipping, not from a song,
  /// and are dropped instead of becoming chapters of their own.
  static const minimumChapterMs = 5000;

  /// Applies a completed scan's reviewed [proposals] as one undoable step
  /// (see [planRecognition] for what the chapters become).
  ///
  /// A run is applied once per [epoch], which undo, reset and file
  /// replacement bump; a stale epoch or a repeated run returns false.
  ///
  /// [fileKey] is the run's [RecognitionRun.fileKey]. When given, the
  /// track's current file must still have that content key, checked inside
  /// the transaction; otherwise [StaleRecognitionRun] is thrown and nothing
  /// changes. The review page always passes it.
  Future<bool> applyRecognition(
    Track track, {
    required String runId,
    required int epoch,
    required int durationMs,
    required List<MediaChapter> proposals,
    required String? fileKey,
    bool replaceAll = false,
  }) => _change(track, (old, _) {
    if (old.recognitionEpoch != epoch ||
        old.lastRecognitionRunId == runId ||
        proposals.isEmpty) {
      return old;
    }
    final plan = planRecognition(
      old,
      proposals,
      durationMs: durationMs,
      replaceAll: replaceAll,
    );
    return _edited(old, [
      ...plan.chapters,
    ], durationMs: plan.durationMs).copyWith(lastRecognitionRunId: runId);
  }, verify: fileKey == null ? null : (fresh) => _checkRunFile(fresh, fileKey));

  /// The chapters [old] gets when a scan's [proposals] are applied.
  ///
  /// With [replaceAll] (the user confirmed replacing their chapters), the
  /// proposals become the whole list. A proposal with the same start and
  /// title as a current chapter keeps that chapter (its id, so its lyrics
  /// and Always skip mark stay; its notes and flags) and takes the
  /// proposal's end.
  ///
  /// Otherwise chapters the user created or edited are never moved or
  /// clipped; proposals are cut around them, and earlier untouched
  /// recognition results are replaced wherever a new proposal covers them.
  ///
  /// Either way, proposals that overlap each other or run past the file are
  /// clipped rather than rejected, so one odd match cannot throw away a
  /// whole run, and pieces shorter than [minimumChapterMs] are dropped.
  static RecognitionPlan planRecognition(
    ChapterData old,
    List<MediaChapter> proposals, {
    required int durationMs,
    bool replaceAll = false,
  }) {
    final protected =
        replaceAll
            ? const <MediaChapter>[]
            : old.active.where((c) => c.protectedFromRecognition).toList();
    final protectedRanges = protected.map((c) => (c.startMs, c.endMs)).toList();
    // Current chapters a proposal can stand for unchanged: same start and
    // title. Each is used once.
    final reusable = <(int, String), MediaChapter>{
      if (replaceAll)
        for (final c in old.active) (c.startMs, c.title): c,
    };

    final added = <MediaChapter>[];
    final moved = <MediaChapter>[];
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
        final same = reusable.remove((range.$1, proposal.title));
        if (same != null) {
          if (same.endMs != range.$2) moved.add(same);
          added.add(same.copyWith(endMs: range.$2));
          continue;
        }
        added.add(
          proposal.copyWith(
            id: '${proposal.id}-${range.$1}-${range.$2}',
            startMs: range.$1,
            endMs: range.$2,
            origin: ChapterOrigin.auto,
            // Titles typed or merges made on the review page are the user's
            // work and stay protected from later scans.
            manuallyEdited: proposal.manuallyEdited,
          ),
        );
      }
    }

    // Earlier automatic results also stay inside the file; protected
    // chapters are kept exactly as they are, even past the probed length.
    final addedRanges = [
      ...added.map((c) => (c.startMs, c.endMs)),
      (durationMs, 1 << 40),
    ];
    final retained = <MediaChapter>[...protected];
    if (!replaceAll) {
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
    }
    // A YouTube chapter ends at a whole-second length and a user chapter at
    // the player's length; either can be a little past the probed length.
    // The stored length covers them, so later edits are not refused.
    final storedDurationMs = protected.fold<int>(
      durationMs,
      (longest, c) => math.max(longest, c.endMs),
    );
    final chapters = [...retained, ...added]
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final oldIds = {for (final c in old.active) c.id};
    final newIds = {for (final c in chapters) c.id};
    return RecognitionPlan(
      chapters: List.unmodifiable(chapters),
      durationMs: storedDurationMs,
      removed: [
        for (final c in old.active)
          if (!newIds.contains(c.id)) c,
      ],
      added: [
        for (final c in chapters)
          if (!oldIds.contains(c.id)) c,
      ],
      moved: moved,
    );
  }

  /// Refuses a run made from other content than [track]'s file has now.
  static Future<void> _checkRunFile(Track track, String fileKey) async {
    final current = await SongRecognitionService.currentFileKey(track);
    if (current == null || current != fileKey) {
      throw const StaleRecognitionRun.fileChanged();
    }
  }

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

/// What applying a recognition run does to a file's chapters
/// ([ChapterService.planRecognition]).
class RecognitionPlan {
  /// The chapters after applying, in order.
  final List<MediaChapter> chapters;

  /// The file length stored with them.
  final int durationMs;

  /// Current chapters that are not in [chapters] (by id): replaced, cut or
  /// dropped. Their lyrics go with them.
  final List<MediaChapter> removed;

  /// Chapters that are new (by id).
  final List<MediaChapter> added;

  /// Current chapters (as they are now) that keep their id, start and title
  /// but get another end. Synced lyrics that are not pinned go with the old
  /// end.
  final List<MediaChapter> moved;

  const RecognitionPlan({
    required this.chapters,
    required this.durationMs,
    required this.removed,
    required this.added,
    this.moved = const [],
  });

  /// Chapters that stay exactly as they are or keep their id.
  int get kept => chapters.length - added.length;

  /// Chapters that stay exactly as they are.
  int get identical => kept - moved.length;

  /// Whether applying changes any current chapter (the user is asked first).
  bool get changesCurrent => removed.isNotEmpty || moved.isNotEmpty;
}

/// A recognition run that no longer fits the track: its chapters were
/// undone or reset since the scan, or its file was replaced
/// ([StaleRecognitionRun.fileChanged]).
class StaleRecognitionRun implements Exception {
  static const chaptersChangedMessage =
      'These proposals were made before the chapters were undone or reset, '
      'so they were not applied. Use Recognize again: it rebuilds them from '
      'saved lookups.';
  static const fileChangedMessage =
      'These proposals were made for an earlier version of this file, so '
      'they were not applied. Use Recognize again to scan the file as it is '
      'now.';

  final String message;
  const StaleRecognitionRun([this.message = chaptersChangedMessage]);
  const StaleRecognitionRun.fileChanged() : message = fileChangedMessage;
  @override
  String toString() => message;
}

class _MediaChanged implements Exception {
  const _MediaChanged();
  String get message => 'The media changed while chapters were loading.';
}
