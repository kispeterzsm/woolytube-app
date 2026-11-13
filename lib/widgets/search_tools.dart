import 'package:flutter/material.dart';

import '../services/chapter_playback.dart';
import '../services/lyrics/lyrics_models.dart';
import '../services/playback_service.dart';
import '../services/track_search.dart';
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

/// The filter chips under a search field: today only Lyrics (shown when
/// [lyricsLabel] is set), off by default. Label filters go here too.
class SearchFilterChips extends StatelessWidget {
  const SearchFilterChips({
    super.key,
    required this.filters,
    required this.onChanged,
    this.lyricsLabel,
  });

  final SearchFilters filters;
  final ValueChanged<SearchFilters> onChanged;

  /// "Lyrics" or "Transcript"; null hides the chip (lyrics are off).
  final String? lyricsLabel;

  @override
  Widget build(BuildContext context) {
    final label = lyricsLabel;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
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
        ],
      ),
    );
  }
}

/// "Play all" for search results, with a menu that adds them to Up next.
class SearchPlayAllButton extends StatelessWidget {
  const SearchPlayAllButton({
    super.key,
    required this.entries,
    required this.onPlayAll,
    required this.onAddToUpNext,
    this.label = 'Play all',
  });

  /// What would be queued; empty disables both actions.
  final List<QueueEntry> entries;
  final VoidCallback onPlayAll;
  final VoidCallback onAddToUpNext;
  final String label;

  @override
  Widget build(BuildContext context) {
    final enabled = entries.isNotEmpty;
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
          enabled: enabled,
          color: const Color(0xFF2A2A2A),
          icon: const Icon(Icons.more_vert, color: _muted),
          onSelected: (value) {
            if (value == 'up-next') onAddToUpNext();
          },
          itemBuilder:
              (_) => [
                PopupMenuItem(
                  key: const ValueKey('search-add-to-up-next'),
                  value: 'up-next',
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
