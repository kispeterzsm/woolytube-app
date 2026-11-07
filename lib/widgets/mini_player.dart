import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_layout.dart';
import '../player/player_widgets.dart';
import '../providers/playback_providers.dart';

/// The collapsed player's own content: elapsed time, play/pause and next.
///
/// The thumbnail, title and progress line are drawn by the player sheet on
/// top of this bar, because they move into the expanded panel. This widget
/// leaves room for them and handles the bar's gestures: tap opens the player,
/// dragging up expands it, dragging down dismisses it (stops playback).
class MiniPlayerBar extends StatelessWidget {
  final VoidCallback onOpen;

  /// Stops playback; offered to screen readers in place of the swipe.
  final VoidCallback onStop;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  const MiniPlayerBar({
    super.key,
    required this.onOpen,
    required this.onStop,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: 'Open player',
      hint: 'Swipe down to stop playback',
      onTap: onOpen,
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Stop playback'): onStop,
      },
      explicitChildNodes: true,
      child: GestureDetector(
        key: const ValueKey('mini-player-bar'),
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        onVerticalDragStart: onDragStart,
        onVerticalDragUpdate: onDragUpdate,
        onVerticalDragEnd: onDragEnd,
        child: const SizedBox(
          height: PlayerLayout.miniHeight,
          child: Padding(
            padding: EdgeInsets.only(top: PlayerLayout.miniProgressHeight),
            child: Row(
              children: [
                // Thumbnail slot; the sheet draws the artwork here.
                SizedBox(width: PlayerLayout.miniTitleLeft),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title slot; the sheet draws the moving title here.
                      SizedBox(height: 20),
                      _MiniTime(),
                    ],
                  ),
                ),
                PlayPauseButton(iconSize: 30),
                _MiniNextButton(),
                SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniTime extends ConsumerWidget {
  const _MiniTime();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seconds = ref.watch(positionSecondsProvider);
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    return SizedBox(
      height: 16,
      child: Text(
        duration > Duration.zero
            ? '${formatClock(Duration(seconds: seconds))} / ${formatClock(duration)}'
            : '',
        style: const TextStyle(
          color: PlayerLayout.mutedText,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        maxLines: 1,
      ),
    );
  }
}

class _MiniNextButton extends ConsumerWidget {
  const _MiniNextButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapter = ref.watch(isChapterItemProvider);
    return IconButton(
      icon: const Icon(Icons.skip_next_rounded, size: 28),
      color: Colors.white,
      tooltip: chapter ? 'Next chapter' : 'Next',
      onPressed: () => ref.read(playbackServiceProvider).next(),
    );
  }
}
