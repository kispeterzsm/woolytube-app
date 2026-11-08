// Fields are unused until the bodies are written.
// ignore_for_file: unused_field

import '../../database/database.dart';
import 'lyrics_models.dart';

/// Finds lines of stored lyrics and transcripts from a half-remembered
/// query: FTS5 candidates with typo expansion, reranked in Dart.
class LyricsSearch {
  LyricsSearch(this._db);

  final AppDatabase _db;

  /// The best line of each matching doc, best first, scoring at least
  /// 0.65. Only playlists with lyrics on; only [playlistId] when given.
  Future<List<LyricsHit>> search(
    String query, {
    int? playlistId,
    int limit = 50,
  }) {
    throw UnimplementedError();
  }

  /// Forgets the cached vocabulary (it reloads on the next search).
  void invalidateVocabulary() {
    throw UnimplementedError();
  }
}
