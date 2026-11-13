import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_text.dart';
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

  test('a query keeps distinct words, and its phrase as typed', () {
    final query = SearchQuery('  Ná na  NA hey ');
    expect(query.words, ['na', 'hey']);
    expect(query.folded, 'na hey');
    expect(query.phrase, 'na na na hey');
    // More of the same words is another query for the lyrics search.
    expect(SearchQuery('na hey'), isNot(query));
    expect(SearchQuery('NA na na hey'), query);
  });

  group('searchLibrary', () {
    late AppDatabase db;
    late int playlistId;
    var nextIndex = 1;

    setUp(() async {
      db = openTestDatabase();
      playlistId = (await insertTestPlaylist(db)).id;
      nextIndex = 1;
    });
    tearDown(() => db.close());

    Future<Track> track(
      String title, {
      int? index,
      int? playlist,
      List<MediaChapter>? chapters,
      String status = 'complete',
      bool alwaysSkip = false,
    }) async {
      final i = index ?? nextIndex++;
      final inserted = await insertTestTrack(
        db,
        playlistId: playlist ?? playlistId,
        index: i,
        videoId: 'v$i-${title.hashCode}',
        title: title,
        status: status,
        filePath: status == 'complete' ? '/tmp/$i.m4a' : null,
        alwaysSkip: alwaysSkip,
      );
      return chapters == null
          ? inserted
          : inserted.copyWith(
            chaptersJson: Value(ChapterData(downloaded: chapters).encode()),
          );
    }

    List<String> titles(List<SearchHit> hits) => [
      for (final hit in hits) hit.track.title,
    ];

    test('ignores accents, punctuation and word order', () async {
      final song = await track('Föl földobott kő');
      final other = await track('AC/DC - Thunderstruck');
      final tracks = [song, other];
      for (final query in [
        'fol',
        'FÖL',
        'ko foldobott',
        'kő föl',
        'foldobott,',
      ]) {
        expect(titles(searchLibrary(tracks, SearchQuery(query))), [
          'Föl földobott kő',
        ], reason: query);
      }
      expect(titles(searchLibrary(tracks, SearchQuery('thunder ac/dc'))), [
        'AC/DC - Thunderstruck',
      ]);
      expect(searchLibrary(tracks, SearchQuery('fol thunder')), isEmpty);
    });

    test('a number finds that track, then numbers starting with it', () async {
      final tracks = [
        for (final i in [1, 2, 10, 12, 21]) await track('Song', index: i),
        await track('Live 1999', index: 30),
      ];
      List<int> found(String query) => [
        for (final hit in searchLibrary(tracks, SearchQuery(query)))
          hit.track.index,
      ];
      // Never 21; a title holding the number is found too.
      expect(found('1'), [1, 10, 12, 30]);
      expect(found('#12'), [12]);
      expect(found('12'), [12]);
      expect(found('1999'), [30]);
      expect(
        searchLibrary(tracks, SearchQuery('1')).first.reason,
        SearchReason.number,
      );
    });

    test('ranks exact, then starting, then word starts, then the rest, then '
        'chapters; ties by playlist order and number', () async {
      final later = (await insertTestPlaylist(db, url: 'later')).id;
      final tracks = [
        await track('Glove'),
        await track('Endless love'),
        await track(
          'Mix',
          chapters: const [
            MediaChapter(id: 'a', title: 'Love song', startMs: 0, endMs: 1),
          ],
        ),
        await track('Love story'),
        await track('Love', playlist: later, index: 1),
        await track('love', index: 50),
      ];
      final hits = searchLibrary(
        tracks,
        SearchQuery('love'),
        playlistOrder: {later: 0, playlistId: 1},
      );
      expect(titles(hits), [
        'Love',
        'love',
        'Love story',
        'Endless love',
        'Glove',
        'Mix',
      ]);
      expect([for (final hit in hits) hit.rank], [0, 0, 1, 2, 3, 4]);

      // Unranked keeps the list order (the playlist page).
      expect(
        titles(searchLibrary(tracks, SearchQuery('love'), ranked: false)),
        ['Glove', 'Endless love', 'Mix', 'Love story', 'Love', 'love'],
      );
      // An empty search lists everything, in playlist order.
      expect(
        titles(
          searchLibrary(
            tracks,
            SearchQuery.empty,
            playlistOrder: {later: 0, playlistId: 1},
          ),
        ).first,
        'Love',
      );
    });

    test('chapter hits list every chapter found; Play all plays only those '
        'unless the title matched', () async {
      const chapters = [
        MediaChapter(id: 'a', title: 'Intro', startMs: 0, endMs: 10),
        MediaChapter(id: 'b', title: 'Hidden melody', startMs: 10, endMs: 20),
        MediaChapter(id: 'c', title: 'Outro', startMs: 20, endMs: 30),
        MediaChapter(id: 'd', title: 'Melody (hidden)', startMs: 30, endMs: 40),
      ];
      final mix = await track('Full album', chapters: chapters);
      final named = await track('Hidden melody live', chapters: chapters);

      final hits = searchLibrary([mix, named], SearchQuery('melody hidden'));
      expect(titles(hits), ['Hidden melody live', 'Full album']);
      final byChapter = hits.last;
      expect(byChapter.reason, SearchReason.chapter);
      expect([for (final c in byChapter.chapters) c.id], ['b', 'd']);
      expect(byChapter.chapter?.id, 'b');
      expect(byChapter.queueEntry, QueueEntry(mix, const {'b', 'd'}));
      // The title matched: the whole file, though a tap starts at the
      // chapter.
      expect(hits.first.reason, SearchReason.title);
      expect(hits.first.chapter?.id, 'b');
      expect(hits.first.queueEntry, QueueEntry(named));
    });

    test('lyrics count only with the Lyrics filter on', () async {
      final mix = await track(
        'Mix',
        chapters: const [
          MediaChapter(id: 'a', title: 'One', startMs: 0, endMs: 60000),
          MediaChapter(id: 'b', title: 'Two', startMs: 60000, endMs: 120000),
        ],
      );
      final song = await track('Road song');
      final plain = await track('Plain');
      LyricsHit lyric(Track track, int? at) => LyricsHit(
        trackId: track.id,
        docId: track.id,
        lineId: track.id,
        lineNo: 0,
        lineText: 'endless road',
        positionMs: at,
        score: 1,
        kind: LyricsMode.lyrics,
      );
      final lyricHits = [lyric(mix, 90000), lyric(song, 1000), lyric(plain, 0)];
      final tracks = [mix, song, plain];

      expect(
        titles(
          searchLibrary(tracks, SearchQuery('road'), lyricHits: lyricHits),
        ),
        ['Road song'],
      );
      final hits = searchLibrary(
        tracks,
        SearchQuery('road'),
        filters: const SearchFilters(lyrics: true),
        lyricHits: lyricHits,
      );
      expect(titles(hits), ['Road song', 'Mix', 'Plain']);
      expect(
        [for (final hit in hits) hit.reason],
        [SearchReason.title, SearchReason.lyrics, SearchReason.lyrics],
      );
      expect(hits.first.lyric, isNotNull);
      // A lyrics hit plays the chapter holding the line, or the whole file.
      expect(searchQueueEntries(hits), [
        QueueEntry(song),
        QueueEntry(mix, const {'b'}),
        QueueEntry(plain),
      ]);
    });

    test('Play all leaves out what cannot play automatically', () async {
      final tracks = [
        await track('Song one'),
        await track('Song two', status: 'pending'),
        await track('Song three', alwaysSkip: true),
        await track('Song four'),
      ];
      final hits = searchLibrary(tracks, SearchQuery('song'), ranked: false);
      expect(hits, hasLength(4));
      expect(searchQueueEntries(hits), [
        QueueEntry(tracks[0]),
        QueueEntry(tracks[3]),
      ]);
    });

    test('the Lyrics filter is off by default', () {
      expect(const SearchFilters().lyrics, isFalse);
      expect(
        const SearchFilters().copyWith(lyrics: true),
        const SearchFilters(lyrics: true),
      );
    });

    test('playlist names match the same way', () {
      expect(
        matchesSearchText('Vibe Mix – Őszi', SearchQuery('oszi vibe')),
        isTrue,
      );
      expect(matchesSearchText('Vibe Mix', SearchQuery('vibe rock')), isFalse);
    });
  });

  group('highlights', () {
    test('cover the raw letters of each word found', () {
      String marked(String text, String query) {
        final buffer = StringBuffer();
        var at = 0;
        for (final h in searchHighlights(text, SearchQuery(query))) {
          buffer
            ..write(text.substring(at, h.start))
            ..write('[${text.substring(h.start, h.end)}]');
          at = h.end;
        }
        return (buffer..write(text.substring(at))).toString();
      }

      expect(marked('Föl földobott kő', 'fol'), '[Föl] [föl]dobott kő');
      expect(marked('Föl földobott kő', 'ko'), 'Föl földobott [kő]');
      expect(marked("Don't Stop Me Now", 'dont me'), "[Don't] Stop [Me] Now");
      expect(marked('Straße', 'strass'), '[Straß]e');
      expect(marked('Love Love', 'lo love'), '[Love] [Love]');
      expect(marked('Nothing', 'xyz'), 'Nothing');
    });

    test('folding with offsets folds like foldForSearch', () {
      for (final text in [
        "  Don't — stop!  ",
        'AC/DC',
        'Cafe\u0301 Ős',
        'Straße æ',
        '♪ 日本語 ♪',
        '',
      ]) {
        expect(foldWithOffsets(text).text, foldForSearch(text), reason: text);
      }
    });
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
