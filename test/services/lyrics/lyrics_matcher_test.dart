import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/lyrics/lrclib_client.dart';
import 'package:woolytube/services/lyrics/lyrics_matcher.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/title_parser.dart';

import '../../helpers/lyrics_fakes.dart';

void main() {
  late FakeLrclib lrclib;

  setUp(() => lrclib = FakeLrclib());

  test('an exact get is accepted first', () async {
    lrclib.exact['Europe|The Final Countdown'] = lrclibRecord();
    final match = await lrclib.matcher().match(
      parseSongTitle('Europe - The Final Countdown (Official Video)'),
      durationSeconds: 297,
    );
    expect(match.found, isTrue);
    expect(match.step, 'get');
    expect(match.synced, isTrue);
    expect(match.timeScale, 1.0);
    expect(
      match.lines.first,
      const LyricsLineDraft("We're leaving together", startMs: 87770),
    );
    expect(lrclib.paths, ['get']);
  });

  test('a swapped title is looked up the other way round', () async {
    lrclib.searches['track_name=New Divide&artist_name=Linkin Park'] = [
      lrclibRecord(
        id: 9,
        track: 'New Divide',
        artist: 'Linkin Park',
        duration: 268,
      ),
    ];
    final match = await lrclib.matcher().match(
      parseSongTitle('New Divide (Official Music Video) - Linkin Park'),
      durationSeconds: 268,
    );
    expect(match.found, isTrue);
    expect(match.step, 'swapped');
    expect(match.record!.id, 9);
  });

  test('a known artist must match: a same-titled song is refused', () async {
    lrclib.searches['track_name=Unaware'] = [
      lrclibRecord(
        id: 3,
        track: 'Unaware',
        artist: 'Billie Marten',
        duration: 200,
      ),
    ];
    final match = await lrclib.matcher().match(
      parseSongTitle('EVRLST - Unaware (feat. PegasYs) [Future Bass]'),
      durationSeconds: 200,
    );
    expect(match.found, isFalse);
    expect(match.status, LyricsStatus.none);
  });

  test('nightcore of the original gets a time scale', () async {
    lrclib.searches['track_name=Heaven&artist_name=DJ Sammy'] = [
      lrclibRecord(
        id: 4,
        track: 'Heaven',
        artist: 'DJ Sammy',
        duration: 236,
        synced: '[00:10.00] Baby you\'re all that I want\n[00:20.00] Next',
      ),
    ];
    final match = await lrclib.matcher().match(
      parseSongTitle('Nightcore - Heaven [DJ Sammy]'),
      durationSeconds: 181,
    );
    expect(match.found, isTrue);
    expect(match.synced, isTrue);
    expect(match.timeScale, closeTo(181 / 236, 1e-9));
    expect(match.lines.first.startMs, (10000 * 181 / 236).round());
    // Nightcore never uses the exact get: the duration would not fit.
    expect(lrclib.paths, isNot(contains('get')));
  });

  test('nightcore without an artist needs the duration window', () async {
    lrclib.searches['q=Rockefeller Street'] = [
      lrclibRecord(
        id: 5,
        track: 'Rockefeller Street',
        artist: 'Someone',
        duration: 400,
      ),
      lrclibRecord(
        id: 6,
        track: 'Rockefeller Street',
        artist: 'Getter Jaani',
        duration: 180,
      ),
    ];
    final match = await lrclib.matcher().match(
      parseSongTitle('Nightcore - Rockefeller Street'),
      durationSeconds: 148,
    );
    expect(match.record!.id, 6);
    expect(match.timeScale, closeTo(148 / 180, 1e-9));
  });

  test('nightcore without an artist refuses a same-length record', () async {
    lrclib.searches['q=Come Clean'] = [
      lrclibRecord(
        id: 8,
        track: 'Come Clean',
        artist: 'Conrad Sewell',
        duration: 184,
      ),
    ];
    final match = await lrclib.matcher().match(
      parseSongTitle('Nightcore - Come Clean'),
      durationSeconds: 184,
    );
    expect(match.found, isFalse);
  });

  test(
    'timing that does not fit keeps the lines but drops the times',
    () async {
      lrclib.searches['track_name=Crush&artist_name=Pendulum'] = [
        lrclibRecord(id: 7, track: 'Crush', artist: 'Pendulum', duration: 255),
      ];
      final match = await lrclib.matcher().match(
        parseSongTitle('Pendulum - Crush (Extended Mix)'),
        durationSeconds: 431,
      );
      expect(match.found, isTrue);
      expect(match.synced, isFalse);
      expect(match.lines.every((l) => l.startMs == null), isTrue);
    },
  );

  test(
    'synced with fitting timing is preferred, then the closest length',
    () async {
      lrclib.searches['track_name=Slam&artist_name=Pendulum'] = [
        lrclibRecord(
          id: 1,
          track: 'Slam',
          artist: 'Pendulum',
          duration: 300,
          synced: null,
        ),
        lrclibRecord(id: 2, track: 'Slam', artist: 'Pendulum', duration: 400),
        lrclibRecord(id: 3, track: 'Slam', artist: 'Pendulum', duration: 343),
      ];
      final match = await lrclib.matcher().match(
        const SongQuery(artist: 'Pendulum', title: 'Slam', rawTitle: 'x'),
        durationSeconds: 342,
      );
      expect(match.record!.id, 3);
    },
  );

  test('instrumental is remembered when nothing has lyrics', () async {
    lrclib.searches['track_name=Allstars&artist_name=K-391'] = [
      lrclibRecord(
        id: 8,
        track: 'Allstars',
        artist: 'K-391',
        instrumental: true,
        plain: null,
        synced: null,
      ),
    ];
    final match = await lrclib.matcher().match(
      const SongQuery(artist: 'K-391', title: 'Allstars', rawTitle: 'x'),
      durationSeconds: 200,
    );
    expect(match.status, LyricsStatus.instrumental);
    expect(match.record!.id, 8);
  });

  test('records without any lyrics are never accepted', () async {
    lrclib.searches['track_name=Fallen Kingdom&artist_name=CaptainSparklez'] = [
      lrclibRecord(
        track: 'Fallen Kingdom',
        artist: 'CaptainSparklez',
        plain: null,
        synced: null,
      ),
    ];
    final match = await lrclib.matcher().match(
      const SongQuery(
        artist: 'CaptainSparklez',
        title: 'Fallen Kingdom',
        rawTitle: 'x',
      ),
    );
    expect(match.status, LyricsStatus.none);
  });

  test(
    'chapters skip get, ignore the duration and add the context word',
    () async {
      lrclib.searches['q=POKÉMON Born to Be a Winner'] = [
        lrclibRecord(
          id: 11,
          track: 'Born to Be a Winner',
          artist: 'Pokemon',
          duration: 200,
          synced: '[00:12.00] Born to be a winner\n[03:10.00] Last line',
        ),
      ];
      final match = await lrclib.matcher().match(
        parseChapterTitle(
          'Born to Be a Winner',
          parentTitle: 'POKÉMON - All 20 theme songs with lyrics',
        ),
        durationSeconds: 55,
        chapter: true,
      );
      expect(match.found, isTrue);
      expect(match.record!.id, 11);
      // A chapter's start lines up with the song's even when it is shorter
      // (a TV size): its lines are cut at the chapter's end later.
      expect(match.synced, isTrue);
      expect(lrclib.paths.first, 'q=POKÉMON Born to Be a Winner');
    },
  );

  test('a chapter ending before the first synced line gets plain lyrics', () {
    final record =
        LrclibRecord.fromJson(
          lrclibRecord(
            duration: 200,
            synced: '[01:27.77] Late\n[01:31.17] Later',
          ),
        )!;
    expect(
      syncedTimingFor(record, localSeconds: 55, chapter: true).fits,
      isFalse,
    );
    expect(
      syncedTimingFor(record, localSeconds: 120, chapter: true).fits,
      isTrue,
    );
  });

  test('a title-only lookup still needs the known artist', () async {
    lrclib.searches['track_name=Wonderful Wonder World'] = [
      lrclibRecord(
        id: 12,
        track: 'Wonderful Wonder World*',
        artist: 'Yun*chi',
        duration: 293,
      ),
    ];
    final match = await lrclib.matcher().match(
      const SongQuery(
        artist: 'yunchi',
        title: 'Wonderful Wonder World',
        nightcore: true,
        rawTitle: 'x',
      ),
      durationSeconds: 250,
    );
    expect(match.step, 'title');
    expect(match.record!.id, 12);

    final other = await lrclib.matcher().match(
      const SongQuery(
        artist: 'Somebody Else',
        title: 'Wonderful Wonder World',
        rawTitle: 'x',
      ),
      durationSeconds: 293,
    );
    expect(other.found, isFalse);
  });

  test('the same request is sent only once', () async {
    await lrclib.matcher().match(
      const SongQuery(
        artist: 'A',
        title: 'T',
        rawTitle: 'x',
        alternatives: [('A', 'T')],
      ),
    );
    expect(lrclib.paths.toSet().length, lrclib.paths.length);
  });
}
