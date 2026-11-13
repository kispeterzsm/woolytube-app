import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../services/track_status_labels.dart';
import 'providers.dart';

/// Track counts of one playlist (total, downloaded, unavailable, failed,
/// and the downloaded ones kept without a YouTube copy).
typedef PlaylistTrackCounts = PlaylistCounts;

/// Per-playlist track counts, or null until the first answer arrived.
///
/// Comes from one SQL aggregate ([playlistTrackCountsStreamProvider]) that
/// only emits when a number changes, so neither the track table nor the UI
/// isolate is busy with it during downloads.
final playlistTrackCountsProvider = Provider<Map<int, PlaylistCounts>?>((ref) {
  return ref.watch(playlistTrackCountsStreamProvider).valueOrNull;
});

/// The counts of one playlist for a card: whether the counts arrived yet,
/// and the playlist's entry (null when it has no tracks). Only changes when
/// this playlist's numbers change.
final playlistCountsProvider = Provider.autoDispose
    .family<({bool loaded, PlaylistCounts? counts}), int>((ref, playlistId) {
      return ref.watch(
        playlistTrackCountsProvider.select(
          (all) => (loaded: all != null, counts: all?[playlistId]),
        ),
      );
    });

/// The same numbers as the database aggregate, from a list of tracks (for
/// code that already holds the tracks, like the playlist page, and for
/// tests). Keep the two in step: the home card shows the aggregate, the
/// playlist page these.
Map<int, PlaylistCounts> countTracksByPlaylist(Iterable<Track> tracks) {
  final byPlaylist = <int, List<Track>>{};
  for (final track in tracks) {
    byPlaylist.putIfAbsent(track.playlistId, () => []).add(track);
  }
  return {
    for (final entry in byPlaylist.entries) entry.key: countTracks(entry.value),
  };
}

/// The counts of [tracks] taken together (one playlist's, usually).
PlaylistCounts countTracks(Iterable<Track> tracks) {
  var total = 0;
  var downloaded = 0;
  var unavailable = 0;
  var failed = 0;
  var removedKept = 0;
  var noYouTubeCopy = 0;
  for (final track in tracks) {
    total++;
    switch (track.status) {
      case 'complete':
        downloaded++;
        if (track.unavailableReason != null) removedKept++;
        if (trackReplacementFailed(track)) noYouTubeCopy++;
      case 'unavailable':
        unavailable++;
      case 'error':
        failed++;
    }
  }
  return PlaylistCounts(
    total: total,
    downloaded: downloaded,
    unavailable: unavailable,
    failed: failed,
    removedKept: removedKept,
    noYouTubeCopy: noYouTubeCopy,
  );
}
