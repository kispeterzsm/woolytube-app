import '../database/database.dart';
import 'chapters.dart';
import 'metadata_service.dart';
import 'ytdlp_service.dart';
import 'playlist_service.dart';

/// Owns chapter edits and durable metadata; it never opens media for writing.
class ChapterService {
  final AppDatabase db;
  final YtDlpService ytdlp;
  ChapterService(this.db, this.ytdlp);

  Future<void> persist(int playlistId) async {
    await MetadataService(db).writeMetadata(
      await db.getPlaylist(playlistId),
      await db.getTracksForPlaylist(playlistId),
    );
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

  Future<(int, int)> fetchMissing(int playlistId) async {
    final tracks = await db.getTracksForPlaylist(playlistId);
    var checked = 0, failed = 0;
    final results = <String, ChapterData>{};
    for (final track in tracks) {
      final old = ChapterData.decode(track.chaptersJson);
      if (track.status != 'complete' ||
          track.filePath == null ||
          track.isLocalReplacement ||
          PlaylistService.isForcedInsertVideoId(track.videoId) ||
          !old.valid ||
          old.checkedAt != null) {
        continue;
      }
      try {
        if (results.containsKey(track.videoId)) {
          final remote = results[track.videoId]!;
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
          await refresh(track);
          results[track.videoId] = ChapterData.decode(
            (await db.getTrack(track.id))?.chaptersJson,
          );
        }
        checked++;
      } catch (_) {
        failed++;
      }
    }
    await persist(playlistId);
    return (checked, failed);
  }

  Future<void> refresh(Track track) async {
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
      throw StateError('The media changed while chapters were loading.');
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
    await persist(track.playlistId);
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
    final duration =
        durationMs ??
        (old.valid ? old.durationMs : null) ??
        (fresh.isLocalReplacement
            ? null
            : fresh.durationSeconds == null
            ? null
            : fresh.durationSeconds! * 1000);
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

  Future<void> delete(Track track, String chapterId) async {
    final fresh = await db.getTrack(track.id);
    if (fresh == null) return;
    final old = ChapterData.decode(fresh.chaptersJson);
    await db.writeTrackChapters(
      track.id,
      old.withCustom(old.active.where((c) => c.id != chapterId).toList()),
    );
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
