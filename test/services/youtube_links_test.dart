import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/youtube_links.dart';

Track _track({String videoId = 'dQw4w9WgXcQ', bool local = false}) => Track(
  id: 1,
  playlistId: 1,
  videoId: videoId,
  title: 'Long mix',
  index: 1,
  status: 'complete',
  isLocalReplacement: local,
  alwaysSkip: false,
  replaceRequested: false,
);

void main() {
  group('youTubeTimestampUrl', () {
    test('a start at 0 links to t=0', () {
      expect(
        youTubeTimestampUrl('dQw4w9WgXcQ', startMs: 0),
        'https://youtu.be/dQw4w9WgXcQ?t=0',
      );
    });

    test('fractional seconds round down', () {
      expect(
        youTubeTimestampUrl('dQw4w9WgXcQ', startMs: 61999),
        'https://youtu.be/dQw4w9WgXcQ?t=61',
      );
      expect(
        youTubeTimestampUrl('dQw4w9WgXcQ', startMs: 999),
        'https://youtu.be/dQw4w9WgXcQ?t=0',
      );
      expect(
        youTubeTimestampUrl('dQw4w9WgXcQ', startMs: 1000),
        'https://youtu.be/dQw4w9WgXcQ?t=1',
      );
    });

    test('hours-long offsets stay in plain seconds', () {
      // 3:25:07.5
      expect(
        youTubeTimestampUrl('dQw4w9WgXcQ', startMs: 12307500),
        'https://youtu.be/dQw4w9WgXcQ?t=12307',
      );
      // 11:00:00
      expect(
        youTubeTimestampUrl('dQw4w9WgXcQ', startMs: 39600000),
        'https://youtu.be/dQw4w9WgXcQ?t=39600',
      );
    });

    test('ids with - and _ are kept as they are', () {
      expect(
        youTubeTimestampUrl('-_aB3-x_Z9q', startMs: 42000),
        'https://youtu.be/-_aB3-x_Z9q?t=42',
      );
      expect(youTubeTimestampUrl('_-', startMs: 0), 'https://youtu.be/_-?t=0');
    });

    test('a negative start clamps to 0', () {
      expect(
        youTubeTimestampUrl('dQw4w9WgXcQ', startMs: -500),
        'https://youtu.be/dQw4w9WgXcQ?t=0',
      );
    });
  });

  test('youTubeChapterUrl links to the chapter start', () {
    const chapter = MediaChapter(
      id: 'b',
      title: 'Song',
      startMs: 3725400,
      endMs: 3900000,
    );
    expect(
      youTubeChapterUrl(_track(videoId: 'a-b_c'), chapter),
      'https://youtu.be/a-b_c?t=3725',
    );
  });

  group('hasYouTubeTimeline', () {
    test('a downloaded YouTube video has one', () {
      expect(hasYouTubeTimeline(_track()), isTrue);
    });

    test('an inserted local file has a made-up id', () {
      expect(
        hasYouTubeTimeline(_track(videoId: 'force-insert:1700000000')),
        isFalse,
      );
    });

    test('a file put in place of the original has its own timeline', () {
      expect(hasYouTubeTimeline(_track(local: true)), isFalse);
    });

    test('an empty id has nothing to link to', () {
      expect(hasYouTubeTimeline(_track(videoId: '')), isFalse);
    });
  });
}
