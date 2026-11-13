import '../database/database.dart';
import 'download_errors.dart';

// The words for a playlist's track counts. The home card, the playlist
// page's summary line and the download notifications all take them from
// here, so their totals and categories always agree.
//
// Every summary counts against the whole playlist ([PlaylistCounts.total]):
// downloaded, failed, unavailable and not yet downloaded tracks add up to
// it, so "105 of 108 downloaded · 2 failed · 1 unavailable" adds up.

/// A kind of track a summary counts beside the downloaded ones, in the
/// order summaries list them.
enum TrackCountKind {
  /// The last download failed; the next update tries again.
  failed,

  /// YouTube no longer has it and there is no file.
  unavailable,

  /// YouTube (or the YouTube playlist) no longer has it; the file is kept.
  removedKept,

  /// The requested YouTube copy could not be fetched; the user's file (or
  /// the old one) is kept and plays.
  noYouTubeCopy;

  /// Needs the user's attention (shown in red), not just a note.
  bool get isProblem => this == failed;
}

/// "2 failed", "1 unavailable", "1 removed, kept", "1 no YouTube copy".
String trackCountLabel(TrackCountKind kind, int count) => switch (kind) {
  TrackCountKind.failed => '$count failed',
  TrackCountKind.unavailable => '$count unavailable',
  TrackCountKind.removedKept => '$count removed, kept',
  TrackCountKind.noYouTubeCopy => '$count no YouTube copy',
};

/// The kinds of track [counts] has, with how many, in summary order.
List<(TrackCountKind, int)> trackCountNotes(PlaylistCounts counts) => [
  for (final (kind, count) in [
    (TrackCountKind.failed, counts.failed),
    (TrackCountKind.unavailable, counts.unavailable),
    (TrackCountKind.removedKept, counts.removedKept),
    (TrackCountKind.noYouTubeCopy, counts.noYouTubeCopy),
  ])
    if (count > 0) (kind, count),
];

/// "1 track", "108 tracks".
String tracksLabel(int count) => count == 1 ? '1 track' : '$count tracks';

/// The home card's count: "108 tracks" once every track that can be
/// downloaded is, otherwise "105 of 108 downloaded". [trackCountNotes] says
/// what the rest are.
String playlistDownloadedText(PlaylistCounts counts) =>
    counts.nothingToDownload
        ? tracksLabel(counts.total)
        : '${counts.downloaded} of ${counts.total} downloaded';

/// The playlist page's summary line: "108 tracks · 105 downloaded · 2 failed
/// · 1 unavailable · 18 min" ([duration] last, when given).
String playlistSummaryText(PlaylistCounts counts, {String? duration}) {
  if (counts.total == 0) return 'No tracks';
  return [
    tracksLabel(counts.total),
    counts.downloaded == counts.total
        ? 'all downloaded'
        : '${counts.downloaded} downloaded',
    for (final (kind, count) in trackCountNotes(counts))
      trackCountLabel(kind, count),
    if (duration != null) duration,
  ].join(' · ');
}

/// What went wrong in a download run, as a headline: "2 downloads failed",
/// "YouTube copy unavailable, your file is kept". A track that keeps its
/// file and plays ([DownloadFailure.replacement]) is never called a failed
/// download.
String downloadFailuresHeadline(List<DownloadFailure> failures) {
  final kept = [
    for (final failure in failures)
      if (failure.replacement) failure,
  ];
  final failed = failures.length - kept.length;
  return [
    if (failed > 0) '$failed ${failed == 1 ? 'download' : 'downloads'} failed',
    if (kept.isNotEmpty) _keptHeadline(kept),
  ].join(' · ');
}

String _keptHeadline(List<DownloadFailure> kept) {
  final count = kept.length;
  final what =
      kept.every((failure) => failure.youTubeCopyUnavailable)
          ? 'unavailable'
          : 'failed';
  return count == 1
      ? 'YouTube copy $what, your file is kept'
      : '$count YouTube copies $what, your files are kept';
}

/// A run's failures as counts that follow a sentence: "1 failed · 1 no
/// YouTube copy", in the words of [trackCountLabel].
String downloadFailuresCount(List<DownloadFailure> failures) {
  final kept = failures.where((failure) => failure.replacement).length;
  final failed = failures.length - kept;
  return [
    if (failed > 0) trackCountLabel(TrackCountKind.failed, failed),
    if (kept > 0) trackCountLabel(TrackCountKind.noYouTubeCopy, kept),
  ].join(' · ');
}
