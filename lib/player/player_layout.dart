import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';

/// Fixed geometry of the persistent player.
///
/// The mini bar and the expanded audio panel use fixed row heights so the
/// morph between them can be computed without measuring anything. Every
/// rectangle here is relative to the top edge of the sheet.
abstract final class PlayerLayout {
  // Mini bar ---------------------------------------------------------------
  static const double miniProgressHeight = 2;
  static const double miniRowHeight = 62;
  static const double miniHeight = miniProgressHeight + miniRowHeight;
  static const Rect miniThumb = Rect.fromLTWH(12, 9, 48, 48);
  static const double miniTitleLeft = 72;
  static const double miniTitleTop = 15;
  static const double miniTitleFontSize = 13;

  /// Two 48 dp buttons plus the right padding.
  static const double miniTrailingWidth = 104;

  // Expanded audio panel ---------------------------------------------------
  static const double panelHeaderHeight = 56;
  static const double panelArtRowTop = panelHeaderHeight + 4;
  static const double panelArtRowHeight = 84;
  static const Rect panelArt = Rect.fromLTWH(16, panelArtRowTop + 6, 128, 72);
  static const double panelTitleLeft = 158;
  static const double panelTitleTop = panelArtRowTop + 6;
  static const double panelTitleFontSize = 16;

  /// Everything above this line is the panel's drag area.
  static const double panelDragAreaHeight =
      panelArtRowTop + panelArtRowHeight + 4;
  static const double seekTop = panelDragAreaHeight;
  static const double seekSliderHeight = 36;
  static const double seekHorizontalPadding = 8;

  /// The slider's track starts this far from each side of the slider box:
  /// max(overlay radius, thumb radius) with Flutter's default track shape.
  static const double seekTrackInset = 14;
  static const double seekTrackHeight = 4;
  static const double seekTimesHeight = 18;
  static const double transportTop =
      seekTop + seekSliderHeight + seekTimesHeight + 2;
  static const double transportHeight = 80;
  static const double secondaryTop = transportTop + transportHeight + 6;
  static const double secondaryHeight = 64;
  static const double panelBottomPadding = 12;
  static const double panelContentHeight =
      secondaryTop + secondaryHeight + panelBottomPadding;

  // Colours ----------------------------------------------------------------
  static const Color miniBackground = Color(0xFF2A2A2A);
  static const Color panelBackground = Color(0xFF202020);
  static const Color accent = Color(0xFF2196F3);
  static const Color activeToggle = Color(0xFF64B5F6);
  static const Color secondaryText = Color(0xFFB0B0B0);
  static const Color mutedText = Color(0xFF8A8A8A);
  static const Color trackBackground = Color(0xFF444444);
  static const Color miniTrackBackground = Color(0xFF3A3A3A);
}

/// Screen-size dependent geometry of the sheet.
@immutable
class PlayerGeometry {
  final Size size;

  /// System navigation bar / gesture area at the bottom of the screen.
  final double bottomInset;

  /// Status bar height.
  final double topInset;

  const PlayerGeometry({
    required this.size,
    required this.bottomInset,
    required this.topInset,
  });

  double get miniHeight => PlayerLayout.miniHeight + bottomInset;

  /// Height of the expanded audio panel including the system inset. It never
  /// covers more than the screen below the status bar minus a strip of page
  /// that stays visible and usable above it.
  double get panelHeight {
    final wanted = PlayerLayout.panelContentHeight + bottomInset;
    final maxHeight = size.height - topInset - 72;
    return math.max(miniHeight, math.min(wanted, maxHeight));
  }

  /// Logical pixels the expanded audio panel covers above the reserved
  /// mini-player strip (the `audioPlayerOverlayHeightNotifier` contract).
  double get overlayHeight => panelHeight - miniHeight;

  /// Fully expanded height for a [videoness] between 0 (audio) and 1 (video).
  double expandedHeight(double videoness) =>
      lerpDouble(panelHeight, size.height, videoness)!;

  double sheetHeight(double expansion, double videoness) =>
      lerpDouble(miniHeight, expandedHeight(videoness), expansion)!;

  /// The distance a full drag covers, used to turn finger movement into an
  /// expansion fraction.
  double dragRange(double videoness) =>
      math.max(1, expandedHeight(videoness) - miniHeight);

  Rect get seekTrack {
    const inset =
        PlayerLayout.seekHorizontalPadding + PlayerLayout.seekTrackInset;
    return Rect.fromLTWH(
      inset,
      PlayerLayout.seekTop +
          (PlayerLayout.seekSliderHeight - PlayerLayout.seekTrackHeight) / 2,
      math.max(0, size.width - inset * 2),
      PlayerLayout.seekTrackHeight,
    );
  }

  Rect get miniProgressLine =>
      Rect.fromLTWH(0, 0, size.width, PlayerLayout.miniProgressHeight);

  double get miniTitleWidth => math.max(
    0,
    size.width - PlayerLayout.miniTitleLeft - PlayerLayout.miniTrailingWidth,
  );

  double get panelTitleWidth =>
      math.max(0, size.width - PlayerLayout.panelTitleLeft - 16);

  @override
  bool operator ==(Object other) =>
      other is PlayerGeometry &&
      other.size == size &&
      other.bottomInset == bottomInset &&
      other.topInset == topInset;

  @override
  int get hashCode => Object.hash(size, bottomInset, topInset);
}

/// Fraction of [t] inside [begin]..[end], clamped to 0..1.
double intervalOf(double t, double begin, double end) {
  if (t <= begin) return 0;
  if (t >= end) return 1;
  return (t - begin) / (end - begin);
}

/// One clock format for every player time label: m:ss, or h:mm:ss from one
/// hour on.
String formatClock(Duration duration) {
  final negative = duration.isNegative;
  final d = negative ? -duration : duration;
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final text =
      hours > 0
          ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
          : '$minutes:$seconds';
  return negative ? '-$text' : text;
}

/// The rectangle a video of [aspect] occupies when fitted into [box].
Rect fitVideoRect(Rect box, double aspect, {required bool cover}) {
  if (box.isEmpty || aspect <= 0) return box;
  final boxAspect = box.width / box.height;
  final widthLimited = cover ? boxAspect > aspect : boxAspect < aspect;
  final size =
      widthLimited
          ? Size(box.width, box.width / aspect)
          : Size(box.height * aspect, box.height);
  return Rect.fromCenter(
    center: box.center,
    width: size.width,
    height: size.height,
  );
}
