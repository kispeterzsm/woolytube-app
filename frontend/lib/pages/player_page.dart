import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../widgets/player_controls.dart';

class PlayerPage extends ConsumerWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;
    final isVideo = ref.watch(isVideoContentProvider).valueOrNull ?? false;
    final playbackService = ref.watch(playbackServiceProvider);
    final currentPlaylist = ref.watch(currentPlaylistProvider).valueOrNull;

    if (currentTrack == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Text(
            'Nothing playing',
            style: TextStyle(color: Color(0xFF888888)),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down, size: 30),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          currentPlaylist?.name ?? 'Now Playing',
          style: const TextStyle(fontSize: 14, color: Color(0xFF888888)),
        ),
        centerTitle: true,
        actions: [
          // Audio-only toggle for video files
          if (isVideo || playbackService.audioOnlyMode)
            IconButton(
              icon: Icon(
                playbackService.audioOnlyMode
                    ? Icons.videocam_off
                    : Icons.videocam,
                color: playbackService.audioOnlyMode
                    ? const Color(0xFF888888)
                    : const Color(0xFF2196F3),
              ),
              onPressed: playbackService.toggleAudioOnlyMode,
              tooltip: playbackService.audioOnlyMode
                  ? 'Show video'
                  : 'Audio only',
            ),
        ],
      ),
      body: SafeArea(
        child: isVideo ? _buildVideoLayout(ref) : _buildAudioLayout(ref, currentTrack),
      ),
    );
  }

  Widget _buildVideoLayout(WidgetRef ref) {
    final playbackService = ref.watch(playbackServiceProvider);
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;

    return Column(
      children: [
        // Video
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Video(
                controller: playbackService.videoController,
              ),
            ),
          ),
        ),
        // Track title
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            currentTrack?.title ?? '',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
        // Seek bar
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: SeekBar(),
        ),
        // Controls
        const Padding(
          padding: EdgeInsets.only(bottom: 24),
          child: PlayerControls(showShuffleAutoplay: true),
        ),
      ],
    );
  }

  /// Get thumbnail URL with YouTube fallback from video ID
  String? _thumbnailUrl(Track track) {
    if (track.thumbnailUrl != null && track.thumbnailUrl!.isNotEmpty) {
      return track.thumbnailUrl;
    }
    if (track.videoId.isNotEmpty) {
      return 'https://i.ytimg.com/vi/${track.videoId}/hqdefault.jpg';
    }
    return null;
  }

  Widget _buildAudioLayout(WidgetRef ref, Track currentTrack) {
    return Column(
      children: [
        const Spacer(flex: 1),
        // Large thumbnail
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _buildLargeThumbnail(_thumbnailUrl(currentTrack)),
            ),
          ),
        ),
        const SizedBox(height: 32),
        // Track title
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            currentTrack.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        // Playlist name
        Consumer(builder: (context, ref, _) {
          final playlist = ref.watch(currentPlaylistProvider).valueOrNull;
          return Text(
            playlist?.name ?? '',
            style: const TextStyle(color: Color(0xFF888888), fontSize: 14),
          );
        }),
        const Spacer(flex: 1),
        // Seek bar
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: SeekBar(),
        ),
        const SizedBox(height: 8),
        // Controls
        const PlayerControls(showShuffleAutoplay: true),
        const Spacer(flex: 1),
      ],
    );
  }

  Widget _buildLargeThumbnail(String? url) {
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(color: const Color(0xFF2A2A2A)),
        errorWidget: (_, __, ___) => _largePlaceholder(),
      );
    }
    return _largePlaceholder();
  }

  Widget _largePlaceholder() {
    return Container(
      color: const Color(0xFF2A2A2A),
      child: const Center(
        child: Icon(Icons.music_note, color: Color(0xFF444444), size: 80),
      ),
    );
  }
}
