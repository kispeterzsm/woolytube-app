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

/// Cover files known to exist, so widgets that show a cover in every list
/// row do not ask the (slow, FUSE-backed) shared storage again on every
/// rebuild. Only positive answers are kept: a missing cover is checked
/// again next time, so a cover that appears later is found at once. A
/// cover deleted outside the app is still shown as present; every image
/// widget falls back to the remote image or a placeholder when the file
/// cannot be loaded.
final _knownThumbnails = <String>{};
const _maxKnownThumbnails = 20000;

/// [path] when that cover file exists, else null. Cheap enough for build
/// methods: a cover seen once is not checked on disk again.
///
/// Code that is about to keep, copy or record a cover must check the disk
/// itself (see [thumbnailFileExists]): this answer can be out of date for a
/// file deleted outside the app.
String? existingThumbnailPath(String? path) {
  if (path == null || path.isEmpty) return null;
  if (_knownThumbnails.contains(path)) return path;
  if (!File(path).existsSync()) return null;
  if (_knownThumbnails.length >= _maxKnownThumbnails) _knownThumbnails.clear();
  _knownThumbnails.add(path);
  return path;
}

/// Records that a cover was written to [path], so the next
/// [existingThumbnailPath] needs no disk check.
void noteThumbnailWritten(String? path) {
  if (path == null || path.isEmpty) return;
  if (_knownThumbnails.length >= _maxKnownThumbnails) _knownThumbnails.clear();
  _knownThumbnails.add(path);
}

/// Forgets [path] after its cover was deleted or moved away.
void noteThumbnailRemoved(String? path) {
  if (path == null || path.isEmpty) return;
  _knownThumbnails.remove(path);
}

/// Forgets every cover under [folder] (a deleted or moved playlist folder).
void forgetThumbnailsUnder(String folder) {
  if (folder.isEmpty) return;
  final prefix =
      folder.endsWith(Platform.pathSeparator)
          ? folder
          : '$folder${Platform.pathSeparator}';
  _knownThumbnails.removeWhere((path) => path.startsWith(prefix));
}

/// Whether the cover at [path] exists, asked of the disk (asynchronously)
/// rather than of the cache. Keeps the cache up to date.
Future<bool> thumbnailFileExists(String? path) async {
  if (path == null || path.isEmpty) return false;
  final exists = await File(path).exists();
  if (exists) {
    noteThumbnailWritten(path);
  } else {
    noteThumbnailRemoved(path);
  }
  return exists;
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
      return await thumbnailFileExists(path) ? path : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
