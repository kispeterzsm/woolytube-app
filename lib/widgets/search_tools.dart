import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../database/database.dart';
import '../services/chapter_playback.dart';
import '../services/labels.dart';
import '../services/lyrics/lyrics_models.dart';
import '../services/playback_service.dart';
import '../services/track_search.dart';
import 'label_widgets.dart';
import 'lyrics_line_text.dart';

const _accent = Color(0xFF2196F3);
const _muted = Color(0xFF888888);

/// How matched words show in a result title.
const searchHighlightStyle = TextStyle(
  color: Color(0xFF90CAF9),
  fontWeight: FontWeight.w700,
);

/// [text] with the words of [query] highlighted. Plain [Text] when nothing
/// matches in it.
Widget searchHighlightedText(
  String text,
  SearchQuery? query, {
  required TextStyle style,
  int maxLines = 1,
  StrutStyle? strutStyle,
  TextStyle highlightStyle = searchHighlightStyle,
}) {
  final highlights =
      query == null ? const <LyricsHighlight>[] : searchHighlights(text, query);
  if (highlights.isEmpty) {
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      strutStyle: strutStyle,
      style: style,
    );
  }
  return Text.rich(
    TextSpan(children: lyricsSpans(text, highlights, highlightStyle)),
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    strutStyle: strutStyle,
    style: style,
  );
}

/// The filter chips under a search field: Lyrics (shown when [lyricsLabel]
/// is set) and Labels (shown when there are [labels]). Both are off when
/// search opens. With two or more labels chosen, a small switch after
/// them says whether results need all of them (the default) or any one.
///
/// Labels on shows a second row, one line that scrolls sideways, with the
/// labels to choose: the chosen ones first, then the rest in the owner's
/// order, narrowed to those whose names match [query]. A label just chosen
/// moves to the front, so the row scrolls back there.
///
/// With [labels], the chips row is [rowHeight] tall whether Labels is on
/// or not, so the chips stay put when the label row opens under them.
class SearchFilterChips extends StatefulWidget {
  const SearchFilterChips({
    super.key,
    required this.filters,
    required this.onChanged,
    this.lyricsLabel,
    this.labels = const [],
    this.query,
  });

  final SearchFilters filters;
  final ValueChanged<SearchFilters> onChanged;

  /// "Lyrics" or "Transcript"; null hides the chip (lyrics are off).
  final String? lyricsLabel;

  /// The labels to offer, in the owner's order. Empty hides the Labels
  /// chip.
  final List<Label> labels;

  /// What is typed: it narrows the labels offered.
  final SearchQuery? query;

  /// The height of one row of chips at the current text size.
  static double rowHeight(BuildContext context) =>
      math.max(44, MediaQuery.textScalerOf(context).scale(14) * 1.45 + 24);

  /// How tall the chips are with [filters]: one row, or two while Labels is
  /// on.
  static double heightFor(BuildContext context, SearchFilters filters) =>
      rowHeight(context) * (filters.labelSearch ? 2 : 1);

  @override
  State<SearchFilterChips> createState() => _SearchFilterChipsState();
}

class _SearchFilterChipsState extends State<SearchFilterChips> {
  final _chipScroll = ScrollController();
  final _labelScroll = ScrollController();

  @override
  void didUpdateWidget(SearchFilterChips oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_showsMatch(widget.filters) && !_showsMatch(oldWidget.filters)) {
      // The switch is last in the chips row: with a large font it can land
      // past the edge, so bring it in.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_chipScroll.hasClients) return;
        final end = _chipScroll.position.maxScrollExtent;
        if (end <= _chipScroll.offset) return;
        unawaited(
          _chipScroll.animateTo(
            end,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _chipScroll.dispose();
    _labelScroll.dispose();
    super.dispose();
  }

  /// Whether the All labels / Any label switch shows.
  bool _showsMatch(SearchFilters filters) =>
      widget.labels.isNotEmpty &&
      filters.labelSearch &&
      filters.labels.length >= 2;

  SearchFilters get _filters => widget.filters;

  void _toggleLabel(String uid, bool on) {
    final chosen = {..._filters.labels};
    on ? chosen.add(uid) : chosen.remove(uid);
    // The chosen label moves to the front: show it there, not whatever
    // label now sits where it was.
    if (on && _labelScroll.hasClients) _labelScroll.jumpTo(0);
    widget.onChanged(_filters.copyWith(labels: chosen));
  }

  @override
  Widget build(BuildContext context) {
    final filters = _filters;
    final onChanged = widget.onChanged;
    final label = widget.lyricsLabel;
    final showLabels = widget.labels.isNotEmpty;
    final matchAll = filters.labelMatch == LabelMatch.all;
    final chips = SingleChildScrollView(
      controller: _chipScroll,
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 6,
        children: [
          if (label != null)
            FilterChip(
              key: const ValueKey('search-filter-lyrics'),
              avatar:
                  filters.lyrics
                      ? null
                      : const Icon(Icons.lyrics_outlined, size: 18),
              label: Text(label),
              tooltip:
                  filters.lyrics
                      ? 'Searching ${label.toLowerCase()} too'
                      : 'Also search ${label.toLowerCase()}',
              selected: filters.lyrics,
              showCheckmark: true,
              visualDensity: VisualDensity.compact,
              onSelected: (on) => onChanged(filters.copyWith(lyrics: on)),
            ),
          if (showLabels)
            FilterChip(
              key: const ValueKey('search-filter-labels'),
              avatar:
                  filters.labelSearch
                      ? null
                      : const Icon(Icons.label_outline, size: 18),
              label: const Text('Labels'),
              tooltip:
                  filters.labelSearch
                      ? 'Searching labels too'
                      : 'Choose or search labels',
              selected: filters.labelSearch,
              showCheckmark: true,
              visualDensity: VisualDensity.compact,
              onSelected:
                  (on) => onChanged(
                    on
                        ? filters.copyWith(labelSearch: true)
                        : filters.copyWith(
                          labelSearch: false,
                          labels: const {},
                          labelMatch: LabelMatch.all,
                        ),
                  ),
            ),
          // Beside Labels, where it shows without scrolling the labels,
          // and last, so no chip moves when it appears.
          if (_showsMatch(filters))
            ActionChip(
              key: const ValueKey('search-label-match'),
              avatar: Icon(
                matchAll ? Icons.join_inner : Icons.join_full,
                size: 18,
              ),
              label: Text(matchAll ? 'All labels' : 'Any label'),
              tooltip:
                  matchAll
                      ? 'Showing what has all chosen labels. Tap for any of '
                          'them'
                      : 'Showing what has any chosen label. Tap for all of '
                          'them',
              visualDensity: VisualDensity.compact,
              onPressed:
                  () => onChanged(
                    filters.copyWith(
                      labelMatch: matchAll ? LabelMatch.any : LabelMatch.all,
                    ),
                  ),
            ),
        ],
      ),
    );
    if (!showLabels) return chips;
    final height = SearchFilterChips.rowHeight(context);
    final chipsRow = SizedBox(
      height: height,
      child: Align(alignment: Alignment.centerLeft, child: chips),
    );
    if (!filters.labelSearch) return chipsRow;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        chipsRow,
        SizedBox(
          height: height,
          child: Align(alignment: Alignment.centerLeft, child: _labelRow()),
        ),
      ],
    );
  }

  Widget _labelRow() {
    final labels = widget.labels;
    final filters = _filters;
    final query = widget.query ?? SearchQuery.empty;
    final named = labelUidsNamed(labels, query);
    final chosen = [
      for (final item in labels)
        if (filters.labels.contains(item.uid)) item,
    ];
    final rest = [
      for (final item in labels)
        if (!filters.labels.contains(item.uid) &&
            (query.isEmpty || named.contains(item.uid)))
          item,
    ];
    if (chosen.isEmpty && rest.isEmpty) {
      return const Text(
        'No label matches',
        key: ValueKey('search-label-none'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _muted),
      );
    }
    return SingleChildScrollView(
      key: const ValueKey('search-label-row'),
      controller: _labelScroll,
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 6,
        children: [
          for (final item in chosen) _labelChip(item, true),
          for (final item in rest) _labelChip(item, false),
        ],
      ),
    );
  }

  Widget _labelChip(Label item, bool chosen) => FilterChip(
    key: ValueKey('search-label-option-${item.uid}'),
    avatar: LabelSwatch(color: item.color, icon: chosen ? Icons.check : null),
    label: Text(item.name),
    tooltip:
        chosen
            ? 'Only what has "${item.name}"'
            : 'Show what has "${item.name}"',
    selected: chosen,
    showCheckmark: false,
    visualDensity: VisualDensity.compact,
    onSelected: (on) => _toggleLabel(item.uid, on),
  );
}

/// "Play all" for search results, with a menu that adds them to Up next
/// and labels them all.
class SearchPlayAllButton extends StatelessWidget {
  const SearchPlayAllButton({
    super.key,
    required this.entries,
    required this.onPlayAll,
    required this.onAddToUpNext,
    this.onLabelAll,
    this.label = 'Play all',
  });

  /// What would be queued; empty disables playing and queueing.
  final List<QueueEntry> entries;
  final VoidCallback onPlayAll;
  final VoidCallback onAddToUpNext;

  /// Labels every result, played or not; null leaves it out.
  final VoidCallback? onLabelAll;
  final String label;

  @override
  Widget build(BuildContext context) {
    final enabled = entries.isNotEmpty;
    final onLabelAll = this.onLabelAll;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          key: const ValueKey('search-play-all'),
          onPressed: enabled ? onPlayAll : null,
          icon: const Icon(Icons.play_arrow),
          label: Text(label),
        ),
        PopupMenuButton<String>(
          key: const ValueKey('search-results-menu'),
          tooltip: 'More for these results',
          enabled: enabled || onLabelAll != null,
          color: const Color(0xFF2A2A2A),
          icon: const Icon(Icons.more_vert, color: _muted),
          onSelected: (value) {
            if (value == 'up-next') onAddToUpNext();
            if (value == 'label-all') onLabelAll?.call();
          },
          itemBuilder:
              (_) => [
                PopupMenuItem(
                  key: const ValueKey('search-add-to-up-next'),
                  value: 'up-next',
                  enabled: enabled,
                  child: ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text(
                      entries.length == 1
                          ? 'Add to Up next'
                          : 'Add ${entries.length} to Up next',
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (onLabelAll != null)
                  const PopupMenuItem(
                    key: ValueKey('search-label-all'),
                    value: 'label-all',
                    child: ListTile(
                      leading: Icon(Icons.label_outline),
                      title: Text('Label all…'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
        ),
      ],
    );
  }
}

/// Adds search results to Up next, starts it when nothing plays, and says
/// what happened.
Future<void> addSearchResultsToUpNext(
  BuildContext context,
  PlaybackService playback,
  List<QueueEntry> entries,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final added = await playback.enqueueEntries(entries);
  if (added == 0) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Nothing here can be added to Up next')),
      );
    return;
  }
  final started = await playback.startUpNextQueueIfIdle();
  final tracks = added == 1 ? '1 track' : '$added tracks';
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          started ? 'Playing $tracks from Up next' : 'Added $tracks to Up next',
        ),
      ),
    );
}

/// "No titles match" with a button that turns the Lyrics filter on.
class SearchLyricsNudge extends StatelessWidget {
  const SearchLyricsNudge({
    super.key,
    required this.message,
    required this.lyricsLabel,
    required this.onSearchLyrics,
  });

  final String message;
  final String lyricsLabel;
  final VoidCallback onSearchLyrics;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: const TextStyle(color: _muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('search-lyrics-nudge'),
              onPressed: onSearchLyrics,
              icon: const Icon(Icons.lyrics_outlined, color: _accent),
              label: Text('Search ${lyricsLabel.toLowerCase()} too'),
            ),
          ],
        ),
      ),
    );
  }
}
