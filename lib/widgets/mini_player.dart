import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../providers/playback_providers.dart';
import '../pages/player_page.dart';
import 'sponsorblock_progress_bar.dart';
import '../services/media_thumbnail_service.dart';

class MiniPlayerBar extends ConsumerStatefulWidget {
  final VoidCallback? onOpenPlayer;

  const MiniPlayerBar({super.key, this.onOpenPlayer});

  @override
  ConsumerState<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends ConsumerState<MiniPlayerBar> {
  @override
  void initState() {
    super.initState();
    videoFullscreenNotifier.addListener(_onFullscreenChanged);
  }

  @override
  void dispose() {
    videoFullscreenNotifier.removeListener(_onFullscreenChanged);
    super.dispose();
  }

  void _onFullscreenChanged() {
    // Route teardown may flip the notifier while Flutter is finishing a
    // frame. Defer to the next event-loop turn so setState schedules a fresh
    // frame instead of being coalesced into the frame that is already ending.
    Timer(const Duration(milliseconds: 1), () {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;
    if (currentTrack == null) return const SizedBox.shrink();
    if (videoFullscreenNotifier.value) return const SizedBox.shrink();
    return _buildBar(context, ref, currentTrack);
  }

  Widget _buildBar(BuildContext context, WidgetRef ref, dynamic currentTrack) {
    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final sponsorBlockSegments =
        ref.watch(playbackSponsorBlockSegmentsProvider).valueOrNull ?? const [];
    final isVideo = ref.watch(isVideoContentProvider).valueOrNull ?? false;
    final playbackService = ref.watch(playbackServiceProvider);

    final progress =
        duration.inMilliseconds > 0
            ? position.inMilliseconds / duration.inMilliseconds
            : 0.0;

    return GestureDetector(
      onTap: _openPlayer,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF2A2A2A),
          border: Border(top: BorderSide(color: Color(0xFF333333), width: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedProgressBar(
              progress: progress,
              durationMs: duration.inMilliseconds,
              segments: sponsorBlockSegments,
              height: 2,
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
                      child:
                          isVideo
                              ? Video(
                                controller: playbackService.videoController,
                                controls: noVideoControls,
                                pauseUponEnteringBackgroundMode: false,
                              )
                              : _buildThumbnail(currentTrack),
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

  void _openPlayer() {
    final openPlayer = widget.onOpenPlayer;
    if (openPlayer != null) {
      openPlayer();
      return;
    }

    Navigator.maybeOf(context)?.push(playerPageRoute());
  }

  Widget _buildThumbnail(dynamic track) {
    final url = resolveRemoteThumbnailUrl(
      thumbnailUrl: track.thumbnailUrl as String?,
      youtubeVideoId: track.videoId as String?,
    );
    final fallback =
        url != null && url.isNotEmpty
            ? CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: const Color(0xFF333333)),
              errorWidget: (_, __, ___) => _placeholderIcon(),
            )
            : _placeholderIcon();
    final path = existingThumbnailPath(track.thumbnailPath as String?);
    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      );
    }
    return fallback;
  }

  Widget _placeholderIcon() {
    return Container(
      color: const Color(0xFF333333),
      child: const Icon(Icons.music_note, color: Color(0xFF555555), size: 24),
    );
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
Widget noVideoControls(VideoState state) => const SizedBox.shrink();
