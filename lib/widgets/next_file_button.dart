import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/playback_providers.dart';
import '../services/chapters.dart';

class NextFileButton extends ConsumerWidget {
  final double iconSize;
  final VoidCallback? onAction;
  const NextFileButton({super.key, this.iconSize = 32, this.onAction});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).valueOrNull;
    if (ChapterData.decode(track?.chaptersJson).active.isEmpty) {
      return const SizedBox.shrink();
    }
    // The global mini-player sits outside the Navigator's tooltip overlay.
    final hasOverlay = Overlay.maybeOf(context) != null;
    return Semantics(
      label: hasOverlay ? null : 'Next file',
      child: IconButton(
        tooltip: hasOverlay ? 'Next file' : null,
        icon: Icon(Icons.fast_forward, size: iconSize),
        color: Colors.white,
        onPressed: () {
          ref.read(playbackServiceProvider).nextFile();
          onAction?.call();
        },
      ),
    );
  }
}
