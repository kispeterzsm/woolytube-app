import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/lifecycle_provider.dart';
import '../providers/playback_providers.dart';
import 'player_layout.dart';
import 'player_sheet.dart';
import 'video_view.dart';

/// The app shell: the page navigator plus the persistent player on top.
///
/// * Pages live in their own navigator, laid out above a strip that is
///   reserved for the mini player while a track is loaded. The strip never
///   changes while the player expands or collapses, so the page underneath
///   never re-lays out mid-animation.
/// * The player ([PlayerSheet]) is one widget driven by [expansion]
///   (0 = mini bar, 1 = expanded). The page above the expanded audio panel
///   stays visible and usable: nothing blocks or dims it.
/// * Dialogs, bottom sheets and menus opened from pages are moved to the root
///   navigator, so they cover and dim the player too. Snackbars are shown by
///   this shell's Scaffold, above the player.
/// * Android back closes popups first, then collapses the player, then pops
///   pages.
class PlayerShell extends ConsumerStatefulWidget {
  final Widget home;
  final GlobalKey<NavigatorState>? pagesNavigatorKey;

  const PlayerShell({super.key, required this.home, this.pagesNavigatorKey});

  /// The shell above [context], if any.
  static PlayerShellState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_PlayerShellScope>()?.state;

  @override
  ConsumerState<PlayerShell> createState() => PlayerShellState();
}

enum _DragMode { expand, dismiss }

/// Which part of the player a drag started on.
enum PlayerDragOrigin { miniBar, panel }

class PlayerShellState extends ConsumerState<PlayerShell>
    with TickerProviderStateMixin {
  static const Duration _expandDuration = Duration(milliseconds: 220);

  /// 0 = mini bar, 1 = expanded panel (or full-screen video).
  late final AnimationController expansion = AnimationController(
    vsync: this,
    duration: _expandDuration,
  );

  /// 0 = the expanded state is the audio panel, 1 = full-screen video.
  late final AnimationController videoness = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  /// 1 while a track is loaded; the bar slides in and out with it.
  late final AnimationController presence = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  /// Swipe-down-to-stop offset of the mini bar, as a fraction of its height.
  late final AnimationController dismissal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  final ValueNotifier<VideoFitMode> fitMode = ValueNotifier(VideoFitMode.fit);
  final ValueNotifier<bool> videoLocked = ValueNotifier(false);
  final ValueNotifier<bool> _pagesHidden = ValueNotifier(false);

  /// Where the drag in progress started, or null when there is none. The
  /// sheet keeps that part mounted until the drag ends, even if the drag
  /// reaches the end where the part is normally removed; otherwise its
  /// gesture recognizer would be disposed mid-drag and never report the end.
  final ValueNotifier<PlayerDragOrigin?> activeDrag = ValueNotifier(null);

  late final GlobalKey<NavigatorState> _pagesKey =
      widget.pagesNavigatorKey ?? GlobalKey<NavigatorState>();
  final HeroController _heroController =
      MaterialApp.createMaterialHeroController();
  late final Widget _pagesNavigator =
      NotificationListener<NavigationNotification>(
        // The shell route decides what back does; the inner navigator's own
        // notifications must not tell the engine that the app cannot pop.
        onNotification: (_) => true,
        child: HeroControllerScope(
          controller: _heroController,
          child: _PagesNavigator(
            key: _pagesKey,
            observers: [_PagePushObserver(_onPagePushed)],
            onGenerateInitialRoutes:
                (navigator, initialRoute) => [
                  MaterialPageRoute<void>(builder: (_) => widget.home),
                ],
          ),
        ),
      );

  PlayerGeometry _geometry = const PlayerGeometry(
    size: Size(400, 800),
    bottomInset: 0,
    topInset: 0,
  );
  bool _hasTrack = false;
  bool _video = false;
  bool _collapsing = false;
  _DragMode? _dragMode;
  bool _systemFullscreen = false;
  bool? _appliedLandscape;
  DateTime? _suppressVideoAutoOpenUntil;

  NavigatorState? get pagesNavigator => _pagesKey.currentState;
  bool get isExpanded => expansion.value > 0;
  bool get isDragging => activeDrag.value != null;
  PlayerGeometry get geometry => _geometry;

  @override
  void initState() {
    super.initState();
    _hasTrack = ref.read(currentTrackProvider).valueOrNull != null;
    presence.value = _hasTrack ? 1 : 0;
    expansion.addListener(_onExpansionChanged);
    expansion.addStatusListener(_onExpansionStatus);
    videoness.addListener(_onExpansionChanged);
    presence.addStatusListener(_onPresenceStatus);
  }

  @override
  void dispose() {
    if (_systemFullscreen) _restoreSystemUi();
    expansion.dispose();
    videoness.dispose();
    presence.dispose();
    dismissal.dispose();
    fitMode.dispose();
    videoLocked.dispose();
    _pagesHidden.dispose();
    activeDrag.dispose();
    _heroController.dispose();
    super.dispose();
  }

  // Public API ---------------------------------------------------------------

  /// Opens the player: the audio panel, or full-screen video.
  void expand() {
    if (!_hasTrack) return;
    _cancelDrag();
    _collapsing = false;
    if (dismissal.value != 0) dismissal.animateTo(0);
    _animateExpansion(1);
  }

  /// Collapses the player back to the mini bar. System UI and orientation
  /// are restored at once, not after the animation.
  void collapse() {
    _cancelDrag();
    videoLocked.value = false;
    if (expansion.value == 0) {
      expansion.stop();
      _settled();
      return;
    }
    _collapsing = true;
    _syncSystemUi();
    _animateExpansion(0);
  }

  /// Stops playback and clears the queue (the player then slides away).
  void stopPlayback() {
    unawaited(ref.read(playbackServiceProvider).stop());
  }

  void beginDrag(PlayerDragOrigin origin) {
    if (!_hasTrack) return;
    expansion.stop();
    dismissal.stop();
    _dragMode = null;
    activeDrag.value = origin;
  }

  void updateDrag(double dy) {
    if (!isDragging) return;
    _dragMode ??=
        expansion.value == 0 && dy > 0 ? _DragMode.dismiss : _DragMode.expand;
    if (_dragMode == _DragMode.dismiss) {
      dismissal.value = (dismissal.value + dy / _geometry.miniHeight).clamp(
        0.0,
        1.0,
      );
      return;
    }
    if (_systemFullscreen) _syncSystemUi();
    final range = _geometry.dragRange(videoness.value);
    expansion.value = (expansion.value - dy / range).clamp(0.0, 1.0);
  }

  void endDrag(double velocity) {
    if (!isDragging) return;
    final mode = _dragMode;
    _cancelDrag();
    switch (mode) {
      case _DragMode.dismiss:
        // Stopping clears the queue, so it needs real travel: a fling only
        // finishes a swipe that already moved a good part of the bar, and a
        // quick flick (for example while meaning to scroll) springs back.
        final stop =
            dismissal.value > 0.5 || (velocity > 700 && dismissal.value > 0.3);
        if (stop) {
          dismissal.animateTo(1, curve: Curves.easeOut).whenCompleteOrCancel(
            () {
              if (mounted && dismissal.value == 1) {
                stopPlayback();
                ScaffoldMessenger.maybeOf(context)
                  ?..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(content: Text('Playback stopped')),
                  );
              }
            },
          );
        } else {
          dismissal.animateTo(0, curve: Curves.easeOut);
        }
      case _DragMode.expand:
        final open =
            velocity < -600
                ? true
                : velocity > 600
                ? false
                : expansion.value >= 0.5;
        open ? expand() : collapse();
      case null:
        _syncSystemUi();
    }
  }

  // Internals ----------------------------------------------------------------

  void _cancelDrag() {
    _dragMode = null;
    activeDrag.value = null;
  }

  void _animateExpansion(double target) {
    final distance = (expansion.value - target).abs();
    if (distance == 0) {
      expansion.stop();
      _settled();
      return;
    }
    final ms =
        (_expandDuration.inMilliseconds * math.max(distance, 0.45)).round();
    expansion.animateTo(
      target,
      duration: Duration(milliseconds: ms),
      // Starts fast so a tap feels immediate, then settles softly.
      curve: Curves.easeOutQuart,
    );
  }

  void _onExpansionStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _settled();
    }
  }

  /// The expansion stopped at a rest position (0 or 1, or wherever an
  /// interrupted drag left it).
  void _settled() {
    if (expansion.isAnimating) return;
    if (expansion.value == 0) {
      _collapsing = false;
      videoLocked.value = false;
      fitMode.value = VideoFitMode.fit;
    } else if (expansion.value == 1) {
      _collapsing = false;
    }
    _syncSystemUi();
    _onExpansionChanged();
  }

  void _onExpansionChanged() {
    _updateOverlayHeight();
    final fullScreenVideo =
        _hasTrack &&
        _video &&
        expansion.value == 1 &&
        videoness.value == 1 &&
        !isDragging &&
        !_collapsing;
    _pagesHidden.value = fullScreenVideo;
    videoFullscreenNotifier.value = fullScreenVideo;
  }

  void _updateOverlayHeight() {
    final covered =
        _hasTrack && !_video && expansion.value > 0
            ? _geometry.overlayHeight
            : 0.0;
    if (audioPlayerOverlayHeightNotifier.value != covered) {
      audioPlayerOverlayHeightNotifier.value = covered;
    }
  }

  void _onPresenceStatus(AnimationStatus status) {
    if (!presence.isAnimating && presence.value == 0 && !_hasTrack) {
      dismissal.value = 0;
      if (mounted) setState(() {});
    }
  }

  void _syncSystemUi() {
    final want =
        _hasTrack &&
        _video &&
        expansion.value == 1 &&
        !isDragging &&
        !_collapsing;
    if (want != _systemFullscreen) {
      _systemFullscreen = want;
      if (want) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        _restoreSystemUi();
      }
    }
    if (want) {
      _applyOrientation(
        _hasTrack ? ref.read(videoAspectProvider).valueOrNull : null,
      );
    }
  }

  void _restoreSystemUi() {
    _appliedLandscape = null;
    // Manual mode with all overlays: not edge-to-edge, so the mini player
    // stays above the system navigation bar.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  }

  void _applyOrientation(double? aspect) {
    if (aspect == null) return;
    final landscape = aspect > 1.0;
    if (_appliedLandscape == landscape) return;
    _appliedLandscape = landscape;
    SystemChrome.setPreferredOrientations(
      landscape
          ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
          : const [DeviceOrientation.portraitUp],
    );
  }

  void _setVideo(bool video) {
    if (_video == video) return;
    _video = video;
    if (expansion.value == 0) {
      videoness.value = video ? 1 : 0;
    } else {
      videoness.animateTo(video ? 1 : 0, curve: Curves.easeInOutCubic);
    }
    if (!video) videoLocked.value = false;
    _syncSystemUi();
    _onExpansionChanged();
    if (mounted) setState(() {});
  }

  /// Read from the service rather than [isVideoContentProvider], which can
  /// still hold the previous track's value on this frame.
  bool _isVideoNow() => ref.read(playbackServiceProvider).isVideoContent;

  void _onTrackChanged(AsyncValue<Track?>? previous, AsyncValue<Track?> next) {
    if (!next.hasValue) return;
    final track = next.valueOrNull;
    final had = _hasTrack;
    _hasTrack = track != null;
    if (track == null) {
      if (had) {
        collapse();
        presence.animateTo(0, curve: Curves.easeInCubic);
        setState(() {});
      }
      _syncSystemUi();
      _onExpansionChanged();
      return;
    }
    if (!had) {
      dismissal.value = 0;
      presence.animateTo(1, curve: Curves.easeOutCubic);
      setState(() {});
    }
    final video = _isVideoNow();
    _setVideo(video);
    if (previous?.valueOrNull?.id == track.id) return;
    // A new video starts: open the full-screen player, as before.
    if (video) expand();
  }

  void _onVideoContentChanged(
    AsyncValue<bool>? previous,
    AsyncValue<bool> next,
  ) {
    if (!next.hasValue || !_hasTrack) return;
    final video = next.requireValue;
    _setVideo(video);
    final wasVideo = previous?.valueOrNull ?? false;
    if (!video || wasVideo) return;
    // Audio-only was switched off for the playing track. Not when the app
    // just came back from picture-in-picture: that restore keeps the player
    // where it was, as it always has.
    final suppressedUntil = _suppressVideoAutoOpenUntil;
    if (suppressedUntil != null && DateTime.now().isBefore(suppressedUntil)) {
      return;
    }
    expand();
  }

  void _onPagePushed() {
    // A page opened from the area above the panel: show it with the mini
    // player instead of leaving the panel over it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && expansion.value > 0 && !_video) collapse();
    });
  }

  void _handleBack() {
    if (_video && expansion.value > 0 && videoLocked.value) return;
    if (expansion.value > 0) {
      collapse();
      return;
    }
    final navigator = pagesNavigator;
    if (navigator == null) {
      SystemNavigator.pop();
      return;
    }
    navigator.maybePop().then((handled) {
      if (!handled) SystemNavigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<Track?>>(currentTrackProvider, _onTrackChanged);
    ref.listen<AppLifecycleState>(appLifecycleProvider, (previous, next) {
      if (next == AppLifecycleState.resumed &&
          previous != AppLifecycleState.resumed) {
        _suppressVideoAutoOpenUntil = DateTime.now().add(
          const Duration(seconds: 3),
        );
      }
    });
    if (_hasTrack) {
      ref.listen<AsyncValue<bool>>(
        isVideoContentProvider,
        _onVideoContentChanged,
      );
      // Keeping this listener alive from the start of playback also means the
      // aspect ratio, which media_kit does not replay, is never missed.
      ref.listen<AsyncValue<double?>>(videoAspectProvider, (_, next) {
        if (_systemFullscreen) _applyOrientation(next.valueOrNull);
      });
    }

    final viewPadding = MediaQuery.viewPaddingOf(context);
    final geometry = PlayerGeometry(
      size: MediaQuery.sizeOf(context),
      bottomInset: viewPadding.bottom,
      topInset: viewPadding.top,
    );
    if (geometry != _geometry) {
      _geometry = geometry;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateOverlayHeight();
      });
    }

    return _PlayerShellScope(
      state: this,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _handleBack();
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF1E1E1E),
          resizeToAvoidBottomInset: false,
          extendBody: true,
          bottomNavigationBar: _SnackBarLift(shell: this, geometry: geometry),
          body: Stack(
            fit: StackFit.expand,
            children: [
              _PagesArea(
                presence: presence,
                hidden: _pagesHidden,
                geometry: geometry,
                child: _pagesNavigator,
              ),
              if (_hasTrack || presence.value > 0)
                // Fixed row heights: keep very large text from overflowing.
                MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.2,
                  child: PlayerSheet(
                    shell: this,
                    geometry: geometry,
                    video: _video,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerShellScope extends InheritedWidget {
  final PlayerShellState state;

  const _PlayerShellScope({required this.state, required super.child});

  @override
  bool updateShouldNotify(_PlayerShellScope oldWidget) =>
      state != oldWidget.state;
}

/// Lays out the page navigator above the mini player's reserved strip and
/// hides it entirely behind full-screen video.
class _PagesArea extends StatelessWidget {
  final Animation<double> presence;
  final ValueListenable<bool> hidden;
  final PlayerGeometry geometry;
  final Widget child;

  const _PagesArea({
    required this.presence,
    required this.hidden,
    required this.geometry,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: presence,
      child: ValueListenableBuilder<bool>(
        valueListenable: hidden,
        child: child,
        builder:
            (context, hidden, child) => Offstage(
              offstage: hidden,
              child: TickerMode(enabled: !hidden, child: child!),
            ),
      ),
      builder: (context, child) {
        final reserve = presence.value * geometry.miniHeight;
        final media = MediaQuery.of(context);
        final keyboard = media.viewInsets.bottom;
        final system = geometry.bottomInset;
        // The pages end where the reserved strip starts. Take the strip out
        // of the system and keyboard insets the pages see, so they do not
        // leave a second gap for space that is already outside them.
        final data = media.copyWith(
          padding: media.padding.copyWith(
            bottom: math.max(0.0, math.max(0.0, system - keyboard) - reserve),
          ),
          viewPadding: media.viewPadding.copyWith(
            bottom: math.max(0.0, system - reserve),
          ),
          viewInsets: media.viewInsets.copyWith(
            bottom: math.max(0.0, keyboard - reserve),
          ),
        );
        return Padding(
          padding: EdgeInsets.only(bottom: reserve),
          child: MediaQuery(data: data, child: child!),
        );
      },
    );
  }
}

/// An invisible bottom bar as tall as the visible player, so the shell
/// Scaffold shows snackbars right above the player (or the keyboard).
class _SnackBarLift extends StatelessWidget {
  final PlayerShellState shell;
  final PlayerGeometry geometry;

  const _SnackBarLift({required this.shell, required this.geometry});

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          shell.expansion,
          shell.videoness,
          shell.presence,
          shell.dismissal,
        ]),
        builder: (context, _) {
          final t = shell.expansion.value;
          final v = shell.videoness.value;
          final hiddenPart =
              (1 - shell.presence.value + shell.dismissal.value) *
              geometry.miniHeight;
          final audio = math.max(0.0, geometry.sheetHeight(t, 0) - hiddenPart);
          final video = math.max(
            0.0,
            geometry.miniHeight * (1 - t) - hiddenPart,
          );
          final lift = audio * (1 - v) + video * v;
          return SizedBox(
            width: double.infinity,
            height: math.max(lift, keyboard),
          );
        },
      ),
    );
  }
}

/// Collapses the panel when a page is pushed.
class _PagePushObserver extends NavigatorObserver {
  final VoidCallback onPush;

  _PagePushObserver(this.onPush);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute && previousRoute != null) onPush();
  }
}

/// The page navigator. Popup routes (dialogs, bottom sheets, menus,
/// dropdowns) pushed on it go to the root navigator instead, so they are
/// drawn above the player and dim it.
///
/// `pop`, `maybePop` and `canPop` keep the semantics of a single navigator:
/// while anything sits above the shell on the root navigator (a redirected
/// popup, a dialog shown on the root navigator directly, or a stack of
/// both), they act on the root navigator's top route, so page code that
/// closes a sheet or dialog with the page's context still closes it.
class _PagesNavigator extends Navigator {
  const _PagesNavigator({
    super.key,
    super.observers,
    super.onGenerateInitialRoutes,
  });

  @override
  NavigatorState createState() => _PagesNavigatorState();
}

class _PagesNavigatorState extends NavigatorState {
  /// The app's root navigator. Cached, because `canPop` is also asked while
  /// this navigator is being taken down, when ancestors can no longer be
  /// looked up.
  NavigatorState? _root;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final root = context.findRootAncestorStateOfType<NavigatorState>();
    _root = identical(root, this) ? null : root;
  }

  /// The root navigator when something is shown above the shell on it. The
  /// shell is the root navigator's only route of its own, so the root can
  /// pop exactly when such a route is present.
  NavigatorState? get _rootAboveShell {
    final root = _root;
    return root != null && root.mounted && root.canPop() ? root : null;
  }

  @override
  Future<T?> push<T extends Object?>(Route<T> route) {
    if (route is PopupRoute<T>) {
      final root = _root;
      if (root != null) return root.push(route);
    }
    return super.push(route);
  }

  @override
  void pop<T extends Object?>([T? result]) {
    final root = _rootAboveShell;
    if (root != null) {
      root.pop<T>(result);
      return;
    }
    super.pop<T>(result);
  }

  @override
  Future<bool> maybePop<T extends Object?>([T? result]) {
    final root = _rootAboveShell;
    if (root != null) return root.maybePop<T>(result);
    return super.maybePop<T>(result);
  }

  @override
  bool canPop() => _rootAboveShell != null || super.canPop();
}
