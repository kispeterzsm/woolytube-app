import 'package:share_plus/share_plus.dart';

import '../database/database.dart';
import 'chapters.dart';
import 'media_thumbnail_service.dart' show forcedInsertVideoIdPrefix;

/// Whether a chapter time in [track] is also a time in its YouTube video, so
/// a link to it lands on the same moment. Inserted local files have made-up
/// video IDs, and a file the user put in place of the original keeps the ID
/// but has its own timeline.
bool hasYouTubeTimeline(Track track) =>
    track.videoId.isNotEmpty &&
    !track.videoId.startsWith(forcedInsertVideoIdPrefix) &&
    !track.isLocalReplacement;

/// The YouTube watch link of [track]'s video.
String youTubeVideoUrl(Track track) =>
    'https://www.youtube.com/watch?v=${track.videoId}';

/// Opens the system share sheet with [track]'s YouTube link.
Future<void> shareYouTubeVideo(Track track, {SharePlus? sharePlus}) async {
  await (sharePlus ?? SharePlus.instance).share(
    ShareParams(uri: Uri.parse(youTubeVideoUrl(track)), title: track.title),
  );
}

/// A short YouTube link that starts [videoId] at [startMs], rounded down to
/// the whole second (YouTube's `t=` takes seconds).
String youTubeTimestampUrl(String videoId, {required int startMs}) {
  final seconds = startMs <= 0 ? 0 : startMs ~/ 1000;
  return 'https://youtu.be/${Uri.encodeComponent(videoId)}?t=$seconds';
}

/// The link to the start of [chapter] in [track]'s YouTube video.
String youTubeChapterUrl(Track track, MediaChapter chapter) =>
    youTubeTimestampUrl(track.videoId, startMs: chapter.startMs);

/// Opens the system share sheet with the link to the start of [chapter],
/// titled like the track share. Callers check [hasYouTubeTimeline] first.
Future<void> shareYouTubeChapter(
  Track track,
  MediaChapter chapter, {
  SharePlus? sharePlus,
}) async {
  await (sharePlus ?? SharePlus.instance).share(
    ShareParams(
      uri: Uri.parse(youTubeChapterUrl(track, chapter)),
      title: chapter.title,
    ),
  );
}
