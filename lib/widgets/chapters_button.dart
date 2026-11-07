import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pages/chapters_page.dart';
import '../player/player_widgets.dart';
import '../providers/playback_providers.dart';

/// Opens the chapter list (and chapter editor) of the playing track.
///
/// The player lives above the page navigator, so this pushes onto the app's
/// root navigator: the chapters page covers the player, and back returns to
/// the player as it was.
class ChaptersButton extends ConsumerWidget {
  final bool showLabel;
  final Color inactiveColor;
  final double iconSize;
  final VoidCallback? onAction;

  const ChaptersButton({
    super.key,
    this.showLabel = false,
    this.inactiveColor = Colors.white70,
    this.iconSize = 24,
    this.onAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).valueOrNull;
    return PlayerActionButton(
      icon: Icons.format_list_bulleted_rounded,
      label: 'Chapters',
      tooltip: 'Chapters',
      showLabel: showLabel,
      inactiveColor: inactiveColor,
      iconSize: iconSize,
      onPressed:
          track == null
              ? null
              : () {
                onAction?.call();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ChaptersPage(track: track),
                  ),
                );
              },
    );
  }
}
