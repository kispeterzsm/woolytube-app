import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/track_search.dart';
import 'package:woolytube/widgets/lyrics_line_text.dart';
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
    expect(matchingChapterForSearch(track, ' HIDDEN melody ')?.id, 'one');
    expect(matchingChapterForSearch(track, 'Full album'), isNull);
    expect(matchingChapterForSearch(track, '42'), isNull);
    expect(matchingChapterForSearch(track, '   '), isNull);
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
    expect(matchingChapterForSearch(edited, 'renamed')?.id, 'custom');
    expect(matchingChapterForSearch(edited, 'hidden'), isNull);
    final multiple = track.copyWith(
      chaptersJson: Value(
        const ChapterData(
          downloaded: [
            MediaChapter(
              id: 'later',
              title: 'Melody reprise',
              startMs: 20000,
              endMs: 30000,
            ),
            MediaChapter(
              id: 'earlier',
              title: 'Melody',
              startMs: 10000,
              endMs: 20000,
            ),
          ],
        ).encode(),
      ),
    );
    expect(matchingChapterForSearch(multiple, 'melody')?.id, 'earlier');
    expect(
      matchingChapterForSearch(
        track.copyWith(chaptersJson: Value(custom.invalidate().encode())),
        'renamed',
      ),
      isNull,
    );
    expect(
      matchingChapterForSearch(
        track.copyWith(chaptersJson: const Value('invalid json')),
        'hidden',
      ),
      isNull,
    );
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

  group('lyrics hits', () {
    LyricsHit hit({String? chapterId, int? positionMs}) => LyricsHit(
      trackId: 1,
      chapterId: chapterId,
      docId: 1,
      lineId: 1,
      lineNo: 0,
      lineText: 'line',
      positionMs: positionMs,
      score: 1,
      kind: LyricsMode.lyrics,
    );

    test('a hit plays its chapter, or the one at its time', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final playlist = await insertTestPlaylist(db);
      final track = (await insertTestTrack(
        db,
        playlistId: playlist.id,
      )).copyWith(
        chaptersJson: Value(
          const ChapterData(
            downloaded: [
              MediaChapter(id: 'a', title: 'A', startMs: 0, endMs: 60000),
              MediaChapter(id: 'b', title: 'B', startMs: 60000, endMs: 120000),
            ],
          ).encode(),
        ),
      );

      var target = lyricsHitTarget(
        track,
        hit(chapterId: 'b', positionMs: 61000),
      );
      expect(target.chapter?.id, 'b');
      expect(target.startAt, const Duration(milliseconds: 59000));

      target = lyricsHitTarget(track, hit(positionMs: 90000));
      expect(target.chapter?.id, 'b');
      expect(target.startAt, const Duration(milliseconds: 88000));

      target = lyricsHitTarget(track, hit(positionMs: 1000));
      expect(target.chapter?.id, 'a');
      expect(target.startAt, Duration.zero);

      // Plain lyrics of a chapter: the chapter from its start.
      target = lyricsHitTarget(track, hit(chapterId: 'a'));
      expect(target.chapter?.id, 'a');
      expect(target.startAt, isNull);

      final plain = track.copyWith(chaptersJson: const Value(null));
      target = lyricsHitTarget(plain, hit(chapterId: 'a', positionMs: 5000));
      expect(target.chapter, isNull);
      expect(target.startAt, const Duration(milliseconds: 3000));
    });

    test('times read m:ss or h:mm:ss', () {
      expect(formatLyricsTime(83000), '1:23');
      expect(formatLyricsTime(5000), '0:05');
      expect(formatLyricsTime(3723000), '1:02:03');
    });

    test('a snippet starts shortly before the first match', () {
      const text =
          'Oh brother, oh sister, there is an endless road to rediscover';
      final long = LyricsHit(
        trackId: 1,
        docId: 1,
        lineId: 1,
        lineNo: 0,
        lineText: text,
        highlightRanges: const [
          LyricsHighlight(35, 42),
          LyricsHighlight(43, 47),
        ],
        score: 1,
        kind: LyricsMode.lyrics,
      );
      final snippet = lyricsSnippet(long);
      expect(snippet.text, '…there is an endless road to rediscover');
      expect(
        [
          for (final r in snippet.highlights)
            snippet.text.substring(r.start, r.end),
        ],
        ['endless', 'road'],
      );
      // A match near the start keeps the whole line.
      final short = lyricsSnippet(hit());
      expect(short.text, 'line');
    });
  });
}
