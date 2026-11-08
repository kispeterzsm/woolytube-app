import 'package:flutter/material.dart';

import '../services/lyrics/lyrics_models.dart';

/// [hit]'s line, cut to start shortly before the first match when that
/// lies further in than [lead] characters ("…" marks the cut), with the
/// highlight ranges moved along.
({String text, List<LyricsHighlight> highlights}) lyricsSnippet(
  LyricsHit hit, {
  int lead = 16,
}) {
  final text = hit.lineText;
  final ranges = hit.highlightRanges;
  if (ranges.isEmpty || ranges.first.start <= lead) {
    return (text: text, highlights: ranges);
  }
  final first = ranges.first.start;
  // Cut at a word start between first - lead and the first match.
  var cut = text.indexOf(' ', first - lead);
  cut = cut < 0 || cut >= first ? first : cut + 1;
  const prefix = '…';
  final shift = cut - prefix.length;
  return (
    text: '$prefix${text.substring(cut)}',
    highlights: [
      for (final r in ranges)
        if (r.start >= cut) LyricsHighlight(r.start - shift, r.end - shift),
    ],
  );
}

/// [text] as spans, the [highlights] ranges in [highlightStyle].
List<TextSpan> lyricsSpans(
  String text,
  List<LyricsHighlight> highlights,
  TextStyle highlightStyle,
) {
  final spans = <TextSpan>[];
  var at = 0;
  for (final range in highlights) {
    final start = range.start.clamp(at, text.length);
    final end = range.end.clamp(start, text.length);
    if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
    if (end > start) {
      spans.add(
        TextSpan(text: text.substring(start, end), style: highlightStyle),
      );
    }
    at = end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return spans;
}

/// A matched lyrics line with its matched words highlighted.
class LyricsLineText extends StatelessWidget {
  const LyricsLineText({
    super.key,
    required this.hit,
    required this.style,
    this.highlightStyle = const TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w600,
    ),
    this.maxLines = 2,
    this.snippet = false,
    this.quoted = false,
    this.strutStyle,
  });

  final LyricsHit hit;
  final TextStyle style;
  final TextStyle highlightStyle;
  final int maxLines;

  /// Start shortly before the first match (see [lyricsSnippet]).
  final bool snippet;

  /// Opens with “ (the closing one is the caller's, so an ellipsis
  /// never hides it).
  final bool quoted;
  final StrutStyle? strutStyle;

  @override
  Widget build(BuildContext context) {
    final (:text, :highlights) =
        snippet
            ? lyricsSnippet(hit)
            : (text: hit.lineText, highlights: hit.highlightRanges);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          if (quoted) const TextSpan(text: '“'),
          ...lyricsSpans(text, highlights, highlightStyle),
        ],
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      strutStyle: strutStyle,
    );
  }
}
