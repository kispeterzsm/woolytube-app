import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/track_search.dart';
import '../helpers/test_database.dart';

void main() {
  test('search matches titles, indices, and active chapter titles', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlist = await insertTestPlaylist(db);
    final track = (await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 42,
      title: 'Full album',
    )).copyWith(
      chaptersJson: Value(
        const ChapterData(
          downloaded: [
            MediaChapter(
              id: 'one',
              title: 'Hidden Melody',
              startMs: 0,
              endMs: 10000,
            ),
          ],
        ).encode(),
      ),
    );
    for (final query in ['full album', '42', '#42', ' HIDDEN melody ']) {
      expect(matchesTrackSearch(track, query), isTrue, reason: query);
    }
    expect(matchesTrackSearch(track, 'absent'), isFalse);
    final custom = ChapterData.decode(track.chaptersJson).withCustom([
      const MediaChapter(
        id: 'custom',
        title: 'Renamed song',
        startMs: 0,
        endMs: 10000,
      ),
    ]);
    final edited = track.copyWith(chaptersJson: Value(custom.encode()));
    expect(matchesTrackSearch(edited, 'hidden'), isFalse);
    expect(matchesTrackSearch(edited, 'renamed'), isTrue);
    expect(
      matchesTrackSearch(
        track.copyWith(chaptersEnabled: const Value(false)),
        'hidden',
      ),
      isTrue,
    );
    expect(
      matchesTrackSearch(
        track.copyWith(chaptersJson: Value(custom.invalidate().encode())),
        'renamed',
      ),
      isFalse,
    );
    expect(
      matchesTrackSearch(
        track.copyWith(chaptersJson: const Value('invalid json')),
        'hidden',
      ),
      isFalse,
    );
  });
}
