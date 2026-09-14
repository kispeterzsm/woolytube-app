import '../database/database.dart';
import 'chapters.dart';

bool matchesTrackSearch(Track track, String query) {
  final normalized = query.trim().toLowerCase();
  final index = track.index.toString();
  return track.title.toLowerCase().contains(normalized) ||
      index.contains(normalized) ||
      '#$index'.contains(normalized) ||
      ChapterData.decode(track.chaptersJson).active.any(
        (chapter) => chapter.title.toLowerCase().contains(normalized),
      );
}
