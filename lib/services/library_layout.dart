import 'package:path/path.dart' as p;

/// Names and paths of everything WoolyTube keeps inside a playlist folder
/// besides the media files themselves.
///
/// A playlist folder is meant to be a complete, self-describing copy of the
/// playlist: media files named `<index>_<title>.<ext>`, the
/// `woolytube_meta.json` sidecar, a `.m3u8` playlist and these hidden helper
/// folders. Hidden folders keep cover images out of gallery apps.
class LibraryLayout {
  LibraryLayout._();

  static const defaultAudioBasePath = '/storage/emulated/0/Music/WoolyTube';
  static const defaultVideoBasePath = '/storage/emulated/0/Movies/WoolyTube';

  static String _audioBasePath = defaultAudioBasePath;
  static String _videoBasePath = defaultVideoBasePath;

  static String get audioBasePath => _audioBasePath;
  static String get videoBasePath => _videoBasePath;

  /// Points the library at other folders. Tests only.
  static void overrideBasePathsForTesting({
    required String audio,
    required String video,
  }) {
    _audioBasePath = audio;
    _videoBasePath = video;
  }

  static void resetBasePathsForTesting() {
    _audioBasePath = defaultAudioBasePath;
    _videoBasePath = defaultVideoBasePath;
  }

  /// Cover art the app shows offline, one file per track plus the playlist
  /// cover. Named by video id so the names survive a reinstall and import.
  static const thumbnailsDirName = '.woolytube_thumbnails';

  /// Per-track working folders for yt-dlp. A download only ever writes here;
  /// the finished file is moved into the playlist folder afterwards, so a
  /// killed or failed download can never leave a broken file beside the
  /// real ones or overwrite an existing copy.
  static const stagingDirName = '.woolytube-staging';

  /// Previous files the owner replaced (for example with a local file) are
  /// kept here instead of being deleted.
  static const replacedDirName = '.woolytube_replaced';

  /// Trimmed yt-dlp metadata (uploader, upload date, description, ...) per
  /// video, kept because YouTube may delete the original.
  static const infoDirName = '.woolytube_info';

  static const playlistCoverStemName = '_playlist_cover';

  static String basePathFor({required bool audioOnly}) =>
      audioOnly ? audioBasePath : videoBasePath;

  static String thumbnailsDir(String playlistPath) =>
      p.join(playlistPath, thumbnailsDirName);

  static String stagingRoot(String playlistPath) =>
      p.join(playlistPath, stagingDirName);

  static String replacedDir(String playlistPath) =>
      p.join(playlistPath, replacedDirName);

  static String infoDir(String playlistPath) =>
      p.join(playlistPath, infoDirName);

  /// File-name-safe form of a video id. Forced inserts use synthetic ids
  /// such as `force-insert:1700000000`.
  static String safeId(String videoId) {
    final safe = videoId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe.isEmpty ? '_' : safe;
  }

  /// Path without extension of a track's cover image. A local replacement
  /// gets its own name so that switching back to the YouTube original keeps
  /// the original cover.
  static String trackThumbnailStem(
    String playlistPath,
    String videoId, {
    bool localFile = false,
  }) => p.join(
    thumbnailsDir(playlistPath),
    localFile ? '${safeId(videoId)}.local' : safeId(videoId),
  );

  static String playlistCoverStem(String playlistPath) =>
      p.join(thumbnailsDir(playlistPath), playlistCoverStemName);

  static String infoJsonPath(String playlistPath, String videoId) =>
      p.join(infoDir(playlistPath), '${safeId(videoId)}.info.json');

  /// A track's lyrics and transcripts with their lines, so they survive a
  /// reinstall (see `lyrics_files.dart`).
  static String lyricsJsonPath(String playlistPath, String videoId) =>
      p.join(infoDir(playlistPath), '${safeId(videoId)}.lyrics.json');

  /// Whether [path] lies strictly inside one of the two library roots, one
  /// level down (a playlist folder). Guards every recursive operation.
  static bool isPlaylistFolder(String path) {
    final normalized = p.normalize(p.absolute(path));
    for (final base in [audioBasePath, videoBasePath]) {
      if (p.equals(p.dirname(normalized), base) &&
          !p.equals(normalized, base)) {
        return true;
      }
    }
    return false;
  }
}
