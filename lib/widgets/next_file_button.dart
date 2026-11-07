import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_widgets.dart';
import '../providers/playback_providers.dart';

/// 'Next file': skips the remaining chapters of the current file.
///
/// Only shown while chapters are played as separate tracks; otherwise the
/// current item already is the whole file and 'Next' does the same thing.
class NextFileButton extends ConsumerWidget {
  final double iconSize;
  final bool showLabel;
  final Color inactiveColor;
  final VoidCallback? onAction;

  const NextFileButton({
    super.key,
    this.iconSize = 24,
    this.showLabel = true,
    this.inactiveColor = Colors.white70,
    this.onAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(isChapterItemProvider)) return const SizedBox.shrink();
    return PlayerActionButton(
      key: const ValueKey('next-file-button'),
      icon: Icons.last_page_rounded,
      label: 'Next file',
      tooltip: 'Next file (skip the remaining chapters)',
      showLabel: showLabel,
      inactiveColor: inactiveColor,
      iconSize: iconSize,
      onPressed: () {
        ref.read(playbackServiceProvider).nextFile();
        onAction?.call();
      },
    );
  }
}
