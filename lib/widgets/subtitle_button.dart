import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' show SubtitleTrack;

import '../providers/playback_providers.dart';

class SubtitleButton extends ConsumerStatefulWidget {
  const SubtitleButton({super.key, this.onOpened, this.onClosed});

  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  @override
  ConsumerState<SubtitleButton> createState() => _SubtitleButtonState();
}

class _SubtitleButtonState extends ConsumerState<SubtitleButton> {
  int? _menuTrackId;

  @override
  Widget build(BuildContext context) {
    final tracks =
        (ref.watch(subtitleTracksProvider).valueOrNull ?? [])
            .where((track) => track.id != 'auto' && track.id != 'no')
            .toList();
    final selected = ref.watch(selectedSubtitleTrackProvider).valueOrNull;
    final currentTrackId = ref.watch(currentTrackProvider).valueOrNull?.id;
    final active = tracks.isNotEmpty && selected != null && selected.id != 'no';

    return PopupMenuButton<SubtitleTrack>(
      tooltip: 'Subtitles',
      icon: Icon(
        active ? Icons.closed_caption : Icons.closed_caption_outlined,
        color: active ? const Color(0xFF2196F3) : Colors.white,
      ),
      onOpened: () {
        _menuTrackId = currentTrackId;
        widget.onOpened?.call();
      },
      onCanceled: widget.onClosed,
      onSelected: (track) async {
        widget.onClosed?.call();
        // A video can finish while the menu is open. Its track IDs must not
        // accidentally select an unrelated language in the next video.
        if (ref.read(currentTrackProvider).valueOrNull?.id != _menuTrackId) {
          return;
        }
        try {
          await ref.read(playbackServiceProvider).setSubtitleTrack(track);
        } catch (error) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not change subtitles: $error')),
          );
        }
      },
      itemBuilder:
          (_) => [
            CheckedPopupMenuItem(
              value: SubtitleTrack.no(),
              checked: selected?.id == 'no',
              child: const Text('Off'),
            ),
            CheckedPopupMenuItem(
              value: SubtitleTrack.auto(),
              checked: selected?.id == 'auto',
              enabled: tracks.isNotEmpty,
              child: const Text('Automatic'),
            ),
            if (tracks.isEmpty)
              const PopupMenuItem<SubtitleTrack>(
                enabled: false,
                child: Text('No subtitles available'),
              ),
            for (final track in tracks)
              CheckedPopupMenuItem(
                value: track,
                checked: selected == track,
                child: Text(_label(track)),
              ),
          ],
    );
  }

  String _label(SubtitleTrack track) {
    final title = track.title?.trim();
    final language = track.language?.trim();
    if (title != null && title.isNotEmpty) {
      return language != null && language.isNotEmpty && language != title
          ? '$title ($language)'
          : title;
    }
    return language != null && language.isNotEmpty
        ? language
        : 'Subtitle ${track.id}';
  }
}
