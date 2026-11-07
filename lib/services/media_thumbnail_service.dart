import 'dart:io';

import 'package:flutter/services.dart';

const forcedInsertVideoIdPrefix = 'force-insert:';

/// Returns the explicit thumbnail URL, or the conventional YouTube fallback.
/// Local-only tracks deliberately have no YouTube fallback because their
/// synthetic IDs cannot resolve on i.ytimg.com.
String? resolveRemoteThumbnailUrl({
  String? thumbnailUrl,
  String? youtubeVideoId,
}) {
  if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) return thumbnailUrl;
  if (youtubeVideoId == null ||
      youtubeVideoId.isEmpty ||
      youtubeVideoId.startsWith(forcedInsertVideoIdPrefix)) {
    return null;
  }
  return 'https://i.ytimg.com/vi/$youtubeVideoId/hqdefault.jpg';
}

String? existingThumbnailPath(String? path) {
  if (path == null || path.isEmpty) return null;
  return File(path).existsSync() ? path : null;
}

/// Extracts cover art embedded in a media file into WoolyTube's private
/// thumbnail folder beside the playlist media.
class MediaThumbnailService {
  static const _channel = MethodChannel('com.woolytube/media_metadata');

  const MediaThumbnailService();

  /// Writes the embedded cover of [mediaPath] to `<targetStem>.<ext>` and
  /// returns that path, or null when the file has no cover. Only files with
  /// exactly [targetStem] as their stem are replaced.
  Future<String?> extractEmbeddedThumbnail({
    required String mediaPath,
    required String targetStem,
  }) async {
    try {
      final path = await _channel.invokeMethod<String>(
        'extractEmbeddedThumbnail',
        {'mediaPath': mediaPath, 'targetStem': targetStem},
      );
      return existingThumbnailPath(path);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
