part of '../playlist_detail_page.dart';

const _titleFontSize = 14.0;
const _subtitleFontSize = 12.0;
const _lineHeight = 1.3;
const _indexFontSize = 13.0;

const _titleStrut = StrutStyle(
  fontSize: _titleFontSize,
  height: _lineHeight,
  forceStrutHeight: true,
);
const _subtitleStrut = StrutStyle(
  fontSize: _subtitleFontSize,
  height: _lineHeight,
  forceStrutHeight: true,
);

/// The geometry every track row shares. Each row is exactly [extent] tall
/// whatever its content (2-line title, 1-line subtitle, fixed thumbnail),
/// so the list can use a fixed item extent and compute any row's offset.
class _TrackRowMetrics {
  const _TrackRowMetrics({
    required this.extent,
    required this.thumbWidth,
    required this.indexWidth,
  });

  /// Larger text scales are clamped to this inside the list, so a row
  /// stays a sensible size.
  static const maxTextScale = 1.6;
  static const verticalPadding = 8.0;

  final double extent;
  final double thumbWidth;
  final double indexWidth;

  double get thumbHeight => thumbWidth * 9 / 16;

  static _TrackRowMetrics of(BuildContext context, {required int maxIndex}) {
    final scaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: maxTextScale);
    final thumbWidth = MediaQuery.sizeOf(context).width < 360 ? 96.0 : 112.0;
    final titleLine = scaler.scale(_titleFontSize) * _lineHeight;
    final subtitleLine = scaler.scale(_subtitleFontSize) * _lineHeight;
    final textHeight = 2 * titleLine + 4 + subtitleLine;
    final content = math.max(
      kMinInteractiveDimension,
      math.max(thumbWidth * 9 / 16, textHeight),
    );
    // A little slack so rounding inside text layout can never overflow.
    final extent = (content + 2 * verticalPadding + 2).ceilToDouble();

    final painter = TextPainter(
      text: TextSpan(
        text: '${math.max(maxIndex, 9)}',
        style: const TextStyle(
          fontSize: _indexFontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final indexWidth = painter.width.ceilToDouble() + 2;
    painter.dispose();

    return _TrackRowMetrics(
      extent: extent,
      thumbWidth: thumbWidth,
      indexWidth: indexWidth,
    );
  }
}

typedef _TrackTapCallback =
    void Function(
      Track track,
      bool isCurrent,
      MediaChapter? chapter,
      LyricsHit? lyricMatch,
    );

/// One row of the track list. It watches only whether it is the current
/// track (and, if so, whether it plays), so a track change or play/pause
/// rebuilds one or two rows instead of the page.
class _TrackRow extends ConsumerWidget {
  const _TrackRow({
    super.key,
    required this.track,
    required this.metrics,
    required this.chapterMatch,
    this.lyricMatch,
    this.searchQuery,
    required this.onTap,
    required this.onActions,
  });

  final Track track;
  final _TrackRowMetrics metrics;

  /// The chapter the search query matched, if any.
  final MediaChapter? chapterMatch;

  /// The lyric line the search query matched, if any. A chapter match wins.
  final LyricsHit? lyricMatch;

  /// The search, whose words are highlighted in the title.
  final SearchQuery? searchQuery;
  final _TrackTapCallback onTap;
  final void Function(Track track) onActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCurrent = ref.watch(
      currentTrackProvider.select(
        (current) => current.valueOrNull?.id == track.id,
      ),
    );
    final isPlaying =
        isCurrent &&
        ref.watch(
          isPlayingProvider.select((playing) => playing.valueOrNull ?? false),
        );
    final state = _TrackState.of(track);
    final subtitles = _rowSubtitles(track, chapterMatch);
    final lyric = chapterMatch == null ? lyricMatch : null;
    final subtitleStyle = TextStyle(
      color: _subtitleColor(track, state),
      fontSize: _subtitleFontSize,
      height: _lineHeight,
    );

    return SizedBox(
      height: metrics.extent,
      child: Material(
        color: isCurrent ? const Color(0xFF2A2A2A) : Colors.transparent,
        child: InkWell(
          onTap: () => onTap(track, isCurrent, chapterMatch, lyricMatch),
          onLongPress: () => onActions(track),
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                SizedBox(
                  width: metrics.indexWidth,
                  child: Text(
                    track.index.toString(),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: TextStyle(
                      color: isCurrent ? _accent : _muted,
                      fontSize: _indexFontSize,
                      fontWeight:
                          isCurrent ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: metrics.thumbWidth,
                  height: metrics.thumbHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _TrackArtwork(
                          track: track,
                          logicalWidth: metrics.thumbWidth,
                        ),
                        if (isCurrent)
                          ColoredBox(
                            color: Colors.black45,
                            child: Center(
                              child: IconButton(
                                key: ValueKey('track-toggle-${track.id}'),
                                icon: Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: Colors.white,
                                  size: 28,
                                ),
                                tooltip: isPlaying ? 'Pause' : 'Play',
                                onPressed:
                                    () =>
                                        ref
                                            .read(playbackServiceProvider)
                                            .togglePlayPause(),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      searchHighlightedText(
                        track.displayTitle,
                        searchQuery,
                        maxLines: 2,
                        strutStyle: _titleStrut,
                        style: TextStyle(
                          color: isCurrent ? _accent : Colors.white,
                          fontSize: _titleFontSize,
                          height: _lineHeight,
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (lyric != null)
                        _LyricSubtitle(hit: lyric, style: subtitleStyle)
                      else
                        _RowSubtitle(
                          key: ValueKey('track-subtitle-${track.id}'),
                          options: subtitles,
                          style: subtitleStyle,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 24,
                  child: Center(
                    child:
                        isPlaying
                            ? const Icon(
                              Icons.graphic_eq,
                              color: _accent,
                              size: 20,
                            )
                            : _statusIcon(track.status, state),
                  ),
                ),
                IconButton(
                  key: ValueKey('track-more-${track.id}'),
                  icon: const Icon(Icons.more_vert, color: _muted, size: 20),
                  tooltip: 'Track options',
                  onPressed: () => onActions(track),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The one-line subtitle of a lyric match: `“…line…” · 1:23`. The time
/// always shows; the line is cut to fit.
class _LyricSubtitle extends StatelessWidget {
  const _LyricSubtitle({required this.hit, required this.style});

  final LyricsHit hit;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final position = hit.positionMs;
    return Row(
      key: ValueKey('track-lyric-${hit.trackId}'),
      children: [
        Flexible(
          child: LyricsLineText(
            hit: hit,
            style: style,
            highlightStyle: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            snippet: true,
            quoted: true,
            strutStyle: _subtitleStrut,
          ),
        ),
        Text(
          position == null ? '”' : '” · ${formatLyricsTime(position)}',
          maxLines: 1,
          strutStyle: _subtitleStrut,
          style: style,
        ),
      ],
    );
  }
}

/// A track cover decoded at the size it is shown, never at full size. A
/// missing local file falls back to the YouTube image or a placeholder, so
/// no file check runs while building.
class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({required this.track, required this.logicalWidth});

  final Track track;
  final double logicalWidth;

  @override
  Widget build(BuildContext context) {
    final cacheWidth =
        (logicalWidth * MediaQuery.devicePixelRatioOf(context)).round();
    final url = resolveRemoteThumbnailUrl(
      thumbnailUrl: track.thumbnailUrl,
      youtubeVideoId: track.videoId,
    );

    Widget network() {
      if (url == null) return const _ArtworkPlaceholder();
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        memCacheWidth: cacheWidth,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, __) => const ColoredBox(color: Color(0xFF333333)),
        errorWidget: (_, __, ___) => const _ArtworkPlaceholder(),
      );
    }

    final localPath = track.thumbnailPath;
    if (localPath == null || localPath.isEmpty) return network();
    return ColoredBox(
      color: const Color(0xFF333333),
      child: Image.file(
        File(localPath),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => network(),
      ),
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF333333),
      child: Center(
        child: Icon(Icons.music_note, color: Color(0xFF555555), size: 24),
      ),
    );
  }
}

/// The few facts about a track's download state the row and the options
/// sheet both show.
class _TrackState {
  const _TrackState({
    required this.hasError,
    required this.isUnavailable,
    required this.hasLocalFile,
    required this.replacementFailed,
  });

  factory _TrackState.of(Track track) => _TrackState(
    hasError: track.status == 'error' && track.lastError != null,
    isUnavailable: track.status == 'unavailable',
    hasLocalFile: track.status == 'complete' && track.unavailableReason != null,
    replacementFailed: trackReplacementFailed(track),
  );

  final bool hasError;
  final bool isUnavailable;

  /// A kept local file for a video YouTube no longer offers.
  final bool hasLocalFile;

  /// The requested new copy (for example the YouTube original of a local
  /// file) could not be fetched; the file stays and updates try again.
  final bool replacementFailed;
}

/// The one grey line under a track: its short status, or for a chapter
/// the search matched, where that chapter starts and its title.
///
/// Longest first: when "Always skip" in front of a long status would not
/// fit, the row says "Skip", and if even that is too long, only "Always
/// skip" (the icon and the ⋮ sheet still tell the state). The red colour
/// marks the row either way.
List<String> _rowSubtitles(Track track, MediaChapter? chapter) {
  if (chapter != null) {
    final match = '${_formatMs(chapter.startMs)} · ${chapter.title}';
    return [track.alwaysSkip ? 'Always skip · $match' : match];
  }
  final status = shortTrackStatus(track);
  if (!track.alwaysSkip) {
    // Never empty, so every row lays out the same two text blocks.
    return [status.isEmpty ? ' ' : status];
  }
  if (status.isEmpty) return const ['Always skip'];
  return ['Always skip · $status', 'Skip · $status', 'Always skip'];
}

/// The first of [options] that fits the row on one line, so the line is
/// not cut with "…" when a shorter wording exists.
class _RowSubtitle extends StatelessWidget {
  const _RowSubtitle({super.key, required this.options, required this.style});

  final List<String> options;
  final TextStyle style;

  Text _text(String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    strutStyle: _subtitleStrut,
    style: style,
  );

  @override
  Widget build(BuildContext context) {
    if (options.length == 1) return _text(options.single);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          strutStyle: _subtitleStrut,
          maxLines: 1,
        );
        final fullStyle = DefaultTextStyle.of(context).style.merge(style);
        var chosen = options.last;
        for (final option in options) {
          painter
            ..text = TextSpan(text: option, style: fullStyle)
            ..layout(maxWidth: constraints.maxWidth);
          if (!painter.didExceedMaxLines) {
            chosen = option;
            break;
          }
        }
        painter.dispose();
        return _text(chosen);
      },
    );
  }
}

Color _subtitleColor(Track track, _TrackState state) {
  if (track.alwaysSkip) return const Color(0xFFE57373);
  if (state.hasError || state.isUnavailable) return const Color(0xFFAA6666);
  if (state.hasLocalFile || state.replacementFailed) {
    return const Color(0xFFAAAA66);
  }
  return _muted;
}

Widget _statusIcon(String status, _TrackState state) {
  switch (status) {
    case 'complete':
      final kept = state.hasLocalFile || state.replacementFailed;
      return Icon(
        kept ? Icons.check_circle_outline : Icons.check_circle,
        color: kept ? const Color(0xFFAAAA66) : Colors.green,
        size: 20,
      );
    case 'downloading':
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    case 'error':
      return const Icon(Icons.error, color: Colors.red, size: 20);
    case 'unavailable':
      return const Icon(Icons.block, color: _muted, size: 20);
    default:
      return const Icon(Icons.download, color: Color(0xFF555555), size: 20);
  }
}

String _formatMs(int ms) {
  final duration = Duration(milliseconds: ms);
  final h = duration.inHours;
  final m = duration.inMinutes % 60;
  final s = duration.inSeconds % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _unavailableLabel(String? reason) => unavailableTrackLabel(reason);
