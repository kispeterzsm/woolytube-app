import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import 'providers.dart';

/// Track counts of one playlist (total, downloaded, unavailable, failed).
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
/// code that already holds the tracks, and for tests).
Map<int, PlaylistCounts> countTracksByPlaylist(Iterable<Track> tracks) {
  final total = <int, int>{};
  final downloaded = <int, int>{};
  final unavailable = <int, int>{};
  final failed = <int, int>{};
  void bump(Map<int, int> map, int id) =>
      map.update(id, (n) => n + 1, ifAbsent: () => 1);
  for (final track in tracks) {
    bump(total, track.playlistId);
    switch (track.status) {
      case 'complete':
        bump(downloaded, track.playlistId);
      case 'unavailable':
        bump(unavailable, track.playlistId);
      case 'error':
        bump(failed, track.playlistId);
    }
  }
  return {
    for (final entry in total.entries)
      entry.key: PlaylistCounts(
        total: entry.value,
        downloaded: downloaded[entry.key] ?? 0,
        unavailable: unavailable[entry.key] ?? 0,
        failed: failed[entry.key] ?? 0,
      ),
  };
}
