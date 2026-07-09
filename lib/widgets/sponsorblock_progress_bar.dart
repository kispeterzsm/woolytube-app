import 'dart:math';

import 'package:flutter/material.dart';

import '../services/playback_service.dart';

class SegmentedProgressBar extends StatelessWidget {
  final double progress;
  final int durationMs;
  final List<PlaybackSponsorBlockSegment> segments;
  final double height;
  final Color backgroundColor;
  final Color progressColor;

  const SegmentedProgressBar({
    super.key,
    required this.progress,
    required this.durationMs,
    required this.segments,
    this.height = 3,
    this.backgroundColor = const Color(0xFF333333),
    this.progressColor = const Color(0xFF2196F3),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _SegmentedProgressPainter(
          progress: progress.clamp(0.0, 1.0),
          durationMs: durationMs,
          segments: segments,
          backgroundColor: backgroundColor,
          progressColor: progressColor,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class SegmentOverlayBar extends StatelessWidget {
  final int durationMs;
  final List<PlaybackSponsorBlockSegment> segments;
  final double height;

  const SegmentOverlayBar({
    super.key,
    required this.durationMs,
    required this.segments,
    this.height = 3,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _SegmentedProgressPainter(
          progress: 0,
          durationMs: durationMs,
          segments: segments,
          backgroundColor: Colors.transparent,
          progressColor: Colors.transparent,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SegmentedProgressPainter extends CustomPainter {
  final double progress;
  final int durationMs;
  final List<PlaybackSponsorBlockSegment> segments;
  final Color backgroundColor;
  final Color progressColor;

  const _SegmentedProgressPainter({
    required this.progress,
    required this.durationMs,
    required this.segments,
    required this.backgroundColor,
    required this.progressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final base = RRect.fromRectAndRadius(Offset.zero & size, radius);
    if (backgroundColor.alpha > 0) {
      canvas.drawRRect(base, Paint()..color = backgroundColor);
    }
    if (progressColor.alpha > 0 && progress > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * progress, size.height),
          radius,
        ),
        Paint()..color = progressColor,
      );
    }
    if (durationMs <= 0 || size.width <= 0) return;

    for (final segment in segments) {
      final start = segment.startMs.clamp(0, durationMs);
      final end = segment.endMs.clamp(start + 1, durationMs);
      final left = size.width * start / durationMs;
      final rawRight = size.width * end / durationMs;
      final right = min(size.width, max(rawRight, left + 2));
      if (right <= 0 || left >= size.width) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, 0, right - left, size.height),
          radius,
        ),
        Paint()..color = Color(segment.colorValue).withValues(alpha: 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentedProgressPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      durationMs != oldDelegate.durationMs ||
      segments != oldDelegate.segments ||
      backgroundColor != oldDelegate.backgroundColor ||
      progressColor != oldDelegate.progressColor;
}
