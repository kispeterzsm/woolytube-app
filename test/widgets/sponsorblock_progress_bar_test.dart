import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/sponsorblock_categories.dart';
import 'package:woolytube/widgets/sponsorblock_progress_bar.dart';

PlaybackSponsorBlockSegment _segment(int startMs, int endMs) =>
    PlaybackSponsorBlockSegment(
      id: startMs,
      source: 'sponsorblock',
      category: 'music_offtopic',
      label: 'Non-music',
      colorValue: 0xFFFF9900,
      action: SponsorBlockCategoryAction.showInSeekbar,
      actionType: 'skip',
      startMs: startMs,
      endMs: endMs,
    );

void main() {
  test(
    'a segment past the end of a shorter file is skipped, not thrown on',
    () {
      // Seen on the phone: the previous file's segment at 36:41 met the next
      // chapter's 2:36 length for one frame.
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      expect(
        () => paintSponsorBlockSegments(
          canvas,
          const Rect.fromLTWH(0, 0, 300, 4),
          [_segment(2201578, 2212544), _segment(156048, 156100)],
          156048,
        ),
        returnsNormally,
      );
      recorder.endRecording().dispose();
    },
  );
}
