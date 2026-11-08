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
}
