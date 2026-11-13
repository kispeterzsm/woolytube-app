import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

class _WaitingYtDlp extends FakeYtDlpService {
  final release = Completer<void>();
  final asked = Completer<void>();

  @override
  Future<Map<String, dynamic>> getPlaylistInfo(String url) async {
    if (!asked.isCompleted) asked.complete();
    await release.future;
    return super.getPlaylistInfo(url);
  }
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late String folder;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_sync_test_');
    folder = p.join(tempDir.path, 'Playlist');
    await Directory(folder).create();
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a video found removed from YouTube stays marked on sync', () async {
    final ytdlp = FakeYtDlpService();
    final service = PlaylistService(db, ytdlp, MetadataService(db));
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'gone',
      status: 'unavailable',
      unavailableReason: removedFromYouTubeReason,
    );
    // The playlist listing still shows the video as if nothing happened.
    ytdlp.playlistInfo = {
      'entries': [
        {'id': 'gone', 'title': 'Gone', 'duration': 10},
      ],
    };

    final result = await service.syncPlaylist(playlist);

    expect(result.markedAvailable, 0);
    final synced = (await db.getTrack(track.id))!;
    expect(synced.status, 'unavailable');
    expect(synced.unavailableReason, removedFromYouTubeReason);
    expect((await db.getPlaylist(playlist.id)).lastUpdateAttempt, isNotNull);
    // The download of the update tries it again (see DownloadService).
    expect(
      (await db.getRemovedFromYouTubeTracks(playlist.id)).single.id,
      track.id,
    );
  });

  test('one update per playlist at a time, and it can be stopped', () async {
    final ytdlp = _WaitingYtDlp();
    final service = PlaylistService(db, ytdlp, MetadataService(db));
    addTearDown(service.dispose);
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    final states = <Set<int>>[];
    final sub = service.syncingStream.listen(states.add);
    addTearDown(sub.cancel);

    final running = service.syncPlaylist(playlist);
    await ytdlp.asked.future;
    expect(service.syncingPlaylistIds, {playlist.id});
    await expectLater(
      service.syncPlaylist(playlist),
      throwsA(isA<LibraryBusyException>()),
    );

    expect(service.cancelSync(playlist.id), isTrue);
    // Stopped at once, not when YouTube answers.
    expect(service.syncingPlaylistIds, isEmpty);
    await pumpEventQueue();
    expect(states.last, isEmpty);

    // A new update may start right away; the stopped one returning late
    // does not end it.
    final again = service.syncPlaylist(playlist);
    expect(service.syncingPlaylistIds, {playlist.id});
    ytdlp.release.complete();
    await expectLater(running, throwsA(isA<SyncCancelledException>()));
    expect(service.syncingPlaylistIds, {playlist.id});
    await again;
    expect(service.syncingPlaylistIds, isEmpty);
    expect(service.cancelSync(playlist.id), isFalse);
  });

  test('an update is refused before asking YouTube while a download '
      'runs', () async {
    final ytdlp = FakeYtDlpService();
    final gate = LibraryGate.unlocked();
    final service = PlaylistService(
      db,
      ytdlp,
      MetadataService(db),
      null,
      null,
      gate,
    );
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    expect(await gate.tryEnter('download'), isNull);

    await expectLater(
      service.syncPlaylist(playlist),
      throwsA(isA<LibraryBusyException>()),
    );
    expect(ytdlp.requestedPlaylistUrls, isEmpty);
    expect(service.syncingPlaylistIds, isEmpty);
    await gate.exit();
  });

  test('new entries without duration or thumbnail store nothing', () async {
    final ytdlp = FakeYtDlpService();
    final service = PlaylistService(db, ytdlp, MetadataService(db));
    final playlist = await insertTestPlaylist(db, outputPath: folder);

    await service.populateTracksFromInfo(playlist.id, {
      'entries': [
        {'id': 'live', 'title': 'Live', 'thumbnail': '', 'duration': 0},
      ],
    });

    final track = (await db.getTracksForPlaylist(playlist.id)).single;
    expect(track.thumbnailUrl, isNull);
    expect(track.durationSeconds, isNull);
  });

  test('inserting at the top renames every file in chunks', () async {
    final ytdlp = FakeYtDlpService();
    final service = PlaylistService(db, ytdlp, MetadataService(db));
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
    const count = 120;
    for (var i = 1; i <= count; i++) {
      final path = p.join(folder, '${i.toString().padLeft(5, '0')}_S$i.m4a');
      await File(path).writeAsString('$i');
      await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: i,
        videoId: 'v$i',
        title: 'S$i',
        status: 'complete',
        filePath: path,
      );
    }
    ytdlp.playlistInfo = {
      'entries': [
        {'id': 'new', 'title': 'New'},
        for (var i = 1; i <= count; i++) {'id': 'v$i', 'title': 'S$i'},
      ],
    };

    await service.syncPlaylist(playlist);

    final tracks = await db.getTracksForPlaylist(playlist.id);
    expect(tracks.first.videoId, 'new');
    for (final track in tracks.skip(1)) {
      final expected = p.join(
        folder,
        '${track.index.toString().padLeft(5, '0')}_${track.title}.m4a',
      );
      expect(track.filePath, expected);
      expect(await File(expected).readAsString(), '${track.index - 1}');
    }
  });
}
