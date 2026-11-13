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
}
