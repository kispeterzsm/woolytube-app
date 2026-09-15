import '../database/database.dart';
import 'chapters.dart';

bool matchesTrackSearch(Track track, String query) {
  final normalized = query.trim().toLowerCase();
  final index = track.index.toString();
  return track.title.toLowerCase().contains(normalized) ||
      index.contains(normalized) ||
      '#$index'.contains(normalized) ||
      matchingChapterForSearch(track, normalized) != null;
}

/// Select the first matching active chapter in timeline order. Empty searches
/// leave normal file playback unchanged.
MediaChapter? matchingChapterForSearch(Track track, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return null;
  return ChapterData.decode(track.chaptersJson).active
      .where((chapter) => chapter.title.toLowerCase().contains(normalized))
      .firstOrNull;
}
