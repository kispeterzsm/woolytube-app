import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/label_service.dart';
import 'package:woolytube/services/labels.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/track_search.dart';

import '../helpers/test_database.dart';

const rock = '00000000-0000-4000-8000-000000000001';
const live = '00000000-0000-4000-8000-000000000002';
const jazz = '00000000-0000-4000-8000-000000000003';

void main() {
  late AppDatabase db;
  late Playlist playlist;

  setUp(() async {
    db = openTestDatabase();
    playlist = await insertTestPlaylist(db);
  });

  tearDown(() => db.close());

  const chapters = [
    MediaChapter(id: 'a', title: 'Opening', startMs: 0, endMs: 10000),
    MediaChapter(id: 'b', title: 'Rock ballad', startMs: 10000, endMs: 20000),
    MediaChapter(id: 'c', title: 'Closing', startMs: 20000, endMs: 30000),
  ];

  Future<Track> track(
    int index,
    String title, {
    List<String> labels = const [],
    Map<String, List<String>> chapterLabels = const {},
    bool withChapters = false,
  }) async {
    final inserted = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: index,
      videoId: 'video-$index',
      title: title,
      status: 'complete',
      filePath: '/tmp/$index.m4a',
    );
    return inserted.copyWith(
      labelUids: Value(encodeLabelUids(labels)),
      chaptersJson: Value(
        withChapters || chapterLabels.isNotEmpty
            ? ChapterData(
              custom: chapters,
              chapterLabels: chapterLabels,
            ).encode()
            : null,
      ),
    );
  }

  /// Each hit as "index reason chapters".
  List<String> describe(List<SearchHit> hits) => [
    for (final hit in hits)
      [
        hit.track.index,
        hit.reason.name,
        for (final chapter in hit.chapters) chapter.id,
      ].join(' '),
  ];

  test('an empty search with a label lists every file and chapter that '
      'carries it, and Play all plays the files whole and the chapters '
      'alone', () async {
    final tracks = [
      await track(1, 'Song one', labels: [rock]),
      await track(2, 'Song two'),
      await track(
        3,
        'A mix',
        chapterLabels: {
          'b': [rock],
          'c': [rock, live],
        },
      ),
      // Labelled itself and in chapters: the file plays whole.
      await track(
        4,
        'Live album',
        labels: [rock],
        chapterLabels: {
          'a': [rock],
        },
      ),
    ];
    final hits = searchLibrary(
      tracks,
      SearchQuery.empty,
      filters: const SearchFilters(labels: {rock}),
    );
    expect(describe(hits), ['1 label', '3 chapter b c', '4 label']);
    final entries = searchQueueEntries(hits);
    expect(entries.map((e) => '${e.track.index} ${e.chapterIds?.join(',')}'), [
      '1 null',
      '3 b,c',
      '4 null',
    ]);
  });

  test('several labels need all of them by default, any of them on '
      'request; a file and its chapters do not add up', () async {
    final tracks = [
      await track(1, 'Both', labels: [rock, live]),
      await track(2, 'Only rock', labels: [rock]),
      await track(
        3,
        'File rock, chapter live',
        labels: [rock],
        chapterLabels: {
          'a': [live],
        },
      ),
      await track(
        4,
        'Chapter both',
        chapterLabels: {
          'b': [live, rock],
        },
      ),
      await track(5, 'Jazz', labels: [jazz]),
    ];
    final all = searchLibrary(
      tracks,
      SearchQuery.empty,
      filters: const SearchFilters(labels: {rock, live}),
    );
    expect(describe(all), ['1 label', '4 chapter b']);
    final any = searchLibrary(
      tracks,
      SearchQuery.empty,
      filters: const SearchFilters(
        labels: {rock, live},
        labelMatch: LabelMatch.any,
      ),
    );
    expect(describe(any).map((d) => d.split(' ').first), ['1', '2', '3', '4']);
  });

  test('words and labels together', () async {
    final tracks = [
      await track(1, 'Rock anthem', labels: [rock]),
      await track(2, 'Rock without label'),
      await track(
        3,
        'Rock mix',
        chapterLabels: {
          'a': [rock],
          'b': [rock],
        },
      ),
      await track(
        4,
        'Other mix',
        chapterLabels: {
          'a': [rock],
        },
      ),
      await track(
        5,
        'Third mix',
        chapterLabels: {
          'b': [rock],
        },
      ),
    ];
    final hits = searchLibrary(
      tracks,
      SearchQuery('rock'),
      filters: const SearchFilters(labels: {rock}),
      ranked: false,
    );
    expect(describe(hits), [
      // Labelled itself: found as by the words alone.
      '1 title',
      // The title matches, the labelled chapters whose title matches too.
      '3 chapter b',
      // Only a chapter title matches, but that chapter has no label.
      // (4 is left out.)
      // A chapter title matches and that chapter carries the label.
      '5 chapter b',
    ]);
    // Title matches and labelled chapters' titles don't: all of them.
    final mix = searchLibrary(
      [tracks[2]],
      SearchQuery('mix'),
      filters: const SearchFilters(labels: {rock}),
    );
    expect(describe(mix), ['3 chapter a b']);
    expect(searchQueueEntries(mix).single.chapterIds, {'a', 'b'});
  });

  test('a lyric line counts when its chapter carries the label', () async {
    final mix = await track(
      1,
      'Mix',
      chapterLabels: {
        'b': [rock],
      },
    );
    LyricsHit line(int positionMs) => LyricsHit(
      docId: 1,
      trackId: mix.id,
      kind: LyricsMode.lyrics,
      lineId: 1,
      lineNo: 0,
      lineText: 'sing along',
      positionMs: positionMs,
      score: 1,
    );
    SearchHit? hit(int positionMs) =>
        searchLibrary(
          [mix],
          SearchQuery('along'),
          filters: const SearchFilters(lyrics: true, labels: {rock}),
          lyricHits: [line(positionMs)],
        ).firstOrNull;
    expect(hit(15000)?.reason, SearchReason.lyrics);
    expect(hit(15000)?.queueEntry.chapterIds, {'b'});
    expect(hit(5000), isNull);
    expect(
      searchLabelsAllow(mix, chapters[1], const SearchFilters(labels: {rock})),
      isTrue,
    );
    expect(
      searchLabelsAllow(mix, null, const SearchFilters(labels: {rock})),
      isFalse,
    );
    expect(searchLabelsAllow(mix, null, const SearchFilters()), isTrue);
  });

  test(
    'Label all labels what Play all would play, downloaded or not',
    () async {
      final tracks = [
        await track(1, 'Song', labels: [rock]),
        await track(
          2,
          'Mix',
          chapterLabels: {
            'c': [rock],
          },
        ),
      ];
      final hits = searchLibrary(
        tracks,
        SearchQuery.empty,
        filters: const SearchFilters(labels: {rock}),
      );
      final targets = searchLabelTargets(hits);
      expect(targets, [
        LabelledItem(tracks[0]),
        LabelledItem(tracks[1], chapters[2]),
      ]);
      expect(labelStateOf(targets, rock), isTrue);
      expect(labelStateOf(targets, live), isFalse);

      // Through the service: one label on all of them, then off again.
      final service = LabelService(db);
      final liveLabel = await service.create('Live', 0xff64b5f6);
      // The tracks in the database have no labels yet: store them.
      await db.setTrackLabelUids(tracks[0].id, tracks[0].labelUids);
      await db.writeTrackChapters(
        tracks[1].id,
        ChapterData.decode(tracks[1].chaptersJson),
      );
      expect(await service.setLabelOnItems(targets, liveLabel.uid, true), 2);
      final song = (await db.getTrack(tracks[0].id))!;
      final mix = (await db.getTrack(tracks[1].id))!;
      // Unknown (rock was never made here) uids are dropped on write.
      expect(decodeLabelUids(song.labelUids), [liveLabel.uid]);
      expect(ChapterData.decode(mix.chaptersJson).labelsOf('c'), [
        liveLabel.uid,
      ]);
      expect(ChapterData.decode(mix.chaptersJson).labelsOf('b'), isEmpty);
      expect(
        labelStateOf([
          LabelledItem(song),
          LabelledItem(mix, chapters[2]),
        ], liveLabel.uid),
        isTrue,
      );
      expect(
        labelStateOf([
          LabelledItem(song),
          LabelledItem(mix, chapters[1]),
        ], liveLabel.uid),
        isNull,
      );
      // Again: nothing changes.
      expect(await service.setLabelOnItems(targets, liveLabel.uid, true), 0);
      expect(await service.setLabelOnItems(targets, liveLabel.uid, false), 2);
      expect((await db.getTrack(tracks[0].id))!.labelUids, isNull);
    },
  );

  test('filters compare by value and forget deleted labels', () {
    const a = SearchFilters(labels: {rock, live});
    final b = SearchFilters(labels: {live, rock});
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == const SearchFilters(labels: {rock}), isFalse);
    expect(
      a ==
          const SearchFilters(labels: {rock, live}, labelMatch: LabelMatch.any),
      isFalse,
    );
    expect(identical(a.withLabelsIn({rock, live, jazz}), a), isTrue);
    expect(a.withLabelsIn({rock}), const SearchFilters(labels: {rock}));
    expect(a.withLabelsIn({}).hasLabels, isFalse);
  });

  test('labelUidsUsedBy finds file and chapter labels', () async {
    final tracks = [
      await track(1, 'Song', labels: [rock]),
      await track(
        2,
        'Mix',
        chapterLabels: {
          'c': [live],
        },
      ),
      await track(3, 'Plain', withChapters: true),
    ];
    expect(labelUidsUsedBy(tracks), {rock, live});
  });
}
