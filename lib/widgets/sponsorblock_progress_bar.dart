import 'dart:math';

import 'package:flutter/material.dart';

import '../services/playback_service.dart';

/// Paints SponsorBlock segments as coloured blocks inside [track].
///
/// Shared by the seek bar's track shape and the mini player's progress line,
/// so markers are always aligned with the bar they sit on.
void paintSponsorBlockSegments(
  Canvas canvas,
  Rect track,
  List<PlaybackSponsorBlockSegment> segments,
  int durationMs,
) {
  if (durationMs <= 0 || track.width <= 0 || segments.isEmpty) return;
  final radius = Radius.circular(track.height / 2);
  final paint = Paint();
  for (final segment in segments) {
    final start = segment.startMs.clamp(0, durationMs);
    final end = segment.endMs.clamp(start + 1, durationMs);
    final left = track.left + track.width * start / durationMs;
    final rawRight = track.left + track.width * end / durationMs;
    final right = min(track.right, max(rawRight, left + 2));
    if (right <= track.left || left >= track.right) continue;
    paint.color = Color(segment.colorValue).withValues(alpha: 0.9);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(left, track.top, right, track.bottom),
        radius,
      ),
      paint,
    );
  }
}

/// Paints a rounded track filling its whole canvas: background, progress and
/// SponsorBlock segments.
class SegmentedProgressPainter extends CustomPainter {
  final double progress;
  final int durationMs;
  final List<PlaybackSponsorBlockSegment> segments;
  final Color backgroundColor;
  final Color progressColor;

  const SegmentedProgressPainter({
    required this.progress,
    required this.durationMs,
    required this.segments,
    required this.backgroundColor,
    required this.progressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final track = Offset.zero & size;
    final radius = Radius.circular(size.height / 2);
    if (backgroundColor.a > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(track, radius),
        Paint()..color = backgroundColor,
      );
    }
    if (progressColor.a > 0 && progress > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            0,
            0,
            size.width * progress.clamp(0.0, 1.0),
            size.height,
          ),
          radius,
        ),
        Paint()..color = progressColor,
      );
    }
    paintSponsorBlockSegments(canvas, track, segments, durationMs);
  }

  @override
  bool shouldRepaint(covariant SegmentedProgressPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      durationMs != oldDelegate.durationMs ||
      segments != oldDelegate.segments ||
      backgroundColor != oldDelegate.backgroundColor ||
      progressColor != oldDelegate.progressColor;
}
