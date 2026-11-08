import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/widgets/lyrics_picker_sheet.dart';

void main() {
  test('reads the video id from links to one YouTube video', () {
    const id = '6Cp6mKbRTQY';
    for (final link in [
      'https://www.youtube.com/watch?v=$id',
      'https://m.youtube.com/watch?v=$id&list=PL1&index=2',
      'https://youtu.be/$id?si=x',
      'https://youtube.com/shorts/$id',
      'https://www.youtube.com/live/$id',
      'https://www.youtube.com/embed/$id',
      '  https://music.youtube.com/watch?v=$id  ',
    ]) {
      expect(youTubeVideoIdFromLink(link), id, reason: link);
    }
  });

  test('rejects playlists, channels, other sites and junk', () {
    for (final link in [
      '',
      'hello',
      '6Cp6mKbRTQY',
      'https://www.youtube.com/playlist?list=PL123',
      'https://www.youtube.com/@channel',
      'https://www.youtube.com/watch',
      'https://vimeo.com/12345678',
      'ftp://youtu.be/6Cp6mKbRTQY',
    ]) {
      expect(youTubeVideoIdFromLink(link), isNull, reason: link);
    }
  });
}
