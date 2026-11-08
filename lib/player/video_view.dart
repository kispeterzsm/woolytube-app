import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/playback_providers.dart';
import '../widgets/chapters_button.dart';
import '../widgets/next_file_button.dart';
import '../widgets/plane_mode_button.dart';
import '../widgets/player_controls.dart';
import '../widgets/segment_mark_button.dart';
import '../widgets/sleep_timer_button.dart';
import '../widgets/subtitle_button.dart';
import 'player_layout.dart';
import 'player_widgets.dart';

enum VideoFitMode { fit, fill, zoom }

extension VideoFitModeLabel on VideoFitMode {
  String get label => switch (this) {
    VideoFitMode.fit => 'Fit',
    VideoFitMode.fill => 'Fill',
    VideoFitMode.zoom => 'Zoom',
  };

  VideoFitMode get next =>
      VideoFitMode.values[(index + 1) % VideoFitMode.values.length];
}

/// Controls of the full-screen (VLC-style) video player.
///
/// The video picture itself is drawn by the player sheet underneath, so it
/// can grow out of the mini player's thumbnail without being recreated. This
/// widget adds the gestures (tap for controls, double-tap to seek 10 s, pinch
/// to change the fit, swipe down to minimize), the auto-hiding controls and
/// the lock mode.
class VideoView extends ConsumerStatefulWidget {
  final ValueNotifier<VideoFitMode> fitMode;
  final ValueNotifier<bool> locked;
  final VoidCallback onCollapse;

  const VideoView({
    super.key,
    required this.fitMode,
    required this.locked,
    required this.onCollapse,
  });

  @override
  ConsumerState<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends ConsumerState<VideoView> {
  static const Duration _autoHideDelay = Duration(seconds: 3);

  bool _overlayVisible = true;

  /// The controls stay built while they fade out, then are removed so their
  /// seek bar stops listening to the playback position.
  bool _overlayBuilt = true;
  Timer? _hideTimer;

  String? _modeLabel;
  Timer? _modeLabelTimer;

  String? _seekBadge;
  bool _seekBadgeIsLeft = false;
  Timer? _seekBadgeTimer;

  Offset _lastDoubleTapPos = Offset.zero;
  bool _pinchHandled = false;
  Offset _swipe = Offset.zero;
  int _maxPointers = 0;

  bool get _locked => widget.locked.value;

  @override
  void initState() {
    super.initState();
    widget.locked.addListener(_onLockChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleAutoHide();
    });
  }

  @override
  void dispose() {
    widget.locked.removeListener(_onLockChanged);
    _hideTimer?.cancel();
    _modeLabelTimer?.cancel();
    _seekBadgeTimer?.cancel();
    super.dispose();
  }

  void _onLockChanged() {
    if (mounted) setState(() {});
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

  void _showOverlay() {
    setState(() {
      _overlayBuilt = true;
      _overlayVisible = true;
    });
    _scheduleAutoHide();
  }

  void _toggleOverlay() {
    if (_overlayVisible) {
      _hideTimer?.cancel();
      setState(() => _overlayVisible = false);
    } else {
      _showOverlay();
    }
  }

  void _handleDoubleTap() {
    final width = MediaQuery.sizeOf(context).width;
    final isLeft = _lastDoubleTapPos.dx < width / 2;
    seekPlaybackBy(ref, Duration(seconds: isLeft ? -10 : 10));
    setState(() {
      _seekBadge = isLeft ? '−10 s' : '+10 s';
      _seekBadgeIsLeft = isLeft;
    });
    _seekBadgeTimer?.cancel();
    _seekBadgeTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _seekBadge = null);
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    _pinchHandled = false;
    _swipe = Offset.zero;
    _maxPointers = details.pointerCount;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount > _maxPointers) {
      _maxPointers = details.pointerCount;
    }
    if (details.pointerCount < 2) {
      _swipe += details.focalPointDelta;
      return;
    }
    if (_pinchHandled) return;
    if (details.scale > 1.2 || details.scale < 0.8) {
      _pinchHandled = true;
      _cycleFitMode();
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_maxPointers > 1) return;
    final dy = _swipe.dy;
    final velocity = details.velocity.pixelsPerSecond.dy;
    // A clear downward swipe minimizes the player, like closing a sheet.
    if (dy > 0 &&
        dy > _swipe.dx.abs() * 1.5 &&
        (dy > 90 || (dy > 30 && velocity > 700))) {
      widget.onCollapse();
    }
  }

  void _cycleFitMode() {
    widget.fitMode.value = widget.fitMode.value.next;
    setState(() => _modeLabel = widget.fitMode.value.label);
    _modeLabelTimer?.cancel();
    _modeLabelTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _modeLabel = null);
    });
  }

  void _lock() {
    _hideTimer?.cancel();
    setState(() => _overlayVisible = false);
    widget.locked.value = true;
  }

  void _unlock() {
    widget.locked.value = false;
    _showOverlay();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<bool>>(isPlayingProvider, (_, next) {
      if (next.valueOrNull == true) {
        if (_overlayVisible) _scheduleAutoHide();
      } else {
        _hideTimer?.cancel();
        if (!_overlayVisible && !_locked) _showOverlay();
      }
    });

    final locked = _locked;
    final showOverlay = _overlayVisible && !locked;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const ValueKey('video-gesture-layer'),
            behavior: HitTestBehavior.translucent,
            onTap: locked ? null : _toggleOverlay,
            onDoubleTapDown:
                locked ? null : (d) => _lastDoubleTapPos = d.localPosition,
            onDoubleTap: locked ? null : _handleDoubleTap,
            onScaleStart: locked ? null : _onScaleStart,
            onScaleUpdate: locked ? null : _onScaleUpdate,
            onScaleEnd: locked ? null : _onScaleEnd,
          ),
          if (_seekBadge != null)
            Align(
              alignment:
                  _seekBadgeIsLeft
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: _PillLabel(text: _seekBadge!, large: true),
              ),
            ),
          if (_modeLabel != null)
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              child: Center(child: _PillLabel(text: _modeLabel!)),
            ),
          if (_overlayBuilt)
            IgnorePointer(
              ignoring: !showOverlay,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: showOverlay ? 1.0 : 0.0,
                onEnd: () {
                  if (mounted && !(_overlayVisible && !_locked)) {
                    setState(() => _overlayBuilt = false);
                  }
                },
                child: _VideoControls(
                  fitMode: widget.fitMode,
                  onCollapse: widget.onCollapse,
                  onLock: _lock,
                  onCycleFit: () {
                    _cycleFitMode();
                    _bumpAutoHide();
                  },
                  onAnyAction: _bumpAutoHide,
                  onHoldOpen: () => _hideTimer?.cancel(),
                ),
              ),
            ),
          if (locked)
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: SafeArea(
                top: false,
                child: Center(
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.lock, color: Colors.white),
                      tooltip: 'Unlock controls',
                      onPressed: _unlock,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VideoControls extends ConsumerWidget {
  final ValueNotifier<VideoFitMode> fitMode;
  final VoidCallback onCollapse;
  final VoidCallback onLock;
  final VoidCallback onCycleFit;
  final VoidCallback onAnyAction;
  final VoidCallback onHoldOpen;

  const _VideoControls({
    required this.fitMode,
    required this.onCollapse,
    required this.onLock,
    required this.onCycleFit,
    required this.onAnyAction,
    required this.onHoldOpen,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = ref.watch(
      currentTrackProvider.select((value) => value.valueOrNull?.title ?? ''),
    );
    final playlistName = ref.watch(
      currentPlaylistProvider.select((value) => value.valueOrNull?.name ?? ''),
    );
    final shuffle = ref.watch(shuffleEnabledProvider).valueOrNull ?? false;
    final autoplay = ref.watch(autoplayEnabledProvider).valueOrNull ?? true;
    final chapter = ref.watch(isChapterItemProvider);
    final service = ref.read(playbackServiceProvider);

    void act(VoidCallback action) {
      action();
      onAnyAction();
    }

    return Column(
      children: [
        // Top bar
        DecoratedBox(
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
                    key: const ValueKey('video-collapse-button'),
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 30,
                    ),
                    color: Colors.white,
                    tooltip: 'Minimize player',
                    onPressed: onCollapse,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (playlistName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              playlistName,
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
                  SubtitleButton(onOpened: onHoldOpen, onClosed: onAnyAction),
                  IconButton(
                    icon: const Icon(Icons.lock_open, color: Colors.white),
                    tooltip: 'Lock controls',
                    onPressed: onLock,
                  ),
                ],
              ),
            ),
          ),
        ),

        // Centre transport: previous, play/pause, next.
        Expanded(
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 44,
                  color: Colors.white,
                  tooltip: chapter ? 'Previous chapter' : 'Previous',
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: () => act(service.previous),
                ),
                const SizedBox(width: 24),
                _CenterPlayButton(onAction: onAnyAction),
                const SizedBox(width: 24),
                IconButton(
                  iconSize: 44,
                  color: Colors.white,
                  tooltip: chapter ? 'Next chapter' : 'Next',
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: () => act(service.next),
                ),
              ],
            ),
          ),
        ),

        // Bottom bar
        DecoratedBox(
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
                  SeekBar(
                    horizontalPadding: 12,
                    inactiveTrackColor: Colors.white24,
                    timeColor: const Color(0xFFDDDDDD),
                    onSeekStart: onHoldOpen,
                    onSeekEnd: onAnyAction,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        NextFileButton(
                          showLabel: false,
                          inactiveColor: Colors.white,
                          onAction: onAnyAction,
                        ),
                        PlayerActionButton(
                          icon: Icons.shuffle_rounded,
                          label: 'Shuffle',
                          tooltip: shuffle ? 'Shuffle: on' : 'Shuffle: off',
                          toggled: shuffle,
                          showLabel: false,
                          inactiveColor: Colors.white,
                          activeColor: PlayerLayout.accent,
                          onPressed: () => act(service.toggleShuffle),
                        ),
                        PlayerActionButton(
                          icon: Icons.playlist_play_rounded,
                          label: 'Autoplay',
                          tooltip: autoplay ? 'Autoplay: on' : 'Autoplay: off',
                          toggled: autoplay,
                          showLabel: false,
                          inactiveColor: Colors.white,
                          activeColor: PlayerLayout.accent,
                          iconSize: 26,
                          onPressed: () => act(service.toggleAutoplay),
                        ),
                        ChaptersButton(
                          inactiveColor: Colors.white,
                          onAction: onAnyAction,
                        ),
                        SegmentMarkButton(
                          inactiveColor: Colors.white,
                          onAction: onAnyAction,
                        ),
                        SleepTimerButton(
                          inactiveColor: Colors.white,
                          onAction: onAnyAction,
                        ),
                        PlaneModeButton(
                          inactiveColor: Colors.white,
                          activeColor: PlayerLayout.accent,
                          onAction: onAnyAction,
                        ),
                        PlayerActionButton(
                          icon: Icons.headphones_rounded,
                          label: 'Audio only',
                          tooltip: 'Audio only (hide the video)',
                          showLabel: false,
                          inactiveColor: Colors.white,
                          onPressed: () => act(service.toggleAudioOnlyMode),
                        ),
                        ValueListenableBuilder<VideoFitMode>(
                          valueListenable: fitMode,
                          builder:
                              (context, mode, _) => IconButton(
                                icon: const Icon(
                                  Icons.aspect_ratio,
                                  color: Colors.white,
                                  size: 22,
                                ),
                                tooltip: 'Picture size: ${mode.label}',
                                onPressed: onCycleFit,
                              ),
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

class _CenterPlayButton extends ConsumerWidget {
  final VoidCallback onAction;

  const _CenterPlayButton({required this.onAction});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    return IconButton(
      iconSize: 80,
      color: Colors.white,
      tooltip: isPlaying ? 'Pause' : 'Play',
      icon: Icon(
        isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
      ),
      onPressed: () {
        ref.read(playbackServiceProvider).togglePlayPause();
        onAction();
      },
    );
  }
}

class _PillLabel extends StatelessWidget {
  final String text;
  final bool large;

  const _PillLabel({required this.text, this.large = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 18 : 14,
        vertical: large ? 10 : 6,
      ),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(large ? 28 : 20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: large ? 18 : 13,
          fontWeight: large ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }
}
