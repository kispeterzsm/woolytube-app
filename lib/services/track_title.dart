import 'package:path/path.dart' as p;

import '../database/database.dart';

/// Whether [title] carries no real title: missing, blank, or the literal
/// "null" / "None" that a missing value turns into when it is printed
/// (Android's `JSONObject.optString` returns "null" for a JSON null, and
/// Python prints `None`).
bool isMissingTitle(String? title) {
  final trimmed = title?.trim() ?? '';
  return trimmed.isEmpty || trimmed == 'null' || trimmed == 'None';
}

/// Whether a stored title is only a stand-in that a real title from YouTube
/// (a download's metadata, a playlist update or a sidecar) should replace:
/// a missing title, or the video id that [resolveTrackTitle] stored when
/// YouTube gave none.
bool isStandInTitle(String? title, String videoId) =>
    isMissingTitle(title) || title!.trim() == videoId;

/// The title part of a track's file name: without the folder, the
/// `<index>_` prefix and the extension. Null when there is none.
String? titleFromFileName(String? filePath) {
  if (filePath == null || filePath.isEmpty) return null;
  final rest =
      p
          .basenameWithoutExtension(filePath)
          .replaceFirst(RegExp(r'^\d+_'), '')
          .trim();
  return isMissingTitle(rest) ? null : rest;
}

/// The title to store for a track: [title] when it is a real one, else the
/// [previous] title, else the video id. Never empty and never "null" or
/// "None". The video id is a stand-in: the next real title replaces it, and
/// [TrackDisplayTitle.displayTitle] shows the file name instead while there
/// is one.
String resolveTrackTitle(
  String? title, {
  String? previous,
  required String videoId,
}) {
  if (!isMissingTitle(title)) return title!.trim();
  if (!isMissingTitle(previous)) return previous!.trim();
  return videoId;
}

extension TrackDisplayTitle on Track {
  /// The title to show: [title], or for a stand-in ("null", "None", empty or
  /// the bare video id) the title part of the file name, else the video id.
  /// A later download, playlist update or sidecar import with a real title
  /// replaces the stored stand-in.
  String get displayTitle {
    if (!isStandInTitle(title, videoId)) return title;
    return titleFromFileName(filePath) ?? videoId;
  }
}
