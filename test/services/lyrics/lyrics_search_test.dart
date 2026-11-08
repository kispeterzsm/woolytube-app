import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_search.dart';
import 'package:woolytube/services/lyrics/lyrics_text.dart';

import '../../helpers/test_database.dart';

/// The 24 LRCLIB lyrics of the search prototype.
List<Map<String, dynamic>> loadSample() =>
    (jsonDecode(File('test/fixtures/lyrics_sample.json').readAsStringSync())
            as List)
        .cast<Map<String, dynamic>>();

List<LyricsLineDraft> sampleLines(Map<String, dynamic> song) {
  final synced = song['synced'] as String?;
  if (synced != null && synced.isNotEmpty) return parseLrc(synced);
  return parsePlainLyrics(song['plain'] as String);
}

void main() {
  group('helpers', () {
    test('wordSimilarity follows the rerank rules', () {
      expect(wordSimilarity('road', 'road'), 1.0);
      expect(wordSimilarity('redisc', 'rediscover'), 0.9);
      expect(wordSimilarity('wory', 'worry'), closeTo(0.8, 1e-9));
      expect(wordSimilarity('cat', 'dog'), 0);
      // Prefixes need three letters.
      expect(wordSimilarity('ro', 'road'), 0);
    });

    test('boundedLevenshtein stops past the cap', () {
      expect(boundedLevenshtein('kitten', 'sitting', 3), 3);
      expect(boundedLevenshtein('kitten', 'sitting', 2), 3);
      expect(boundedLevenshtein('abc', 'abcdef', 2), 3);
    });

    test('the match expression drops stop words and expands typos', () {
      final vocab = {'worry': 5, 'happy': 9, 'hippy': 1, 'the': 99, 'be': 40};
      expect(
        buildLyricsMatchExpression(['dont', 'wory', 'be', 'hapy'], vocab),
        // "dont" and "be" are stop words; "hippy" is two edits away.
        '"wory" OR "worry" OR "hapy"* OR "happy"',
      );
      // Only stop words: they are kept.
      expect(buildLyricsMatchExpression(['the', 'be'], vocab), '"the" OR "be"');
      // A known word is not expanded; a short last word is no prefix.
      expect(
        buildLyricsMatchExpression(['happy', 'mix'], vocab),
        '"happy" OR "mix"',
      );
      // Stop words are never typo targets.
      expect(buildLyricsMatchExpression(['tre'], vocab), '"tre"');
      // Only the first unknown words get typo alternatives.
      final many = [
        for (var i = 0; i < LyricsSearch.maxExpandedWords; i++) 'zzz$i',
        'hapy',
      ];
      expect(
        buildLyricsMatchExpression(many, vocab),
        isNot(contains('"happy"')),
      );
      expect(
        buildLyricsMatchExpression(['hapy', 'x'], vocab),
        contains('"happy"'),
      );
      expect(buildLyricsMatchExpression(const [], vocab), isNull);
    });
  });

  group('with the sample library', () {
    late AppDatabase db;
    late LyricsSearch search;
    final titleOfTrack = <int, String>{};

    setUpAll(() async {
      db = openTestDatabase();
      search = LyricsSearch(db);
      final playlist = await insertTestPlaylist(db, lyricsMode: 'lyrics');
      final songs = loadSample();
      for (var i = 0; i < songs.length; i++) {
        final track = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: i + 1,
          videoId: 'v$i',
          title: '${songs[i]['artist']} - ${songs[i]['title']}',
        );
        titleOfTrack[track.id] = songs[i]['title'] as String;
        final lines = sampleLines(songs[i]);
        await db.replaceLyricsDoc(
          LyricsDocDraft(
            trackId: track.id,
            kind: LyricsMode.lyrics,
            status: LyricsStatus.found,
            source: LyricsSource.lrclib,
            synced: lines.any((l) => l.startMs != null),
            checkedAt: DateTime(2026),
            lines: lines,
          ),
        );
      }
    });

    tearDownAll(() async {
      search.dispose();
      await db.close();
    });

    // Misremembered queries from the search research, with the title the
    // right song starts with.
    const queries = {
      'theres an endless road to rediscover': 'Hey Brother',
      'when the sun shines we shine together': 'Umbrella',
      'im sitting here in a boring room': 'Lemon Tree',
      'its my life its now or never': "It's My Life",
      'i wanna live while im alive': "It's My Life",
      'clap along if you feel happiness is the truth': 'Happy',
      'everybody was kungfu fightin': 'Kung Fu',
      'dont wory be hapy': "Don't Worry",
      'cut my life in to pieces': 'Last Resort',
      'ha te ot leszel velem': 'Ha te ott',
      'szetszorom konnyu szivvel': 'Ha te ott',
      'sara perche ti amo': 'Sarà',
      'standing on the top of the world': 'On Top',
      'trying to call home from a payphone': 'Payphone',
      'kick start my heart': 'Kickstart',
      'rediscover endless road brother': 'Hey Brother',
      'see your body in the moonlight': 'Deja Vu',
      'relax take it easy for there is nothing that we can do': 'Relax',
      'lemmon tre': 'Lemon Tree',
      'telapo nem is olyan joszivu': 'Télapó',
    };

    for (final entry in queries.entries) {
      test('"${entry.key}" ranks ${entry.value} first', () async {
        final hits = await search.search(entry.key);
        expect(hits, isNotEmpty);
        final top = hits.first;
        expect(titleOfTrack[top.trackId], startsWith(entry.value));
        expect(top.score, greaterThanOrEqualTo(LyricsSearch.minScore));
        expect(top.highlightRanges, isNotEmpty);
        // One hit per doc.
        expect(hits.map((h) => h.docId).toSet().length, hits.length);
      });
    }

    test('a half-wrong line never ranks a wrong song first', () async {
      // Only "days are" is in The Days ("forever" is not), and "are" is a
      // stop word, so it stays just under the cutoff.
      final hits = await search.search('days are forever');
      if (hits.isNotEmpty) {
        expect(titleOfTrack[hits.first.trackId], 'The Days');
      }
    });

    test('a lyric not in the index finds nothing above the cutoff', () async {
      expect(
        await search.search('i wish that i could be like the cool kids'),
        isEmpty,
      );
    });

    test(
      'the hit carries the line, its time and raw-text highlights',
      () async {
        final hit = (await search.search('theres an endless road')).first;
        expect(hit.lineText, "There's an endless road to rediscover");
        expect(hit.kind, LyricsMode.lyrics);
        expect(hit.chapterId, isNull);
        expect(hit.positionMs, isNotNull);
        final lines = await db.lyricsLinesForDoc(hit.docId);
        final line = lines.firstWhere((l) => l.id == hit.lineId);
        expect(hit.positionMs, line.startMs);
        expect(hit.lineNo, line.lineNo);
        final words = [
          for (final r in hit.highlightRanges)
            hit.lineText.substring(r.start, r.end),
        ];
        expect(words, ["There's", 'an', 'endless', 'road']);
      },
    );

    test('accents are highlighted on the raw text', () async {
      final hit = (await search.search('szetszorom konnyu szivvel')).first;
      final words = [
        for (final r in hit.highlightRanges)
          hit.lineText.substring(r.start, r.end),
      ];
      expect(
        words.map((w) => w.toLowerCase()),
        containsAll(['szétszórom', 'könnyű', 'szívvel']),
      );
    });

    test('a phrase across a line break is joined with " / "', () async {
      final hit = (await search.search('its my life its now or never')).first;
      expect(hit.lineText, contains(' / '));
      for (final r in hit.highlightRanges) {
        expect(hit.lineText.substring(r.start, r.end), isNot(contains('/')));
      }
    });

    test('a playlist with lyrics off is not searched', () async {
      final off = await insertTestPlaylist(db, url: 'off', name: 'Off');
      expect(await search.search('payphone', playlistId: off.id), isEmpty);
      final playlist = await db.getPlaylist(1);
      expect(
        await search.search('payphone', playlistId: playlist.id),
        isNotEmpty,
      );
    });

    test('the vocabulary reloads after lyrics change', () async {
      expect(await search.search('zanzibarian quokka'), isEmpty);
      final playlist = await db.getPlaylist(1);
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 99,
        videoId: 'new',
      );
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: track.id,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          checkedAt: DateTime(2026),
          lines: const [LyricsLineDraft('A zanzibarian quokka sings')],
        ),
      );
      await pumpEventQueue();
      // A typo only finds it through the refreshed vocabulary.
      final hits = await search.search('zanzibarien quoka');
      expect(hits.single.trackId, track.id);
      await db.deleteLyricsDocs(track.id);
    });
  });

  group('chapters and transcripts', () {
    late AppDatabase db;
    late LyricsSearch search;

    setUp(() => db = openTestDatabase());
    tearDown(() async {
      search.dispose();
      await db.close();
    });

    test('a chapter doc reports file time and its chapter', () async {
      search = LyricsSearch(db);
      final playlist = await insertTestPlaylist(db, lyricsMode: 'lyrics');
      final track = await insertTestTrack(db, playlistId: playlist.id);
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: track.id,
          chapterId: 'ch2',
          offsetMs: 600000,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          synced: true,
          checkedAt: DateTime(2026),
          lines: const [
            LyricsLineDraft('Hey brother', startMs: 1000),
            LyricsLineDraft(
              "There's an endless road to rediscover",
              startMs: 5000,
            ),
          ],
        ),
      );
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: track.id,
          chapterId: 'ch3',
          offsetMs: 900000,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          checkedAt: DateTime(2026),
          lines: const [LyricsLineDraft('Endless plain lyrics without times')],
        ),
      );

      final hits = await search.search('endless road rediscover');
      expect(hits.first.chapterId, 'ch2');
      expect(hits.first.positionMs, 605000);

      final plain = await search.search('plain lyrics without times');
      expect(plain.single.chapterId, 'ch3');
      expect(plain.single.positionMs, isNull);
    });

    test('transcript docs are found with their kind', () async {
      search = LyricsSearch(db);
      final playlist = await insertTestPlaylist(db, lyricsMode: 'transcript');
      final track = await insertTestTrack(db, playlistId: playlist.id);
      final lines = parseJson3Captions(
        File('test/fixtures/lyrics/asr_music.cs-orig.json3').readAsStringSync(),
      );
      expect(lines, isNotEmpty);
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: track.id,
          kind: LyricsMode.transcript,
          status: LyricsStatus.found,
          source: LyricsSource.ytAuto,
          synced: true,
          checkedAt: DateTime(2026),
          lines: [
            ...lines,
            const LyricsLineDraft(
              'and that is why the mitochondria is the powerhouse',
              startMs: 3723000,
            ),
          ],
        ),
      );

      final hits = await search.search('mitochondria powerhouse');
      expect(hits.single.kind, LyricsMode.transcript);
      expect(hits.single.positionMs, 3723000);
      expect(hits.single.chapterId, isNull);
    });

    Future<Track> songTrack(
      int playlistId,
      int index,
      List<String> lines, {
      LyricsMode kind = LyricsMode.lyrics,
    }) async {
      final track = await insertTestTrack(
        db,
        playlistId: playlistId,
        index: index,
        videoId: 's$index',
      );
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: track.id,
          kind: kind,
          status: LyricsStatus.found,
          checkedAt: DateTime(2026),
          lines: [for (final line in lines) LyricsLineDraft(line)],
        ),
      );
      return track;
    }

    test(
      'a long doc repeating the words leaves room for other songs',
      () async {
        search = LyricsSearch(db);
        final playlist = await insertTestPlaylist(db, lyricsMode: 'lyrics');
        await songTrack(playlist.id, 1, [
          for (var i = 0; i < 150; i++) 'the summer rain',
        ]);
        for (var i = 2; i <= 11; i++) {
          await songTrack(playlist.id, i, [
            'some other line',
            'walking in the summer rain with you',
          ]);
        }
        expect(await search.search('summer rain'), hasLength(11));
      },
    );

    test('Vietnamese and Greek lyrics are found without accents', () async {
      search = LyricsSearch(db);
      final playlist = await insertTestPlaylist(db, lyricsMode: 'lyrics');
      await songTrack(playlist.id, 1, ['Em ơi Hà Nội phố']);
      await songTrack(playlist.id, 2, ["Σ'αγαπώ πολύ καρδιά μου"]);
      expect(await search.search('em oi ha noi pho'), hasLength(1));
      expect(await search.search('αγαπω πολυ καρδια'), hasLength(1));
    });

    test('a last word of one or two letters does not hide results', () async {
      search = LyricsSearch(db);
      final playlist = await insertTestPlaylist(db, lyricsMode: 'lyrics');
      await songTrack(playlist.id, 1, ['walking in the summer rain']);
      for (final query in ['summer r', 'summer ra', 'summer rai']) {
        expect(await search.search(query), hasLength(1), reason: query);
      }
    });
  });
}
