import 'dart:convert';
import 'dart:io';

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
import 'package:woolytube/services/sponsorblock_categories.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

const _url = 'https://www.youtube.com/playlist?list=PL1';
const _otherUrl = 'https://www.youtube.com/playlist?list=PL2';

/// Lets a test stop a format switch while it moves files, as if the app
/// were killed there.
class _InterruptibleMetadataService extends MetadataService {
  _InterruptibleMetadataService(super.db);

  bool interrupt = false;

  @override
  Future<void> adoptKeptFile(Playlist playlist, int trackId) async {
    if (interrupt) {
      throw const FileSystemException('The app was stopped here');
    }
    return super.adoptKeptFile(playlist, trackId);
  }
}

/// Regression tests for the playlist fixes of the final review (R02, R05,
/// R10, R11, R13, R20, R23, R25).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory tempDir;
  late String audioBase;
  late String videoBase;
  late FakeYtDlpService ytdlp;
  late FakeMediaThumbnailService thumbnails;
  late _InterruptibleMetadataService metadata;
  late LibraryGate gate;
  late PlaylistService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_review_pl_');
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
    metadata = _InterruptibleMetadataService(db);
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

  Future<Track> fileTrack(
    Playlist playlist,
    int index,
    String name, {
    String? videoId,
    String? title,
    String? unavailableReason,
    bool isLocalReplacement = false,
    String? thumbnailPath,
  }) async => insertTestTrack(
    db,
    playlistId: playlist.id,
    index: index,
    videoId: videoId ?? 'v$index',
    title:
        title ??
        p.basenameWithoutExtension(name).replaceFirst(RegExp(r'^\d+_'), ''),
    filePath: await write(p.join(playlist.outputPath, name)),
    status: 'complete',
    downloadedAt: DateTime(2025, 1, 1),
    unavailableReason: unavailableReason,
    isLocalReplacement: isLocalReplacement,
    thumbnailPath: thumbnailPath,
  );

  Future<Map<String, Track>> tracksOf(int playlistId) async => {
    for (final t in await db.getTracksForPlaylist(playlistId)) t.videoId: t,
  };

  Future<Map<String, dynamic>> readSidecar(String folder) async =>
      jsonDecode(
            await File(p.join(folder, 'woolytube_meta.json')).readAsString(),
          )
          as Map<String, dynamic>;

  DownloadService newDownloads() {
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
    return downloads;
  }

  test('R02: a sync after an interrupted renumbering links the track to its '
      'file first and never gives that file to the new entry', () async {
    final folder = p.join(audioBase, 'Renumbered');
    final playlist = await insertTestPlaylist(
      db,
      url: _url,
      audioOnly: true,
      outputPath: folder,
    );
    await fileTrack(playlist, 1, '00001_A.m4a', videoId: 'a');
    // The renumbering recorded b's new name, then the app died before the
    // file was renamed: the recorded path is missing, the file still has
    // the old number.
    await write(p.join(folder, '00002_B.m4a'), 'b');
    await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'b',
      title: 'B',
      filePath: p.join(folder, '00003_B.m4a'),
      status: 'complete',
      downloadedAt: DateTime(2025, 1, 1),
    );
    ytdlp.playlistInfo = {
      'entries': [
        for (final id in ['a', 'new', 'b']) {'id': id, 'title': id},
      ],
    };

    await service.syncPlaylist(playlist);

    var byId = await tracksOf(playlist.id);
    expect(byId['a']!.index, 1);
    expect(byId['new']!.index, 2);
    expect(byId['b']!.index, 3);
    expect(byId['b']!.status, 'complete');
    expect(byId['b']!.filePath, p.join(folder, '00003_B.m4a'));
    expect(await File(byId['b']!.filePath!).readAsString(), 'b');
    expect(byId['new']!.status, 'pending');
    expect(byId['new']!.filePath, isNull);
    expect(await File(p.join(folder, '00002_B.m4a')).exists(), isFalse);

    // Nothing numbered 2 is left for the new entry to pick up.
    await metadata.reconcilePlaylist(await db.getPlaylist(playlist.id));
    byId = await tracksOf(playlist.id);
    expect(byId['new']!.status, 'pending');
    expect(byId['new']!.filePath, isNull);
    expect(byId['b']!.filePath, p.join(folder, '00003_B.m4a'));
  });

  test('R05: separateSharedFolders gives the newer playlist its own folder '
      'and takes only its own files along', () async {
    final shared = p.join(audioBase, 'Mix');
    final thumbs = LibraryLayout.thumbnailsDir(shared);
    final first = await insertTestPlaylist(
      db,
      url: _url,
      name: 'Mix',
      audioOnly: true,
      outputPath: shared,
    );
    final mover = await insertTestPlaylist(
      db,
      url: _otherUrl,
      name: 'Mix',
      audioOnly: true,
      outputPath: shared,
    );

    final bothCover = await write(p.join(thumbs, 'both.jpg'));
    final firstOwn = await fileTrack(
      first,
      1,
      '00001_First.m4a',
      videoId: 'f1',
      thumbnailPath: await write(p.join(thumbs, 'f1.jpg')),
    );
    final firstBoth = await fileTrack(
      first,
      2,
      '00002_Both.m4a',
      videoId: 'f2',
      thumbnailPath: bothCover,
    );
    final firstTheirs = await fileTrack(
      first,
      3,
      '00003_Theirs.m4a',
      videoId: 'f3',
    );

    final moverOwnFile = await write(p.join(shared, '00005_Mine.m4a'), 'mine');
    final moverOwnCover = await write(p.join(thumbs, 'm1.jpg'));
    final moverInfo = await write(LibraryLayout.infoJsonPath(shared, 'm1'));
    final mine = await insertTestTrack(
      db,
      playlistId: mover.id,
      index: 1,
      videoId: 'm1',
      title: 'Mine',
      filePath: moverOwnFile,
      thumbnailPath: moverOwnCover,
      status: 'complete',
      downloadedAt: DateTime(2025, 1, 1),
    );
    // The same song in both playlists: its file name matches the title.
    final both = await insertTestTrack(
      db,
      playlistId: mover.id,
      index: 2,
      videoId: 'm2',
      title: 'Both',
      filePath: firstBoth.filePath,
      thumbnailPath: bothCover,
      status: 'complete',
      downloadedAt: DateTime(2025, 1, 1),
    );
    // Matched only by its number to the other playlist's song.
    final other = await insertTestTrack(
      db,
      playlistId: mover.id,
      index: 3,
      videoId: 'm3',
      title: 'Something else',
      filePath: firstTheirs.filePath,
      status: 'complete',
      downloadedAt: DateTime(2025, 1, 1),
    );
    final firstBefore = await db.getTracksForPlaylist(first.id);

    expect(await service.separateSharedFolders(), 1);

    final newFolder = p.join(audioBase, 'Mix (2)');
    expect((await db.getPlaylist(first.id)).outputPath, shared);
    expect((await db.getPlaylist(mover.id)).outputPath, newFolder);

    final moved = await tracksOf(mover.id);
    expect(moved['m1']!.filePath, p.join(newFolder, '00005_Mine.m4a'));
    expect(await File(moved['m1']!.filePath!).readAsString(), 'mine');
    expect(await File(mine.filePath!).exists(), isFalse);
    expect(
      moved['m1']!.thumbnailPath,
      p.join(LibraryLayout.thumbnailsDir(newFolder), 'm1.jpg'),
    );
    expect(await File(moved['m1']!.thumbnailPath!).exists(), isTrue);
    expect(await File(moverOwnCover).exists(), isFalse);
    expect(
      await File(LibraryLayout.infoJsonPath(newFolder, 'm1')).exists(),
      isTrue,
    );
    expect(await File(moverInfo).exists(), isTrue);

    // Copied: this playlist's own copy of the song.
    expect(moved['m2']!.status, 'complete');
    expect(moved['m2']!.filePath, p.join(newFolder, '00002_Both.m4a'));
    expect(await File(moved['m2']!.filePath!).exists(), isTrue);
    expect(await File(both.filePath!).exists(), isTrue);
    expect(
      moved['m2']!.thumbnailPath,
      p.join(LibraryLayout.thumbnailsDir(newFolder), 'both.jpg'),
    );
    expect(await File(moved['m2']!.thumbnailPath!).exists(), isTrue);
    expect(await File(bothCover).exists(), isTrue);

    // Not this track's song: it downloads its own again.
    expect(moved['m3']!.status, 'pending');
    expect(moved['m3']!.filePath, isNull);
    expect(moved['m3']!.downloadedAt, isNull);
    expect(await File(other.filePath!).exists(), isTrue);

    // The first playlist is untouched.
    expect(await db.getTracksForPlaylist(first.id), firstBefore);
    for (final track in [firstOwn, firstBoth, firstTheirs]) {
      expect(await File(track.filePath!).exists(), isTrue);
      if (track.thumbnailPath != null) {
        expect(await File(track.thumbnailPath!).exists(), isTrue);
      }
    }

    // Each folder describes its own playlist.
    expect((await readSidecar(shared))['playlist']['url'], _url);
    expect((await readSidecar(newFolder))['playlist']['url'], _otherUrl);

    expect(await service.separateSharedFolders(), 0);
  });

  group('R10/R11: format switch', () {
    late Playlist playlist;
    late String audioFolder;
    late String videoFolder;

    setUp(() async {
      final id = await service.addPlaylist(
        url: _url,
        name: 'Switch',
        audioOnly: true,
      );
      playlist = await db.getPlaylist(id);
      audioFolder = playlist.outputPath;
      videoFolder = p.join(videoBase, 'Switch');
    });

    Future<void> givenTracksWithAKeptFileFirst() async {
      // YouTube deleted 'gone': its file has to move along. It comes first,
      // so an interruption hits it before 'normal' is decided.
      await fileTrack(
        playlist,
        1,
        '00001_Gone.m4a',
        videoId: 'gone',
        unavailableReason: 'deleted',
      );
      await fileTrack(playlist, 2, '00002_Normal.m4a', videoId: 'normal');
      await metadata.writeMetadataFor(playlist.id);
    }

    test('every decision is committed even when moving files is '
        'interrupted', () async {
      await givenTracksWithAKeptFileFirst();
      metadata.interrupt = true;

      await expectLater(
        service.updatePlaylistSettings(id: playlist.id, audioOnly: false),
        throwsA(isA<FileSystemException>()),
      );

      final switched = await db.getPlaylist(playlist.id);
      expect(switched.audioOnly, isFalse);
      expect(switched.outputPath, videoFolder);
      final byId = await tracksOf(playlist.id);
      expect(byId['normal']!.replaceRequested, isTrue);
      expect(byId['normal']!.filePath, p.join(audioFolder, '00002_Normal.m4a'));
      // The interrupted move: the file is still in the old folder.
      expect(byId['gone']!.replaceRequested, isFalse);
      expect(byId['gone']!.filePath, p.join(audioFolder, '00001_Gone.m4a'));
      expect(await File(byId['gone']!.filePath!).exists(), isTrue);
    });

    test('the next update finishes an interrupted switch', () async {
      await givenTracksWithAKeptFileFirst();
      metadata.interrupt = true;
      await expectLater(
        service.updatePlaylistSettings(id: playlist.id, audioOnly: false),
        throwsA(isA<FileSystemException>()),
      );
      metadata.interrupt = false;

      await newDownloads().downloadPlaylist(await db.getPlaylist(playlist.id));

      final byId = await tracksOf(playlist.id);
      final gone = byId['gone']!;
      expect(gone.filePath, p.join(videoFolder, '00001_Gone.m4a'));
      expect(await File(gone.filePath!).readAsString(), '00001_Gone.m4a');
      expect(
        await File(p.join(audioFolder, '00001_Gone.m4a')).exists(),
        isFalse,
      );
      expect(gone.replaceRequested, isFalse);
      final normal = byId['normal']!;
      expect(normal.filePath, p.join(videoFolder, '00002_Title.mp4'));
      expect(normal.replaceRequested, isFalse);
      expect(ytdlp.calls.map((c) => c.videoId), ['normal']);
      expect(ytdlp.calls.single.audioOnly, isFalse);
    });

    test('switching back reuses the earlier folder and its files', () async {
      final normal = await fileTrack(
        playlist,
        1,
        '00001_Normal.m4a',
        videoId: 'normal',
      );
      await metadata.writeMetadataFor(playlist.id);

      await service.updatePlaylistSettings(id: playlist.id, audioOnly: false);
      await newDownloads().downloadPlaylist(await db.getPlaylist(playlist.id));
      expect(
        (await db.getTrack(normal.id))!.filePath,
        p.join(videoFolder, '00001_Title.mp4'),
      );
      expect(
        await File(
          p.join(audioFolder, 'woolytube_meta.json.superseded'),
        ).exists(),
        isTrue,
      );

      await service.updatePlaylistSettings(id: playlist.id, audioOnly: true);

      final back = await db.getPlaylist(playlist.id);
      expect(back.audioOnly, isTrue);
      expect(back.outputPath, audioFolder);
      final track = (await db.getTrack(normal.id))!;
      expect(track.status, 'complete');
      expect(track.filePath, normal.filePath);
      expect(track.replaceRequested, isFalse);
      expect(await File(track.filePath!).readAsString(), '00001_Normal.m4a');

      expect(
        await File(p.join(audioFolder, 'woolytube_meta.json')).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(audioFolder, 'woolytube_meta.json.superseded'),
        ).exists(),
        isFalse,
      );
      expect(
        await File(p.join(videoFolder, 'woolytube_meta.json')).exists(),
        isFalse,
      );
      expect(
        await File(
          p.join(videoFolder, 'woolytube_meta.json.superseded'),
        ).exists(),
        isTrue,
      );

      // Nothing needs downloading again.
      await newDownloads().downloadPlaylist(await db.getPlaylist(playlist.id));
      expect(ytdlp.calls, hasLength(1));
    });
  });

  group('restoring a backup on add', () {
    final customActions = {
      ...defaultSponsorBlockCategoryActions(),
      'sponsor': SponsorBlockCategoryAction.showInSeekbar,
      'intro': SponsorBlockCategoryAction.disabled,
    };

    Future<Playlist> givenRemovedPlaylist(String name) async {
      final id = await service.addPlaylist(
        url: _url,
        name: name,
        audioOnly: true,
        sponsorBlockEnabled: false,
        sponsorBlockCategoryActions: customActions,
      );
      final playlist = await db.getPlaylist(id);
      await fileTrack(playlist, 1, '00001_A.m4a', videoId: 'a');
      await insertTestTrack(db, playlistId: id, index: 2, videoId: 'b');
      await metadata.writeMetadataFor(id);
      // Removed from the app, files kept.
      await service.deletePlaylist(id);
      expect(await db.getAllPlaylists(), isEmpty);
      return playlist;
    }

    test('R13: finds the backup under another folder name', () async {
      final removed = await givenRemovedPlaylist('Old Name');
      final renamed = p.join(audioBase, 'Old Name (kept)');
      await Directory(removed.outputPath).rename(renamed);

      final id = await service.addPlaylist(
        url: _url,
        name: 'New Name',
        audioOnly: true,
        autoUpdate: false,
        updateFrequencyHours: 12,
      );

      final restored = await db.getPlaylist(id);
      expect(restored.outputPath, renamed);
      expect(await Directory(p.join(audioBase, 'New Name')).exists(), isFalse);
      expect(restored.autoUpdate, isFalse);
      expect(restored.updateFrequencyHours, 12);
      final tracks = await db.getTracksForPlaylist(id);
      expect(tracks.map((t) => t.videoId), ['a', 'b']);
      expect(tracks.map((t) => t.status), ['complete', 'pending']);
      expect(tracks.first.filePath, p.join(renamed, '00001_A.m4a'));
    });

    test('R20: the restore keeps the SponsorBlock settings of the '
        'backup', () async {
      final removed = await givenRemovedPlaylist('Chill');

      // The add form offers its defaults.
      final id = await service.addPlaylist(
        url: _url,
        name: 'Chill',
        audioOnly: true,
      );

      final restored = await db.getPlaylist(id);
      expect(restored.outputPath, removed.outputPath);
      expect(restored.sponsorBlockEnabled, isFalse);
      expect(
        restored.sponsorBlockCategoryActions,
        encodeSponsorBlockCategoryActions(customActions),
      );
      expect(
        restored.sponsorBlockCategories,
        jsonEncode(autoSkipCategoriesFromActions(customActions)),
      );
      expect(restored.sponsorBlockCategories, removed.sponsorBlockCategories);
    });
  });

  test('R23: a local file without a cover removes the cover of the previous '
      'local file', () async {
    final folder = p.join(audioBase, 'Covers');
    final playlist = await insertTestPlaylist(
      db,
      url: _url,
      audioOnly: true,
      outputPath: folder,
    );
    final track = await fileTrack(playlist, 1, '00001_Song.m4a', videoId: 'v1');
    final withArt = await write(p.join(tempDir.path, 'With art.m4a'), 'art');
    final withoutArt = await write(p.join(tempDir.path, 'Plain.m4a'), 'plain');

    thumbnails.hasEmbeddedThumbnail = true;
    final first = await service.replaceWithLocalFile(
      trackId: track.id,
      sourcePath: withArt,
      sourceFileName: 'With art.m4a',
    );
    final localCover = p.join(
      LibraryLayout.thumbnailsDir(folder),
      'v1.local.jpg',
    );
    expect(first.thumbnailPath, localCover);
    expect(await File(localCover).exists(), isTrue);

    thumbnails.hasEmbeddedThumbnail = false;
    final second = await service.replaceWithLocalFile(
      trackId: track.id,
      sourcePath: withoutArt,
      sourceFileName: 'Plain.m4a',
    );

    expect(second.filePath, p.join(folder, '00001_Plain.m4a'));
    expect(second.thumbnailPath, isNull);
    expect(await File(localCover).exists(), isFalse);
    expect(
      Directory(LibraryLayout.thumbnailsDir(folder))
          .listSync()
          .map((e) => p.basename(e.path))
          .where((name) => name.startsWith('v1.local')),
      isEmpty,
    );

    expect(await service.backfillLocalThumbnails(playlist.id), 0);
    expect((await db.getTrack(track.id))!.thumbnailPath, isNull);
    expect(await File(localCover).exists(), isFalse);
  });

  test('R25: a title-only override works while another operation runs; a '
      'rename waits', () async {
    final folder = p.join(audioBase, 'Busy');
    final playlist = await insertTestPlaylist(
      db,
      url: _url,
      audioOnly: true,
      outputPath: folder,
    );
    final track = await fileTrack(playlist, 1, '00001_Song.m4a');
    expect(await gate.tryEnter('download'), isNull);
    addTearDown(gate.exit);

    expect(
      await service.overrideTrack(trackId: track.id, title: 'Better title'),
      isTrue,
    );
    expect((await db.getTrack(track.id))!.title, 'Better title');

    await expectLater(
      service.overrideTrack(
        trackId: track.id,
        title: 'Other title',
        fileName: 'Renamed',
      ),
      throwsA(isA<LibraryBusyException>()),
    );
    final after = (await db.getTrack(track.id))!;
    expect(after.title, 'Better title');
    expect(after.filePath, track.filePath);
    expect(await File(track.filePath!).exists(), isTrue);
    expect(await File(p.join(folder, '00001_Renamed.m4a')).exists(), isFalse);

    await gate.exit();
    expect(
      await service.overrideTrack(trackId: track.id, fileName: 'Renamed'),
      isTrue,
    );
    expect(
      (await db.getTrack(track.id))!.filePath,
      p.join(folder, '00001_Renamed.m4a'),
    );
  });
}
