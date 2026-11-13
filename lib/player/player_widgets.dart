import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/media_thumbnail_service.dart';
import 'player_layout.dart';

/// Builds the surface that shows the playing video. Overridden in widget
/// tests, where no native player exists.
final playerVideoSurfaceProvider = Provider<Widget Function(BoxFit fit)>((ref) {
  final service = ref.watch(playbackServiceProvider);
  return (fit) => Video(
    controller: service.videoController,
    controls: noVideoControls,
    pauseUponEnteringBackgroundMode: false,
    fit: fit,
  );
});

/// Video widget controls callback that draws nothing.
Widget noVideoControls(VideoState state) => const SizedBox.shrink();

/// Thumbnail of a track: the downloaded file when it can be read, otherwise
/// the remote thumbnail, otherwise a music-note placeholder.
///
/// The local file is not checked with a synchronous `existsSync()`; a missing
/// file simply fails to load and falls back. Images are decoded at
/// [decodeWidth] logical pixels instead of the full 1280 px thumbnail.
class TrackArtwork extends StatelessWidget {
  final String? thumbnailPath;
  final String? thumbnailUrl;
  final String? videoId;
  final double decodeWidth;

  const TrackArtwork({
    super.key,
    required this.thumbnailPath,
    required this.thumbnailUrl,
    required this.videoId,
    required this.decodeWidth,
  });

  TrackArtwork.forTrack(Track track, {Key? key, required double decodeWidth})
    : this(
        key: key,
        thumbnailPath: track.thumbnailPath,
        thumbnailUrl: track.thumbnailUrl,
        videoId: track.videoId,
        decodeWidth: decodeWidth,
      );

  @override
  Widget build(BuildContext context) {
    final cacheWidth =
        (decodeWidth * MediaQuery.devicePixelRatioOf(context)).round();
    const placeholder = ArtworkPlaceholder();
    final url = resolveRemoteThumbnailUrl(
      thumbnailUrl: thumbnailUrl,
      youtubeVideoId: videoId,
    );
    final remote =
        url == null
            ? placeholder
            : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              memCacheWidth: cacheWidth,
              fadeInDuration: const Duration(milliseconds: 150),
              placeholder: (_, __) => placeholder,
              errorWidget: (_, __, ___) => placeholder,
            );
    final path = thumbnailPath;
    if (path == null || path.isEmpty) return remote;
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => remote,
    );
  }
}

class ArtworkPlaceholder extends StatelessWidget {
  const ArtworkPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF333333),
      child: Center(
        child: Icon(Icons.music_note, color: Color(0xFF5A5A5A), size: 24),
      ),
    );
  }
}

/// Play / pause button. Rebuilds only when the playing state changes.
class PlayPauseButton extends ConsumerWidget {
  final double iconSize;
  final bool filled;
  final Color color;

  const PlayPauseButton({
    super.key,
    this.iconSize = 28,
    this.filled = false,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final service = ref.read(playbackServiceProvider);
    final icon = Icon(
      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
      size: iconSize,
    );
    final tooltip = isPlaying ? 'Pause' : 'Play';
    if (!filled) {
      return IconButton(
        icon: icon,
        color: color,
        tooltip: tooltip,
        onPressed: service.togglePlayPause,
      );
    }
    return IconButton(
      icon: icon,
      color: Colors.black,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        fixedSize: Size.square(iconSize + 28),
        backgroundColor: Colors.white,
        shape: const CircleBorder(),
      ),
      onPressed: service.togglePlayPause,
    );
  }
}

/// A labelled player action: an icon with a short caption under it, or a
/// plain icon button when [showLabel] is false. Toggles show their state with
/// the accent colour and expose it to screen readers.
class PlayerActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool? toggled;
  final bool showLabel;
  final Color activeColor;
  final Color inactiveColor;
  final double iconSize;

  /// Drawn over the icon's top-right corner, such as a count or a dot.
  final Widget? badge;

  const PlayerActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.toggled,
    this.showLabel = true,
    this.activeColor = PlayerLayout.activeToggle,
    this.inactiveColor = Colors.white70,
    this.iconSize = 24,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final active = toggled ?? false;
    final enabled = onPressed != null;
    final color =
        !enabled
            ? inactiveColor.withValues(alpha: 0.35)
            : active
            ? activeColor
            : inactiveColor;
    Widget iconWidget = Icon(icon, size: iconSize, color: color);
    if (badge != null) {
      iconWidget = Stack(
        clipBehavior: Clip.none,
        children: [iconWidget, Positioned(top: -4, right: -8, child: badge!)],
      );
    }
    if (!showLabel) {
      return Semantics(
        toggled: toggled,
        child: IconButton(
          icon: iconWidget,
          color: color,
          tooltip: tooltip,
          onPressed: onPressed,
        ),
      );
    }
    return Semantics(
      button: true,
      toggled: toggled,
      enabled: enabled,
      label: tooltip,
      excludeSemantics: true,
      onTap: onPressed,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: InkResponse(
          onTap: onPressed,
          radius: 32,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  iconWidget,
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 'Track 12 of 600' for the current track within its playlist, in the
/// order the playlist page shows. Hidden when the track is not part of the
/// playing playlist.
class PlaylistPositionCaption extends ConsumerWidget {
  final TextStyle style;

  const PlaylistPositionCaption({super.key, required this.style});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackId = ref.watch(
      currentTrackProvider.select((value) => value.valueOrNull?.id),
    );
    final playlistId = ref.watch(
      currentPlaylistProvider.select((value) => value.valueOrNull?.id),
    );
    if (trackId == null || playlistId == null) return const SizedBox.shrink();
    final position = ref.watch(
      tracksProvider(playlistId).select((value) {
        final tracks = value.valueOrNull;
        if (tracks == null) return null;
        final index = tracks.indexWhere((track) => track.id == trackId);
        return index < 0 ? null : (index + 1, tracks.length);
      }),
    );
    if (position == null) return const SizedBox.shrink();
    return Text(
      'Track ${position.$1} of ${position.$2}',
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Seeks by [delta] from the exact current position, clamped to the track.
/// The end is only clamped once the duration is known, so a forward seek
/// while a file is still loading does not jump back to 0:00.
void seekPlaybackBy(WidgetRef ref, Duration delta) {
  final service = ref.read(playbackServiceProvider);
  final duration = service.duration;
  var target = service.position + delta;
  if (target < Duration.zero) target = Duration.zero;
  if (duration > Duration.zero && target > duration) target = duration;
  service.seekTo(target);
}
