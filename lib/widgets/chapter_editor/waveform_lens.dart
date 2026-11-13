import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../services/chapter_draft.dart';
import '../../services/chapters.dart';
import '../../services/waveform_service.dart';
import 'editor_style.dart';

/// A close-up of the audio around one boundary. The boundary stays in the
/// middle and the waveform moves under it: dragging the waveform to the
/// right moves the boundary earlier, like pulling tape. At the finest zoom
/// one pixel is a few milliseconds.
class WaveformLens extends StatefulWidget {
  const WaveformLens({
    super.key,
    required this.waveforms,
    required this.path,
    required this.centerMs,
    required this.spanMs,
    required this.durationMs,
    required this.chapters,
    required this.otherEdgesMs,
    required this.originalMs,
    required this.playhead,
    required this.showHint,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    required this.onSpanChanged,
  });

  final WaveformService? waveforms;

  /// The media file, or null when it is missing (no waveform then).
  final String? path;

  /// Where the boundary is now.
  final int centerMs;

  /// How much of the file the lens shows.
  final int spanMs;
  final int durationMs;
  final List<DraftChapter> chapters;

  /// The other boundaries, drawn as thin lines when they are in view.
  final List<int> otherEdgesMs;

  /// Where this boundary was when the editor opened, if it existed then.
  final int? originalMs;
  final ValueListenable<int> playhead;

  /// Shows "Drag the waveform to move the boundary".
  final bool showHint;
  final VoidCallback onDragStart;

  /// Asks to move the boundary to a time; returns where it really went
  /// (boundaries stop at their neighbours).
  final int Function(int ms) onDrag;
  final VoidCallback onDragEnd;

  /// A pinch changed the zoom.
  final ValueChanged<int> onSpanChanged;

  static const minSpanMs = 1000;
  static const maxSpanMs = 60000;
  static const height = 136.0;

  @override
  State<WaveformLens> createState() => _WaveformLensState();
}

class _WaveformLensState extends State<WaveformLens> {
  WaveformWindow? _window;
  (int, int)? _covered;
  (int, int)? _loading;
  (int, int)? _failed;

  double _width = 1;
  double? _dragMs;

  final _pointers = <int, Offset>{};
  double? _pinchDistance;
  int _pinchSpan = 0;

  @override
  void initState() {
    super.initState();
    _ensureLoaded();
  }

  @override
  void didUpdateWidget(WaveformLens old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _window = null;
      _covered = _loading = _failed = null;
    }
    _ensureLoaded();
  }

  /// Loads a stretch well beyond what is visible, so small moves never
  /// wait for audio.
  void _ensureLoaded() {
    final service = widget.waveforms;
    final path = widget.path;
    if (service == null || path == null) return;
    final duration = widget.durationMs;
    int upTo(int ms) => duration > 0 ? min(ms, duration) : ms;
    final needFrom = max(0, widget.centerMs - widget.spanMs);
    final needTo = upTo(widget.centerMs + widget.spanMs);
    bool covers((int, int)? r) =>
        r != null && r.$1 <= needFrom && r.$2 >= needTo;
    if (covers(_covered) || covers(_loading) || covers(_failed)) return;
    final margin = max(widget.spanMs * 2, 10000);
    final from = max(0, widget.centerMs - margin);
    final to = upTo(widget.centerMs + margin);
    if (to <= from) return;
    final range = (from, to);
    _loading = range;
    service
        .load(path, from, to)
        .then(
          (window) {
            if (!mounted || _loading != range) return;
            setState(() {
              _window = window;
              _covered = range;
              _loading = null;
            });
            _ensureLoaded();
          },
          onError: (Object _) {
            if (!mounted || _loading != range) return;
            setState(() {
              _loading = null;
              _failed = range;
            });
          },
        );
  }

  double get _msPerPixel => widget.spanMs / max(_width, 1);

  void _pointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      _pinchDistance = _distance();
      _pinchSpan = widget.spanMs;
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    final start = _pinchDistance;
    if (_pointers.length < 2 || start == null || start < 8) return;
    final now = _distance();
    if (now < 8) return;
    final span = (_pinchSpan * start / now).round().clamp(
      WaveformLens.minSpanMs,
      WaveformLens.maxSpanMs,
    );
    if (span != widget.spanMs) widget.onSpanChanged(span);
  }

  void _pointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2 && _pinchDistance != null) {
      _pinchDistance = null;
      // Carry on dragging from where the boundary is now.
      if (_dragMs != null) _dragMs = widget.centerMs.toDouble();
    }
  }

  double _distance() {
    final points = _pointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  @override
  Widget build(BuildContext context) {
    final loading = _window == null && _loading != null;
    final failed = _window == null && _failed != null && _loading == null;
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        // Claims a pinch's pointers, so the list the lens sits in does not
        // scroll while two fingers zoom.
        return RawGestureDetector(
          gestures: {
            _PinchClaimRecognizer:
                GestureRecognizerFactoryWithHandlers<_PinchClaimRecognizer>(
                  () => _PinchClaimRecognizer(debugOwner: this),
                  (_) {},
                ),
          },
          child: Listener(
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerUp,
            onPointerCancel: _pointerUp,
            child: GestureDetector(
              key: const ValueKey('editor-waveform'),
              behavior: HitTestBehavior.opaque,
              // The whole movement counts, so small drags are exact.
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragStart: (_) {
                _dragMs = widget.centerMs.toDouble();
                widget.onDragStart();
              },
              onHorizontalDragUpdate: (d) {
                final from = _dragMs;
                if (from == null || _pinchDistance != null) return;
                final wanted = from - d.delta.dx * _msPerPixel;
                final got = widget.onDrag(wanted.round());
                _dragMs = got == wanted.round() ? wanted : got.toDouble();
              },
              onHorizontalDragEnd: (_) {
                _dragMs = null;
                widget.onDragEnd();
              },
              onHorizontalDragCancel: () {
                _dragMs = null;
                widget.onDragEnd();
              },
              child: SizedBox(
                height: WaveformLens.height,
                width: double.infinity,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _LensPainter(
                          window: _window,
                          centerMs: widget.centerMs,
                          spanMs: widget.spanMs,
                          durationMs: widget.durationMs,
                          chapters: widget.chapters,
                          otherEdgesMs: widget.otherEdgesMs,
                          originalMs: widget.originalMs,
                          playhead: widget.playhead,
                        ),
                      ),
                    ),
                    if (widget.showHint || loading || failed)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 6,
                        child: IgnorePointer(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xCC1E1E1E),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                widget.showHint
                                    ? 'Drag the waveform to move the boundary'
                                    : loading
                                    ? 'Loading waveform…'
                                    : 'No waveform for this file',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFDDDDDD),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Wins the gesture arena of every pointer on the lens once a second finger
/// is down, so a pinch is never taken for a scroll of the enclosing list.
/// A single finger is left to the other recognizers (the lens's drag, the
/// list's scroll).
class _PinchClaimRecognizer extends OneSequenceGestureRecognizer {
  _PinchClaimRecognizer({super.debugOwner});

  /// The fingers on the lens, also those another recognizer already won.
  final _down = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _down.add(event.pointer);
    if (_down.length >= 2) resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _down.remove(event.pointer);
      // Not a pinch: give the pointer up before the arena is swept, so a
      // tap or drag elsewhere is not won by this recognizer.
      resolvePointer(event.pointer, GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'pinch claim';
}

class _LensPainter extends CustomPainter {
  _LensPainter({
    required this.window,
    required this.centerMs,
    required this.spanMs,
    required this.durationMs,
    required this.chapters,
    required this.otherEdgesMs,
    required this.originalMs,
    required this.playhead,
  }) : super(repaint: playhead);

  final WaveformWindow? window;
  final int centerMs;
  final int spanMs;
  final int durationMs;
  final List<DraftChapter> chapters;
  final List<int> otherEdgesMs;
  final int? originalMs;
  final ValueListenable<int> playhead;

  static const _rulerHeight = 18.0;
  static const _step = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final mpp = spanMs / max(w, 1);
    double xAt(num ms) => w / 2 + (ms - centerMs) / mpp;
    double tAt(double x) => centerMs + (x - w / 2) * mpp;
    final top = _rulerHeight;
    final bottom = h - 4;
    final mid = (top + bottom) / 2;
    final amp = (bottom - top) / 2 - 2;

    final frame = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(10),
    );
    canvas.save();
    canvas.clipRRect(frame);
    canvas.drawRect(Offset.zero & size, Paint()..color = EditorColors.panel);

    // Chapter tints, and darker past either end of the file.
    for (final (i, c) in chapters.indexed) {
      final left = xAt(c.startMs);
      final right = xAt(c.endMs);
      if (right < 0 || left > w) continue;
      canvas.drawRect(
        Rect.fromLTRB(left, top, right, bottom),
        Paint()
          ..color = EditorColors.chapter(c.origin, i).withValues(alpha: 0.13),
      );
    }
    final outside = Paint()..color = const Color(0xFF161616);
    if (xAt(0) > 0) canvas.drawRect(Rect.fromLTRB(0, 0, xAt(0), h), outside);
    if (durationMs > 0 && xAt(durationMs) < w) {
      canvas.drawRect(Rect.fromLTRB(xAt(durationMs), 0, w, h), outside);
    }

    _ruler(canvas, w, xAt, tAt);

    // The waveform, coloured by chapter: one bar per [_step] pixels' worth
    // of time. Bars are fixed to the file timeline, not to the screen, so
    // each is drawn centred on the audio it shows and moves smoothly with
    // the waveform while dragging.
    final data = window;
    var c = 0;
    final bar = Paint()..strokeWidth = 1.4;
    final barMs = _step * mpp;
    final last = (tAt(w + _step) / barMs).ceil();
    for (var k = (tAt(-_step) / barMs).floor(); k <= last; k++) {
      final t0 = k * barMs;
      final t1 = t0 + barMs;
      if (t1 <= 0 || (durationMs > 0 && t0 >= durationMs)) continue;
      final at = t0 + barMs / 2;
      final x = xAt(at);
      while (c < chapters.length && chapters[c].endMs <= at) {
        c++;
      }
      final inChapter = c < chapters.length && chapters[c].startMs <= at;
      final color =
          inChapter
              ? Color.lerp(
                EditorColors.chapter(chapters[c].origin, c),
                Colors.white,
                0.35,
              )!
              : const Color(0xFF8A8A8A);
      final peak = data == null ? -1.0 : _peak(data, t0, t1);
      if (peak < 0) {
        bar.color = const Color(0xFF444444);
        canvas.drawLine(Offset(x, mid - 1), Offset(x, mid + 1), bar);
        continue;
      }
      final level = max(1.0, pow(peak, 0.7) * amp);
      bar.color = color;
      canvas.drawLine(Offset(x, mid - level), Offset(x, mid + level), bar);
    }

    // Other boundaries.
    final edge =
        Paint()
          ..color = Colors.white.withValues(alpha: 0.55)
          ..strokeWidth = 1;
    for (final ms in otherEdgesMs) {
      final x = xAt(ms);
      if (x < 0 || x > w) continue;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), edge);
    }

    // Where the boundary was.
    final original = originalMs;
    if (original != null && original != centerMs) {
      final x = xAt(original);
      if (x >= 0 && x <= w) {
        final dash =
            Paint()
              ..color = EditorColors.original.withValues(alpha: 0.7)
              ..strokeWidth = 1;
        for (var y = top; y < bottom; y += 6) {
          canvas.drawLine(Offset(x, y), Offset(x, min(y + 3, bottom)), dash);
        }
      }
    }

    // The playhead.
    final px = xAt(playhead.value);
    if (px >= 0 && px <= w) {
      canvas.drawLine(
        Offset(px, top),
        Offset(px, bottom),
        Paint()
          ..color = EditorColors.playhead
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        Offset(px, top),
        3.5,
        Paint()..color = EditorColors.playhead,
      );
    }

    // The boundary, fixed in the middle. The line lets the audio right at
    // the boundary show through.
    final cx = w / 2;
    final line = Paint()..color = EditorColors.boundary;
    canvas.drawRect(
      Rect.fromLTWH(cx - 1.25, top - 2, 2.5, h - top),
      Paint()..color = EditorColors.boundary.withValues(alpha: 0.6),
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - 7, top - 7)
        ..lineTo(cx + 7, top - 7)
        ..lineTo(cx, top + 1)
        ..close(),
      line,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - 7, h)
        ..lineTo(cx + 7, h)
        ..lineTo(cx, h - 8)
        ..close(),
      line,
    );
    canvas.restore();
  }

  /// The loudest level between [t0] and [t1], or -1 without data there
  /// (buckets the decoder gave no audio for do not count as silence).
  double _peak(WaveformWindow data, double t0, double t1) {
    final bucket = data.bucketMs;
    var i0 = ((t0 - data.startMs) / bucket).floor();
    var i1 = ((t1 - data.startMs) / bucket).ceil();
    i0 = max(i0, 0);
    i1 = min(i1, data.peaks.length);
    var peak = -1.0;
    for (var i = i0; i < i1; i++) {
      final level = data.peaks[i];
      if (!level.isNaN && level > peak) peak = level;
    }
    return peak;
  }

  void _ruler(
    Canvas canvas,
    double w,
    double Function(num) xAt,
    double Function(double) tAt,
  ) {
    final (minor, label) = switch (spanMs) {
      <= 3000 => (100, 500),
      <= 12000 => (500, 2000),
      <= 40000 => (1000, 5000),
      _ => (5000, 15000),
    };
    final tick = Paint()..color = const Color(0xFF6A6A6A);
    final first = (max(0.0, tAt(0)) / minor).floor() * minor;
    final last = tAt(w);
    for (var t = first; t <= last; t += minor) {
      if (durationMs > 0 && t > durationMs) break;
      final x = xAt(t);
      final major = t % label == 0;
      canvas.drawRect(
        Rect.fromLTWH(x - 0.5, major ? 10 : 13, 1, major ? 8 : 5),
        tick,
      );
      if (!major) continue;
      final text = TextPainter(
        text: TextSpan(
          text: _label(t, fine: label < 1000),
          style: const TextStyle(
            color: Color(0xFF9E9E9E),
            fontSize: 10,
            fontFeatures: tabularFigures,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final left = min(max(0.0, x - text.width / 2), max(0.0, w - text.width));
      text.paint(canvas, Offset(left, -1));
    }
  }

  String _label(int ms, {required bool fine}) =>
      chapterClock(ms, fileMs: durationMs, decimals: fine ? 1 : 0);

  @override
  bool shouldRepaint(_LensPainter old) =>
      !identical(old.window, window) ||
      old.centerMs != centerMs ||
      old.spanMs != spanMs ||
      old.durationMs != durationMs ||
      !identical(old.chapters, chapters) ||
      !listEquals(old.otherEdgesMs, otherEdgesMs) ||
      old.originalMs != originalMs ||
      old.playhead != playhead;
}
