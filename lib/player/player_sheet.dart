import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../services/playback_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/sponsorblock_progress_bar.dart';
import 'audio_panel.dart';
import 'player_layout.dart';
import 'player_shell.dart';
import 'player_widgets.dart';
import 'video_view.dart';

/// The persistent player: one widget that is the mini bar when collapsed and
/// grows into the expanded audio panel (or full-screen video) as
/// [PlayerShellState.expansion] goes from 0 to 1.
///
/// The thumbnail, the title and the progress line are shared elements: they
/// are positioned on every animation frame by interpolating between their
/// mini-bar and expanded rectangles, so the bar visibly turns into the panel.
/// Everything else cross-fades. The children are built once and only
/// re-positioned per frame; nothing here rebuilds on position updates.
class PlayerSheet extends ConsumerStatefulWidget {
  final PlayerShellState shell;
  final PlayerGeometry geometry;

  /// Whether the current content is video. Comes from the shell so the sheet
  /// and the shell's auto-open logic never disagree for a frame.
  final bool video;

  const PlayerSheet({
    super.key,
    required this.shell,
    required this.geometry,
    required this.video,
  });

  @override
  ConsumerState<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends ConsumerState<PlayerSheet> {
  late final PlayerShellState _shell = widget.shell;
  late final CurvedAnimation _sliderOpacity = CurvedAnimation(
    parent: _shell.expansion,
    curve: const Interval(0.9, 1),
  );
  late final Listenable _animations = Listenable.merge([
    _shell.expansion,
    _shell.videoness,
    _shell.presence,
    _shell.dismissal,
    _shell.fitMode,
  ]);

  late final Widget _mini = MiniPlayerBar(
    onOpen: _shell.expand,
    onStop: _shell.stopPlayback,
    onDragStart: _onDragStart,
    onDragUpdate: _onDragUpdate,
    onDragEnd: _onDragEnd,
  );
  late final Widget _audioPanel = AudioPanel(
    sliderOpacity: _sliderOpacity,
    onCollapse: _shell.collapse,
    onStop: _shell.stopPlayback,
    onDragStart: _onDragStart,
    onDragUpdate: _onDragUpdate,
    onDragEnd: _onDragEnd,
  );
  late final Widget _videoView = VideoView(
    fitMode: _shell.fitMode,
    locked: _shell.videoLocked,
    onCollapse: _shell.collapse,
  );

  /// The last track shown, kept while the bar slides away after playback
  /// stopped.
  Track? _track;
  Widget? _artwork;
  String? _artworkKey;

  @override
  void dispose() {
    _sliderOpacity.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) => _shell.beginDrag();

  void _onDragUpdate(DragUpdateDetails details) =>
      _shell.updateDrag(details.primaryDelta ?? details.delta.dy);

  void _onDragEnd(DragEndDetails details) =>
      _shell.endDrag(details.primaryVelocity ?? 0);

  Widget _artworkFor(Track track) {
    final key =
        '${track.id}|${track.thumbnailPath}|${track.thumbnailUrl}|${track.videoId}';
    if (_artwork == null || _artworkKey != key) {
      _artworkKey = key;
      _artwork = TrackArtwork.forTrack(
        track,
        decodeWidth: PlayerLayout.panelArt.width,
      );
    }
    return _artwork!;
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(currentTrackProvider).valueOrNull;
    if (current != null) _track = current;
    final track = _track;
    if (track == null) return const SizedBox.shrink();

    final video = widget.video;
    final aspect =
        video ? ref.watch(videoAspectProvider).valueOrNull ?? 16 / 9 : 16 / 9;
    final media =
        video
            ? ref.watch(playerVideoSurfaceProvider)(BoxFit.contain)
            : _artworkFor(track);
    final title = _SheetTitle(title: track.title);

    return AnimatedBuilder(
      animation: _animations,
      builder:
          (context, _) => _buildLayers(
            title: title,
            media: media,
            video: video,
            aspect: aspect,
          ),
    );
  }

  Widget _buildLayers({
    required Widget title,
    required Widget media,
    required bool video,
    required double aspect,
  }) {
    final g = widget.geometry;
    final height = g.size.height;
    final t = _shell.expansion.value;
    final v = _shell.videoness.value;
    final p = _shell.presence.value;
    final d = _shell.dismissal.value;

    final sheetHeight = g.sheetHeight(t, v);
    final top =
        height - sheetHeight + (1 - p) * g.miniHeight + d * g.miniHeight;

    final miniOpacity = 1 - intervalOf(t, 0, 0.35);
    final panelOpacity = intervalOf(t, 0.35, 1) * (1 - v);
    final videoOpacity = intervalOf(t, 0.75, 1) * v;
    final dismissOpacity = 1 - d * 0.6;

    final background =
        Color.lerp(
          Color.lerp(
            PlayerLayout.miniBackground,
            PlayerLayout.panelBackground,
            intervalOf(t, 0, 0.6),
          ),
          Colors.black,
          v * intervalOf(t, 0, 0.5),
        )!;
    final cornerRadius = 16 * intervalOf(t, 0, 0.3) * (1 - v * t);

    // Shared element: artwork or video.
    final fullScreen = Offset.zero & g.size;
    final expandedMediaRect = Rect.lerp(PlayerLayout.panelArt, fullScreen, v)!;
    final mediaRect = Rect.lerp(PlayerLayout.miniThumb, expandedMediaRect, t)!;
    final mediaRadius = lerpDouble(6, 8 * (1 - v), t)!;
    Widget mediaChild = media;
    if (video) {
      final mode = _shell.fitMode.value;
      final miniVideo = fitVideoRect(
        PlayerLayout.miniThumb,
        aspect,
        cover: true,
      );
      var fullVideo = fitVideoRect(
        fullScreen,
        aspect,
        cover: mode == VideoFitMode.fill,
      );
      if (mode == VideoFitMode.zoom) {
        fullVideo = Rect.fromCenter(
          center: fullVideo.center,
          width: fullVideo.width * 1.5,
          height: fullVideo.height * 1.5,
        );
      }
      final panelVideo = fitVideoRect(
        PlayerLayout.panelArt,
        aspect,
        cover: true,
      );
      final videoRect =
          Rect.lerp(miniVideo, Rect.lerp(panelVideo, fullVideo, v)!, t)!;
      mediaChild = ColoredBox(
        color: Colors.black,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fromRect(
              rect: videoRect.shift(-mediaRect.topLeft),
              child: media,
            ),
          ],
        ),
      );
    }

    // Shared element: title.
    final titleTarget =
        Offset.lerp(
          const Offset(PlayerLayout.panelTitleLeft, PlayerLayout.panelTitleTop),
          Offset(60, g.topInset + 12),
          v,
        )!;
    final titleOffset =
        Offset.lerp(
          const Offset(PlayerLayout.miniTitleLeft, PlayerLayout.miniTitleTop),
          titleTarget,
          t,
        )!;
    final titleScale =
        lerpDouble(
          1,
          PlayerLayout.panelTitleFontSize / PlayerLayout.miniTitleFontSize,
          t * (1 - v),
        )!;
    final titleOpacity = 1 - intervalOf(t, 0, 0.6);

    // Shared element: progress line → seek bar track.
    final progressRect = Rect.lerp(g.miniProgressLine, g.seekTrack, t)!;
    final progressOpacity =
        (1 - intervalOf(t, 0.9, 1)) * (1 - v * intervalOf(t, 0, 0.3));

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // Background; it also keeps taps on the sheet away from the page.
        Positioned(
          key: const ValueKey('layer-background'),
          left: 0,
          right: 0,
          top: top,
          height: math.max(sheetHeight, height - top),
          child: AbsorbPointer(
            child: Opacity(
              opacity: dismissOpacity,
              child: DecoratedBox(
                key: const ValueKey('player-sheet-background'),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(cornerRadius),
                  ),
                  boxShadow:
                      t > 0 && v < 1
                          ? [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: 0.45 * intervalOf(t, 0, 0.3),
                              ),
                              blurRadius: 24,
                              offset: const Offset(0, -6),
                            ),
                          ]
                          : const [],
                ),
              ),
            ),
          ),
        ),
        Positioned.fromRect(
          key: const ValueKey('layer-media'),
          rect: mediaRect.shift(Offset(0, top)),
          child: IgnorePointer(
            child: Opacity(
              opacity: dismissOpacity,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(mediaRadius),
                child: mediaChild,
              ),
            ),
          ),
        ),
        if (t < 1)
          Positioned(
            key: const ValueKey('layer-mini'),
            left: 0,
            right: 0,
            top: top,
            height: PlayerLayout.miniHeight,
            child: IgnorePointer(
              ignoring: t > 0,
              child: Opacity(
                opacity: miniOpacity * dismissOpacity,
                child: _mini,
              ),
            ),
          ),
        if (t > 0 && v < 1)
          Positioned(
            key: const ValueKey('layer-panel'),
            left: 0,
            right: 0,
            top: top,
            height: g.panelHeight - g.bottomInset,
            child: IgnorePointer(
              ignoring: t < 1 && !_shell.isDragging,
              child: Opacity(
                opacity: panelOpacity,
                child: _ScrollIfNeeded(child: _audioPanel),
              ),
            ),
          ),
        if (video && t > 0 && v > 0)
          Positioned(
            key: const ValueKey('layer-video'),
            left: 0,
            right: 0,
            top: top,
            height: sheetHeight,
            child: IgnorePointer(
              ignoring: t < 1 || v < 1,
              child: Opacity(opacity: videoOpacity, child: _videoView),
            ),
          ),
        if (t < 1)
          Positioned(
            key: const ValueKey('layer-title'),
            left: titleOffset.dx,
            top: top + titleOffset.dy,
            width: g.miniTitleWidth,
            child: IgnorePointer(
              child: Opacity(
                opacity: titleOpacity * dismissOpacity,
                child: Transform.scale(
                  scale: titleScale,
                  alignment: Alignment.topLeft,
                  child: title,
                ),
              ),
            ),
          ),
        if (t < 1 && progressOpacity > 0)
          Positioned.fromRect(
            key: const ValueKey('layer-progress'),
            rect: progressRect.shift(Offset(0, top)),
            child: IgnorePointer(
              child: Opacity(
                opacity: progressOpacity * dismissOpacity,
                child: _MorphingProgress(expansion: t),
              ),
            ),
          ),
      ],
    );
  }
}

class _SheetTitle extends StatelessWidget {
  final String title;

  const _SheetTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      key: const ValueKey('player-mini-title'),
      style: const TextStyle(
        color: Colors.white,
        fontSize: PlayerLayout.miniTitleFontSize,
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The mini bar's 2 dp progress line, which becomes the seek bar's track as
/// the panel opens.
class _MorphingProgress extends ConsumerWidget {
  final double expansion;

  const _MorphingProgress({required this.expansion});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final segments =
        ref.watch(playbackSponsorBlockSegmentsProvider).valueOrNull ??
        const <PlaybackSponsorBlockSegment>[];
    final progress =
        duration.inMilliseconds > 0
            ? position.inMilliseconds / duration.inMilliseconds
            : 0.0;
    return RepaintBoundary(
      child: CustomPaint(
        key: const ValueKey('player-progress-line'),
        painter: SegmentedProgressPainter(
          progress: progress.clamp(0.0, 1.0),
          durationMs: duration.inMilliseconds,
          segments: segments,
          backgroundColor:
              Color.lerp(
                PlayerLayout.miniTrackBackground,
                PlayerLayout.trackBackground,
                expansion,
              )!,
          progressColor: PlayerLayout.accent,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Lets the panel scroll when the screen is too short for it (landscape,
/// split screen). At its natural height it lays out exactly like a Column,
/// so the morph geometry still lines up.
class _ScrollIfNeeded extends StatelessWidget {
  final Widget child;

  const _ScrollIfNeeded({required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight >= PlayerLayout.panelContentHeight) {
          return Align(alignment: Alignment.topCenter, child: child);
        }
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: child,
        );
      },
    );
  }
}
