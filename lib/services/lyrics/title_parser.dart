/// Turns YouTube titles and chapter titles into an artist and song title to
/// look lyrics up by. Plain Dart (no Flutter), so tool/lyrics_eval.dart can
/// run it.
library;

import 'dart:math' as math;

import 'lyrics_text.dart';

/// What to look a song up by.
class SongQuery {
  /// The performer; null when the title names none.
  final String? artist;
  final String title;

  /// The title had exactly two parts ("A - T"), which uploaders write both
  /// ways round, so the swapped pair is worth a lookup too.
  final bool swappable;

  /// A nightcore / sped-up upload: faster and shorter than the original.
  final bool nightcore;
  final String rawTitle;

  /// For a chapter that names only a song: a word from the file's title
  /// (for example "Pokemon") added to a free-text search.
  final String? contextWord;

  /// Where [artist] came from: 'metadata', 'topic', 'title', 'bracket',
  /// 'description' or 'chapter'.
  final String? artistSource;

  /// Other (artist, title) readings worth one lookup each, best first.
  final List<(String, String)> alternatives;

  const SongQuery({
    this.artist,
    required this.title,
    this.swappable = false,
    this.nightcore = false,
    required this.rawTitle,
    this.contextWord,
    this.artistSource,
    this.alternatives = const [],
  });

  SongQuery copyWith({
    String? artist,
    String? title,
    bool? swappable,
    String? contextWord,
    String? artistSource,
  }) => SongQuery(
    artist: artist ?? this.artist,
    title: title ?? this.title,
    swappable: swappable ?? this.swappable,
    nightcore: nightcore,
    rawTitle: rawTitle,
    contextWord: contextWord ?? this.contextWord,
    artistSource: artistSource ?? this.artistSource,
    alternatives: alternatives,
  );

  /// "Artist Title", for the picker's search field.
  String get searchText => artist == null ? title : '$artist $title';

  @override
  String toString() =>
      'SongQuery(artist: $artist, title: $title'
      '${swappable ? ', swappable' : ''}${nightcore ? ', nightcore' : ''}'
      '${contextWord == null ? '' : ', context: $contextWord'}'
      '${alternatives.isEmpty ? '' : ', alt: $alternatives'})';
}

/// The parts of yt-dlp's info that help: `artist`, `track`, `uploader`,
/// `channel` and `description`.
class VideoMeta {
  final String? artist;
  final String? track;
  final String? uploader;
  final String? channel;
  final String? description;

  const VideoMeta({
    this.artist,
    this.track,
    this.uploader,
    this.channel,
    this.description,
  });

  factory VideoMeta.fromInfo(Map<String, dynamic> info) {
    String? text(String key) {
      final value = info[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    return VideoMeta(
      artist: text('artist') ?? text('creator'),
      track: text('track'),
      uploader: text('uploader'),
      channel: text('channel'),
      description: text('description'),
    );
  }

  bool get isEmpty =>
      artist == null &&
      track == null &&
      uploader == null &&
      channel == null &&
      description == null;
}

// R1: wide brackets and quotes to plain ones, decoration removed.
const _charMap = {
  '【': '[', '】': ']', '〔': '[', '〕': ']', '［': '[', '］': ']', //
  '（': '(', '）': ')', '“': '"', '”': '"', '„': '"', '«': '"', '»': '"', //
  '：': ':', '｜': '|', '〖': '[', '〗': ']', '＜': '(', '＞': ')', //
};
final _decor = RegExp(
  r'[♪♫♬★☆▹◃↬→←✦✧•●◆◇♥❤➼➤►◄▶◀✕\uFE0E\uFE0F]+|\p{So}+',
  unicode: true,
);
final _spaces = RegExp(r'\s+');

// R2
final _nightcore = RegExp(
  r'\b(night\s?core(\s+remix)?|nightstep|night\s?step|sped\s?up|speed\s?up)\b',
  caseSensitive: false,
);

// R3
final _noise = RegExp(
  r'\b(official|video|audio|lyrics?|lyric\s*video|letra|testo|paroles|'
  r'clip\s*officiel|hivatalos|sz[öo]veges|music\s*video|musikvideo|'
  r'offizielles|mv|amv|nmv|pv|hd|hq|4k|1080p|720p|\d+\s*kbps|'
  r'remaster(ed)?|upgrade|visuali[sz](er|ation)|full\s*(song|version)|full|explicit|'
  r'monstercat\s*release|release|ncs|copyright\s*free(\s*music)?|'
  r'with\s*lyrics|sub\s*\w+|english\s*lyrics|videoclip|perfect\s*sync|'
  r'high\s*res|free\s*download|out\s*now|premiere|\d{4})\b',
  caseSensitive: false,
);
final _version = RegExp(
  r'\b(remix|mix|version|cover|edit|bootleg|vip|rework|acoustic|live|'
  r'instrumental|eurobeat|synthwave|bardcore|switching\s*vocals|extended)\b',
  caseSensitive: false,
);
// A part made only of genre names ("Trance", "Glitch Hop", "Techno Trance").
final _genrePart = RegExp(
  r'^(?:(?:glitch\s*hop|trance|techno|house|deep\s*house|progressive|'
  r'dubstep|drum\s*(?:&|and|n)\s*bass|dnb|electro|electronic|edm|hardstyle|'
  r'hardcore|happy\s*hardcore|trap|future\s*(?:bass|trap|house|garage)|chill(?:step|out)?|'
  r'melodic|complextro|big\s*room|bass|pop|rock|metal|folk|epic|music|'
  r'ost|ambient|synthwave|phonk|lofi|lo-fi|eurodance|dance|drumstep|indie|'
  r'nu\s*disco|future\s*house|electro\s*house|hip\s*hop|rap|j-?pop|k-?pop|'
  r'glitch|moombahton|liquid|neurofunk|breakbeat|garage|eurobeat|'
  r'drum\s*and\s*bass)\s*)+$',
  caseSensitive: false,
);
// A part naming the source of an anime/game song, not the artist.
final _sourceMarker = RegExp(
  r'\b(op|ed|opening|ending|ost|soundtrack|theme|season\s*\d+|s\d+|amv|'
  r'insert\s*song|full)\b',
  caseSensitive: false,
);
final _featGroup = RegExp(
  r'^(feat\.?|ft\.?|featuring|with)\s+(.*)$',
  caseSensitive: false,
);
final _feat = RegExp(
  r'\s*[(\[]?\b(feat\.?|ft\.?|featuring)\s+[^)\]\-|]+[)\]]?',
  caseSensitive: false,
);
final _seps = RegExp(
  r'\s+[-–—|~/]{1,3}\s+|\s+:[-–—]:?\s+|\s+::?\s+|\s+-(?=\S)|(?<=\S)-\s+|'
  r'\s*\|\s*|\s+—\s+|\s*//\s*',
);
// A colon right after a word ("Creedence Clearwater Revival: Title"),
// used only when nothing else splits the title.
final _colonSep = RegExp(r'(?<=\S):\s+');
final _trailingNoise = RegExp(
  r'\s+\b(audio|lyrics?|official|video|hd|hq)\b\s*$',
  caseSensitive: false,
);
final _by = RegExp(r'^(.+?)\s+by\s+(.+)$', caseSensitive: false);
final _cjkOnly = RegExp(
  r'^[\s\p{P}\p{S}\p{N}\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}'
  r'\p{Script=Hangul}ー]+$',
  unicode: true,
);
final _latin = RegExp(r'[A-Za-z]');
final _nightcoreGroup = RegExp(
  r'[(\[{][^()\[\]{}]*night\s?core[^()\[\]{}]*[)\]}]',
  caseSensitive: false,
);
final _strayBracket = RegExp(r'[()\[\]{}]');
final _producedBy = RegExp(r'\s+prod\.?\s+by\s+.*$', caseSensitive: false);
final _cornerQuote = RegExp(r'[『「]([^』」]+)[』」]');

String _norm(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_charMap[char] ?? char);
  }
  return buffer
      .toString()
      .replaceAll(_decor, ' ')
      .replaceAll(_spaces, ' ')
      .trim();
}

String _strip(String text, [String chars = ' -–—|:~/"']) {
  var start = 0;
  var end = text.length;
  while (start < end && chars.contains(text[start])) {
    start++;
  }
  while (end > start && chars.contains(text[end - 1])) {
    end--;
  }
  return text.substring(start, end);
}

bool _isNoiseOnly(String text) =>
    _strip(
      text.replaceAll(_noise, ' ').replaceAll(_spaces, ' '),
      ' -–—|:/&,.',
    ).isEmpty;

/// A separated part that only says which version or where from: "Eurobeat
/// Remix", "Ending", "OP 2".
bool _isTagOnly(String text) =>
    _strip(
      text
          .replaceAll(_noise, ' ')
          .replaceAll(_version, ' ')
          .replaceAll(_sourceMarker, ' ')
          .replaceAll(RegExp(r'\b\d+\b'), ' ')
          .replaceAll(_spaces, ' '),
      ' -–—|:/&,.#',
    ).isEmpty ||
    _genrePart.hasMatch(text.trim());

String? _cleanArtist(String? artist) {
  if (artist == null) return null;
  final cleaned =
      _strip(
        artist.replaceAll(
          RegExp(r'\s+(feat\.?|ft\.?|featuring)\s.*$', caseSensitive: false),
          '',
        ),
      ).trim();
  return cleaned.isEmpty ? null : cleaned;
}

String? _cleanTitle(String? title) {
  if (title == null) return null;
  final cleaned = _strip(title.replaceAll(_feat, ' ')).replaceAll(_spaces, ' ');
  return cleaned.trim().isEmpty ? null : cleaned.trim();
}

class _Groups {
  final feat = <String>[];
  final versionTags = <String>[];
  final others = <String>[];
}

/// Takes out every (...), [...] and {...} group of [text] into [groups] and
/// returns what is left.
String _takeGroups(String text, _Groups groups) {
  final group = RegExp(r'\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\}');
  var rest = text;
  // Nested brackets: take the inner ones first, a few rounds at most.
  for (var round = 0; round < 3; round++) {
    final next = rest.replaceAllMapped(group, (m) {
      final inner = m[0]!.substring(1, m[0]!.length - 1).trim();
      if (inner.isNotEmpty) _classify(inner, groups);
      return ' ';
    });
    if (next == rest) break;
    rest = next;
  }
  return rest.replaceAll(_spaces, ' ').trim();
}

void _classify(String inner, _Groups groups) {
  final feat = _featGroup.firstMatch(inner);
  if (feat != null) {
    groups.feat.add(feat[2]!);
    return;
  }
  var content = inner;
  if (_noise.hasMatch(content) && !_version.hasMatch(content)) {
    // "(Desmeon & Kalidrium / Lyrics)": keep the parts that are not noise.
    final pieces = content.split(RegExp(r'\s*[/|]\s*'));
    final kept = pieces.where((piece) => !_isNoiseOnly(piece)).toList();
    if (kept.isEmpty || kept.length == pieces.length) {
      if (kept.isEmpty || _isNoiseOnly(content)) return;
    }
    content = kept.join(' / ');
    if (content.isEmpty) return;
  }
  if (_version.hasMatch(content)) {
    groups.versionTags.add(content);
    return;
  }
  groups.others.add(content);
}

/// Parses a YouTube video title (rules R1–R8 of the lyrics research).
/// [meta] from the kept info.json wins where it knows better.
SongQuery parseSongTitle(String rawTitle, {VideoMeta? meta}) {
  var text = rawTitle;
  final nightcoreTitle = _nightcore.hasMatch(rawTitle);
  // Japanese corner quotes hold the song title when it is in Latin script
  // (on a nightcore upload they rather hold the artist).
  String? cornerTitle;
  text = text.replaceAllMapped(_cornerQuote, (m) {
    final inner = m[1]!.trim();
    if (cornerTitle == null &&
        !nightcoreTitle &&
        _latin.hasMatch(inner) &&
        !_nightcore.hasMatch(inner) &&
        !_cjkOnly.hasMatch(inner)) {
      cornerTitle = inner;
      return ' ';
    }
    return _nightcore.hasMatch(inner) ? ' $inner ' : ' [$inner] ';
  });
  text = _norm(text);

  var nightcore = false;
  if (_nightcore.hasMatch(text)) {
    nightcore = true;
    // "[NEW NIGHTCORE SONG!]" says nothing about the song.
    text = text.replaceAll(_nightcoreGroup, ' ').replaceAll(_nightcore, ' ');
  }

  final groups = _Groups();
  text =
      _takeGroups(text, groups)
          .replaceAll(_strayBracket, ' ')
          .replaceAll(_producedBy, ' ')
          .replaceAll(_spaces, ' ')
          .trim();

  String? artist;
  String? title;
  var swappable = false;
  String? artistSource;
  String? contextWord;
  final alternatives = <(String, String)>[];

  // R4: a quoted title.
  final quote = RegExp(r'"([^"]+)"').firstMatch(text);
  final quoted = cornerTitle ?? quote?[1]?.trim();
  if (quoted != null && quoted.isNotEmpty) {
    title = quoted;
    var rest = text;
    if (cornerTitle == null && quote != null) {
      rest = '${text.substring(0, quote.start)} ${text.substring(quote.end)}';
    }
    rest = rest.replaceAll(_spaces, ' ').trim();
    final by = RegExp(r'\bby\s+(.+)$', caseSensitive: false).firstMatch(rest);
    if (by != null) {
      artist = _strip(by[1]!);
    } else {
      final parts =
          rest
              .split(_seps)
              .map((part) => _strip(part).trim())
              .where((part) => part.isNotEmpty && !_isNoiseOnly(part))
              .where((part) => !_sourceMarker.hasMatch(part))
              .toList();
      if (parts.isNotEmpty) artist = parts.first;
    }
  } else {
    text = text.replaceAll(_feat, ' ').replaceAll(_spaces, ' ').trim();
    var parts = _splitParts(text, _seps);
    if (parts.length < 2) {
      final byColon = _splitParts(text, _colonSep);
      if (byColon.length == 2) parts = byColon;
    }
    if (parts.isNotEmpty) {
      parts[parts.length - 1] =
          parts.last.replaceAll(_trailingNoise, '').trim();
      if (parts.last.isEmpty) parts.removeLast();
    }
    // "Show - Ending | Song": a dropped "Ending" part marks the show.
    final sourcePart = text
        .split(_seps)
        .any(
          (part) =>
              _sourceMarker.hasMatch(part) && _isTagOnly(_strip(part).trim()),
        );
    if (parts.length == 2 && (sourcePart || _sourceMarker.hasMatch(parts[0]))) {
      // "Show OPENING 1 | Song": the first part names the source.
      title = parts[1];
      contextWord = contextWordFor(parts[0]);
    } else if (parts.length == 2) {
      artist = parts[0];
      title = parts[1];
      swappable = true;
    } else if (parts.length >= 3) {
      // "Show OP - Artist - Song": the first part names the source.
      if (_sourceMarker.hasMatch(parts.first)) {
        artist = parts[1];
        title = parts.last;
        alternatives.add((parts.first, parts.last));
      } else {
        artist = parts.first;
        title = parts.last;
        alternatives.add((parts[1], parts.last));
      }
      alternatives.add((parts.first, parts[1]));
    } else if (parts.length == 1) {
      final by = _by.firstMatch(parts.first);
      if (by != null) {
        title = by[1];
        artist = by[2];
      } else {
        title = parts.first;
      }
    }
  }

  title = _cleanTitle(title);
  if (title != null && artist == null) {
    final by = _by.firstMatch(title);
    if (by != null) {
      title = by[1]!.trim();
      artist = by[2];
    }
  }
  artist = _cleanArtist(artist);
  if (artist != null) artistSource = 'title';
  if (artist != null && _nightcore.hasMatch(artist)) artist = null;

  // "Show Ending [Song] Full": the bracket names the song.
  if (!nightcore &&
      artist == null &&
      groups.others.isNotEmpty &&
      title != null &&
      _sourceMarker.hasMatch(title)) {
    contextWord ??= contextWordFor(title);
    title = groups.others.first;
  }

  // A bracket group holding "A - T" (an AMV naming its song).
  for (final other in groups.others) {
    final parts = _splitParts(other, _seps);
    if (parts.length == 2) alternatives.add((parts[0], parts[1]));
  }

  // R8 (title part): nightcore uploads name the original artist in brackets.
  if (nightcore && groups.others.isNotEmpty) {
    final bracketArtist = _cleanArtist(groups.others.first);
    if (bracketArtist != null &&
        (artist == null || artist.toLowerCase() == 'nightcore')) {
      if (title == null) {
        title = bracketArtist;
      } else {
        artist = bracketArtist;
        artistSource = 'bracket';
        swappable = false;
      }
    }
  }

  // R7: metadata wins.
  if (meta != null) {
    final provided = providedToYouTube(meta.description);
    if (meta.artist != null && meta.track != null) {
      artist = _cleanArtist(meta.artist);
      title = meta.track;
      swappable = false;
      artistSource = 'metadata';
    } else if (provided != null) {
      artist = provided.$1;
      title = provided.$2;
      swappable = false;
      artistSource = 'metadata';
    } else {
      final topic = RegExp(
        r'^(.+?) - Topic$',
      ).firstMatch(meta.uploader ?? meta.channel ?? '');
      if (topic != null && artist == null) {
        artist = topic[1];
        artistSource = 'topic';
      } else if (meta.artist != null && artist == null) {
        artist = _cleanArtist(meta.artist);
        artistSource = 'metadata';
      }
      if (nightcore && meta.description != null) {
        final fromDescription = descriptionArtist(
          meta.description!,
          title: title,
        );
        if (fromDescription == null) {
          // Nothing to add.
        } else if (artist == null) {
          artist = fromDescription.$1;
          title ??= fromDescription.$2;
          artistSource = 'description';
          swappable = false;
        } else if (fromDescription.$1 != artist) {
          // The title's split may be wrong ("Show 2 - song Singer").
          alternatives.insert(0, (
            fromDescription.$1,
            fromDescription.$2 ?? title ?? fromDescription.$1,
          ));
        }
      }
    }
  }

  title ??= artist ?? _strip(_norm(rawTitle));
  if (title.toLowerCase() == 'nightcore') title = _strip(_norm(rawTitle));
  return SongQuery(
    artist: artist,
    title: title,
    swappable: swappable && artist != null,
    nightcore: nightcore,
    rawTitle: rawTitle,
    contextWord: contextWord,
    artistSource: artist == null ? null : artistSource,
    alternatives: [
      for (final alt in alternatives)
        if (_cleanArtist(alt.$1) case final a?)
          if (_cleanTitle(alt.$2) case final t?)
            if ((a, t) != (artist, title)) (a, t),
    ],
  );
}

List<String> _splitParts(String text, RegExp separators) => [
  for (final part in text.split(separators))
    if (_strip(part).trim() case final cleaned
        when cleaned.isNotEmpty &&
            !_isNoiseOnly(cleaned) &&
            !_isTagOnly(cleaned))
      cleaned,
];

/// "Provided to YouTube by …" descriptions of official uploads:
/// (artist, title) from the "Title · Artist" line.
(String, String)? providedToYouTube(String? description) {
  if (description == null) return null;
  final match = RegExp(
    r'Provided to YouTube by [^\n]*\n\s*\n([^\n]+)',
  ).firstMatch(description);
  if (match == null) return null;
  final parts = match[1]!.split(' · ').map((p) => p.trim()).toList();
  if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  return (parts[1], parts[0]);
}

final _descriptionPatterns = [
  // "Original Song: A - T", "Music: A - T", "Song: A - T"
  RegExp(
    r'^\W*(?:original\s+)?(?:song|music|track|original)\s*[:➼\-–>]+\s*'
    r'(.+?)\s+[-–—]\s+(.+?)\s*$',
    caseSensitive: false,
    multiLine: true,
  ),
  // "Artist ➼ X", "Original Artist: X", "Artist: X"
  RegExp(
    r'^\W*(?:original\s+)?artists?\s*(?:[:➼\-–>]+|\s)\s*(.+?)\s*$',
    caseSensitive: false,
    multiLine: true,
  ),
  // "credit goes to the original artist of the song: X"
  RegExp(
    r'credits?\s+(?:goes|go)\s+to\s+(?:the\s+)?original\s+artists?'
    r'(?:\s+of\s+(?:the\s+)?song)?\s*[:\-–]?\s*([^\n.]+)',
    caseSensitive: false,
  ),
];

/// R8: the original artist named in a nightcore upload's description, with
/// the song title when the line gives one. [title] (the parsed song title)
/// lets a plain "Artist - Title" line count.
(String, String?)? descriptionArtist(String description, {String? title}) {
  final lines = description.split('\n').map(_norm).toList();
  // A first line "Nightcore - A - T".
  if (lines.isNotEmpty && _nightcoreFirstLine.hasMatch(lines.first)) {
    final parts = _splitParts(
      _takeGroups(lines.first.replaceAll(_nightcore, ' '), _Groups()),
      _seps,
    );
    if (parts.length == 2) return (parts[0], parts[1]);
  }
  for (final pattern in _descriptionPatterns) {
    for (final match in pattern.allMatches(lines.join('\n'))) {
      final artist = _cleanArtist(
        _strip(match[1]!.replaceAll(_creditTail, ''), ' -|:~/"@.'),
      );
      if (artist == null ||
          artist.length > 60 ||
          artist.contains('http') ||
          _isNoiseOnly(artist) ||
          _nightcore.hasMatch(artist)) {
        continue;
      }
      final songTitle =
          match.groupCount >= 2
              ? match[2]
              : _songLine.firstMatch(lines.join('\n'))?[1];
      return (artist, songTitle == null ? null : _cleanTitle(songTitle));
    }
  }
  // "Harddope, Halvorsen - More Than You Know" near the top.
  if (title != null) {
    for (final line in lines.take(12)) {
      if (line.contains('http')) continue;
      final parts = _splitParts(_takeGroups(line, _Groups()), _seps);
      if (parts.length != 2) continue;
      if (textSimilarity(parts[1], title) >= 0.75) {
        if (_cleanArtist(parts[0]) case final artist?) return (artist, null);
      }
      if (textSimilarity(parts[0], title) >= 0.75) {
        if (_cleanArtist(parts[1]) case final artist?) return (artist, null);
      }
    }
  }
  return null;
}

final _songLine = RegExp(
  r'^\W*(?:song|title|track)\s*[:➼]\s*(.+?)\s*$',
  caseSensitive: false,
  multiLine: true,
);
final _nightcoreFirstLine = RegExp(
  r'^\W*night\s?core\s*[-–—:|~]',
  caseSensitive: false,
);
final _creditTail = RegExp(
  r'\s+and\s+(?:the\s+)?(?:picture|pic|art|image|artwork)\b.*$',
  caseSensitive: false,
);

final _bracketed = RegExp(r'\([^)]*\)|\[[^\]]*\]|\{[^}]*\}');
final _articles = RegExp(r'\b(the|a|an)\b');
final _space = RegExp(r'\s+');

/// Folded form used to compare titles and artists: no brackets, accents,
/// punctuation or articles.
String foldForMatch(String text) {
  final folded = foldForSearch(text.replaceAll(_bracketed, ' '));
  final withoutArticles = folded.replaceAll(_articles, ' ');
  final result = withoutArticles.replaceAll(_space, ' ').trim();
  // A title that is only an article ("A") keeps it.
  return result.isEmpty ? folded.trim() : result;
}

/// 0..1: equal 1, one inside the other 0.9 (when not much shorter), else
/// the share of characters in common.
double textSimilarity(String a, String b) {
  final x = foldForMatch(a);
  final y = foldForMatch(b);
  if (x.isEmpty || y.isEmpty) return 0;
  if (x == y) return 1;
  final x2 = x.replaceAll(' ', '');
  final y2 = y.replaceAll(' ', '');
  if (x2 == y2) return 1;
  final shorter = x.length < y.length ? x : y;
  final longer = x.length < y.length ? y : x;
  if (longer.contains(shorter)) {
    if (shorter.length < 4) return 0.5;
    return shorter.length / longer.length >= 0.6 ? 0.9 : 0.7;
  }
  return _lcsRatio(x2, y2);
}

double _lcsRatio(String a, String b) {
  final previous = List<int>.filled(b.length + 1, 0);
  final current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      current[j] =
          a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)
              ? previous[j - 1] + 1
              : math.max(previous[j], current[j - 1]);
    }
    previous.setAll(0, current);
  }
  return 2 * previous[b.length] / (a.length + b.length);
}

final _artistSplit = RegExp(
  r'\s*(?:&|,|\+|/|;|\bx\b|\bvs\.?|\bfeat\.?|\bft\.?|\bfeaturing\b|\band\b|'
  r'\bwith\b|\bes\b|\bund\b)\s*',
  caseSensitive: false,
);

/// [textSimilarity] for artists: "Owl City & Carly Rae Jepsen" matches
/// "Owl City", and either side may list several.
double artistSimilarity(String a, String b) {
  var best = textSimilarity(a, b);
  if (best >= 1) return best;
  final left = a.split(_artistSplit).where((s) => s.trim().isNotEmpty);
  final right = b.split(_artistSplit).where((s) => s.trim().isNotEmpty);
  for (final x in left) {
    for (final y in right) {
      best = math.max(best, textSimilarity(x, y));
    }
  }
  return best;
}

/// A chapter title: Shazam's "Artist — Title" (em dash), or a YouTube or
/// description chapter. A chapter naming only a song gets a context word
/// from [parentTitle].
SongQuery parseChapterTitle(String chapterTitle, {String? parentTitle}) {
  final shazam = chapterTitle.split(' — ');
  if (shazam.length == 2 &&
      shazam[0].trim().isNotEmpty &&
      shazam[1].trim().isNotEmpty) {
    return SongQuery(
      artist: _cleanArtist(shazam[0].trim()),
      title:
          _cleanTitle(_takeGroups(_norm(shazam[1]), _Groups())) ??
          shazam[1].trim(),
      rawTitle: chapterTitle,
      artistSource: 'chapter',
    );
  }
  final parsed = parseSongTitle(chapterTitle);
  if (parsed.artist != null || parentTitle == null) return parsed;
  return parsed.copyWith(contextWord: contextWordFor(parentTitle));
}

const _genericWords = {
  'all', 'the', 'best', 'top', 'every', 'full', 'songs', 'song', 'theme', //
  'themes', 'openings', 'opening', 'endings', 'ending', 'mix', 'with', //
  'lyrics', 'and', 'of', 'music', 'compilation', 'collection', 'complete', //
};

/// A word or two naming what a compilation is about: the "artist" part of
/// its title when there is one ("POKÉMON - All 20 theme songs" → "POKÉMON"),
/// otherwise its first specific words.
String? contextWordFor(String parentTitle) {
  final parsed = parseSongTitle(parentTitle);
  final candidate = parsed.artist ?? parsed.title;
  final words =
      candidate
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .where((w) => !_genericWords.contains(w.toLowerCase()))
          .where((w) => !RegExp(r'^\d+$|^\(').hasMatch(w))
          .where((w) => !_sourceMarker.hasMatch(w))
          .take(3)
          .toList();
  if (words.isEmpty) return null;
  return words.join(' ');
}
