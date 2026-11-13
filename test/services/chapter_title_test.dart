import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/chapter_draft.dart';
import 'package:woolytube/services/chapters.dart';

void main() {
  group('isPlaceholderChapterTitle', () {
    test('matches the title recognition gives an unknown section', () {
      expect(isPlaceholderChapterTitle(unrecognizedChapterTitle), isTrue);
      expect(isPlaceholderChapterTitle('Unrecognized section'), isTrue);
      expect(isPlaceholderChapterTitle('  unrecognized SECTION '), isTrue);
    });

    test('matches default "Chapter N" names in any case', () {
      expect(isPlaceholderChapterTitle('Chapter 1'), isTrue);
      expect(isPlaceholderChapterTitle('Chapter 12'), isTrue);
      expect(isPlaceholderChapterTitle('chapter 3'), isTrue);
      expect(isPlaceholderChapterTitle('CHAPTER 4'), isTrue);
      expect(isPlaceholderChapterTitle(' Chapter 5\n'), isTrue);
      expect(isPlaceholderChapterTitle('Chapter  6'), isTrue);
      expect(isPlaceholderChapterTitle('Chapter7'), isTrue);
    });

    test('leaves real names alone', () {
      expect(isPlaceholderChapterTitle('Intro'), isFalse);
      expect(isPlaceholderChapterTitle(''), isFalse);
      expect(isPlaceholderChapterTitle('Chapter'), isFalse);
      expect(isPlaceholderChapterTitle('Chapter One'), isFalse);
      expect(isPlaceholderChapterTitle('Chapter 1: The beginning'), isFalse);
      expect(isPlaceholderChapterTitle('Chapter 3 (live)'), isFalse);
      expect(isPlaceholderChapterTitle('Chapter 1.5'), isFalse);
      expect(isPlaceholderChapterTitle('Chapter -1'), isFalse);
      expect(isPlaceholderChapterTitle('The Chapter 2'), isFalse);
      expect(isPlaceholderChapterTitle('Unrecognized section 2'), isFalse);
      expect(
        isPlaceholderChapterTitle('Artist — Unrecognized section'),
        isFalse,
      );
    });

    test('matches the names the app makes up', () {
      final youTube = ChapterData.fromVideoInfo({
        'duration': 120,
        'chapters': [
          {'start_time': 0, 'end_time': 60, 'title': ''},
          {'start_time': 60, 'end_time': 120, 'title': 'Song'},
        ],
      });
      expect(
        youTube.downloaded
            .map((c) => isPlaceholderChapterTitle(c.title))
            .toList(),
        [true, false],
      );
      final split = ChapterDraft(const [], durationMs: 10000).splitAt(2000);
      expect(isPlaceholderChapterTitle(split.chapters.single.title), isTrue);
    });
  });

  group('chapterClock', () {
    test('m:ss under an hour, h:mm:ss from an hour on: minutes never '
        'pass 59', () {
      expect(chapterClock(0), '0:00');
      expect(chapterClock(84000), '1:24');
      expect(chapterClock(3599999), '59:59');
      expect(chapterClock(3600000), '1:00:00');
      // Seen on the phone as "157:24" next to "2:21:13.958".
      expect(chapterClock(9444000), '2:37:24');
    });

    test('every time of a file of an hour or more has hours, so they '
        'read alike', () {
      expect(chapterClock(84000, fileMs: 9444000), '0:01:24');
      expect(chapterClock(84000, fileMs: 3600000), '0:01:24');
      expect(chapterClock(84000, fileMs: 3599999), '1:24');
      expect(chapterClock(84000, fileMs: null), '1:24');
    });

    test('decimals are cut, not rounded', () {
      expect(chapterClock(84999, decimals: 3), '1:24.999');
      expect(chapterClock(84999, decimals: 1), '1:24.9');
      expect(chapterClock(84050, decimals: 3), '1:24.050');
      expect(chapterClock(8473958, decimals: 3), '2:21:13.958');
      expect(chapterClock(-1250, decimals: 3), '−0:01.250');
    });
  });

  group('chapterTimestamp', () {
    test('shows milliseconds only when the time has them', () {
      expect(chapterTimestamp(84000), '1:24');
      expect(chapterTimestamp(84250), '1:24.250');
      expect(chapterTimestamp(9444000), '2:37:24');
      expect(chapterTimestamp(84250, fileMs: 9444000), '0:01:24.250');
    });

    test('reads back exactly', () {
      for (final ms in [0, 84250, 3599999, 3600000, 8473958]) {
        for (final fileMs in [null, 9444000]) {
          final text = chapterTimestamp(ms, fileMs: fileMs);
          expect(parseChapterTimestamp(text), ms, reason: text);
        }
      }
    });
  });
}
