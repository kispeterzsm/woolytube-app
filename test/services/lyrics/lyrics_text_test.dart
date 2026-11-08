import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_text.dart';

void main() {
  group('foldForSearch', () {
    test('folds Hungarian and other Latin accents', () {
      expect(
        foldForSearch('Szétszórom könnyű szívvel mindenem'),
        'szetszorom konnyu szivvel mindenem',
      );
      expect(foldForSearch('ŐRÜLT ŰRHAJÓ'), 'orult urhajo');
      expect(foldForSearch('Sarà perché ti amo'), 'sara perche ti amo');
      expect(foldForSearch('Ça déjà vu, naïve Øre'), 'ca deja vu naive ore');
      expect(foldForSearch('Straße Łódź Česko'), 'strasse lodz cesko');
      expect(foldForSearch('Æon œuvre'), 'aeon oeuvre');
    });

    test('folds Vietnamese and Greek precomposed letters', () {
      expect(foldForSearch('Em ơi Hà Nội phố'), 'em oi ha noi pho');
      expect(foldForSearch('Người ấy đã đi'), 'nguoi ay da di');
      expect(
        foldForSearch("Σ'αγαπώ πολύ καρδιά μου"),
        'σαγαπω πολυ καρδια μου',
      );
      expect(foldForSearch('ΰ ΐ ἄ ǽ ǿ'), 'υ ι α ae o');
      // Spacing accents are no letters: they separate words.
      expect(foldForSearch('λόγος΅ x'), 'λογοσ x');
      expect(foldForSearch('a῍b x῝y'), 'a b x y');
      expect(foldForSearch('΅'), '');
    });

    test('folds decomposed accents', () {
      expect(foldForSearch('Télápó'), 'telapo');
    });

    test('drops apostrophes and turns punctuation into one space', () {
      expect(
        foldForSearch("There's an endless road… to rediscover!"),
        'theres an endless road to rediscover',
      );
      expect(foldForSearch('Don’t   worry,be-happy'), 'dont worry be happy');
      expect(foldForSearch('  ..Hi.. '), 'hi');
      expect(foldForSearch('rock & roll 2'), 'rock roll 2');
    });

    test('keeps non-Latin letters', () {
      expect(foldForSearch('木の下の 草'), '木の下の 草');
      expect(foldForSearch('Привет, мир'), 'привет мир');
    });
  });

  test('tokenizeFolded splits on spaces', () {
    expect(tokenizeFolded('a bc  d'), ['a', 'bc', 'd']);
    expect(tokenizeFolded(''), isEmpty);
  });

  test('tokenizeWithOffsets matches the folded words', () {
    const text = "Oh, there's ŐRÜLT—love!";
    final tokens = tokenizeWithOffsets(text);
    expect(tokens.map((t) => t.folded), tokenizeFolded(foldForSearch(text)));
    expect(text.substring(tokens[1].start, tokens[1].end), "there's");
    expect(text.substring(tokens[2].start, tokens[2].end), 'ŐRÜLT');
    expect(text.substring(tokens[3].start, tokens[3].end), 'love');
  });

  test('buildSearchWindow joins a line with the next one', () {
    final lines = ['Hey brother', "There's an endless road", 'Hey sister'];
    expect(buildSearchWindow(lines, 0), 'hey brother theres an endless road');
    expect(buildSearchWindow(lines, 2), 'hey sister');
    expect(buildSearchWindows(lines), [
      for (var i = 0; i < lines.length; i++) buildSearchWindow(lines, i),
    ]);
  });

  group('parseLrc', () {
    test('reads times, repeated stamps and skips metadata', () {
      final lines = parseLrc('''
[ar:Avicii]
[ti:Hey Brother]
[length: 4:15]
[00:04.05] Hey brother
[00:07.37]There's an endless road
[00:12.71][01:02.5] Hey sister
[00:20.00]
plain line without time
[01:10] Last
''');
      expect(lines, const [
        LyricsLineDraft('Hey brother', startMs: 4050),
        LyricsLineDraft("There's an endless road", startMs: 7370),
        LyricsLineDraft('Hey sister', startMs: 12710),
        LyricsLineDraft('Hey sister', startMs: 62500),
        LyricsLineDraft('Last', startMs: 70000),
      ]);
    });

    test('applies the offset tag and strips word stamps', () {
      final lines = parseLrc('''
[offset:+500]
[00:00.20]Early
[00:10.123]<00:10.12>Word <00:10.50>by <00:11.00>word
''');
      expect(lines, const [
        LyricsLineDraft('Early', startMs: 0),
        LyricsLineDraft('Word by word', startMs: 9623),
      ]);
      expect(parseLrc('[offset:-250]\n[00:01.00]x').single.startMs, 1250);
    });
  });

  test('parsePlainLyrics drops blanks and section labels', () {
    expect(parsePlainLyrics('[Verse 1]\nHello  there\n\n  (ooh) yeah \n'), [
      const LyricsLineDraft('Hello there'),
      const LyricsLineDraft('(ooh) yeah'),
    ]);
  });

  group('parseJson3Captions', () {
    test('reads manual music captions without notes and noise', () {
      final lines = parseJson3Captions(
        File('test/fixtures/lyrics/manual_music.en.json3').readAsStringSync(),
      );
      expect(lines.first, const LyricsLineDraft('Hey brother', startMs: 4278));
      expect(
        lines[1],
        const LyricsLineDraft(
          "There's an endless road to rediscover",
          startMs: 7587,
        ),
      );
      expect(lines[3].text, "Know that water's sweet, but blood is thicker");
      expect(lines.any((line) => line.text.contains('music')), isFalse);
      expect(lines.any((line) => line.text.contains('♪')), isFalse);
    });

    test('joins speech-to-text segments and drops bracket lines', () {
      final lines = parseJson3Captions(
        File('test/fixtures/lyrics/asr_music.cs-orig.json3').readAsStringSync(),
      );
      expect(lines, isNotEmpty);
      expect(lines.any((line) => line.text.contains('[Hudba]')), isFalse);
      expect(lines.every((line) => line.text.trim() == line.text), isTrue);
      expect(lines.first, const LyricsLineDraft('TR', startMs: 24560));
      expect(lines[1].text, startsWith('for Life my'));
    });

    test('never merges lines; skips only overlapping exact repeats', () {
      const json = '''
{"events": [
  {"tStartMs": 0, "dDurationMs": 9000, "id": 1},
  {"tStartMs": 1000, "dDurationMs": 1500, "segs": [{"utf8": "hello"}, {"utf8": " there", "tOffsetMs": 300}]},
  {"tStartMs": 1500, "aAppend": 1, "segs": [{"utf8": "\\n"}]},
  {"tStartMs": 2000, "dDurationMs": 1000, "segs": [{"utf8": "hello there"}]},
  {"tStartMs": 3000, "dDurationMs": 500, "segs": [{"utf8": "hello there my friend"}]},
  {"tStartMs": 3500, "dDurationMs": 500, "segs": [{"utf8": "my friend"}]},
  {"tStartMs": 4000, "segs": [{"utf8": "[Applause]"}]},
  {"tStartMs": 5000, "segs": [{"utf8": "♪ ♪"}]},
  {"tStartMs": 6000, "dDurationMs": 1000, "segs": [{"utf8": "next\\nline"}]},
  {"tStartMs": 9000, "dDurationMs": 1000, "segs": [{"utf8": "next line"}]},
  {"tStartMs": 59000, "dDurationMs": 1000, "segs": [{"utf8": "Yeah"}]},
  {"tStartMs": 60000, "dDurationMs": 1000, "segs": [{"utf8": "Yeah, I'm on fire"}]}
]}''';
      expect(parseJson3Captions(json), const [
        LyricsLineDraft('hello there', startMs: 1000),
        LyricsLineDraft('hello there my friend', startMs: 3000),
        LyricsLineDraft('my friend', startMs: 3500),
        LyricsLineDraft('next line', startMs: 6000),
        LyricsLineDraft('next line', startMs: 9000),
        LyricsLineDraft('Yeah', startMs: 59000),
        LyricsLineDraft("Yeah, I'm on fire", startMs: 60000),
      ]);
    });

    test('keeps lyric lines in parentheses, drops sound cues', () {
      const json = '''
{"events": [
  {"tStartMs": 1000, "segs": [{"utf8": "(gentle music)"}]},
  {"tStartMs": 2000, "segs": [{"utf8": "(Don't you forget about me)"}]},
  {"tStartMs": 3000, "segs": [{"utf8": "(audience laughs)"}]},
  {"tStartMs": 4000, "segs": [{"utf8": "♪ (Ooh, baby) ♪"}]},
  {"tStartMs": 5000, "segs": [{"utf8": "(Applause)"}]}
]}''';
      expect(parseJson3Captions(json), const [
        LyricsLineDraft("(Don't you forget about me)", startMs: 2000),
        LyricsLineDraft('(Ooh, baby)', startMs: 4000),
      ]);
    });

    test('returns nothing for unexpected json', () {
      expect(parseJson3Captions('[]'), isEmpty);
      expect(parseJson3Captions('{}'), isEmpty);
    });
  });

  test('stop words cover English and Hungarian', () {
    for (final word in ['the', 'im', 'a', 'az', 'es', 'hogy', 'nem']) {
      expect(isLyricsStopWord(word), isTrue, reason: word);
    }
    expect(isLyricsStopWord('brother'), isFalse);
    expect(isLyricsStopWord('szivvel'), isFalse);
  });

  test('LyricsMode maps to and from the database', () {
    expect(LyricsMode.fromDb('lyrics'), LyricsMode.lyrics);
    expect(LyricsMode.fromDb('transcript'), LyricsMode.transcript);
    expect(LyricsMode.fromDb(null), isNull);
    expect(LyricsMode.fromDb('bogus'), isNull);
    expect(LyricsMode.toDb(null), isNull);
    expect(LyricsMode.toDb(LyricsMode.transcript), 'transcript');
    expect(lyricsModeIsOn('lyrics'), isTrue);
    expect(lyricsModeIsOn(null), isFalse);
  });
}
