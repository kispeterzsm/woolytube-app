import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import 'providers.dart';

/// Per-playlist `(downloaded, total)` track counts derived from the shared
/// track stream, so the home page does not issue two database queries per
/// playlist on every rebuild.
typedef PlaylistTrackCounts = ({int downloaded, int total});

final playlistTrackCountsProvider = Provider<Map<int, PlaylistTrackCounts>>((
  ref,
) {
  final tracks = ref.watch(allTracksProvider).valueOrNull ?? const <Track>[];
  return countTracksByPlaylist(tracks);
});

Map<int, PlaylistTrackCounts> countTracksByPlaylist(Iterable<Track> tracks) {
  final downloaded = <int, int>{};
  final total = <int, int>{};
  for (final track in tracks) {
    total.update(track.playlistId, (n) => n + 1, ifAbsent: () => 1);
    if (track.status == 'complete') {
      downloaded.update(track.playlistId, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  return {
    for (final entry in total.entries)
      entry.key: (downloaded: downloaded[entry.key] ?? 0, total: entry.value),
  };
}
