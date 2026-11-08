/// Text handling for lyrics search: folding, parsing and search windows.
library;

import 'dart:convert';

import 'lyrics_models.dart';

const _latinFolding = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', //
  'ă': 'a', 'ą': 'a', 'ǎ': 'a', 'æ': 'ae', 'ç': 'c', 'ć': 'c', 'ĉ': 'c', //
  'ċ': 'c', 'č': 'c', 'ď': 'd', 'đ': 'd', 'ð': 'd', 'è': 'e', 'é': 'e', //
  'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e', //
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g', 'ĥ': 'h', 'ħ': 'h', 'ì': 'i', //
  'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i', 'į': 'i', //
  'ı': 'i', 'ǐ': 'i', 'ĳ': 'ij', 'ĵ': 'j', 'ķ': 'k', 'ĺ': 'l', 'ļ': 'l', //
  'ľ': 'l', 'ŀ': 'l', 'ł': 'l', 'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n', //
  'ŉ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', //
  'ō': 'o', 'ŏ': 'o', 'ő': 'o', 'ǒ': 'o', 'œ': 'oe', 'ŕ': 'r', 'ŗ': 'r', //
  'ř': 'r', 'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's', 'ș': 's', 'ß': 'ss', //
  'ţ': 't', 'ť': 't', 'ŧ': 't', 'ț': 't', 'þ': 'th', 'ù': 'u', 'ú': 'u', //
  'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u', 'ů': 'u', 'ű': 'u', //
  'ų': 'u', 'ǔ': 'u', 'ŵ': 'w', 'ý': 'y', 'ÿ': 'y', 'ŷ': 'y', 'ź': 'z', //
  'ż': 'z', 'ž': 'z',
};

/// Apostrophes vanish inside words ("there's" → "theres").
const _apostrophes = {0x27, 0x2019, 0x2018, 0x02BC, 0x60, 0xB4};

final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _mark = RegExp(r'\p{M}', unicode: true);

/// How one character of the input folds: null drops it, ' ' separates
/// words, anything else is word text.
String? _foldChar(String char) {
  final unit = char.codeUnitAt(0);
  if (unit < 0x80) {
    if (unit >= 0x41 && unit <= 0x5a) return String.fromCharCode(unit + 32);
    if ((unit >= 0x61 && unit <= 0x7a) || (unit >= 0x30 && unit <= 0x39)) {
      return char;
    }
    return unit == 0x27 || unit == 0x60 ? null : ' ';
  }
  final lower = char.toLowerCase();
  final mapped = _latinFolding[lower];
  if (mapped != null) return mapped;
  if (_apostrophes.contains(char.codeUnitAt(0))) return null;
  if (_mark.hasMatch(char)) return null;
  if (_wordChar.hasMatch(lower)) return lower;
  return ' ';
}

/// Lower case, accents removed (including Hungarian ő and ű), apostrophes
/// dropped and other punctuation turned into single spaces. The same
/// folding is used for the index and for queries.
String foldForSearch(String text) {
  final buffer = StringBuffer();
  var pendingSpace = false;
  for (final rune in text.runes) {
    final folded = _foldChar(String.fromCharCode(rune));
    if (folded == null) continue;
    if (folded == ' ') {
      pendingSpace = buffer.isNotEmpty;
      continue;
    }
    if (pendingSpace) buffer.write(' ');
    pendingSpace = false;
    buffer.write(folded);
  }
  return buffer.toString();
}

/// The words of a string already folded with [foldForSearch].
List<String> tokenizeFolded(String folded) =>
    folded.split(' ').where((word) => word.isNotEmpty).toList();

/// A word of raw text with its place in that text, for highlighting.
class LyricsToken {
  /// The word as [foldForSearch] folds it.
  final String folded;

  /// Character range [start, end) in the raw text.
  final int start;
  final int end;

  const LyricsToken(this.folded, this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is LyricsToken &&
      other.folded == folded &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(folded, start, end);

  @override
  String toString() => 'LyricsToken($folded, $start, $end)';
}

/// The words of raw [text] with their offsets (UTF-16 indices); their
/// folded forms equal `tokenizeFolded(foldForSearch(text))`.
List<LyricsToken> tokenizeWithOffsets(String text) {
  final tokens = <LyricsToken>[];
  final word = StringBuffer();
  var start = -1;
  var end = 0;
  var offset = 0;
  void finish() {
    if (word.isNotEmpty) tokens.add(LyricsToken(word.toString(), start, end));
    word.clear();
    start = -1;
  }

  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final folded = _foldChar(char);
    if (folded == ' ') {
      finish();
    } else if (folded != null) {
      if (start < 0) start = offset;
      word.write(folded);
      end = offset + char.length;
    } else if (start >= 0) {
      end = offset + char.length;
    }
    offset += char.length;
  }
  finish();
  return tokens;
}

/// The text indexed for line [i]: folded line i and line i + 1, so a
/// phrase across a line break still matches.
String buildSearchWindow(List<String> lines, int i) {
  final current = foldForSearch(lines[i]);
  if (i + 1 >= lines.length) return current;
  final next = foldForSearch(lines[i + 1]);
  if (current.isEmpty) return next;
  if (next.isEmpty) return current;
  return '$current $next';
}

/// [buildSearchWindow] for every line, folding each line once.
List<String> buildSearchWindows(List<String> lines) {
  final folded = [for (final line in lines) foldForSearch(line)];
  return [
    for (var i = 0; i < folded.length; i++)
      [
        folded[i],
        if (i + 1 < folded.length) folded[i + 1],
      ].where((part) => part.isNotEmpty).join(' '),
  ];
}

final _lrcTag = RegExp(r'\[([^\]]*)\]');
final _lrcTime = RegExp(r'^(\d+):(\d{1,2})(?:[.:](\d{1,3}))?$');
final _lrcOffset = RegExp(r'^offset:\s*([+-]?\d+)$', caseSensitive: false);
final _lrcWordTime = RegExp(r'<\d+:\d{1,2}(?:[.:]\d{1,3})?>');

int? _lrcMillis(String tag) {
  final match = _lrcTime.firstMatch(tag.trim());
  if (match == null) return null;
  final minutes = int.parse(match.group(1)!);
  final seconds = int.parse(match.group(2)!);
  final fraction = match.group(3);
  var millis = 0;
  if (fraction != null) {
    millis = int.parse(fraction.padRight(3, '0').substring(0, 3));
  }
  return (minutes * 60 + seconds) * 1000 + millis;
}

/// Parses LRC synced lyrics: several time stamps on one line give one line
/// each, `[offset:±ms]` shifts every line (positive = earlier), metadata
/// tags like `[ar:...]` and lines without a time are skipped, as are empty
/// lines (instrumental gaps). Enhanced per-word stamps are removed. Lines
/// come back in time order.
List<LyricsLineDraft> parseLrc(String lrc) {
  var offset = 0;
  final timed = <(int, int, String)>[];
  var order = 0;
  for (final rawLine in const LineSplitter().convert(lrc)) {
    var rest = rawLine.trim();
    final times = <int>[];
    while (rest.startsWith('[')) {
      final match = _lrcTag.matchAsPrefix(rest);
      if (match == null) break;
      final tag = match.group(1)!;
      final millis = _lrcMillis(tag);
      if (millis != null) {
        times.add(millis);
      } else {
        final offsetMatch = _lrcOffset.firstMatch(tag.trim());
        if (offsetMatch != null) offset = int.parse(offsetMatch.group(1)!);
      }
      rest = rest.substring(match.end).trimLeft();
    }
    if (times.isEmpty) continue;
    final text =
        rest
            .replaceAll(_lrcWordTime, '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (text.isEmpty) continue;
    for (final time in times) {
      timed.add((time, order++, text));
    }
  }
  timed.sort((a, b) {
    final byTime = a.$1.compareTo(b.$1);
    return byTime != 0 ? byTime : a.$2.compareTo(b.$2);
  });
  return [
    for (final (time, _, text) in timed)
      LyricsLineDraft(text, startMs: time - offset < 0 ? 0 : time - offset),
  ];
}

/// Lines like "[Chorus]", "[Music]", "(gentle music)" or "♪♪".
final _noiseLine = RegExp(r'^(?:\[[^\]]*\]|\([^)]*\)|[♪♫♬\s*~-])*$');
final _notes = RegExp(r'^[♪♫♬\s]+|[♪♫♬\s]+$');

String _cleanLine(String line) =>
    line.replaceAll(RegExp(r'\s+'), ' ').replaceAll(_notes, '').trim();

final _sectionLine = RegExp(r'^\[[^\]]*\]$');

/// Plain lyrics: one line per non-empty line, without section labels such
/// as "[Chorus]".
List<LyricsLineDraft> parsePlainLyrics(String text) => [
  for (final raw in const LineSplitter().convert(text))
    if (_cleanLine(raw) case final line
        when line.isNotEmpty && !_sectionLine.hasMatch(line))
      LyricsLineDraft(line),
];

/// Parses YouTube json3 captions: the segments of each event are joined
/// into one line timed at the event start; blank lines and bracket-only
/// lines ("[Music]", "(applause)", "♪") are dropped; and the rolling lines
/// of speech-to-text, where a line repeats or grows into the next, are
/// collapsed into one.
List<LyricsLineDraft> parseJson3Captions(String json) {
  final decoded = jsonDecode(json);
  final events =
      decoded is Map<String, dynamic> ? decoded['events'] as List? : null;
  if (events == null) return const [];
  final lines = <LyricsLineDraft>[];
  for (final event in events) {
    if (event is! Map) continue;
    final segs = event['segs'];
    if (segs is! List) continue;
    final text = _cleanLine(
      segs.map((seg) => seg is Map ? '${seg['utf8'] ?? ''}' : '').join(),
    );
    if (text.isEmpty || _noiseLine.hasMatch(text)) continue;
    final start = (event['tStartMs'] as num?)?.toInt() ?? 0;
    if (lines.isNotEmpty) {
      final previous = lines.last.text;
      if (text == previous || previous.startsWith(text)) continue;
      if (text.startsWith(previous)) {
        lines[lines.length - 1] = LyricsLineDraft(
          text,
          startMs: lines.last.startMs,
        );
        continue;
      }
    }
    lines.add(LyricsLineDraft(text, startMs: start));
  }
  return lines;
}

/// English words left out of searches (folded).
const englishStopWords = {
  'a', 'an', 'the', 'and', 'or', 'but', 'so', 'if', 'of', 'to', 'in', //
  'on', 'at', 'by', 'for', 'from', 'with', 'as', 'is', 'am', 'are', 'was', //
  'were', 'be', 'been', 'it', 'its', 'i', 'im', 'ive', 'id', 'ill', 'me', //
  'my', 'you', 'your', 'youre', 'we', 'us', 'our', 'he', 'him', 'his', //
  'she', 'her', 'they', 'them', 'their', 'that', 'this', 'do', 'dont', //
  's', 't', 'll', 're', 've', 'd', 'm',
};

/// Hungarian words left out of searches (folded).
const hungarianStopWords = {
  'a', 'az', 'es', 'egy', 'is', 'hogy', 'nem', 'de', 'ha', 'meg', 'mar', //
  'csak', 'en', 'te', 'o', 'mi', 'ti', 'ok', 'ez', 'azt', 'ezt', 'van', //
  'volt', 'vagy', 'mint', 'sem', 'se', 'ne', 'el', 'ki', 'be', 'fel', //
};

/// Every stop word (folded).
final lyricsStopWords = {...englishStopWords, ...hungarianStopWords};

/// Whether [foldedWord] is a stop word.
bool isLyricsStopWord(String foldedWord) =>
    lyricsStopWords.contains(foldedWord);
