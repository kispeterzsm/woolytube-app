import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/playback_service.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = openTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  test('automatic playback filters always-skipped tracks', () async {
    final playlist = await insertTestPlaylist(db);
    final playable = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'playable',
      status: 'complete',
      filePath: '/tmp/playable.m4a',
    );
    final skipped = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'skip-me',
      status: 'complete',
      filePath: '/tmp/skip-me.m4a',
      alwaysSkip: true,
    );
    final pending = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 3,
      videoId: 'pending',
    );

    final automatic = playableTracksForPlayback([playable, skipped, pending]);

    expect(automatic.map((track) => track.id), [playable.id]);
    expect(isTrackAutomaticallyPlayable(skipped), isFalse);
  });

  test('a direct tap may play its own always-skipped track', () async {
    final playlist = await insertTestPlaylist(db);
    final selected = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'selected',
      status: 'complete',
      filePath: '/tmp/selected.m4a',
      alwaysSkip: true,
    );
    final otherSkipped = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'other-skipped',
      status: 'complete',
      filePath: '/tmp/other-skipped.m4a',
      alwaysSkip: true,
    );
    final playable = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 3,
      videoId: 'playable',
      status: 'complete',
      filePath: '/tmp/playable.m4a',
    );

    final direct = playableTracksForPlayback([
      selected,
      otherSkipped,
      playable,
    ], directlySelectedTrackId: selected.id);

    expect(direct.map((track) => track.id), [selected.id, playable.id]);
  });
}
