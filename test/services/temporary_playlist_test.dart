import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/video_quality.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

Map<String, dynamic> _entry(String id, {String? title}) => {
  'id': id,
  'title': title ?? 'Video $id',
  'thumbnail': 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
  'duration': 61,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory tempDir;
  late String videoBase;
  late FakeYtDlpService ytdlp;
  late FakeMediaThumbnailService thumbnails;
  late MetadataService metadata;
  late LibraryGate gate;
  late PlaylistService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_temporary_');
    final audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
    videoBase = p.join(tempDir.path, 'Movies', 'WoolyTube');
    await Directory(audioBase).create(recursive: true);
    await Directory(videoBase).create(recursive: true);
    LibraryLayout.overrideBasePathsForTesting(
      audio: audioBase,
      video: videoBase,
    );
    ytdlp = FakeYtDlpService();
    thumbnails = FakeMediaThumbnailService();
    metadata = MetadataService(db);
    gate = LibraryGate.unlocked();
    service = PlaylistService(db, ytdlp, metadata, thumbnails, null, gate);
  });

  tearDown(() async {
    LibraryLayout.resetBasePathsForTesting();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> write(String path, [String? content]) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(content ?? p.basename(path));
    return path;
  }

  /// Gives a temporary track a downloaded file, cover and kept info.
  Future<Track> download(Playlist playlist, Track track) async {
    final folder = playlist.outputPath;
    final number = track.index.toString().padLeft(2, '0');
    final media = await write(p.join(folder, '${number}_${track.title}.mp4'));
    final cover = await write(
      '${LibraryLayout.trackThumbnailStem(folder, track.videoId)}.jpg',
    );
    await write(LibraryLayout.infoJsonPath(folder, track.videoId), '{}');
    await db.markTrackDownloaded(
      track.id,
      filePath: media,
      thumbnailPath: cover,
    );
    return (await db.getTrack(track.id))!;
  }

  group('ensureTemporaryPlaylist', () {
    test(
      'creates one video playlist that is never updated from YouTube',
      () async {
        final playlist = await service.ensureTemporaryPlaylist();
        expect(playlist.isTemporary, isTrue);
        expect(playlist.url, temporaryPlaylistUrl);
        expect(playlist.name, 'Temporary');
        expect(playlist.audioOnly, isFalse);
        expect(playlist.autoUpdate, isFalse);
        expect(playlist.videoQuality, 720);
        expect(p.dirname(playlist.outputPath), videoBase);
        expect(await Directory(playlist.outputPath).exists(), isTrue);

        final again = await service.ensureTemporaryPlaylist();
        expect(again.id, playlist.id);
        expect(await db.getAllPlaylists(), hasLength(1));
      },
    );

    test('two calls at once still create one playlist', () async {
      final both = await Future.wait([
        service.ensureTemporaryPlaylist(),
        service.ensureTemporaryPlaylist(),
      ]);
      expect(both[0].id, both[1].id);
      expect(await db.getAllPlaylists(), hasLength(1));
    });
  });

  group('addToTemporary', () {
    test('appends videos in order and does not add one twice', () async {
      final first = await service.addToTemporary(_entry('aaaaaaaaaaa'));
      final second = await service.addToTemporary(_entry('bbbbbbbbbbb'));
      final again = await service.addToTemporary(_entry('aaaaaaaaaaa'));

      expect(first.added, isTrue);
      expect(second.added, isTrue);
      expect(again.added, isFalse);
      expect(again.track.id, first.track.id);
      expect(first.track.index, 1);
      expect(second.track.index, 2);
      expect(first.track.status, 'pending');
      expect(first.track.title, 'Video aaaaaaaaaaa');
      expect(first.track.durationSeconds, 61);
      expect(
        (await db.getTracksForPlaylist(
          first.playlist.id,
        )).map((t) => t.videoId),
        ['aaaaaaaaaaa', 'bbbbbbbbbbb'],
      );
      // The sidecar marks it as the temporary playlist.
      final sidecar =
          jsonDecode(
                await File(
                  p.join(first.playlist.outputPath, 'woolytube_meta.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(sidecar['playlist']['temporary'], isTrue);
    });

    test('quick adds get their own numbers', () async {
      final added = await Future.wait([
        for (final id in ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc'])
          service.addToTemporary(_entry(id)),
      ]);
      expect(added.map((a) => a.track.index).toSet(), {1, 2, 3});
    });

    test('never gives out the number of a file left in the folder', () async {
      final playlist = await service.ensureTemporaryPlaylist();
      await write(p.join(playlist.outputPath, '05_Left behind.mp4'));
      await write(
        p.join(LibraryLayout.replacedDir(playlist.outputPath), '07_Older.mp4'),
      );
      final added = await service.addToTemporary(_entry('aaaaaaaaaaa'));
      expect(added.track.index, 8);
    });

    test('works while a download holds the library', () async {
      await service.ensureTemporaryPlaylist();
      expect(await gate.tryEnter('download'), isNull);
      try {
        final added = await service.addToTemporary(_entry('aaaaaaaaaaa'));
        expect(added.added, isTrue);
      } finally {
        await gate.exit();
      }
    });

    test(
      'a removed and re-added video does not take a leftover file',
      () async {
        final first = await service.addToTemporary(_entry('aaaaaaaaaaa'));
        final downloaded = await download(first.playlist, first.track);
        // Deleting the file failed: it is still there after the removal.
        final leftover = await write(
          p.join(first.playlist.outputPath, '01_Kept copy.mp4'),
        );
        await service.removeTracks(first.playlist.id, [downloaded.id]);
        expect(await File(leftover).exists(), isTrue);

        final again = await service.addToTemporary(_entry('bbbbbbbbbbb'));
        expect(again.track.index, isNot(1));
        final adopted = await metadata.findAdoptableMediaFile(
          first.playlist,
          again.track,
        );
        expect(adopted, isNull);
      },
    );
  });

  group('removeTracks', () {
    test(
      'deletes the rows, segments and files of the removed videos only',
      () async {
        final a = await service.addToTemporary(_entry('aaaaaaaaaaa'));
        final b = await service.addToTemporary(_entry('bbbbbbbbbbb'));
        final playlist = a.playlist;
        final trackA = await download(playlist, a.track);
        final trackB = await download(playlist, b.track);
        await db.insertSegment(
          SponsorBlockSegmentsCompanion.insert(
            trackId: trackA.id,
            videoId: trackA.videoId,
            source: 'local',
            category: 'sponsor',
            startMs: 0,
            endMs: 10,
            createdAt: DateTime(2024),
          ),
        );
        final aside = await write(
          p.join(LibraryLayout.replacedDir(playlist.outputPath), '01_Old.mp4'),
        );
        final otherAside = await write(
          p.join(LibraryLayout.replacedDir(playlist.outputPath), '02_Old.mp4'),
        );

        await service.removeTracks(playlist.id, [trackA.id]);

        expect(await db.getTrack(trackA.id), isNull);
        expect(await db.getSegmentsForTrack(trackA.id), isEmpty);
        expect(await File(trackA.filePath!).exists(), isFalse);
        expect(await File(trackA.thumbnailPath!).exists(), isFalse);
        expect(
          await File(
            LibraryLayout.infoJsonPath(playlist.outputPath, trackA.videoId),
          ).exists(),
          isFalse,
        );
        expect(await File(aside).exists(), isFalse);

        expect(await db.getTrack(trackB.id), isNotNull);
        expect(await File(trackB.filePath!).exists(), isTrue);
        expect(await File(trackB.thumbnailPath!).exists(), isTrue);
        expect(await File(otherAside).exists(), isTrue);

        final sidecar =
            jsonDecode(
                  await File(
                    p.join(playlist.outputPath, 'woolytube_meta.json'),
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        expect(
          [for (final t in sidecar['tracks'] as List) t['videoId']],
          ['bbbbbbbbbbb'],
        );
        final m3u =
            await File(
              MetadataService.playlistFilePath(playlist.outputPath),
            ).readAsString();
        expect(m3u, isNot(contains(p.basename(trackA.filePath!))));
        expect(m3u, contains(p.basename(trackB.filePath!)));
      },
    );

    test('keeps a file another playlist uses', () async {
      final a = await service.addToTemporary(_entry('aaaaaaaaaaa'));
      final track = await download(a.playlist, a.track);
      final other = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=other',
        outputPath: p.join(videoBase, 'Other'),
      );
      await insertTestTrack(
        db,
        playlistId: other.id,
        videoId: 'aaaaaaaaaaa',
        status: 'complete',
        filePath: track.filePath,
      );

      await service.removeTracks(a.playlist.id, [track.id]);
      expect(await db.getTrack(track.id), isNull);
      expect(await File(track.filePath!).exists(), isTrue);
    });

    test('clearing leaves the playlist without videos and without the '
        'cover copied from one of them', () async {
      final a = await service.addToTemporary(_entry('aaaaaaaaaaa'));
      final b = await service.addToTemporary(_entry('bbbbbbbbbbb'));
      await download(a.playlist, a.track);
      await download(a.playlist, b.track);
      final cover = await write(
        '${LibraryLayout.playlistCoverStem(a.playlist.outputPath)}.jpg',
      );
      await db.updatePlaylistFields(
        a.playlist.id,
        PlaylistsCompanion(thumbnailPath: Value(cover)),
      );

      await service.clearPlaylist(a.playlist.id);

      final playlist = await db.getPlaylist(a.playlist.id);
      expect(playlist.isTemporary, isTrue);
      expect(playlist.thumbnailPath, isNull);
      expect(await File(cover).exists(), isFalse);
      expect(await db.getTracksForPlaylist(playlist.id), isEmpty);
      // Still the one temporary playlist when the next video is saved.
      final next = await service.addToTemporary(_entry('ccccccccccc'));
      expect(next.playlist.id, playlist.id);
    });

    test(
      'waits for no download: refused while one holds the library',
      () async {
        final a = await service.addToTemporary(_entry('aaaaaaaaaaa'));
        expect(await gate.tryEnter('download'), isNull);
        try {
          await expectLater(
            service.removeTracks(a.playlist.id, [a.track.id]),
            throwsA(isA<LibraryBusyException>()),
          );
        } finally {
          await gate.exit();
        }
        expect(await db.getTrack(a.track.id), isNotNull);
      },
    );
  });

  test('updating the temporary playlist never asks YouTube', () async {
    final playlist = await service.ensureTemporaryPlaylist();
    final result = await service.syncPlaylist(playlist);
    expect(result.hasChanges, isFalse);
    expect(ytdlp.requestedPlaylistUrls, isEmpty);
  });

  group('downloads', () {
    late LogService log;
    late DownloadService downloads;

    setUp(() {
      log = LogService();
      downloads = DownloadService(
        db,
        ytdlp,
        log,
        metadata,
        null,
        null,
        null,
        DownloadLock.foregroundOwner,
        gate,
        thumbnails,
      );
    });

    tearDown(() {
      downloads.dispose();
      log.dispose();
    });

    test('download at 720p and do not count as an update', () async {
      final added = await service.addToTemporary(_entry('aaaaaaaaaaa'));
      await downloads.downloadPlaylist(added.playlist, sourceChecked: false);

      expect(ytdlp.calls.single.maxHeight, 720);
      expect(ytdlp.calls.single.audioOnly, isFalse);
      final track = (await db.getTrack(added.track.id))!;
      expect(track.status, 'complete');
      expect((await db.getPlaylist(added.playlist.id)).lastUpdated, isNull);
    });

    test(
      'a video saved while Temporary downloads is downloaded after it',
      () async {
        final first = await service.addToTemporary(_entry('aaaaaaaaaaa'));
        ytdlp.downloadCompleter = Completer<void>();
        ytdlp.downloadStarted = Completer<void>();
        final running = downloads.downloadPlaylist(
          first.playlist,
          sourceChecked: false,
        );
        await ytdlp.downloadStarted!.future;

        final second = await service.addToTemporary(_entry('bbbbbbbbbbb'));
        expect(
          await downloads.downloadPlaylist(
            second.playlist,
            sourceChecked: false,
          ),
          DownloadStart.alreadyQueued,
        );
        ytdlp.downloadCompleter!.complete();
        await running;
        for (var i = 0; i < 100 && ytdlp.calls.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await downloads.runFinished;

        expect(ytdlp.calls.map((c) => c.videoId), [
          'aaaaaaaaaaa',
          'bbbbbbbbbbb',
        ]);
        expect((await db.getTrack(second.track.id))!.status, 'complete');
      },
    );

    Future<void> waitFor(bool Function() done) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Future<Playlist> otherPlaylist() async {
      final other = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=other',
        name: 'Other',
        outputPath: p.join(videoBase, 'Other'),
      );
      await insertTestTrack(
        db,
        playlistId: other.id,
        videoId: 'ccccccccccc',
        title: 'Other video',
      );
      return other;
    }

    test(
      'removing a video while Temporary downloads keeps the queue behind it',
      () async {
        final a = await service.addToTemporary(_entry('aaaaaaaaaaa'));
        final b = await service.addToTemporary(_entry('bbbbbbbbbbb'));
        final other = await otherPlaylist();
        ytdlp.downloadCompleter = Completer<void>();
        ytdlp.downloadStarted = Completer<void>();
        final running = downloads.downloadPlaylist(
          a.playlist,
          sourceChecked: false,
        );
        await ytdlp.downloadStarted!.future;
        expect(await downloads.downloadPlaylist(other), DownloadStart.queued);

        await downloads.runWithDownloadStopped(a.playlist.id, () async {
          await running;
          // The playlist queued behind it waits for the removal.
          expect(downloads.isDownloading, isFalse);
          expect(downloads.queuedPlaylistIds, [other.id]);
          ytdlp.downloadCompleter = null;
          await service.removeTracks(a.playlist.id, [a.track.id]);
        }, resume: true);

        await waitFor(() => ytdlp.calls.length >= 3);
        await waitFor(() => !downloads.isDownloading);
        await downloads.runFinished;
        expect(ytdlp.calls.map((c) => c.videoId), [
          'aaaaaaaaaaa',
          'bbbbbbbbbbb',
          'ccccccccccc',
        ]);
        expect(await db.getTrack(a.track.id), isNull);
        expect((await db.getTrack(b.track.id))!.status, 'complete');
      },
    );

    test('nothing changes while another playlist downloads', () async {
      final a = await service.addToTemporary(_entry('aaaaaaaaaaa'));
      final other = await otherPlaylist();
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();
      final running = downloads.downloadPlaylist(other);
      await ytdlp.downloadStarted!.future;
      expect(
        await downloads.downloadPlaylist(a.playlist, sourceChecked: false),
        DownloadStart.queued,
      );

      var ran = false;
      await expectLater(
        downloads.runWithDownloadStopped(a.playlist.id, () async {
          ran = true;
        }),
        throwsA(isA<LibraryBusyException>()),
      );
      expect(ran, isFalse);
      expect(downloads.queuedPlaylistIds, [a.playlist.id]);
      expect(downloads.isDownloading, isTrue);

      ytdlp.downloadCompleter!.complete();
      await running;
      await waitFor(() => ytdlp.calls.length >= 2);
      await waitFor(() => !downloads.isDownloading);
      await downloads.runFinished;
      expect((await db.getTrack(a.track.id))!.status, 'complete');
    });

    test('a stopped download resumes when the removal fails', () async {
      final a = await service.addToTemporary(_entry('aaaaaaaaaaa'));
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();
      final running = downloads.downloadPlaylist(
        a.playlist,
        sourceChecked: false,
      );
      await ytdlp.downloadStarted!.future;

      await expectLater(
        downloads.runWithDownloadStopped(a.playlist.id, () async {
          await running;
          ytdlp.downloadCompleter = null;
          throw const LibraryBusyException('busy');
        }),
        throwsA(isA<LibraryBusyException>()),
      );
      await waitFor(() => ytdlp.calls.length >= 2);
      await waitFor(() => !downloads.isDownloading);
      await downloads.runFinished;
      expect((await db.getTrack(a.track.id))!.status, 'complete');
    });

    test('a quality set on a waiting video during the run is used', () async {
      final a = await service.addToTemporary(_entry('aaaaaaaaaaa'));
      final b = await service.addToTemporary(_entry('bbbbbbbbbbb'));
      ytdlp.downloadCompleter = Completer<void>();
      ytdlp.downloadStarted = Completer<void>();
      final running = downloads.downloadPlaylist(
        a.playlist,
        sourceChecked: false,
      );
      await ytdlp.downloadStarted!.future;
      await db.setTrackVideoQuality(b.track.id, 360);
      ytdlp.downloadCompleter!.complete();
      await running;

      expect(ytdlp.calls.map((c) => c.maxHeight), [720, 360]);
      expect((await db.getTrack(b.track.id))!.downloadedMaxHeight, 360);
    });
  });
}
