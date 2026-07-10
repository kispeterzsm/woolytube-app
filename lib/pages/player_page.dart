import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/lifecycle_provider.dart';
import '../widgets/player_controls.dart';
import '../widgets/segment_mark_button.dart';

class PlayerPage extends ConsumerWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;
    final isVideo = ref.watch(isVideoContentProvider).valueOrNull ?? false;

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

    if (isVideo) return const _VideoPlayerView();
    return _AudioPlayerView(track: currentTrack);
  }
}

Route<void> playerPageRoute() {
  return _PassthroughPlayerPageRoute();
}

/// A non-modal route so the audio player's unused screen area stays
/// interactive for the page underneath it.
class _PassthroughPlayerPageRoute extends PageRouteBuilder<void> {
  _PassthroughPlayerPageRoute()
    : super(
        opaque: false,
        pageBuilder: (_, __, ___) => const PlayerPage(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      );

  // PageRouteBuilder installs a full-screen ModalBarrier by default, including
  // when it is transparent. Remove it so the audio overlay can pass scrolling
  // and taps through outside its control panel.
  @override
  Widget buildModalBarrier() => const SizedBox.shrink();
}

// ─────────────────────────────────────────────────────────────────────────────
// Video — VLC-style full-screen player

class _VideoPlayerView extends ConsumerStatefulWidget {
  const _VideoPlayerView();

  @override
  ConsumerState<_VideoPlayerView> createState() => _VideoPlayerViewState();
}

enum _FitMode { fit, fill, zoom }

extension on _FitMode {
  String get label => switch (this) {
    _FitMode.fit => 'Fit',
    _FitMode.fill => 'Fill',
    _FitMode.zoom => 'Zoom',
  };
}

class _VideoPlayerViewState extends ConsumerState<_VideoPlayerView> {
  static const Duration _autoHideDelay = Duration(seconds: 3);

  bool _overlayVisible = true;
  bool _locked = false;
  _FitMode _fitMode = _FitMode.fit;

  Timer? _hideTimer;

  String? _modeLabel;
  Timer? _modeLabelTimer;

  String? _seekBadge;
  bool _seekBadgeIsLeft = false;
  Timer? _seekBadgeTimer;

  Offset _lastDoubleTapPos = Offset.zero;
  bool _pinchHandled = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    videoFullscreenNotifier.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scheduleAutoHide();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _modeLabelTimer?.cancel();
    _seekBadgeTimer?.cancel();
    // Restore status + nav bars to their normal layout (not edge-to-edge,
    // otherwise the global mini-player ends up behind the system nav bar).
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    // Lock back to portrait — the rest of the app is portrait-only and
    // simply allowing all orientations won't force a re-rotation if the
    // device is currently in landscape.
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    videoFullscreenNotifier.value = false;
    super.dispose();
  }

  void _applyOrientationFor(double? aspect) {
    if (aspect == null) return;
    if (aspect > 1.0) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  void _scheduleAutoHide() {
    _hideTimer?.cancel();
    final isPlaying = ref.read(isPlayingProvider).valueOrNull ?? false;
    if (!isPlaying) return;
    _hideTimer = Timer(_autoHideDelay, () {
      if (mounted) setState(() => _overlayVisible = false);
    });
  }

  void _bumpAutoHide() {
    if (_overlayVisible) _scheduleAutoHide();
  }

  void _toggleOverlay() {
    setState(() => _overlayVisible = !_overlayVisible);
    if (_overlayVisible) _scheduleAutoHide();
  }

  void _handleDoubleTap() {
    if (!mounted) return;
    final width = MediaQuery.of(context).size.width;
    final isLeft = _lastDoubleTapPos.dx < width / 2;
    final svc = ref.read(playbackServiceProvider);
    final pos = svc.position;
    final dur = svc.duration;
    if (isLeft) {
      final t = pos - const Duration(seconds: 10);
      svc.seekTo(t < Duration.zero ? Duration.zero : t);
      _flashSeekBadge('−10s', true);
    } else {
      final t = pos + const Duration(seconds: 10);
      svc.seekTo(t > dur ? dur : t);
      _flashSeekBadge('+10s', false);
    }
  }

  void _flashSeekBadge(String text, bool isLeft) {
    setState(() {
      _seekBadge = text;
      _seekBadgeIsLeft = isLeft;
    });
    _seekBadgeTimer?.cancel();
    _seekBadgeTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _seekBadge = null);
    });
  }

  void _onScaleStart(ScaleStartDetails _) {
    _pinchHandled = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_pinchHandled) return;
    if (details.pointerCount < 2) return;
    if (details.scale > 1.2 || details.scale < 0.8) {
      _pinchHandled = true;
      _cycleFitMode();
    }
  }

  void _cycleFitMode() {
    setState(() {
      _fitMode = _FitMode.values[(_fitMode.index + 1) % _FitMode.values.length];
      _modeLabel = _fitMode.label;
    });
    _modeLabelTimer?.cancel();
    _modeLabelTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _modeLabel = null);
    });
  }

  Widget _buildVideo(double? aspect, bool foregrounded) {
    if (!foregrounded) return Container(color: Colors.black);

    final svc = ref.read(playbackServiceProvider);
    final effectiveAspect = aspect ?? 16 / 9;

    if (_fitMode == _FitMode.fill) {
      return Video(
        controller: svc.videoController,
        controls: _noVideoControls,
        fit: BoxFit.cover,
      );
    }

    Widget v = Center(
      child: AspectRatio(
        aspectRatio: effectiveAspect,
        child: Video(
          controller: svc.videoController,
          controls: _noVideoControls,
          fit: BoxFit.contain,
        ),
      ),
    );
    if (_fitMode == _FitMode.zoom) {
      v = Transform.scale(scale: 1.5, child: v);
    }
    return v;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<double?>>(videoAspectProvider, (_, next) {
      _applyOrientationFor(next.valueOrNull);
    });
    ref.listen<AsyncValue<bool>>(isPlayingProvider, (_, next) {
      if (next.valueOrNull == true) {
        if (_overlayVisible) _scheduleAutoHide();
      } else {
        _hideTimer?.cancel();
        if (!_overlayVisible) setState(() => _overlayVisible = true);
      }
    });

    final aspect = ref.watch(videoAspectProvider).valueOrNull;
    final foregrounded = ref.watch(isAppForegroundedProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildVideo(aspect, foregrounded),

          // Gesture layer
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _locked ? null : _toggleOverlay,
              onDoubleTapDown:
                  _locked ? null : (d) => _lastDoubleTapPos = d.localPosition,
              onDoubleTap: _locked ? null : _handleDoubleTap,
              onScaleStart: _locked ? null : _onScaleStart,
              onScaleUpdate: _locked ? null : _onScaleUpdate,
            ),
          ),

          // Seek badge (left or right half)
          if (_seekBadge != null)
            Positioned.fill(
              child: Align(
                alignment:
                    _seekBadgeIsLeft
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: _SeekBadge(text: _seekBadge!),
                ),
              ),
            ),

          // Fit mode label
          if (_modeLabel != null)
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              child: Center(child: _PillLabel(text: _modeLabel!)),
            ),

          // Overlay
          IgnorePointer(
            ignoring: !_overlayVisible || _locked,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: (_overlayVisible && !_locked) ? 1.0 : 0.0,
              child: _VideoOverlay(
                fitMode: _fitMode,
                onLock: () {
                  setState(() {
                    _locked = true;
                    _overlayVisible = false;
                  });
                  _hideTimer?.cancel();
                },
                onCycleFit: () {
                  _cycleFitMode();
                  _bumpAutoHide();
                },
                onAnyAction: _bumpAutoHide,
              ),
            ),
          ),

          // Locked: small unlock button
          if (_locked)
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: Center(
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.lock, color: Colors.white),
                    onPressed:
                        () => setState(() {
                          _locked = false;
                          _overlayVisible = true;
                          _scheduleAutoHide();
                        }),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Overlay (top / center / bottom chrome over the video)

class _VideoOverlay extends ConsumerWidget {
  final _FitMode fitMode;
  final VoidCallback onLock;
  final VoidCallback onCycleFit;
  final VoidCallback onAnyAction;

  const _VideoOverlay({
    required this.fitMode,
    required this.onLock,
    required this.onCycleFit,
    required this.onAnyAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).valueOrNull;
    final playlist = ref.watch(currentPlaylistProvider).valueOrNull;
    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final shuffleEnabled =
        ref.watch(shuffleEnabledProvider).valueOrNull ?? false;
    final autoplayEnabled =
        ref.watch(autoplayEnabledProvider).valueOrNull ?? true;
    final svc = ref.watch(playbackServiceProvider);

    return Column(
      children: [
        // Top bar
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 24),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track?.title ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (playlist?.name != null && playlist!.name.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              playlist.name,
                              style: const TextStyle(
                                color: Color(0xFFBBBBBB),
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.lock_open, color: Colors.white),
                    tooltip: 'Lock',
                    onPressed: onLock,
                  ),
                ],
              ),
            ),
          ),
        ),

        // Center play controls
        Expanded(
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 44,
                  color: Colors.white,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () {
                    svc.previous();
                    onAnyAction();
                  },
                ),
                const SizedBox(width: 24),
                IconButton(
                  iconSize: 80,
                  color: Colors.white,
                  icon: Icon(
                    isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                  ),
                  onPressed: () {
                    svc.togglePlayPause();
                    onAnyAction();
                  },
                ),
                const SizedBox(width: 24),
                IconButton(
                  iconSize: 44,
                  color: Colors.white,
                  icon: const Icon(Icons.skip_next),
                  onPressed: () {
                    svc.next();
                    onAnyAction();
                  },
                ),
              ],
            ),
          ),
        ),

        // Bottom bar
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SeekBar(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.shuffle,
                            color:
                                shuffleEnabled
                                    ? const Color(0xFF2196F3)
                                    : Colors.white,
                            size: 22,
                          ),
                          onPressed: () {
                            svc.toggleShuffle();
                            onAnyAction();
                          },
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.playlist_play,
                            color:
                                autoplayEnabled
                                    ? const Color(0xFF2196F3)
                                    : Colors.white,
                            size: 26,
                          ),
                          tooltip:
                              autoplayEnabled ? 'Autoplay on' : 'Autoplay off',
                          onPressed: () {
                            svc.toggleAutoplay();
                            onAnyAction();
                          },
                        ),
                        SegmentMarkButton(
                          inactiveColor: Colors.white,
                          onAction: onAnyAction,
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.videocam_off,
                            color: Colors.white,
                            size: 22,
                          ),
                          tooltip: 'Audio only',
                          onPressed: () {
                            svc.toggleAudioOnlyMode();
                            onAnyAction();
                          },
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.aspect_ratio,
                            color: Colors.white,
                            size: 22,
                          ),
                          tooltip: 'Aspect: ${fitMode.label}',
                          onPressed: onCycleFit,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SeekBadge extends StatelessWidget {
  final String text;
  const _SeekBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PillLabel extends StatelessWidget {
  final String text;
  const _PillLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

Widget _noVideoControls(VideoState state) => const SizedBox.shrink();

// ─────────────────────────────────────────────────────────────────────────────
// Audio — expanded VLC-style player

class _AudioPlayerView extends ConsumerStatefulWidget {
  final Track track;
  const _AudioPlayerView({required this.track});

  @override
  ConsumerState<_AudioPlayerView> createState() => _AudioPlayerViewState();
}

class _AudioPlayerViewState extends ConsumerState<_AudioPlayerView> {
  final _controlPanelKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    videoFullscreenNotifier.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateOverlayHeight();
    });
  }

  @override
  void dispose() {
    audioPlayerOverlayHeightNotifier.value = 0;
    videoFullscreenNotifier.value = false;
    super.dispose();
  }

  bool _onControlPanelSizeChanged(SizeChangedLayoutNotification _) {
    // SizeChangedLayoutNotification is sent during layout. Read the final
    // dimensions after that frame rather than observing a previous size.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateOverlayHeight();
    });
    return false;
  }

  void _updateOverlayHeight() {
    if (!mounted) return;
    // Include the system gesture/navigation area because this route is drawn
    // edge-to-edge over the page below it.
    final panelHeight = _controlPanelKey.currentContext?.size?.height;
    if (panelHeight != null) {
      final overlayHeight =
          panelHeight + MediaQuery.viewPaddingOf(context).bottom;
      if (audioPlayerOverlayHeightNotifier.value != overlayHeight) {
        audioPlayerOverlayHeightNotifier.value = overlayHeight;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPlaylist = ref.watch(currentPlaylistProvider).valueOrNull;
    final queue = ref.watch(queueProvider).valueOrNull ?? const <Track>[];
    final queueIndex = ref.watch(queueIndexProvider).valueOrNull ?? 0;
    final clampedQueueIndex =
        queue.isEmpty ? 0 : queueIndex.clamp(0, queue.length - 1).toInt();
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final shuffleEnabled =
        ref.watch(shuffleEnabledProvider).valueOrNull ?? false;
    final autoplayEnabled =
        ref.watch(autoplayEnabledProvider).valueOrNull ?? true;
    final audioOnlyMode = ref.watch(audioOnlyModeProvider).valueOrNull ?? false;
    final isVideoPlaylist = currentPlaylist?.audioOnly == false;
    final playbackService = ref.watch(playbackServiceProvider);

    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: NotificationListener<SizeChangedLayoutNotification>(
              onNotification: _onControlPanelSizeChanged,
              child: SizeChangedLayoutNotifier(
                key: _controlPanelKey,
                child: _AudioControlPanel(
                  track: widget.track,
                  playlist: currentPlaylist,
                  queueIndex: queue.isEmpty ? null : clampedQueueIndex,
                  queueCount: queue.length,
                  position: position,
                  duration: duration,
                  isPlaying: isPlaying,
                  isVideoPlaylist: isVideoPlaylist,
                  audioOnlyMode: audioOnlyMode,
                  shuffleEnabled: shuffleEnabled,
                  autoplayEnabled: autoplayEnabled,
                  onReplay: () => _seekBy(ref, const Duration(seconds: -10)),
                  onPrevious: () => playbackService.previous(),
                  onPlayPause: playbackService.togglePlayPause,
                  onNext: () => playbackService.next(),
                  onForward: () => _seekBy(ref, const Duration(seconds: 10)),
                  onToggleAudioOnly: playbackService.toggleAudioOnlyMode,
                  onToggleShuffle: playbackService.toggleShuffle,
                  onToggleAutoplay: playbackService.toggleAutoplay,
                  onMinimize: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _seekBy(WidgetRef ref, Duration delta) {
    final playbackService = ref.read(playbackServiceProvider);
    final duration = playbackService.duration;
    var target = playbackService.position + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    }
    if (duration > Duration.zero && target > duration) {
      target = duration;
    }
    playbackService.seekTo(target);
  }
}

class _AudioControlPanel extends StatelessWidget {
  final Track track;
  final Playlist? playlist;
  final int? queueIndex;
  final int queueCount;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool isVideoPlaylist;
  final bool audioOnlyMode;
  final bool shuffleEnabled;
  final bool autoplayEnabled;
  final VoidCallback onReplay;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onForward;
  final VoidCallback onToggleAudioOnly;
  final VoidCallback onToggleShuffle;
  final VoidCallback onToggleAutoplay;
  final VoidCallback onMinimize;

  const _AudioControlPanel({
    required this.track,
    required this.playlist,
    required this.queueIndex,
    required this.queueCount,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.isVideoPlaylist,
    required this.audioOnlyMode,
    required this.shuffleEnabled,
    required this.autoplayEnabled,
    required this.onReplay,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onForward,
    required this.onToggleAudioOnly,
    required this.onToggleShuffle,
    required this.onToggleAutoplay,
    required this.onMinimize,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF151515).withValues(alpha: 0.96),
          border: const Border(
            top: BorderSide(color: Color(0xFF333333), width: 0.5),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.42),
              blurRadius: 22,
              offset: const Offset(0, -10),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                label: 'Minimize player',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onMinimize,
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox(
                          width: 82,
                          height: 46,
                          child: _AudioImage(track: track, fit: BoxFit.cover),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              track.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                height: 1.18,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if ((playlist?.name ?? '').isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                playlist!.name,
                                style: const TextStyle(
                                  color: Color(0xFFB0B0B0),
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _AudioProgressPill(
                queueIndex: queueIndex,
                queueCount: queueCount,
                position: position,
                duration: duration,
              ),
              const SizedBox(height: 8),
              const SeekBar(),
              const SizedBox(height: 2),
              _AudioTransportControls(
                isPlaying: isPlaying,
                onReplay: onReplay,
                onPrevious: onPrevious,
                onPlayPause: onPlayPause,
                onNext: onNext,
                onForward: onForward,
              ),
              const SizedBox(height: 6),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 0,
                children: [
                  if (isVideoPlaylist)
                    _AudioSecondaryButton(
                      icon: audioOnlyMode ? Icons.videocam_off : Icons.videocam,
                      color:
                          audioOnlyMode
                              ? const Color(0xFF64B5F6)
                              : Colors.white70,
                      tooltip: audioOnlyMode ? 'Audio only' : 'Play video',
                      onPressed: onToggleAudioOnly,
                    ),
                  _AudioSecondaryButton(
                    icon: Icons.shuffle,
                    color:
                        shuffleEnabled
                            ? const Color(0xFF64B5F6)
                            : Colors.white70,
                    tooltip: 'Shuffle',
                    onPressed: onToggleShuffle,
                  ),
                  const SegmentMarkButton(
                    activeColor: Color(0xFF64B5F6),
                    inactiveColor: Colors.white70,
                  ),
                  _AudioSecondaryButton(
                    icon: Icons.playlist_play,
                    color:
                        autoplayEnabled
                            ? const Color(0xFF64B5F6)
                            : Colors.white70,
                    tooltip: autoplayEnabled ? 'Autoplay on' : 'Autoplay off',
                    onPressed: onToggleAutoplay,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioProgressPill extends StatelessWidget {
  final int? queueIndex;
  final int queueCount;
  final Duration position;
  final Duration duration;

  const _AudioProgressPill({
    required this.queueIndex,
    required this.queueCount,
    required this.position,
    required this.duration,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (queueIndex != null) 'Track: ${queueIndex! + 1} / $queueCount',
      'Progress: ${_formatClock(position)} / ${_formatClock(duration)}',
    ];

    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        parts.join('  ·  '),
        style: const TextStyle(
          color: Color(0xFF4A4A4A),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _AudioTransportControls extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onReplay;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onForward;

  const _AudioTransportControls({
    required this.isPlaying,
    required this.onReplay,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onForward,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _AudioPrimaryButton(
            icon: Icons.replay_10,
            iconSize: 30,
            buttonSize: 48,
            onPressed: onReplay,
            tooltip: 'Back 10 seconds',
          ),
          const SizedBox(width: 8),
          _AudioPrimaryButton(
            icon: Icons.skip_previous,
            iconSize: 40,
            buttonSize: 52,
            onPressed: onPrevious,
            tooltip: 'Previous',
          ),
          const SizedBox(width: 12),
          IconButton(
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, size: 44),
            color: Colors.black,
            tooltip: isPlaying ? 'Pause' : 'Play',
            style: IconButton.styleFrom(
              fixedSize: const Size.square(74),
              backgroundColor: Colors.white,
              shape: const CircleBorder(),
            ),
            onPressed: onPlayPause,
          ),
          const SizedBox(width: 12),
          _AudioPrimaryButton(
            icon: Icons.skip_next,
            iconSize: 40,
            buttonSize: 52,
            onPressed: onNext,
            tooltip: 'Next',
          ),
          const SizedBox(width: 8),
          _AudioPrimaryButton(
            icon: Icons.forward_10,
            iconSize: 30,
            buttonSize: 48,
            onPressed: onForward,
            tooltip: 'Forward 10 seconds',
          ),
        ],
      ),
    );
  }
}

class _AudioPrimaryButton extends StatelessWidget {
  final IconData icon;
  final double iconSize;
  final double buttonSize;
  final VoidCallback onPressed;
  final String tooltip;

  const _AudioPrimaryButton({
    required this.icon,
    required this.iconSize,
    required this.buttonSize,
    required this.onPressed,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: iconSize),
      color: Colors.white,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        fixedSize: Size.square(buttonSize),
        backgroundColor: Colors.black.withValues(alpha: 0.34),
        shape: const CircleBorder(),
      ),
      onPressed: onPressed,
    );
  }
}

class _AudioSecondaryButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  const _AudioSecondaryButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 24),
      color: color,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

class _AudioImage extends StatelessWidget {
  final Track track;
  final BoxFit fit;

  const _AudioImage({required this.track, required this.fit});

  @override
  Widget build(BuildContext context) {
    final path = _thumbnailPath(track);
    const placeholder = _AudioImagePlaceholder();
    if (path != null) {
      return Image.file(
        File(path),
        fit: fit,
        errorBuilder: (_, __, ___) => placeholder,
      );
    }

    final url = _thumbnailUrl(track);
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      );
    }

    return placeholder;
  }
}

class _AudioImagePlaceholder extends StatelessWidget {
  const _AudioImagePlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF252525),
      child: Center(
        child: Icon(Icons.music_note, color: Color(0xFF595959), size: 24),
      ),
    );
  }
}

String? _thumbnailPath(Track track) {
  final path = track.thumbnailPath;
  if (path == null || path.isEmpty) return null;
  return File(path).existsSync() ? path : null;
}

String? _thumbnailUrl(Track track) {
  if (track.thumbnailUrl != null && track.thumbnailUrl!.isNotEmpty) {
    return track.thumbnailUrl;
  }
  if (track.videoId.isNotEmpty) {
    return 'https://i.ytimg.com/vi/${track.videoId}/hqdefault.jpg';
  }
  return null;
}

String _formatClock(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${d.inMinutes}:${seconds.toString().padLeft(2, '0')}';
}
