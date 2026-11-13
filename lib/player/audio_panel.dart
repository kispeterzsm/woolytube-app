import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/playback_providers.dart';
import '../widgets/chapters_button.dart';
import '../widgets/player_controls.dart';
import '../widgets/player_more_button.dart';
import 'player_layout.dart';
import 'player_shell.dart';
import 'player_widgets.dart';

/// Content of the expanded audio panel, laid out with the fixed row heights
/// of [PlayerLayout]. The artwork and the moving title are drawn by the sheet
/// on top; this widget leaves their slots free.
///
/// Nothing here watches the playback position except the seek bar, so the
/// panel does not rebuild while a track plays.
class AudioPanel extends StatelessWidget {
  final Animation<double> sliderOpacity;
  final VoidCallback onCollapse;
  final VoidCallback onStop;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  const AudioPanel({
    super.key,
    required this.sliderOpacity,
    required this.onCollapse,
    required this.onStop,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag area: handle, header and the artwork/title row.
            GestureDetector(
              key: const ValueKey('player-panel-drag-area'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: onDragStart,
              onVerticalDragUpdate: onDragUpdate,
              onVerticalDragEnd: onDragEnd,
              child: SizedBox(
                height: PlayerLayout.panelDragAreaHeight,
                child: Column(
                  children: [
                    SizedBox(
                      height: PlayerLayout.panelHeaderHeight,
                      child: _PanelHeader(
                        onCollapse: onCollapse,
                        onStop: onStop,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const SizedBox(
                      height: PlayerLayout.panelArtRowHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Artwork slot; the sheet draws the artwork here.
                          SizedBox(width: PlayerLayout.panelTitleLeft),
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(
                                top:
                                    PlayerLayout.panelTitleTop -
                                    PlayerLayout.panelArtRowTop,
                                right: 16,
                              ),
                              child: _PanelTitleBlock(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SeekBar(sliderOpacity: sliderOpacity),
            const SizedBox(height: 2),
            const SizedBox(
              height: PlayerLayout.transportHeight,
              child: _TransportRow(),
            ),
            const SizedBox(height: 6),
            const SizedBox(
              height: PlayerLayout.secondaryHeight,
              child: _SecondaryRow(),
            ),
            const SizedBox(height: PlayerLayout.panelBottomPadding),
          ],
        ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  final VoidCallback onCollapse;
  final VoidCallback onStop;

  const _PanelHeader({required this.onCollapse, required this.onStop});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Drag handle; tapping the header's empty space also collapses.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onCollapse,
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF5A5A5A),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 4,
          top: 8,
          child: IconButton(
            key: const ValueKey('player-collapse-button'),
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
            color: Colors.white,
            tooltip: 'Minimize player',
            onPressed: onCollapse,
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: TextButton.icon(
            key: const ValueKey('player-stop-button'),
            style: TextButton.styleFrom(
              foregroundColor: PlayerLayout.secondaryText,
              minimumSize: const Size(48, 48),
            ),
            onPressed: onStop,
            icon: const Icon(Icons.stop_rounded, size: 20),
            label: const Text('Stop'),
          ),
        ),
      ],
    );
  }
}

/// The title, playlist and position under the artwork. Their slot has a
/// fixed height (the mini bar morphs into it), so a long title is cut to
/// two lines; tapping the block shows it in full.
class _PanelTitleBlock extends ConsumerWidget {
  const _PanelTitleBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = ref.watch(
      currentTrackProvider.select((value) => value.valueOrNull?.title ?? ''),
    );
    final playlistName = ref.watch(
      currentPlaylistProvider.select((value) => value.valueOrNull?.name ?? ''),
    );
    return Semantics(
      button: true,
      hint: 'Shows the full title',
      child: GestureDetector(
        key: const ValueKey('player-panel-title-block'),
        behavior: HitTestBehavior.opaque,
        onTap:
            title.isEmpty
                ? null
                : () => _showFullTitle(context, title, playlistName),
        child: LayoutBuilder(
          builder:
              (context, constraints) => _titleColumn(
                title,
                playlistName,
                _titleLines(context, constraints.maxHeight),
              ),
        ),
      ),
    );
  }

  static const _lineHeight = 1.2;
  static const _playlistFontSize = 13.0;
  static const _captionFontSize = 12.0;

  /// Two title lines when they fit above the playlist and position lines,
  /// one with large text, so nothing in the fixed slot is cut off.
  static int _titleLines(BuildContext context, double height) {
    final scaler = MediaQuery.textScalerOf(context);
    double line(double fontSize) => scaler.scale(fontSize) * _lineHeight;
    final rest = 3 + line(_playlistFontSize) + 2 + line(_captionFontSize);
    final lines = (height - rest) / line(PlayerLayout.panelTitleFontSize);
    return lines >= 2 ? 2 : 1;
  }

  Widget _titleColumn(String title, String playlistName, int titleLines) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          key: const ValueKey('player-panel-title'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: PlayerLayout.panelTitleFontSize,
            fontWeight: FontWeight.w700,
            height: _lineHeight,
          ),
          maxLines: titleLines,
          overflow: TextOverflow.ellipsis,
        ),
        if (playlistName.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            playlistName,
            style: const TextStyle(
              color: PlayerLayout.secondaryText,
              fontSize: _playlistFontSize,
              height: _lineHeight,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 2),
        const PlaylistPositionCaption(
          style: TextStyle(
            color: PlayerLayout.mutedText,
            fontSize: _captionFontSize,
            height: _lineHeight,
          ),
        ),
      ],
    );
  }
}

/// The playing track's whole title and playlist name, selectable, with a
/// button that copies the title.
void _showFullTitle(BuildContext context, String title, String playlistName) {
  final host = PlayerShell.maybeOf(context);
  final hostContext = host != null && host.mounted ? host.context : context;
  showDialog<void>(
    context: hostContext,
    builder:
        (dialogContext) => AlertDialog(
          key: const ValueKey('player-full-title'),
          backgroundColor: const Color(0xFF2A2A2A),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  title,
                  key: const ValueKey('player-full-title-text'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (playlistName.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    playlistName,
                    style: const TextStyle(color: PlayerLayout.secondaryText),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              key: const ValueKey('player-full-title-copy'),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy title'),
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: title)));
                Navigator.pop(dialogContext);
              },
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
  );
}

/// −10 s, previous, play/pause, next, +10 s. The row never changes shape, so
/// the play button stays centred.
class _TransportRow extends ConsumerWidget {
  const _TransportRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapter = ref.watch(isChapterItemProvider);
    final service = ref.read(playbackServiceProvider);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TransportButton(
            icon: Icons.replay_10_rounded,
            iconSize: 30,
            tooltip: 'Back 10 seconds',
            onPressed: () => seekPlaybackBy(ref, const Duration(seconds: -10)),
          ),
          const SizedBox(width: 12),
          _TransportButton(
            icon: Icons.skip_previous_rounded,
            iconSize: 40,
            tooltip: chapter ? 'Previous chapter' : 'Previous',
            onPressed: service.previous,
          ),
          const SizedBox(width: 12),
          const PlayPauseButton(iconSize: 42, filled: true),
          const SizedBox(width: 12),
          _TransportButton(
            icon: Icons.skip_next_rounded,
            iconSize: 40,
            tooltip: chapter ? 'Next chapter' : 'Next',
            onPressed: service.next,
          ),
          const SizedBox(width: 12),
          _TransportButton(
            icon: Icons.forward_10_rounded,
            iconSize: 30,
            tooltip: 'Forward 10 seconds',
            onPressed: () => seekPlaybackBy(ref, const Duration(seconds: 10)),
          ),
        ],
      ),
    );
  }
}

class _TransportButton extends StatelessWidget {
  final IconData icon;
  final double iconSize;
  final String tooltip;
  final VoidCallback onPressed;

  const _TransportButton({
    required this.icon,
    required this.iconSize,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: iconSize),
      color: Colors.white,
      tooltip: tooltip,
      style: IconButton.styleFrom(minimumSize: const Size.square(52)),
      onPressed: onPressed,
    );
  }
}

/// Labelled toggles and actions under the transport row, always the same
/// five slots so Queue stays in the middle: Shuffle, Autoplay, Queue,
/// Chapters and More (End segment while a skip segment is being marked).
/// The rarer actions (lyrics, share, sleep timer, the file's own menu) are
/// in More.
class _SecondaryRow extends ConsumerWidget {
  const _SecondaryRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shuffle = ref.watch(shuffleEnabledProvider).valueOrNull ?? false;
    final autoplay = ref.watch(autoplayEnabledProvider).valueOrNull ?? true;
    final service = ref.read(playbackServiceProvider);

    final items = <Widget>[
      PlayerActionButton(
        icon: Icons.shuffle_rounded,
        label: 'Shuffle',
        tooltip: shuffle ? 'Shuffle: on' : 'Shuffle: off',
        toggled: shuffle,
        onPressed: service.toggleShuffle,
      ),
      PlayerActionButton(
        icon: Icons.playlist_play_rounded,
        label: 'Autoplay',
        tooltip:
            autoplay
                ? 'Autoplay: on (plays the next track)'
                : 'Autoplay: off (stops after this track)',
        toggled: autoplay,
        onPressed: service.toggleAutoplay,
      ),
      const QueueButton(),
      const ChaptersButton(showLabel: true),
      const PlayerMoreButton(),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final item in items) Expanded(child: Center(child: item)),
        ],
      ),
    );
  }
}
