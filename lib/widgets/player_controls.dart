import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_layout.dart';
import '../providers/playback_providers.dart';
import '../services/playback_service.dart';
import 'sponsorblock_progress_bar.dart';

/// Seek bar with SponsorBlock segments painted on the slider's own track, and
/// elapsed / remaining time labels aligned with the track's ends.
///
/// Only this widget listens to the playback position, so the player around it
/// does not rebuild on position updates.
class SeekBar extends ConsumerStatefulWidget {
  /// Horizontal space between the widget's edge and the slider box. The track
  /// itself starts [PlayerLayout.seekTrackInset] further in.
  final double horizontalPadding;
  final bool showTimes;

  /// Fades only the slider (not the time labels). The expanded panel uses
  /// this to hand over from the morphing mini progress line.
  final Animation<double>? sliderOpacity;
  final Color inactiveTrackColor;
  final Color timeColor;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;

  const SeekBar({
    super.key,
    this.horizontalPadding = PlayerLayout.seekHorizontalPadding,
    this.showTimes = true,
    this.sliderOpacity,
    this.inactiveTrackColor = PlayerLayout.trackBackground,
    this.timeColor = PlayerLayout.mutedText,
    this.onSeekStart,
    this.onSeekEnd,
  });

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  /// Position shown while the thumb is dragged.
  double? _dragValueMs;

  /// Position of a seek that has been sent but not yet reported back by the
  /// player. Holding it stops the thumb from snapping back to the old
  /// position for a moment after the finger is lifted.
  double? _pendingSeekMs;
  Timer? _pendingTimer;

  @override
  void dispose() {
    _pendingTimer?.cancel();
    super.dispose();
  }

  double? _heldValue(double liveMs) {
    final drag = _dragValueMs;
    if (drag != null) return drag;
    final pending = _pendingSeekMs;
    if (pending == null) return null;
    if ((liveMs - pending).abs() < 1000) {
      // The player has caught up; follow the live position again.
      _pendingSeekMs = null;
      return null;
    }
    return pending;
  }

  Future<void> _seek(double valueMs) async {
    setState(() {
      _dragValueMs = null;
      _pendingSeekMs = valueMs;
    });
    _pendingTimer?.cancel();
    _pendingTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && _pendingSeekMs == valueMs) {
        setState(() => _pendingSeekMs = null);
      }
    });
    widget.onSeekEnd?.call();
    await ref
        .read(playbackServiceProvider)
        .seekTo(Duration(milliseconds: valueMs.round()));
  }

  @override
  Widget build(BuildContext context) {
    final slider = Consumer(
      builder: (context, ref, _) {
        final position =
            ref.watch(positionProvider).valueOrNull ?? Duration.zero;
        final duration =
            ref.watch(durationProvider).valueOrNull ?? Duration.zero;
        final segments =
            ref.watch(playbackSponsorBlockSegmentsProvider).valueOrNull ??
            const <PlaybackSponsorBlockSegment>[];
        final durationMs =
            duration.inMilliseconds > 0
                ? duration.inMilliseconds.toDouble()
                : 1.0;
        final liveMs = position.inMilliseconds.toDouble().clamp(
          0.0,
          durationMs,
        );
        final shownMs = (_heldValue(liveMs) ?? liveMs).clamp(0.0, durationMs);

        return SliderTheme(
          data: SliderThemeData(
            trackHeight: PlayerLayout.seekTrackHeight,
            trackShape: SponsorBlockSliderTrackShape(
              segments: segments,
              durationMs: duration.inMilliseconds,
            ),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(
              overlayRadius: PlayerLayout.seekTrackInset,
            ),
            activeTrackColor: PlayerLayout.accent,
            inactiveTrackColor: widget.inactiveTrackColor,
            thumbColor: PlayerLayout.accent,
            overlayColor: PlayerLayout.accent.withValues(alpha: 0.2),
          ),
          child: Slider(
            value: shownMs,
            max: durationMs,
            semanticFormatterCallback:
                (value) => formatClock(Duration(milliseconds: value.round())),
            onChangeStart: (value) {
              widget.onSeekStart?.call();
              setState(() => _dragValueMs = value);
            },
            onChanged: (value) => setState(() => _dragValueMs = value),
            onChangeEnd: _seek,
          ),
        );
      },
    );

    final sliderOpacity = widget.sliderOpacity;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: PlayerLayout.seekSliderHeight,
            child:
                sliderOpacity == null
                    ? slider
                    : FadeTransition(opacity: sliderOpacity, child: slider),
          ),
          if (widget.showTimes)
            SizedBox(
              height: PlayerLayout.seekTimesHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: PlayerLayout.seekTrackInset,
                ),
                child: _SeekTimes(
                  heldMs: _dragValueMs ?? _pendingSeekMs,
                  color: widget.timeColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Elapsed and remaining time. Rebuilds once a second, or while dragging.
class _SeekTimes extends ConsumerWidget {
  final double? heldMs;
  final Color color;

  const _SeekTimes({required this.heldMs, required this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final held = heldMs;
    final elapsed =
        held != null
            ? Duration(milliseconds: held.round())
            : Duration(seconds: ref.watch(positionSecondsProvider));
    final clamped =
        duration > Duration.zero && elapsed > duration ? duration : elapsed;
    final remaining = duration > clamped ? duration - clamped : Duration.zero;
    final style = TextStyle(
      color: color,
      fontSize: 12,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(formatClock(clamped), style: style),
        Text(
          duration > Duration.zero ? '-${formatClock(remaining)}' : '',
          style: style,
          semanticsLabel:
              duration > Duration.zero
                  ? '${formatClock(remaining)} remaining'
                  : null,
        ),
      ],
    );
  }
}

/// The default rounded slider track with SponsorBlock segments drawn on top,
/// in exactly the rectangle the track occupies.
class SponsorBlockSliderTrackShape extends RoundedRectSliderTrackShape {
  final List<PlaybackSponsorBlockSegment> segments;
  final int durationMs;

  const SponsorBlockSliderTrackShape({
    required this.segments,
    required this.durationMs,
  });

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    paintSponsorBlockSegments(context.canvas, track, segments, durationMs);
  }
}
