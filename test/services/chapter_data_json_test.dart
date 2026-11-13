import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/chapters.dart';

void main() {
  const youtube = [
    MediaChapter(
      id: 'youtube-0-0',
      title: 'Intro',
      startMs: 0,
      endMs: 60000,
      origin: ChapterOrigin.original,
    ),
    MediaChapter(
      id: 'youtube-1-60000',
      title: 'Song',
      startMs: 60000,
      endMs: 120000,
      origin: ChapterOrigin.original,
    ),
  ];

  test('untouched chapter data is stored exactly as 1.4.1 stored it', () {
    final data = ChapterData(
      downloaded: youtube,
      checkedAt: DateTime.utc(2026, 11, 7),
      durationMs: 120000,
    );

    expect(data.toJson(), {
      'downloaded': [
        {'id': 'youtube-0-0', 'title': 'Intro', 'startMs': 0, 'endMs': 60000},
        {
          'id': 'youtube-1-60000',
          'title': 'Song',
          'startMs': 60000,
          'endMs': 120000,
        },
      ],
      'custom': null,
      'checkedAt': '2026-11-07T00:00:00.000Z',
      'durationMs': 120000,
      'valid': true,
      'shuffleChapters': false,
    });
  });

  group('shuffle chapters', () {
    test('Default, Shuffle and Don\'t shuffle round-trip', () {
      for (final value in [null, true, false]) {
        final data = ChapterData(
          downloaded: youtube,
        ).withShuffleChapters(value);
        expect(data.shuffleChapters, value);
        final back = ChapterData.decode(data.encode());
        expect(back.shuffleChapters, value, reason: '$value');
        expect(back.encode(), data.encode());
      }
    });

    test('older versions still read the bool they know', () {
      Map<String, dynamic> json(bool? value) =>
          ChapterData(shuffleChapters: value).toJson();
      expect(json(null)['shuffleChapters'], isFalse);
      expect(json(null).containsKey('shuffleChaptersMode'), isFalse);
      expect(json(true)['shuffleChapters'], isTrue);
      expect(json(true)['shuffleChaptersMode'], 'shuffle');
      expect(json(false)['shuffleChapters'], isFalse);
      expect(json(false)['shuffleChaptersMode'], 'noShuffle');
    });

    test('data from older versions: on is Shuffle, off is Default', () {
      expect(
        ChapterData.decode('{"shuffleChapters":true}').shuffleChapters,
        isTrue,
      );
      expect(
        ChapterData.decode('{"shuffleChapters":false}').shuffleChapters,
        isNull,
      );
      expect(ChapterData.decode('{"downloaded":[]}').shuffleChapters, isNull);
      // The new key wins over the bool.
      expect(
        ChapterData.decode(
          '{"shuffleChapters":false,"shuffleChaptersMode":"noShuffle"}',
        ).shuffleChapters,
        isFalse,
      );
      expect(
        ChapterData.decode(
          '{"shuffleChapters":false,"shuffleChaptersMode":"shuffle"}',
        ).shuffleChapters,
        isTrue,
      );
      // An unknown mode falls back to the bool.
      expect(
        ChapterData.decode(
          '{"shuffleChapters":true,"shuffleChaptersMode":"sometimes"}',
        ).shuffleChapters,
        isTrue,
      );
    });

    test('the choice is kept through copyWith and invalidate', () {
      const off = ChapterData(shuffleChapters: false);
      expect(off.copyWith(valid: false).shuffleChapters, isFalse);
      expect(off.invalidate().shuffleChapters, isFalse);
      expect(off.copyWith(shuffleChapters: null).shuffleChapters, isNull);
    });
  });

  test('every recognition field survives a round trip', () {
    final data = ChapterData(
      downloaded: youtube,
      custom: const [
        // Kept YouTube chapter, unchanged.
        MediaChapter(
          id: 'youtube-0-0',
          title: 'Intro',
          startMs: 0,
          endMs: 60000,
          origin: ChapterOrigin.original,
        ),
        // Recognized, then renamed by the owner.
        MediaChapter(
          id: 'auto-1',
          title: 'Song (renamed)',
          startMs: 60000,
          endMs: 90000,
          origin: ChapterOrigin.auto,
          manuallyEdited: true,
          alternativeTitles: ['Other name'],
          reviewReasons: ['Single detection'],
        ),
        // Recognized, untouched.
        MediaChapter(
          id: 'auto-2',
          title: 'Next song',
          startMs: 90000,
          endMs: 110000,
          origin: ChapterOrigin.auto,
        ),
        // Made by hand.
        MediaChapter(
          id: 'user-1',
          title: 'Outro',
          startMs: 110000,
          endMs: 120000,
        ),
      ],
      undoChapters: const [
        MediaChapter(
          id: 'auto-9',
          title: 'Old guess',
          startMs: 0,
          endMs: 60000,
          origin: ChapterOrigin.auto,
        ),
        MediaChapter(
          id: 'youtube-1-60000',
          title: 'Song',
          startMs: 60000,
          endMs: 120000,
          origin: ChapterOrigin.original,
        ),
      ],
      undoFollowsDownloaded: true,
      checkedAt: DateTime.utc(2026, 11, 7),
      durationMs: 120000,
      shuffleChapters: true,
      recognitionEpoch: 3,
      lastRecognitionRunId: 'run-42',
    );

    final back = ChapterData.fromJson(jsonDecode(data.encode()));

    String describe(List<MediaChapter>? list) => jsonEncode([
      for (final c in list ?? const <MediaChapter>[])
        [
          c.id,
          c.title,
          c.startMs,
          c.endMs,
          c.origin.name,
          c.manuallyEdited,
          c.alternativeTitles,
          c.reviewReasons,
        ],
    ]);
    expect(describe(back.downloaded), describe(data.downloaded));
    expect(describe(back.custom), describe(data.custom));
    expect(describe(back.undoChapters), describe(data.undoChapters));
    expect(back.undoFollowsDownloaded, isTrue);
    expect(back.recognitionEpoch, 3);
    expect(back.lastRecognitionRunId, 'run-42');
    expect(back.shuffleChapters, isTrue);
    expect(back.durationMs, 120000);
    expect(back.checkedAt, DateTime.utc(2026, 11, 7));

    // Encoding what was read back gives the same text again.
    expect(back.encode(), data.encode());
  });

  test('an undo step back to an own list stores no follow flag', () {
    const step = MediaChapter(
      id: 'user-1',
      title: 'Mine',
      startMs: 0,
      endMs: 1000,
    );
    const own = ChapterData(downloaded: youtube, undoChapters: [step]);
    expect(own.toJson().containsKey('undoFollowsDownloaded'), isFalse);
    expect(ChapterData.decode(own.encode()).undoFollowsDownloaded, isFalse);

    // The flag only means something together with an undo step.
    final orphan = ChapterData.fromJson({
      ...const ChapterData(downloaded: youtube).toJson(),
      'undoFollowsDownloaded': true,
    });
    expect(orphan.undoFollowsDownloaded, isFalse);
    expect(orphan.toJson().containsKey('undoFollowsDownloaded'), isFalse);

    const following = ChapterData(
      downloaded: youtube,
      undoChapters: [],
      undoFollowsDownloaded: true,
    );
    final json = following.toJson();
    expect(json['undoChapters'], isEmpty);
    expect(json['undoFollowsDownloaded'], isTrue);
    expect(
      ChapterData.decode(following.encode()).undoFollowsDownloaded,
      isTrue,
    );
  });

  test('a user chapter that reuses no YouTube id needs no origin key', () {
    final json =
        const ChapterData(
          downloaded: youtube,
          custom: [
            MediaChapter(id: 'user-1', title: 'Mine', startMs: 0, endMs: 1000),
          ],
        ).toJson();
    expect((json['custom'] as List).single, {
      'id': 'user-1',
      'title': 'Mine',
      'startMs': 0,
      'endMs': 1000,
    });
  });

  group('Always skip marks', () {
    test('are stored by id, sorted, and left out when there are none', () {
      const none = ChapterData(downloaded: youtube);
      expect(none.toJson().containsKey('skippedChapterIds'), isFalse);

      final marked = none
          .withChapterSkip('youtube-1-60000', true)
          .withChapterSkip('youtube-0-0', true);
      // Followed YouTube chapters are marked without a custom copy.
      expect(marked.custom, isNull);
      expect(marked.toJson()['skippedChapterIds'], [
        'youtube-0-0',
        'youtube-1-60000',
      ]);

      final back = ChapterData.decode(marked.encode());
      expect(back.skippedChapterIds, {'youtube-0-0', 'youtube-1-60000'});
      expect(back.isSkipped('youtube-0-0'), isTrue);
      expect(back.encode(), marked.encode());

      final cleared = back
          .withChapterSkip('youtube-0-0', false)
          .withChapterSkip('youtube-1-60000', false);
      expect(cleared.toJson().containsKey('skippedChapterIds'), isFalse);
    });

    test('setting a mark that is already set changes nothing', () {
      final marked = const ChapterData(
        downloaded: youtube,
      ).withChapterSkip('youtube-0-0', true);
      expect(
        identical(marked.withChapterSkip('youtube-0-0', true), marked),
        isTrue,
      );
    });

    test('unskipped leaves out the marked chapters', () {
      final marked = const ChapterData(
        downloaded: youtube,
      ).withChapterSkip('youtube-0-0', true);
      expect(marked.unskipped.map((c) => c.id), ['youtube-1-60000']);
      expect(marked.active, hasLength(2));
    });

    test('carried by copyWith, dropped when the file is replaced', () {
      final marked = const ChapterData(
        downloaded: youtube,
      ).withChapterSkip('youtube-0-0', true);
      expect(marked.copyWith(shuffleChapters: true).skippedChapterIds, {
        'youtube-0-0',
      });
      expect(marked.invalidate().skippedChapterIds, isEmpty);
    });

    test('a malformed list is ignored', () {
      final data = ChapterData.fromJson({
        ...const ChapterData(downloaded: youtube).toJson(),
        'skippedChapterIds': 'youtube-0-0',
      });
      expect(data.skippedChapterIds, isEmpty);
      final mixed = ChapterData.fromJson({
        ...const ChapterData(downloaded: youtube).toJson(),
        'skippedChapterIds': ['youtube-0-0', 3, null],
      });
      expect(mixed.skippedChapterIds, {'youtube-0-0'});
    });
  });

  group('chapter labels', () {
    const rock = '0f0e2c1a-6c1b-4d7e-9a43-2b1c5d6e7f80';
    const live = '7a1c9e2b-3d4f-4a5b-8c6d-e7f8091a2b3c';

    test('round-trip by chapter id and are left out when there are none', () {
      final data = const ChapterData(
        downloaded: youtube,
      ).withChapterLabels('youtube-1-60000', [rock, live, rock]);
      expect(data.labelsOf('youtube-1-60000'), [rock, live]);
      final json = data.toJson();
      expect(json['chapterLabels'], {
        'youtube-1-60000': [rock, live],
      });
      final back = ChapterData.fromJson(jsonDecode(jsonEncode(json)));
      expect(back.labelsOf('youtube-1-60000'), [rock, live]);
      expect(back.labelsOf('youtube-0-0'), isEmpty);

      final cleared = back.withChapterLabels('youtube-1-60000', const []);
      expect(cleared.chapterLabels, isEmpty);
      expect(cleared.toJson().containsKey('chapterLabels'), isFalse);
      // Unchanged labels give the same object back (nothing to write).
      expect(
        identical(
          back.withChapterLabels('youtube-1-60000', [rock, live]),
          back,
        ),
        isTrue,
      );
    });

    test('chapter data from before labels reads as unlabelled', () {
      final data = ChapterData.fromJson({
        'downloaded': [
          {'id': 'youtube-0-0', 'title': 'Intro', 'startMs': 0, 'endMs': 1000},
        ],
        'custom': null,
        'valid': true,
      });
      expect(data.chapterLabels, isEmpty);
      expect(data.toJson().containsKey('chapterLabels'), isFalse);
    });

    test('labels of chapters in no list are dropped when written; the undo '
        'step and the downloaded list keep theirs', () {
      final data = ChapterData(
        downloaded: youtube,
        custom: const [
          MediaChapter(id: 'mine', title: 'Mine', startMs: 0, endMs: 1000),
        ],
        undoChapters: const [
          MediaChapter(id: 'old', title: 'Old', startMs: 0, endMs: 1000),
        ],
        chapterLabels: const {
          'mine': [rock],
          'old': [live],
          'youtube-0-0': [rock],
          'gone': [rock],
        },
      );
      expect(data.toJson()['chapterLabels'], {
        'mine': [rock],
        'old': [live],
        'youtube-0-0': [rock],
      });
    });

    test('a replaced file keeps them; malformed entries are skipped', () {
      final data = ChapterData.fromJson({
        'downloaded': [
          {'id': 'youtube-0-0', 'title': 'Intro', 'startMs': 0, 'endMs': 1000},
        ],
        'chapterLabels': {
          'youtube-0-0': [rock, 5, '', rock],
          'bad': 'not a list',
        },
      });
      expect(data.chapterLabels, {
        'youtube-0-0': [rock],
      });
      final invalid = data.invalidate();
      expect(invalid.active, isEmpty);
      expect(invalid.labelsOf('youtube-0-0'), [rock]);
      expect(ChapterData.decode(invalid.encode()).labelsOf('youtube-0-0'), [
        rock,
      ]);
    });
  });
}
