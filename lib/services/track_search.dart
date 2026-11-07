import '../database/database.dart';
import 'chapters.dart';

/// What a search compares against, computed once per [Track] object: the
/// lower-case title and the active chapters with lower-case titles. Track
/// objects are immutable and the track streams only emit new ones when a
/// track changed, so a search over a long playlist decodes no chapter JSON
/// and lower-cases no title on later keystrokes.
class _SearchEntry {
  _SearchEntry(Track track)
    : title = track.title.toLowerCase(),
      index = track.index.toString(),
      _chaptersJson = track.chaptersJson;

  final String title;
  final String index;
  final String? _chaptersJson;
  List<(String, MediaChapter)>? _chapters;

  /// Active chapters in timeline order, each with its lower-case title.
  List<(String, MediaChapter)> get chapters =>
      _chapters ??= [
        for (final chapter in ChapterData.decode(_chaptersJson).active)
          (chapter.title.toLowerCase(), chapter),
      ];

  MediaChapter? chapterMatching(String normalized) {
    if (_chaptersJson == null) return null;
    for (final (title, chapter) in chapters) {
      if (title.contains(normalized)) return chapter;
    }
    return null;
  }
}

final _entries = Expando<_SearchEntry>('trackSearch');

_SearchEntry _entryFor(Track track) => _entries[track] ??= _SearchEntry(track);

/// [query] in the form the search compares: trimmed and lower case.
String normalizeTrackSearchQuery(String query) => query.trim().toLowerCase();

bool matchesTrackSearch(Track track, String query) =>
    matchesNormalizedTrackSearch(track, normalizeTrackSearchQuery(query));

/// [matchesTrackSearch] for a query already passed through
/// [normalizeTrackSearchQuery], for filtering long lists.
bool matchesNormalizedTrackSearch(Track track, String normalized) {
  final entry = _entryFor(track);
  return entry.title.contains(normalized) ||
      entry.index.contains(normalized) ||
      '#${entry.index}'.contains(normalized) ||
      (normalized.isNotEmpty && entry.chapterMatching(normalized) != null);
}

/// Select the first matching active chapter in timeline order. Empty searches
/// leave normal file playback unchanged.
MediaChapter? matchingChapterForSearch(Track track, String query) {
  final normalized = normalizeTrackSearchQuery(query);
  if (normalized.isEmpty) return null;
  return _entryFor(track).chapterMatching(normalized);
}
