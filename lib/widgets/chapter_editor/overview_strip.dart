import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/chapter_draft.dart';
import 'editor_style.dart';

/// The whole file as one bar: chapters coloured by where they came from,
/// gaps hatched, every boundary as a tick, the boundary being edited
/// highlighted and the preview playhead as a line.
///
/// A tap near a boundary selects it; a tap elsewhere (or a drag) moves the
/// playhead there.
class ChapterOverviewStrip extends StatefulWidget {
  const ChapterOverviewStrip({
    super.key,
    required this.chapters,
    required this.edgesMs,
    required this.durationMs,
    required this.selectedIndex,
    required this.playhead,
    required this.lensSpanMs,
    required this.onSelectEdge,
    required this.onSeek,
  });

  final List<DraftChapter> chapters;

  /// Every boundary's position, in the order of `ChapterDraft.edges`.
  final List<int> edgesMs;
  final int durationMs;

  /// Index into [edgesMs] of the boundary being edited, if any.
  final int? selectedIndex;
  final ValueListenable<int> playhead;

  /// How much of the file the waveform shows around the boundary.
  final int lensSpanMs;
  final ValueChanged<int> onSelectEdge;
  final ValueChanged<int> onSeek;

  /// How close (in pixels) a tap must be to a boundary to select it.
  static const _hitSlop = 18.0;

  @override
  State<ChapterOverviewStrip> createState() => _ChapterOverviewStripState();
}

class _ChapterOverviewStripState extends State<ChapterOverviewStrip> {
  /// The playhead while the finger scrubs, null otherwise.
  final _scrub = ValueNotifier<int?>(null);

  @override
  void dispose() {
    _scrub.dispose();
    super.dispose();
  }

  int _msAt(double x, double width) {
    if (width <= 0 || widget.durationMs <= 0) return 0;
    return (x / width * widget.durationMs).round().clamp(0, widget.durationMs);
  }

  void _tap(Offset local, double width) {
    if (widget.durationMs <= 0) return;
    var best = -1;
    var bestDistance = double.infinity;
    for (var i = 0; i < widget.edgesMs.length; i++) {
      final x = widget.edgesMs[i] / widget.durationMs * width;
      final d = (x - local.dx).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    if (best >= 0 && bestDistance <= ChapterOverviewStrip._hitSlop) {
      widget.onSelectEdge(best);
    } else {
      widget.onSeek(_msAt(local.dx, width));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          key: const ValueKey('editor-overview'),
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _tap(d.localPosition, width),
          onHorizontalDragStart:
              (d) => _scrub.value = _msAt(d.localPosition.dx, width),
          onHorizontalDragUpdate:
              (d) => _scrub.value = _msAt(d.localPosition.dx, width),
          onHorizontalDragEnd: (_) {
            final ms = _scrub.value;
            _scrub.value = null;
            if (ms != null) widget.onSeek(ms);
          },
          onHorizontalDragCancel: () => _scrub.value = null,
          child: SizedBox(
            height: 44,
            width: double.infinity,
            child: CustomPaint(
              painter: _OverviewPainter(
                chapters: widget.chapters,
                edgesMs: widget.edgesMs,
                durationMs: widget.durationMs,
                selectedIndex: widget.selectedIndex,
                playhead: widget.playhead,
                scrub: _scrub,
                lensSpanMs: widget.lensSpanMs,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter({
    required this.chapters,
    required this.edgesMs,
    required this.durationMs,
    required this.selectedIndex,
    required this.playhead,
    required this.scrub,
    required this.lensSpanMs,
  }) : super(repaint: Listenable.merge([playhead, scrub]));

  final List<DraftChapter> chapters;
  final List<int> edgesMs;
  final int durationMs;
  final int? selectedIndex;
  final ValueListenable<int> playhead;
  final ValueListenable<int?> scrub;
  final int lensSpanMs;

  static const _barTop = 10.0;
  static const _barBottom = 38.0;

  @override
  void paint(Canvas canvas, Size size) {
    final bar = Rect.fromLTRB(0, _barTop, size.width, _barBottom);
    final clip = RRect.fromRectAndRadius(bar, const Radius.circular(6));
    canvas.save();
    canvas.clipRRect(clip);
    _hatch(canvas, bar);
    if (durationMs <= 0) {
      canvas.restore();
      return;
    }
    double x(int ms) => ms / durationMs * size.width;

    for (final (i, c) in chapters.indexed) {
      final rect = Rect.fromLTRB(x(c.startMs), bar.top, x(c.endMs), bar.bottom);
      canvas.drawRect(rect, Paint()..color = EditorColors.chapter(c.origin, i));
    }
    final tick = Paint()..color = const Color(0xCC1E1E1E);
    for (final ms in edgesMs) {
      canvas.drawRect(
        Rect.fromLTWH(x(ms) - 0.75, bar.top, 1.5, bar.height),
        tick,
      );
    }
    canvas.restore();

    final selected = selectedIndex;
    if (selected != null && selected < edgesMs.length) {
      final sx = x(edgesMs[selected]);
      // The stretch the waveform shows.
      final half = lensSpanMs / 2 / durationMs * size.width;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            max(0, sx - half),
            bar.top - 3,
            min(size.width, sx + half),
            bar.bottom + 3,
          ),
          const Radius.circular(4),
        ),
        Paint()
          ..color = EditorColors.boundary.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      canvas.drawRect(
        Rect.fromLTWH(sx - 1.5, bar.top - 4, 3, bar.height + 8),
        Paint()..color = EditorColors.boundary,
      );
      final arrow =
          Path()
            ..moveTo(sx - 6, 0)
            ..lineTo(sx + 6, 0)
            ..lineTo(sx, 7)
            ..close();
      canvas.drawPath(arrow, Paint()..color = EditorColors.boundary);
    }

    final at = scrub.value ?? playhead.value;
    final px = x(at.clamp(0, durationMs));
    canvas.drawRect(
      Rect.fromLTWH(px - 1, bar.top - 2, 2, bar.height + 4),
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(px, bar.bottom + 4),
      3,
      Paint()..color = Colors.white,
    );
  }

  /// Diagonal lines: no chapter here.
  void _hatch(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, Paint()..color = EditorColors.gap);
    final line =
        Paint()
          ..color = EditorColors.gapHatch
          ..strokeWidth = 1;
    for (var x = rect.left - rect.height; x < rect.right; x += 7) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        line,
      );
    }
  }

  @override
  bool shouldRepaint(_OverviewPainter old) =>
      !identical(old.chapters, chapters) ||
      !listEquals(old.edgesMs, edgesMs) ||
      old.durationMs != durationMs ||
      old.selectedIndex != selectedIndex ||
      old.lensSpanMs != lensSpanMs ||
      old.playhead != playhead;
}
