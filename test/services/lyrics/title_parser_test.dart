import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/lyrics/title_parser.dart';

void main() {
  group('parseSongTitle', () {
    void expectParse(
      String title, {
      String? artist,
      required String song,
      bool swappable = false,
      bool nightcore = false,
    }) {
      final query = parseSongTitle(title);
      expect(query.artist, artist, reason: 'artist of "$title"');
      expect(query.title, song, reason: 'title of "$title"');
      expect(query.swappable, swappable, reason: 'swappable "$title"');
      expect(query.nightcore, nightcore, reason: 'nightcore "$title"');
    }

    test('splits "Artist - Title" and drops noise', () {
      expectParse(
        'Coldplay - Viva La Vida (Official Video)',
        artist: 'Coldplay',
        song: 'Viva La Vida',
        swappable: true,
      );
      expectParse(
        'Men At Work - Down Under (Official HD Video)',
        artist: 'Men At Work',
        song: 'Down Under',
        swappable: true,
      );
      expectParse(
        'Pet Shop Boys - Go West (Official Video) [HD REMASTERED]',
        artist: 'Pet Shop Boys',
        song: 'Go West',
        swappable: true,
      );
      expectParse(
        'Miley Cyrus - Midnight Sky (Lyrics)',
        artist: 'Miley Cyrus',
        song: 'Midnight Sky',
        swappable: true,
      );
    });

    test('drops featured artists', () {
      expectParse(
        'Two Steps From Hell - Impossible (feat. Merethe Soltvedt)',
        artist: 'Two Steps From Hell',
        song: 'Impossible',
        swappable: true,
      );
      expectParse(
        'Taio Cruz - Hangover (Official Video) ft. Flo Rida',
        artist: 'Taio Cruz',
        song: 'Hangover',
        swappable: true,
      );
      expectParse(
        'S3RL Feat. Sara - Will To Be (Lyrics)',
        artist: 'S3RL',
        song: 'Will To Be',
        swappable: true,
      );
    });

    test('keeps the pair swappable when the title comes first', () {
      expectParse(
        'In The End [Official HD Music Video] - Linkin Park',
        artist: 'In The End',
        song: 'Linkin Park',
        swappable: true,
      );
    });

    test('drops genre and channel parts', () {
      expectParse(
        'DEAF KEV - Invincible | Glitch Hop | NCS - Copyright Free Music',
        artist: 'DEAF KEV',
        song: 'Invincible',
        swappable: true,
      );
      expectParse(
        'Chaos | Trance - Soldier',
        artist: 'Chaos',
        song: 'Soldier',
        swappable: true,
      );
      expectParse(
        '[Glitch Hop] - OMFG - Hello',
        artist: 'OMFG',
        song: 'Hello',
        swappable: true,
      );
      expectParse(
        'Warriyo - Mortals (feat. Laura Brehm) | Future Trap | NCS - '
        'Copyright Free Music',
        artist: 'Warriyo',
        song: 'Mortals',
        swappable: true,
      );
    });

    test('detects nightcore and takes the bracket artist', () {
      expectParse(
        'Nightcore - This Mess [Shinzo]',
        artist: 'Shinzo',
        song: 'This Mess',
        nightcore: true,
      );
      expectParse(
        '[Nightcore] - Good Time {Owl City & Carly Rae Jepsen}',
        artist: 'Owl City & Carly Rae Jepsen',
        song: 'Good Time',
        nightcore: true,
      );
      expectParse(
        'Nightcore - Infinity - (Desmeon & Kalidrium / Lyrics)',
        artist: 'Desmeon & Kalidrium',
        song: 'Infinity',
        nightcore: true,
      );
      expectParse(
        'Nightcore - Rockefeller Street',
        song: 'Rockefeller Street',
        nightcore: true,
      );
      expectParse(
        'Nightcore → Savages (lyrics)',
        song: 'Savages',
        nightcore: true,
      );
      expectParse('Loreley {Nightcore}', song: 'Loreley', nightcore: true);
      expectParse('「Nightcore」→ Bone Dry', song: 'Bone Dry', nightcore: true);
      expectParse(
        'Nightcore - Into The Sky [NEW NIGHTCORE SONG!]',
        song: 'Into The Sky',
        nightcore: true,
      );
      expectParse(
        'Nightcore – NEFFEX - Careless (Lyrics)',
        artist: 'NEFFEX',
        song: 'Careless',
        swappable: true,
        nightcore: true,
      );
    });

    test('reads quoted and Japanese-quoted titles', () {
      expectParse(
        'Escape the Fate - "One For The Money"',
        artist: 'Escape the Fate',
        song: 'One For The Money',
      );
      expectParse(
        'Song About Minecraft Animation "Hacker" by MC Jams',
        artist: 'MC Jams',
        song: 'Hacker',
      );
      expectParse(
        'Tonikaku Kawaii Opening Song Full『Koi no Uta』by Yunomi',
        artist: 'Yunomi',
        song: 'Koi no Uta',
      );
    });

    test('reads "Title by Artist"', () {
      expectParse(
        '145 (Poodles) by Jake Chudnow [HD]',
        artist: 'Jake Chudnow',
        song: '145',
      );
      expectParse(
        'Again (FMAB op synthwave/80s cyberpunk remix) by Astrophysics',
        artist: 'Astrophysics',
        song: 'Again',
      );
    });

    test('keeps Hungarian titles and accents', () {
      expectParse(
        'Elefánt - Plüss',
        artist: 'Elefánt',
        song: 'Plüss',
        swappable: true,
      );
      expectParse(
        'Beatrice - Azok a boldog szép napok',
        artist: 'Beatrice',
        song: 'Azok a boldog szép napok',
        swappable: true,
      );
      expectParse(
        'Creedence Clearwater Revival: Have You Ever Seen The Rain?',
        artist: 'Creedence Clearwater Revival',
        song: 'Have You Ever Seen The Rain?',
        swappable: true,
      );
    });

    test('anime uploads name the show before the artist', () {
      final query = parseSongTitle(
        'One Punch Man Season 2 OP Full - JAM Project - Seijaku no Apostle',
      );
      expect(query.artist, 'JAM Project');
      expect(query.title, 'Seijaku no Apostle');

      final show = parseSongTitle(
        'Food Wars! Shokugeki no Soma OPENING 1 | Kibō no Uta (HD)',
      );
      expect(show.artist, isNull);
      expect(show.title, 'Kibō no Uta');
      expect(show.contextWord, 'Food Wars! Shokugeki');

      final ending = parseSongTitle(
        'Clannad Ending [Dango Daikazoku] Full Song with Lyrics',
      );
      expect(ending.title, 'Dango Daikazoku');
    });

    test('three parts offer the other readings', () {
      final query = parseSongTitle(
        'Folk/Adventure Music - Vindsvept - Through the Woods we Ran',
      );
      expect(
        query.alternatives,
        contains(('Vindsvept', 'Through the Woods we Ran')),
      );
    });

    test('an AMV naming its song in brackets', () {
      final query = parseSongTitle(
        'Taiho Shichau zo AMV (Cheri Cheri Lady - Modern Talking)',
      );
      expect(
        query.alternatives,
        contains(('Cheri Cheri Lady', 'Modern Talking')),
      );
    });

    test('metadata from the info file wins', () {
      final topic = parseSongTitle(
        'Oak & Ash & Thorn',
        meta: const VideoMeta(uploader: 'The Longest Johns - Topic'),
      );
      expect(topic.artist, 'The Longest Johns');
      expect(topic.artistSource, 'topic');

      final provided = parseSongTitle(
        'Carry on Wayward Son',
        meta: const VideoMeta(
          description:
              'Provided to YouTube by Epic\n\nCarry On Wayward Son · Kansas'
              '\n\nLeftoverture\n',
        ),
      );
      expect(provided.artist, 'Kansas');
      expect(provided.title, 'Carry On Wayward Son');

      final tagged = parseSongTitle(
        'some upload',
        meta: const VideoMeta(artist: 'Europe', track: 'The Final Countdown'),
      );
      expect(tagged.artist, 'Europe');
      expect(tagged.title, 'The Final Countdown');
      expect(tagged.swappable, isFalse);
    });

    test('a nightcore description names the original artist', () {
      final credit = parseSongTitle(
        'Nightcore - My Heart Beats Like A Drum',
        meta: const VideoMeta(
          description:
              'Nightcore By Me\n\nCredit goes to original artist of song ATC '
              'and picture creator \nMusic sample used from ATC',
        ),
      );
      expect(credit.artist, 'ATC');
      expect(credit.artistSource, 'description');

      final firstLine = parseSongTitle(
        'Nightcore - More Than You Know - (Lyrics)',
        meta: const VideoMeta(
          description:
              'Harddope, Halvorsen, LexMorris - More Than You Know\n\n'
              'Syrex Links: https://linktr.ee/SyrexYT',
        ),
      );
      expect(firstLine.artist, 'Harddope, Halvorsen, LexMorris');

      final labelled = parseSongTitle(
        'Nightcore - Log Horizon 2 - wonderful wonder world Yun*chi',
        meta: const VideoMeta(
          description:
              'Welcome to my channel\n\nsong : wonderful wonder world\n'
              'artist : yunchi\nanime : log horizon',
        ),
      );
      expect(labelled.alternatives.first, ('yunchi', 'wonderful wonder world'));
    });
  });

  group('descriptionArtist', () {
    test('reads the common credit lines', () {
      expect(
        descriptionArtist('Original Artist: Within Temptation')?.$1,
        'Within Temptation',
      );
      expect(descriptionArtist('♫Original Song: Nightwish - Nemo'), (
        'Nightwish',
        'Nemo',
      ));
      expect(descriptionArtist('Music: Alan Walker - Faded'), (
        'Alan Walker',
        'Faded',
      ));
      expect(descriptionArtist('Nightcore - Kasanova - I Remember\nmore'), (
        'Kasanova',
        'I Remember',
      ));
      expect(descriptionArtist('Artist ➼ Getter Jaani')?.$1, 'Getter Jaani');
      expect(descriptionArtist('Just a great song, enjoy!'), isNull);
    });
  });

  group('parseChapterTitle', () {
    test('splits Shazam chapter titles on the em dash', () {
      final query = parseChapterTitle('Daft Punk — Get Lucky (Radio Edit)');
      expect(query.artist, 'Daft Punk');
      expect(query.title, 'Get Lucky');
      expect(query.swappable, isFalse);
      expect(query.artistSource, 'chapter');
    });

    test('a title-only chapter gets a context word from the file', () {
      final query = parseChapterTitle(
        'Born to Be a Winner',
        parentTitle: 'POKÉMON - All 20 theme songs with lyrics',
      );
      expect(query.artist, isNull);
      expect(query.title, 'Born to Be a Winner');
      expect(query.contextWord, 'POKÉMON');
    });

    test('YouTube chapters may name the artist', () {
      final query = parseChapterTitle(
        'Avicii - Levels',
        parentTitle: 'Best of 2011 mix',
      );
      expect(query.artist, 'Avicii');
      expect(query.title, 'Levels');
    });
  });

  group('similarity', () {
    test('textSimilarity folds case, accents and brackets', () {
      expect(textSimilarity('Mielőtt elmegyek', 'Mielott Elmegyek'), 1);
      expect(textSimilarity('Crush (Extended Mix)', 'Crush'), 1);
      expect(textSimilarity('The Final Countdown', 'Final Countdown'), 1);
      expect(textSimilarity('Lonely', 'Never Be Lonely'), lessThan(0.75));
      expect(textSimilarity('Heaven', 'Hello'), lessThan(0.75));
    });

    test('artistSimilarity matches one of several artists', () {
      expect(artistSimilarity('Owl City & Carly Rae Jepsen', 'Owl City'), 1);
      expect(artistSimilarity('Yun*chi', 'yunchi'), 1);
      expect(
        artistSimilarity('T & Sugah x NCT', 't  sugah'),
        greaterThanOrEqualTo(0.9),
      );
      expect(artistSimilarity('Billie Marten', 'EVRLST'), lessThan(0.6));
    });
  });
}
