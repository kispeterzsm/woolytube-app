import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/lifecycle_provider.dart';
import '../widgets/player_controls.dart';

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
              onDoubleTapDown: _locked
                  ? null
                  : (d) => _lastDoubleTapPos = d.localPosition,
              onDoubleTap: _locked ? null : _handleDoubleTap,
              onScaleStart: _locked ? null : _onScaleStart,
              onScaleUpdate: _locked ? null : _onScaleUpdate,
            ),
          ),

          // Seek badge (left or right half)
          if (_seekBadge != null)
            Positioned.fill(
              child: Align(
                alignment: _seekBadgeIsLeft
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
              child: Center(
                child: _PillLabel(text: _modeLabel!),
              ),
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
                    onPressed: () => setState(() {
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
                            color: shuffleEnabled
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
                            color: autoplayEnabled
                                ? const Color(0xFF2196F3)
                                : Colors.white,
                            size: 26,
                          ),
                          tooltip: autoplayEnabled
                              ? 'Autoplay on'
                              : 'Autoplay off',
                          onPressed: () {
                            svc.toggleAutoplay();
                            onAnyAction();
                          },
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
// Audio — unchanged portrait layout

class _AudioPlayerView extends ConsumerWidget {
  final Track track;
  const _AudioPlayerView({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentPlaylist = ref.watch(currentPlaylistProvider).valueOrNull;
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
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _buildLargeThumbnail(_thumbnailUrl(track)),
                ),
              ),
            ),
            const SizedBox(height: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                track.title,
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
            Text(
              currentPlaylist?.name ?? '',
              style: const TextStyle(color: Color(0xFF888888), fontSize: 14),
            ),
            const Spacer(flex: 1),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SeekBar(),
            ),
            const SizedBox(height: 8),
            const PlayerControls(showShuffleAutoplay: true),
            const Spacer(flex: 1),
          ],
        ),
      ),
    );
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
