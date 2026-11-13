import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/lyrics/lyrics_files.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_service.dart'
    show persistLyricsFile;
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/recognition/recognition_files.dart';
import 'package:woolytube/services/recognition/song_recognition_service.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

const _url = 'https://www.youtube.com/playlist?list=PL1';
const _otherUrl = 'https://www.youtube.com/playlist?list=PL2';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory tempDir;
  late String audioBase;
  late String videoBase;
  late FakeYtDlpService ytdlp;
  late FakeMediaThumbnailService thumbnails;
  late MetadataService metadata;
  late PlaylistService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_folders_');
    audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
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
    service = PlaylistService(db, ytdlp, metadata, thumbnails);
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

  Future<Track> fileTrack(
    Playlist playlist,
    int index,
    String name, {
    String? videoId,
    String? unavailableReason,
    bool isLocalReplacement = false,
    String? thumbnailPath,
  }) async => insertTestTrack(
    db,
    playlistId: playlist.id,
    index: index,
    videoId: videoId ?? 'v$index',
    title: p.basenameWithoutExtension(name).replaceFirst(RegExp(r'^\d+_'), ''),
    filePath: await write(p.join(playlist.outputPath, name)),
    status: 'complete',
    unavailableReason: unavailableReason,
    isLocalReplacement: isLocalReplacement,
    thumbnailPath: thumbnailPath,
  );

  Set<String> namesIn(String dir) => {
    for (final e in Directory(dir).listSync()) p.basename(e.path),
  };

  test('the lyrics mode is set, kept and turned off', () async {
    final folder = p.join(audioBase, 'Lyrics');
    await Directory(folder).create(recursive: true);
    final playlist = await insertTestPlaylist(db, outputPath: folder);

    await service.updatePlaylistSettings(
      id: playlist.id,
      lyricsMode: const Value(LyricsMode.lyrics),
    );
    expect((await db.getPlaylist(playlist.id)).lyricsMode, 'lyrics');

    await service.updatePlaylistSettings(id: playlist.id, name: 'Renamed');
    expect((await db.getPlaylist(playlist.id)).lyricsMode, 'lyrics');

    await service.updatePlaylistSettings(
      id: playlist.id,
      lyricsMode: const Value(null),
    );
    expect((await db.getPlaylist(playlist.id)).lyricsMode, isNull);
  });

  group('adding playlists', () {
    test('two playlists with the same name get their own folders', () async {
      final first = await service.addPlaylist(
        url: _url,
        name: 'Mix',
        audioOnly: true,
      );
      final second = await service.addPlaylist(
        url: _otherUrl,
        name: 'Mix',
        audioOnly: true,
      );

      expect(
        (await db.getPlaylist(first)).outputPath,
        p.join(audioBase, 'Mix'),
      );
      expect(
        (await db.getPlaylist(second)).outputPath,
        p.join(audioBase, 'Mix (2)'),
      );
      expect(await Directory(p.join(audioBase, 'Mix (2)')).exists(), isTrue);
    });

    test('a folder holding media of unknown origin is not reused', () async {
      await write(p.join(audioBase, 'Live', 'song.mp3'));

      final id = await service.addPlaylist(
        url: _url,
        name: 'Live',
        audioOnly: true,
      );

      expect(
        (await db.getPlaylist(id)).outputPath,
        p.join(audioBase, 'Live (2)'),
      );
      expect(namesIn(p.join(audioBase, 'Live')), {'song.mp3'});
    });

    test(
      'an empty or dot title never becomes the library root or its parent',
      () async {
        for (final name in ['', ' ', '.', '..', '...', ' .. ']) {
          expect(PlaylistService.folderNameFor(name), 'Playlist', reason: name);
        }
        expect(
          PlaylistService.folderNameFor('../../Escape'),
          isNot(contains('/')),
        );

        final dots = await service.addPlaylist(
          url: _url,
          name: '..',
          audioOnly: true,
        );
        final empty = await service.addPlaylist(
          url: _otherUrl,
          name: '',
          audioOnly: true,
        );

        for (final id in [dots, empty]) {
          final folder = (await db.getPlaylist(id)).outputPath;
          expect(
            LibraryLayout.isPlaylistFolder(folder),
            isTrue,
            reason: folder,
          );
          expect(p.dirname(folder), audioBase);
        }
        expect(
          (await db.getPlaylist(dots)).outputPath,
          p.join(audioBase, 'Playlist'),
        );
        expect(
          (await db.getPlaylist(empty)).outputPath,
          p.join(audioBase, 'Playlist (2)'),
        );
      },
    );

    test('a URL already in the library in the same mode is refused', () async {
      await service.addPlaylist(url: _url, name: 'Mine', audioOnly: true);

      await expectLater(
        service.addPlaylist(url: _url, name: 'Again', audioOnly: true),
        throwsA(isA<PlaylistExistsException>()),
      );
      // The same playlist with extra URL parameters is still the same.
      await expectLater(
        service.addPlaylist(
          url: '$_url&si=share-token',
          name: 'Again',
          audioOnly: true,
        ),
        throwsA(isA<PlaylistExistsException>()),
      );
      expect(await db.getAllPlaylists(), hasLength(1));

      // The other mode is a different download.
      await service.addPlaylist(url: _url, name: 'Mine', audioOnly: false);
      expect(await db.getAllPlaylists(), hasLength(2));
    });

    test('re-adding a deleted playlist restores its old tracks and order '
        'from the sidecar', () async {
      final id = await service.addPlaylist(
        url: _url,
        name: 'Chill',
        audioOnly: true,
      );
      final playlist = await db.getPlaylist(id);
      await fileTrack(playlist, 1, '00001_A.m4a', videoId: 'a');
      // Inserted by the owner between A and B.
      await fileTrack(playlist, 2, '00002_X.m4a', videoId: 'x');
      await fileTrack(
        playlist,
        3,
        '00003_C.m4a',
        videoId: 'c',
        unavailableReason: 'deleted',
      );
      await insertTestTrack(db, playlistId: id, index: 4, videoId: 'd');
      await metadata.writeMetadataFor(id);

      // Removed from the app, files kept.
      await service.deletePlaylist(id);
      expect(await db.getAllPlaylists(), isEmpty);

      final restoredId = await service.addPlaylist(
        url: _url,
        name: 'Chill',
        audioOnly: true,
        autoUpdate: false,
      );

      final restored = await db.getPlaylist(restoredId);
      expect(restored.outputPath, playlist.outputPath);
      expect(restored.autoUpdate, isFalse);
      final tracks = await db.getTracksForPlaylist(restoredId);
      expect(tracks.map((t) => t.videoId), ['a', 'x', 'c', 'd']);
      expect(tracks.map((t) => t.index), [1, 2, 3, 4]);
      expect(tracks.map((t) => t.status), [
        'complete',
        'complete',
        'complete',
        'pending',
      ]);
      expect(tracks.map((t) => t.filePath), [
        p.join(playlist.outputPath, '00001_A.m4a'),
        p.join(playlist.outputPath, '00002_X.m4a'),
        p.join(playlist.outputPath, '00003_C.m4a'),
        null,
      ]);
      expect(tracks[2].unavailableReason, 'deleted');
    });
  });

  group('deleting with files', () {
    test(
      "removes only the playlist's own files and keeps unknown ones",
      () async {
        final id = await service.addPlaylist(
          url: _url,
          name: 'Gone',
          audioOnly: true,
        );
        final playlist = await db.getPlaylist(id);
        final folder = playlist.outputPath;
        final cover = await write(
          p.join(LibraryLayout.thumbnailsDir(folder), 'v1.jpg'),
        );
        final track = await fileTrack(
          playlist,
          1,
          '00001_A.m4a',
          thumbnailPath: cover,
        );
        await write(LibraryLayout.infoJsonPath(folder, track.videoId));
        await write(p.join(LibraryLayout.replacedDir(folder), '00001_Old.m4a'));
        await write(p.join(LibraryLayout.stagingRoot(folder), 'track-1', 'x'));
        await metadata.writeMetadataFor(id);
        final notes = await write(p.join(folder, 'notes.txt'));
        final unknown = await write(p.join(folder, '00009_Unknown.m4a'));

        await service.deletePlaylist(id, deleteFiles: true);

        expect(await db.getAllPlaylists(), isEmpty);
        expect(namesIn(folder), {'notes.txt', '00009_Unknown.m4a'});
        expect(await File(notes).exists(), isTrue);
        expect(await File(unknown).exists(), isTrue);
      },
    );

    test('removes the folder once nothing else is in it', () async {
      final id = await service.addPlaylist(
        url: _url,
        name: 'Gone',
        audioOnly: true,
      );
      final playlist = await db.getPlaylist(id);
      await fileTrack(playlist, 1, '00001_A.m4a');
      await metadata.writeMetadataFor(id);

      await service.deletePlaylist(id, deleteFiles: true);

      expect(await Directory(playlist.outputPath).exists(), isFalse);
      expect(await Directory(audioBase).exists(), isTrue);
    });

    test(
      'never deletes the library root or a folder another playlist uses',
      () async {
        // Older versions could put a playlist straight into the root.
        final rootPlaylist = await insertTestPlaylist(
          db,
          url: _url,
          audioOnly: true,
          outputPath: audioBase,
        );
        await fileTrack(rootPlaylist, 1, '00001_Root.m4a');
        final sharedFolder = p.join(audioBase, 'Shared');
        final mine = await insertTestPlaylist(
          db,
          url: _otherUrl,
          audioOnly: true,
          outputPath: sharedFolder,
        );
        final theirs = await insertTestPlaylist(
          db,
          url: 'https://www.youtube.com/playlist?list=PL3',
          audioOnly: true,
          outputPath: sharedFolder,
        );
        final myOwn = await fileTrack(mine, 1, '00001_Mine.m4a');
        final both = await fileTrack(mine, 2, '00002_Both.m4a');
        final theirCover = await write(
          p.join(LibraryLayout.thumbnailsDir(sharedFolder), 'theirs.jpg'),
        );
        final theirOwn = await fileTrack(
          theirs,
          1,
          '00001_Theirs.m4a',
          thumbnailPath: theirCover,
        );
        await insertTestTrack(
          db,
          playlistId: theirs.id,
          index: 2,
          videoId: 'both',
          filePath: both.filePath,
          status: 'complete',
        );
        await metadata.writeMetadataFor(theirs.id);
        final otherFolderFile = await write(
          p.join(audioBase, 'Other', '00001_Other.m4a'),
        );

        await service.deletePlaylist(rootPlaylist.id, deleteFiles: true);
        await service.deletePlaylist(mine.id, deleteFiles: true);

        expect(await Directory(audioBase).exists(), isTrue);
        expect(await File(otherFolderFile).exists(), isTrue);
        expect(
          await File(p.join(audioBase, '00001_Root.m4a')).exists(),
          isFalse,
        );
        expect(await File(myOwn.filePath!).exists(), isFalse);
        expect(await File(both.filePath!).exists(), isTrue);
        expect(await File(theirOwn.filePath!).exists(), isTrue);
        expect(await File(theirCover).exists(), isTrue);
        expect(
          await File(p.join(sharedFolder, 'woolytube_meta.json')).exists(),
          isTrue,
        );
      },
    );
  });

  group('format switch', () {
    late Playlist playlist;
    late String oldFolder;
    late String newFolder;
    late Map<String, Track> before;

    setUp(() async {
      final id = await service.addPlaylist(
        url: _url,
        name: 'Switch',
        audioOnly: true,
      );
      playlist = await db.getPlaylist(id);
      oldFolder = playlist.outputPath;
      newFolder = p.join(videoBase, 'Switch');
      final localCover = await write(
        p.join(LibraryLayout.thumbnailsDir(oldFolder), 'mine.local.jpg'),
      );
      before = {
        'normal': await fileTrack(
          playlist,
          1,
          '00001_Normal.m4a',
          videoId: 'normal',
        ),
        'gone': await fileTrack(
          playlist,
          2,
          '00002_Gone.m4a',
          videoId: 'gone',
          unavailableReason: 'deleted',
        ),
        'mine': await fileTrack(
          playlist,
          3,
          '00003_Mine.m4a',
          videoId: 'mine',
          isLocalReplacement: true,
          thumbnailPath: localCover,
        ),
        'force-insert:1': await fileTrack(
          playlist,
          4,
          '00004_Forced.m4a',
          videoId: 'force-insert:1',
          isLocalReplacement: true,
        ),
        'pending': await insertTestTrack(
          db,
          playlistId: id,
          index: 5,
          videoId: 'pending',
        ),
      };
      await metadata.writeMetadataFor(id);
    });

    Future<Map<String, Track>> tracks() async => {
      for (final t in await db.getTracksForPlaylist(playlist.id)) t.videoId: t,
    };

    test('lyrics files follow the switch; stale ones in a reused folder '
        'go', () async {
      final normal = before['normal']!;
      LyricsDocDraft doc(String text) => LyricsDocDraft(
        trackId: normal.id,
        kind: LyricsMode.transcript,
        status: LyricsStatus.found,
        pinned: true,
        checkedAt: DateTime(2026),
        lines: [LyricsLineDraft(text)],
      );
      await db.replaceLyricsDoc(doc('spoken'));
      await persistLyricsFile(db, normal.id);

      await service.updatePlaylistSettings(id: playlist.id, audioOnly: false);
      expect(
        (await readLyricsFile(newFolder, 'normal', normal.id)).single.lines,
        const [LyricsLineDraft('spoken')],
      );

      // The pin is cleared in the video folder; the audio folder's copy is
      // now stale and must not come back on a switch back.
      await db.deleteLyricsDocs(normal.id);
      await persistLyricsFile(db, normal.id);
      await service.updatePlaylistSettings(id: playlist.id, audioOnly: true);
      final back = await db.getPlaylist(playlist.id);
      expect(
        File(
          LibraryLayout.lyricsJsonPath(back.outputPath, 'normal'),
        ).existsSync(),
        isFalse,
      );
    });

    test('song-recognition runs of the files a track keeps follow the '
        'switch; runs of other content are not carried', () async {
      Future<void> writeRun(String folder, String videoId, String key) => write(
        LibraryLayout.recognitionJsonPath(folder, videoId),
        jsonEncode({
          'version': 1,
          'videoId': videoId,
          'contentKey': key,
          'run': {'edited': videoId},
        }),
      );
      final mine = before['mine']!;
      await writeRun(
        oldFolder,
        'mine',
        await SongRecognitionService.fileKey(mine.filePath!),
      );
      // Made from content the track no longer has.
      await writeRun(oldFolder, 'gone', 'stale');
      // A copy already in the new folder stays when nothing valid replaces
      // it.
      await writeRun(newFolder, 'gone', 'earlier');

      await service.updatePlaylistSettings(id: playlist.id, audioOnly: false);

      final carried = await readRecognitionFile(newFolder, 'mine');
      expect(carried?.run, {'edited': 'mine'});
      expect(
        carried?.contentKey,
        await SongRecognitionService.fileKey(
          (await tracks())['mine']!.filePath!,
        ),
      );
      expect(
        (await readRecognitionFile(newFolder, 'gone'))?.contentKey,
        'earlier',
      );
      // The old folder's copies are left alone.
      expect(await readRecognitionFile(oldFolder, 'mine'), isNotNull);
      expect(await readRecognitionFile(oldFolder, 'gone'), isNotNull);
    });

    test('tracks YouTube can give again keep their file until replaced; the '
        'others take their file along', () async {
      await service.updatePlaylistSettings(id: playlist.id, audioOnly: false);

      final switched = await db.getPlaylist(playlist.id);
      expect(switched.audioOnly, isFalse);
      expect(switched.outputPath, newFolder);

      final after = await tracks();
      final normal = after['normal']!;
      expect(normal.status, 'complete');
      expect(normal.replaceRequested, isTrue);
      expect(normal.filePath, before['normal']!.filePath);
      expect(await File(normal.filePath!).exists(), isTrue);

      for (final id in ['gone', 'mine', 'force-insert:1']) {
        final track = after[id]!;
        final name = p.basename(before[id]!.filePath!);
        expect(track.replaceRequested, isFalse, reason: id);
        expect(track.filePath, p.join(newFolder, name), reason: id);
        expect(await File(track.filePath!).readAsString(), name, reason: id);
        expect(await File(before[id]!.filePath!).exists(), isFalse, reason: id);
      }
      expect(after['mine']!.isLocalReplacement, isTrue);
      expect(p.isWithin(newFolder, after['mine']!.thumbnailPath!), isTrue);
      expect(await File(after['mine']!.thumbnailPath!).exists(), isTrue);
      expect(after['pending']!.status, 'pending');

      // Only the new folder describes the playlist now.
      expect(
        await File(p.join(oldFolder, 'woolytube_meta.json')).exists(),
        isFalse,
      );
      expect(
        await File(
          p.join(oldFolder, 'woolytube_meta.json.superseded'),
        ).exists(),
        isTrue,
      );
      final sidecar =
          jsonDecode(
                await File(
                  p.join(newFolder, 'woolytube_meta.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final normalEntry = (sidecar['tracks'] as List).firstWhere(
        (t) => t['videoId'] == 'normal',
      );
      expect(
        p.normalize(p.join(newFolder, normalEntry['fileName'] as String)),
        before['normal']!.filePath,
      );
    });

    test('reconcile and repair of the new folder keep tracks whose file is '
        'still in the old folder', () async {
      await service.updatePlaylistSettings(id: playlist.id, audioOnly: false);
      final switched = await db.getPlaylist(playlist.id);
      final afterSwitch = await tracks();

      await metadata.reconcilePlaylist(switched);
      await metadata.repairPlaylist(switched);

      expect(await tracks(), afterSwitch);
      expect(await File(before['normal']!.filePath!).exists(), isTrue);
    });

    test('the next update downloads the new format and only then stops using '
        'the old file', () async {
      await service.updatePlaylistSettings(id: playlist.id, audioOnly: false);
      final log = LogService();
      final downloads = DownloadService(
        db,
        ytdlp,
        log,
        metadata,
        null,
        null,
        DownloadLock(directoryProvider: () async => tempDir.path),
        DownloadLock.foregroundOwner,
        null,
        thumbnails,
      );
      addTearDown(() {
        downloads.dispose();
        log.dispose();
      });

      await downloads.downloadPlaylist(await db.getPlaylist(playlist.id));

      final after = await tracks();
      expect(after['normal']!.filePath, p.join(newFolder, '00001_Title.mp4'));
      expect(after['normal']!.replaceRequested, isFalse);
      expect(after['pending']!.filePath, p.join(newFolder, '00005_Title.mp4'));
      expect(ytdlp.calls.map((c) => c.videoId), ['normal', 'pending']);
      expect(ytdlp.calls.every((c) => !c.audioOnly), isTrue);
      // The audio copy is not thrown away.
      expect(await File(before['normal']!.filePath!).exists(), isTrue);
    });

    test('a sync with a copy of the playlist from before the switch renames '
        'files in the current folder only', () async {
      await service.updatePlaylistSettings(id: playlist.id, audioOnly: false);
      ytdlp.playlistInfo = {
        'entries': [
          for (final id in ['top', 'normal', 'gone', 'pending'])
            {'id': id, 'title': id},
        ],
      };

      // [playlist] still names the audio folder.
      await service.syncPlaylist(playlist);

      final after = await tracks();
      expect(after['top']!.index, 1);
      expect(after['normal']!.index, 2);
      expect(after['gone']!.index, 3);
      // The audio file waiting to be replaced is left alone.
      expect(after['normal']!.filePath, before['normal']!.filePath);
      expect(await File(before['normal']!.filePath!).exists(), isTrue);
      expect(after['gone']!.filePath, p.join(newFolder, '00003_Gone.m4a'));
      expect(await File(after['gone']!.filePath!).exists(), isTrue);
    });

    test("never moves into a folder holding another copy's backup", () async {
      // A video copy of the same playlist was removed from the app
      // earlier, with its files and sidecar kept. Its track 5 is a
      // different video than this playlist's pending track 5.
      final backupSidecar = await write(
        p.join(newFolder, 'woolytube_meta.json'),
        jsonEncode({
          'version': 2,
          'playlist': {'url': _url, 'name': 'Switch', 'audioOnly': false},
          'tracks': [
            {
              'index': 5,
              'videoId': 'old-copy',
              'title': 'Old copy',
              'status': 'complete',
              'fileName': '00005_Old copy.mp4',
            },
          ],
        }),
      );
      final oldCopy = await write(p.join(newFolder, '00005_Old copy.mp4'));
      final backup = await File(backupSidecar).readAsString();

      await service.updatePlaylistSettings(id: playlist.id, audioOnly: false);
      final switched = await db.getPlaylist(playlist.id);
      await metadata.reconcilePlaylist(switched);

      expect(switched.outputPath, isNot(newFolder));
      expect(await File(backupSidecar).readAsString(), backup);
      final pending = (await tracks())['pending']!;
      expect(pending.filePath, isNot(oldCopy));
      expect(pending.status, 'pending');
    });
  });
}
