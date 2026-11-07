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
            await db.writeTrackChapters(
              track.id,
              ChapterData(
                downloaded: remote.downloaded,
                custom: old.custom,
                shuffleChapters: old.shuffleChapters,
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
      ChapterData(
        downloaded: remote.downloaded,
        custom: old.valid ? old.custom : null,
        shuffleChapters: old.shuffleChapters,
        checkedAt: remote.checkedAt,
        durationMs: remote.durationMs,
      ),
    );
  }

  Future<void> save(
    Track track,
    MediaChapter chapter, {
    int? durationMs,
  }) async {
    final fresh = await db.getTrack(track.id);
    if (fresh == null || fresh.filePath != track.filePath) {
      throw StateError('The media changed.');
    }
    final old = ChapterData.decode(fresh.chaptersJson);
    final entries = [...old.active.where((c) => c.id != chapter.id), chapter]
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final duration = knownDurationMs(fresh, durationMs: durationMs);
    if (duration == null || duration <= 0) {
      throw StateError('Play the file first to determine its duration.');
    }
    validateChapters(entries, durationMs: duration);
    await db.writeTrackChapters(
      track.id,
      ChapterData(
        downloaded: old.valid ? old.downloaded : const [],
        custom: entries,
        shuffleChapters: old.shuffleChapters,
        checkedAt: old.valid ? old.checkedAt : null,
        durationMs: duration,
      ),
    );
    await persist(track.playlistId);
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

  /// Removes one chapter. Returns the chapter info from before, so the
  /// caller can offer Undo through [replaceChapters].
  Future<ChapterData?> delete(Track track, String chapterId) async {
    final fresh = await db.getTrack(track.id);
    if (fresh == null) return null;
    final old = ChapterData.decode(fresh.chaptersJson);
    await db.writeTrackChapters(
      track.id,
      old.withCustom(old.active.where((c) => c.id != chapterId).toList()),
    );
    await persist(track.playlistId);
    return old;
  }

  /// Writes [data] back as the track's chapter info (Undo of an edit).
  Future<void> replaceChapters(Track track, ChapterData data) async {
    await db.writeTrackChapters(track.id, data);
    await persist(track.playlistId);
  }

  Future<void> restore(Track track) async {
    final fresh = await db.getTrack(track.id);
    if (fresh == null) return;
    await db.writeTrackChapters(
      track.id,
      ChapterData.decode(fresh.chaptersJson).withCustom(null),
    );
    await persist(track.playlistId);
  }
}

class _MediaChanged implements Exception {
  const _MediaChanged();
  String get message => 'The media changed while chapters were loading.';
}
