import '../database/database.dart';

/// The `url` of the app's own "Temporary" playlist, which has no YouTube
/// playlist behind it.
const temporaryPlaylistUrl = 'woolytube:temporary';

/// The id of the one video a YouTube link points at (`watch?v=`, youtu.be,
/// shorts, live and embed links), or null for any other link. A
/// `watch?v=X&list=Y` link gives X.
String? youTubeVideoIdFromUrl(String? url) {
  final uri = Uri.tryParse(url?.trim() ?? '');
  if (uri == null || uri.host.isEmpty) return null;
  final host = uri.host.toLowerCase();
  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    final segments = uri.pathSegments;
    if (segments.length == 1 && segments.first.toLowerCase() == 'watch') {
      id = uri.queryParameters['v'];
    } else if (segments.length >= 2 &&
        const {
          'shorts',
          'live',
          'embed',
        }.contains(segments.first.toLowerCase())) {
      id = segments[1];
    }
  }
  return id != null && RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(id) ? id : null;
}

/// A playlist entry (`id`, `title`, `duration`, `thumbnail`) for the video
/// yt-dlp described in [info] (from `getVideoInfo`, which has no thumbnail:
/// YouTube's standard one is used).
Map<String, dynamic> videoEntryFromInfo(Map<String, dynamic> info) {
  final id = info['id'] as String? ?? '';
  return {
    'id': id,
    'title': info['title'] as String? ?? 'Unknown',
    if (info['duration'] is num) 'duration': info['duration'],
    'thumbnail':
        info['thumbnail'] as String? ??
        'https://i.ytimg.com/vi/$id/hqdefault.jpg',
  };
}

/// The video height caps offered to the user, highest first. Higher caps
/// are not offered: H.264, which the app prefers so every device can play
/// the files, rarely goes above 1080p on YouTube, so they would download
/// the same files as "Best".
const videoQualityCaps = <int>[1080, 720, 480, 360];

/// The height cap a download of [track] uses: null for the best available.
///
/// The track's own choice wins over the playlist's (0 there means the best),
/// and audio-only playlists never have a cap.
int? effectiveMaxHeight(Playlist playlist, Track track) => effectiveMaxHeightOf(
  audioOnly: playlist.audioOnly,
  playlistQuality: playlist.videoQuality,
  trackQuality: track.videoQuality,
);

/// [effectiveMaxHeight] from the bare values.
int? effectiveMaxHeightOf({
  required bool audioOnly,
  required int? playlistQuality,
  required int? trackQuality,
}) {
  if (audioOnly) return null;
  final quality = trackQuality ?? playlistQuality;
  return quality == null || quality <= 0 ? null : quality;
}

/// 'Best available' or 'Up to 720p'.
String videoQualityLabel(int? maxHeight) =>
    maxHeight == null || maxHeight <= 0
        ? 'Best available'
        : 'Up to ${maxHeight}p';

/// 'the best quality' or '720p', for sentences such as "Download 3 videos
/// again at 720p?".
String videoQualityShortLabel(int? maxHeight) =>
    maxHeight == null || maxHeight <= 0 ? 'the best quality' : '${maxHeight}p';

/// Whether [cap] (null = no cap) is lower than [other].
bool _isLowerCap(int? cap, int? other) =>
    cap != null && (other == null || cap < other);

/// The shorter side of a downloaded video, read from yt-dlp's kept info
/// ([info] is the decoded `.info.json`); null when it is not recorded.
///
/// yt-dlp compares resolutions by the shorter side, so a vertical 1080x1920
/// video counts as 1080p, like a landscape 1920x1080 one.
int? videoResolutionFromInfo(Map<String, dynamic>? info) {
  if (info == null) return null;
  final width = info['width'];
  final height = info['height'];
  final w = width is num && width > 0 ? width.toInt() : null;
  final h = height is num && height > 0 ? height.toInt() : null;
  if (w == null) return h;
  if (h == null) return w;
  return w < h ? w : h;
}

/// Whether a downloaded file gets better or smaller when it is downloaded
/// again after its cap changed from [oldMax] to [newMax] (null = the best).
///
/// [resolution] is the file's shorter side and [downloadedMaxHeight] the cap
/// it was downloaded under (0 = none); either may be unknown (null). When
/// it cannot be told, the file counts as affected: the user is asked first
/// anyway.
bool isAffectedByQualityChange({
  required int? oldMax,
  required int? newMax,
  required int? resolution,
  required int? downloadedMaxHeight,
}) {
  if (oldMax == newMax) return false;
  if (_isLowerCap(newMax, oldMax)) {
    // Lowering: only a file above the new cap shrinks.
    return resolution == null || resolution > newMax!;
  }
  // Raising: only a file downloaded under a lower cap than the new one can
  // get better, and not when it was already below that cap (the video had
  // nothing sharper).
  final downloadedUnder = downloadedMaxHeight;
  if (downloadedUnder == null) return true;
  if (downloadedUnder <= 0) return false;
  if (!_isLowerCap(downloadedUnder, newMax)) return false;
  return resolution == null || resolution >= downloadedUnder;
}
