import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/playback_providers.dart';

class PlayerControls extends ConsumerWidget {
  final bool showShuffleAutoplay;
  final double iconSize;

  const PlayerControls({
    super.key,
    this.showShuffleAutoplay = false,
    this.iconSize = 36,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final shuffleEnabled =
        ref.watch(shuffleEnabledProvider).valueOrNull ?? false;
    final autoplayEnabled =
        ref.watch(autoplayEnabledProvider).valueOrNull ?? true;
    final audioOnlyMode =
        ref.watch(audioOnlyModeProvider).valueOrNull ?? false;
    final currentPlaylist = ref.watch(currentPlaylistProvider).valueOrNull;
    final isVideoPlaylist = currentPlaylist?.audioOnly == false;
    final playbackService = ref.watch(playbackServiceProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showShuffleAutoplay)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isVideoPlaylist) ...[
                  IconButton(
                    icon: Icon(
                      audioOnlyMode ? Icons.videocam_off : Icons.videocam,
                      color: audioOnlyMode
                          ? const Color(0xFF2196F3)
                          : const Color(0xFF888888),
                      size: 22,
                    ),
                    onPressed: playbackService.toggleAudioOnlyMode,
                    tooltip: audioOnlyMode ? 'Audio only' : 'Play video',
                  ),
                  const SizedBox(width: 16),
                ],
                IconButton(
                  icon: Icon(
                    Icons.shuffle,
                    color: shuffleEnabled
                        ? const Color(0xFF2196F3)
                        : const Color(0xFF888888),
                    size: 22,
                  ),
                  onPressed: playbackService.toggleShuffle,
                ),
                const SizedBox(width: 16),
                IconButton(
                  icon: Icon(
                    Icons.playlist_play,
                    color: autoplayEnabled
                        ? const Color(0xFF2196F3)
                        : const Color(0xFF888888),
                    size: 26,
                  ),
                  onPressed: playbackService.toggleAutoplay,
                  tooltip: autoplayEnabled ? 'Autoplay on' : 'Autoplay off',
                ),
              ],
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: Icon(Icons.skip_previous, size: iconSize),
              color: Colors.white,
              onPressed: () => playbackService.previous(),
            ),
            const SizedBox(width: 16),
            IconButton(
              icon: Icon(
                isPlaying
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                size: iconSize + 16,
              ),
              color: Colors.white,
              onPressed: playbackService.togglePlayPause,
            ),
            const SizedBox(width: 16),
            IconButton(
              icon: Icon(Icons.skip_next, size: iconSize),
              color: Colors.white,
              onPressed: () => playbackService.next(),
            ),
          ],
        ),
      ],
    );
  }
}

class SeekBar extends ConsumerWidget {
  const SeekBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final playbackService = ref.watch(playbackServiceProvider);

    final positionMs = position.inMilliseconds.toDouble();
    final durationMs =
        duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: const Color(0xFF2196F3),
            inactiveTrackColor: const Color(0xFF444444),
            thumbColor: const Color(0xFF2196F3),
            overlayColor: const Color(0xFF2196F3).withValues(alpha: 0.2),
          ),
          child: Slider(
            value: positionMs.clamp(0, durationMs),
            max: durationMs,
            onChanged: (value) {
              playbackService.seekTo(Duration(milliseconds: value.toInt()));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(position),
                style:
                    const TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
              Text(
                _formatDuration(duration),
                style:
                    const TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
