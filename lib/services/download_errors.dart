/// Maps raw yt-dlp / download exception text to a short user-facing message.
///
/// Falls back to the first line of [raw], truncated, when no known pattern
/// matches so the user still sees something meaningful.
String friendlyDownloadError(String raw) {
  final lower = raw.toLowerCase();
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
  return lower.contains('confirm your age') ||
      lower.contains('sign in to confirm') ||
      lower.contains('age-restricted');
}
