/// Maps raw yt-dlp / download exception text to a short user-facing message.
///
/// Falls back to the first line of [raw], truncated, when no known pattern
/// matches so the user still sees something meaningful.
String friendlyDownloadError(String raw) {
  final lower = raw.toLowerCase();
  if (isRemovedFromYouTubeError(raw)) return 'Removed from YouTube';
  // "Sign in to confirm you're not a bot" is YouTube blocking the
  // downloader, not an age check. It usually passes after a while or with
  // a newer yt-dlp.
  if (isBotCheckDownloadError(raw)) {
    return 'YouTube asked to confirm this is not a bot. Try again later.';
  }
  if (isAgeGateDownloadError(raw)) {
    return 'Age-restricted — needs sign-in';
  }
  if (lower.contains('private video')) return 'Private video';
  if (lower.contains('members-only') || lower.contains('members only')) {
    return 'Members-only video';
  }
  if (lower.contains('premium')) return 'YouTube Premium only';
  if (lower.contains('http error 403') ||
      lower.contains('rate-limit') ||
      lower.contains(' 429')) {
    return 'Blocked by YouTube (rate-limited)';
  }
  if (lower.contains('geo') && lower.contains('restrict')) {
    return 'Geo-restricted';
  }
  if (lower.contains('live event')) return 'Live event, not downloadable';
  if (lower.contains('video unavailable') ||
      lower.contains('this video is not available')) {
    return 'Video unavailable';
  }
  if (lower.contains('network') || lower.contains('connection')) {
    return 'Network error';
  }
  // Fallback: first non-empty line, truncated.
  final firstLine = raw
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  if (firstLine.isEmpty) return 'Download failed';
  if (firstLine.length > 120) {
    return '${firstLine.substring(0, 120)}...';
  }
  return firstLine;
}

/// True when [raw] describes YouTube's age-confirmation gate.
bool isAgeGateDownloadError(String raw) {
  final lower = raw.toLowerCase();
  if (isBotCheckDownloadError(raw)) return false;
  return lower.contains('confirm your age') ||
      lower.contains('sign in to confirm') ||
      lower.contains('age-restricted');
}

/// True when YouTube refused the download with its "not a bot" check.
bool isBotCheckDownloadError(String raw) =>
    raw.toLowerCase().contains('not a bot');

/// Phrases YouTube uses only for videos it has taken down for good.
///
/// A bare "Video unavailable" is deliberately not among them: YouTube also
/// answers bot checks and throttled requests with it, and a temporary
/// refusal must never stop a track from being downloaded later.
const _removedFromYouTubePhrases = [
  'this video has been removed',
  'video has been removed by the uploader',
  'removed for violating',
  'violates youtube\'s community guidelines',
  'violating youtube\'s community guidelines',
  'violating youtube\'s terms of service',
  'copyright removal request',
  'removed following a copyright',
  'due to a copyright claim',
  'account associated with this video has been terminated',
  'uploader has closed their youtube account',
  'youtube account associated with this video has been terminated',
];

/// True when a download failed because YouTube removed the video for good
/// (a copyright claim, a guideline violation, a terminated account). Such a
/// track is marked "Removed from YouTube" and is not retried by updates.
bool isRemovedFromYouTubeError(String raw) {
  final lower = raw.toLowerCase().replaceAll('’', "'");
  if (isBotCheckDownloadError(raw)) return false;
  return _removedFromYouTubePhrases.any(lower.contains);
}
