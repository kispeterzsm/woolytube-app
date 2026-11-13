import '../database/database.dart';
import 'download_errors.dart';

/// Why a track cannot be downloaded, in words: "Private video".
String unavailableTrackLabel(String? reason) {
  switch (reason) {
    case 'private':
      return 'Private video';
    case 'deleted':
      return 'Deleted video';
    case 'removed':
      return 'Removed from playlist';
    case removedFromYouTubeReason:
      return 'Removed from YouTube';
    case 'needs_auth':
      return 'Requires sign-in';
    case 'premium_only':
      return 'Premium only';
    default:
      return 'Unavailable';
  }
}

/// `3:45`, or `1:02:33` from an hour on; empty when the length is unknown.
String formatTrackLength(int? seconds) {
  if (seconds == null || seconds == 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// A track's state in the few words that fit the one grey line under it in
/// a list: `3:45`, `Rate-limited`, `1:02:33 · Removed, kept` (a removed
/// video whose file the app keeps).
///
/// The status icon next to the line already says failed, unavailable or
/// downloaded, so the words only add what the icon cannot. The track's
/// options sheet shows the full wording ([trackStatusInFull]).
String shortTrackStatus(Track track) {
  final length = formatTrackLength(track.durationSeconds);
  String withLength(String text) => length.isEmpty ? text : '$length · $text';

  final error = track.lastError;
  switch (track.status) {
    case 'error' when error != null:
      return shortDownloadError(error);
    case 'unavailable':
      return unavailableTrackLabel(track.unavailableReason);
    case 'complete' when track.unavailableReason != null:
      return withLength(_keptLabel(track.unavailableReason));
    case 'complete' when _replacementFailed(track):
      return withLength(
        _youTubeCopyUnavailable(error!) ? 'No YouTube copy' : 'New copy failed',
      );
    case 'downloading':
      return withLength('Downloading…');
  }
  return length;
}

/// The full wording of a track's state, for the track options sheet where
/// it has room: `Removed from YouTube (local file)`, `Download failed:
/// Blocked by YouTube (rate-limited)`.
String trackStatusInFull(Track track) {
  final error = track.lastError;
  return switch (track.status) {
    'complete' when track.unavailableReason != null =>
      '${unavailableTrackLabel(track.unavailableReason)} (local file)',
    'complete' when _replacementFailed(track) =>
      '${replacementFailureReason(error!)} · '
          '${track.isLocalReplacement ? 'keeping your file' : 'keeping the old file'}',
    'complete' when track.isLocalReplacement => 'Your own file',
    'complete' => 'Downloaded',
    'downloading' => 'Downloading…',
    'error' when error != null =>
      'Download failed: ${friendlyDownloadError(error)}',
    'error' => 'Download failed',
    'unavailable' => unavailableTrackLabel(track.unavailableReason),
    _ => 'Not downloaded',
  };
}

/// A video YouTube no longer offers whose file the app keeps, short
/// enough to follow an hour-long length on the row: "Removed, kept".
String _keptLabel(String? reason) {
  final gone = switch (reason) {
    'private' => 'Private',
    'deleted' => 'Deleted',
    'removed' => 'Off playlist',
    removedFromYouTubeReason => 'Removed',
    'needs_auth' => 'Sign-in only',
    'premium_only' => 'Premium',
    _ => 'Unavailable',
  };
  return '$gone, kept';
}

bool _replacementFailed(Track track) =>
    track.status == 'complete' &&
    track.replaceRequested &&
    track.unavailableReason == null &&
    track.lastError != null;

bool _youTubeCopyUnavailable(String error) =>
    replacementFailureReason(error) == 'YouTube version unavailable';
