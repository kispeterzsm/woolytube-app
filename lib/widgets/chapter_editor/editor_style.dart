import 'package:flutter/material.dart';

import '../../services/chapters.dart';

/// Colours and text helpers shared by the chapter editor widgets.
abstract final class EditorColors {
  static const muted = Color(0xFF999999);
  static const panel = Color(0xFF262626);
  static const track = Color(0xFF333333);

  /// The boundary being edited, everywhere it is drawn.
  static const boundary = Color(0xFFFFCA28);

  /// The preview playhead.
  static const playhead = Color(0xFF81C784);

  /// Where the boundary was when the editor opened.
  static const original = Color(0xFFBDBDBD);

  static const gap = Color(0xFF2C2C2C);
  static const gapHatch = Color(0xFF4A4A4A);

  static const youTube = Color(0xFFE57373);
  static const auto = Color(0xFFBA68C8);
  static const yours = Color(0xFF64B5F6);

  /// The colour of a chapter of [origin]; every other chapter is a little
  /// darker so neighbours stay apart.
  static Color chapter(ChapterOrigin origin, int index) {
    final base = switch (origin) {
      ChapterOrigin.original => youTube,
      ChapterOrigin.auto => auto,
      ChapterOrigin.user => yours,
    };
    return index.isEven ? base : Color.lerp(base, Colors.black, 0.28)!;
  }
}

/// "YouTube", "Auto" or "Yours".
String originName(ChapterOrigin origin) => switch (origin) {
  ChapterOrigin.original => 'YouTube',
  ChapterOrigin.auto => 'Auto',
  ChapterOrigin.user => 'Yours',
};

/// `m:ss.mmm`, or `h:mm:ss.mmm` from an hour on.
String preciseTime(int ms) {
  final negative = ms < 0;
  final abs = ms.abs();
  final hours = abs ~/ 3600000;
  final minutes = abs ~/ 60000 % 60;
  final seconds = abs ~/ 1000 % 60;
  final millis = abs % 1000;
  final ss = seconds.toString().padLeft(2, '0');
  final mmm = millis.toString().padLeft(3, '0');
  final body =
      hours > 0
          ? '$hours:${minutes.toString().padLeft(2, '0')}:$ss.$mmm'
          : '$minutes:$ss.$mmm';
  return negative ? '−$body' : body;
}

/// "+0.420 s" or "−1.250 s" ([decimals] after the point).
String signedSeconds(int ms, {int decimals = 3}) {
  final sign = ms < 0 ? '−' : '+';
  return '$sign${(ms.abs() / 1000).toStringAsFixed(decimals)} s';
}

const tabularFigures = [FontFeature.tabularFigures()];
