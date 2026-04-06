import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../providers/playback_providers.dart';
import '../pages/player_page.dart';

class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;
    if (currentTrack == null) return const SizedBox.shrink();

    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final isVideo = ref.watch(isVideoContentProvider).valueOrNull ?? false;
    final playbackService = ref.watch(playbackServiceProvider);

    final progress =
        duration.inMilliseconds > 0
            ? position.inMilliseconds / duration.inMilliseconds
            : 0.0;

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PlayerPage()),
        );
      },
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF2A2A2A),
          border: Border(
            top: BorderSide(color: Color(0xFF333333), width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress bar
            LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 2,
              backgroundColor: const Color(0xFF333333),
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Color(0xFF2196F3)),
            ),
            // Content
            SizedBox(
              height: 62,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  // Thumbnail or video preview
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: isVideo
                          ? Video(
                              controller: playbackService.videoController,
                              controls: NoVideoControls,
                            )
                          : _buildThumbnail(_thumbnailUrl(currentTrack)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Title
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          currentTrack.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatDuration(position, duration),
                          style: const TextStyle(
                            color: Color(0xFF888888),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Controls
                  IconButton(
                    icon: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: playbackService.togglePlayPause,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.skip_next,
                      color: Colors.white,
                      size: 24,
                    ),
                    onPressed: () => playbackService.next(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40),
                  ),
                  // Close button
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Color(0xFF888888),
                      size: 20,
                    ),
                    onPressed: () => playbackService.stop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(String? url) {
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(color: const Color(0xFF333333)),
        errorWidget: (_, __, ___) => _placeholderIcon(),
      );
    }
    return _placeholderIcon();
  }

  Widget _placeholderIcon() {
    return Container(
      color: const Color(0xFF333333),
      child: const Icon(Icons.music_note, color: Color(0xFF555555), size: 24),
    );
  }

  /// Get thumbnail URL with YouTube fallback from video ID
  String? _thumbnailUrl(dynamic track) {
    if (track.thumbnailUrl != null && (track.thumbnailUrl as String).isNotEmpty) {
      return track.thumbnailUrl;
    }
    if (track.videoId != null && (track.videoId as String).isNotEmpty) {
      return 'https://i.ytimg.com/vi/${track.videoId}/hqdefault.jpg';
    }
    return null;
  }

  String _formatDuration(Duration pos, Duration dur) {
    if (dur == Duration.zero) return '';
    return '${_fmt(pos)} / ${_fmt(dur)}';
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

// No-controls callback for mini video preview
Widget NoVideoControls(VideoState state) => const SizedBox.shrink();
