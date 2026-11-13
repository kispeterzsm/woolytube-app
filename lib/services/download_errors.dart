/// The known kinds of download failure, each with the sentence the app
/// shows ([friendly]) and the few words a one-line list row has room for
/// ([short]).
enum _DownloadErrorKind {
  notArchived('No archived copy was found', 'No archived copy'),
  removedFromYouTube('Removed from YouTube', 'Removed from YouTube'),
  botCheck(
    'YouTube asked to confirm this is not a bot. Try again later.',
    'Bot check, try later',
  ),
  ageGate('Age-restricted — needs sign-in', 'Age-restricted'),
  private('Private video', 'Private video'),
  membersOnly('Members-only video', 'Members only'),
  premium('YouTube Premium only', 'Premium only'),
  rateLimited('Blocked by YouTube (rate-limited)', 'Rate-limited'),
  geoRestricted('Geo-restricted', 'Geo-restricted'),
  liveEvent('Live event, not downloadable', 'Live event'),
  unavailable('Video unavailable', 'Video unavailable'),
  network('Network error', 'Network error');

  const _DownloadErrorKind(this.friendly, this.short);

  final String friendly;
  final String short;

  static _DownloadErrorKind? of(String raw) {
    final lower = raw.toLowerCase();
    // The Wayback Machine has no saved copy of this video.
    if (lower.contains('not archived or indexed')) return notArchived;
    if (isRemovedFromYouTubeError(raw)) return removedFromYouTube;
    // "Sign in to confirm you're not a bot" is YouTube blocking the
    // downloader, not an age check. It usually passes after a while or with
    // a newer yt-dlp.
    if (isBotCheckDownloadError(raw)) return botCheck;
    if (isAgeGateDownloadError(raw)) return ageGate;
    if (lower.contains('private video')) return private;
    if (lower.contains('members-only') || lower.contains('members only')) {
      return membersOnly;
    }
    if (lower.contains('premium')) return premium;
    if (lower.contains('http error 403') ||
        lower.contains('rate-limit') ||
        lower.contains(' 429')) {
      return rateLimited;
    }
    if (lower.contains('geo') && lower.contains('restrict')) {
      return geoRestricted;
    }
    if (lower.contains('live event')) return liveEvent;
    if (lower.contains('video unavailable') ||
        lower.contains('this video is not available')) {
      return unavailable;
    }
    if (lower.contains('network') || lower.contains('connection')) {
      return network;
    }
    return null;
  }
}

/// Maps raw yt-dlp / download exception text to a short user-facing message.
///
/// Falls back to the first line of [raw], truncated, when no known pattern
/// matches so the user still sees something meaningful.
String friendlyDownloadError(String raw) {
  final kind = _DownloadErrorKind.of(raw);
  if (kind != null) return kind.friendly;
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

/// The reason a download failed in at most a few words, for the one grey
/// line under a track in a list ("Rate-limited", "Bot check, try later").
/// An unknown error is just "Download failed"; the track's options sheet
/// and its error details have the full text.
String shortDownloadError(String raw) =>
    _DownloadErrorKind.of(raw)?.short ?? 'Download failed';

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
/// track is marked "Removed from YouTube"; updates try it again quietly.
bool isRemovedFromYouTubeError(String raw) {
  final lower = raw.toLowerCase().replaceAll('’', "'");
  if (isBotCheckDownloadError(raw)) return false;
  return _removedFromYouTubePhrases.any(lower.contains);
}

/// Words in an error that mean the device could not reach YouTube at all,
/// as opposed to YouTube answering with a refusal.
const _networkErrorPatterns = [
  'no address associated with hostname',
  'temporary failure in name resolution',
  'name or service not known',
  'failed to resolve',
  'network is unreachable',
  'connection refused',
  'connection reset',
  'connection closed',
  'connection aborted',
  'timed out',
  'timeout',
  'urlopen error',
];

/// True when a download failed because YouTube could not be reached (no
/// network, DNS, a timeout), so nothing was learned about the video.
bool isNetworkDownloadError(String raw) {
  final lower = raw.toLowerCase();
  return _networkErrorPatterns.any(lower.contains);
}

/// Why a fresh copy of a track that keeps its file could not be fetched,
/// for example the YouTube original of a local replacement:
/// "YouTube version unavailable".
String replacementFailureReason(String raw) {
  final friendly = friendlyDownloadError(raw);
  if (friendly == 'Video unavailable' || friendly == 'Removed from YouTube') {
    return 'YouTube version unavailable';
  }
  return 'YouTube version failed: ${lowerFirst(friendly)}';
}

/// [text] with a lower-case first letter, unless its first word is a name
/// or an abbreviation ("YouTube", "HTTP").
String lowerFirst(String text) {
  if (text.isEmpty) return text;
  final firstWord = text.split(RegExp(r'[\s\-—:(]')).first;
  if (firstWord.length > 1 &&
      firstWord.substring(1) != firstWord.substring(1).toLowerCase()) {
    return text;
  }
  return text[0].toLowerCase() + text.substring(1);
}

/// A track a playlist run could not download.
class DownloadFailure {
  const DownloadFailure({
    required this.trackId,
    required this.title,
    required this.error,
    this.replacement = false,
  });

  final int trackId;
  final String title;

  /// What the downloader said, cleaned up.
  final String error;

  /// A fresh copy of a track that has a file (the original of a local file,
  /// or another format) failed; the file is kept.
  final bool replacement;

  /// The short reason shown to the user.
  String get reason =>
      replacement
          ? replacementFailureReason(error)
          : friendlyDownloadError(error);

  /// The same track failing the same way gives the same key.
  String get key => '$trackId:$reason';

  @override
  bool operator ==(Object other) =>
      other is DownloadFailure &&
      other.trackId == trackId &&
      other.title == title &&
      other.error == error &&
      other.replacement == replacement;

  @override
  int get hashCode => Object.hash(trackId, title, error, replacement);
}

/// How many failed tracks a message names; the rest are counted.
const maxNamedDownloadFailures = 3;

const _maxTitleLength = 40;

/// One line per failure, at most [maxNamedDownloadFailures], each
/// `"Title" – reason`, then `+N more` for the rest.
List<String> downloadFailureLines(List<DownloadFailure> failures) {
  final named = failures.take(maxNamedDownloadFailures);
  final more = failures.length - named.length;
  return [
    for (final failure in named)
      '"${_shortTitle(failure.title)}" – ${lowerFirst(failure.reason)}',
    if (more > 0) '+$more more',
  ];
}

/// One line naming [playlistName] and its failed tracks:
/// `vibe mix: "Old School Nightcore Mix" – video unavailable`.
String describeDownloadFailures(
  String playlistName,
  List<DownloadFailure> failures,
) {
  final lines = downloadFailureLines(failures);
  final more = failures.length > maxNamedDownloadFailures ? lines.last : null;
  final named = more == null ? lines : lines.sublist(0, lines.length - 1);
  return '$playlistName: ${named.join(', ')}${more == null ? '' : ' $more'}';
}

String _shortTitle(String title) {
  final trimmed = title.trim();
  if (trimmed.length <= _maxTitleLength) return trimmed;
  return '${trimmed.substring(0, _maxTitleLength - 1).trimRight()}…';
}
