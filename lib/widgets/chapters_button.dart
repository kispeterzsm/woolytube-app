import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../pages/chapters_page.dart';
import '../providers/playback_providers.dart';

class ChaptersButton extends ConsumerWidget {
  const ChaptersButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).valueOrNull;
    return IconButton(
      tooltip: 'Chapters',
      icon: const Icon(Icons.list_alt),
      onPressed:
          track == null
              ? null
              : () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ChaptersPage(track: track)),
              ),
    );
  }
}
