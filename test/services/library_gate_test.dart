import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory tempDir;
  late String folder;
  late FakeYtDlpService ytdlp;
  late FakeMediaThumbnailService thumbnails;
  late DownloadLock lock;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_gate_test_');
    folder = p.join(tempDir.path, 'Music', 'Playlist');
    await Directory(folder).create(recursive: true);
    ytdlp = FakeYtDlpService();
    thumbnails = FakeMediaThumbnailService();
    lock = DownloadLock(directoryProvider: () async => tempDir.path);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  File lockFile() => File(p.join(tempDir.path, DownloadLock.fileName));

  Future<void> writeLock(String owner) =>
      lockFile().writeAsString('$owner ${DateTime.now().toIso8601String()}');

  test('a second library change is refused while one runs', () async {
    final gate = LibraryGate.unlocked();
    final release = Completer<void>();
    final first = gate.run('download', () => release.future);

    await expectLater(
      gate.run('playlist update', () async {}),
      throwsA(
        isA<LibraryBusyException>().having(
          (e) => e.message,
          'message',
          'Wait until the current download finishes.',
        ),
      ),
    );

    release.complete();
    await first;
    expect(gate.isBusy, isFalse);
    expect(await gate.run('playlist update', () async => 'ran'), 'ran');
  });

  test('a force insert or sync is refused while a download holds the gate, '
      'and nothing changes', () async {
    final gate = LibraryGate.unlocked();
    final log = LogService();
    final downloads = DownloadService(
      db,
      ytdlp,
      log,
      MetadataService(db),
      null,
      null,
      null,
      null,
      DownloadLock.foregroundOwner,
      gate,
      thumbnails,
    );
    addTearDown(() {
      downloads.dispose();
      log.dispose();
    });
    final playlists = PlaylistService(
      db,
      ytdlp,
      MetadataService(db),
      thumbnails,
      null,
      gate,
    );
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    await insertTestTrack(db, playlistId: playlist.id);
    final source = File(p.join(tempDir.path, 'Insert.mp4'));
    await source.writeAsString('insert');
    ytdlp.downloadCompleter = Completer<void>();
    ytdlp.downloadStarted = Completer<void>();

    final download = downloads.downloadPlaylist(playlist);
    await ytdlp.downloadStarted!.future;

    await expectLater(
      playlists.forceInsert(
        playlistId: playlist.id,
        index: 1,
        sourcePath: source.path,
      ),
      throwsA(
        isA<ForceInsertException>().having(
          (e) => e.message,
          'message',
          'Wait until the current download finishes.',
        ),
      ),
    );
    ytdlp.playlistInfo = {
      'entries': [
        {'id': 'video-1', 'title': 'Track 1'},
        {'id': 'new', 'title': 'New'},
      ],
    };
    await expectLater(
      playlists.syncPlaylist(playlist),
      throwsA(isA<LibraryBusyException>()),
    );

    ytdlp.downloadCompleter!.complete();
    await download;

    final tracks = await db.getTracksForPlaylist(playlist.id);
    expect(tracks.map((t) => t.videoId), ['video-1']);
    expect(tracks.single.status, 'complete');
    expect(tracks.single.filePath, p.join(folder, '00001_Title.mp4'));
  });

  test('a background lock blocks a foreground force insert', () async {
    await writeLock(DownloadLock.backgroundOwner);
    final service = PlaylistService(
      db,
      ytdlp,
      MetadataService(db),
      thumbnails,
      null,
      LibraryGate(lock: lock, owner: DownloadLock.foregroundOwner),
    );
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    final existingPath = p.join(folder, '00001_Existing.mp4');
    await File(existingPath).writeAsString('existing');
    final existing = await insertTestTrack(
      db,
      playlistId: playlist.id,
      filePath: existingPath,
      status: 'complete',
    );
    final source = File(p.join(tempDir.path, 'Insert.mp4'));
    await source.writeAsString('insert');

    await expectLater(
      service.forceInsert(
        playlistId: playlist.id,
        index: 1,
        sourcePath: source.path,
      ),
      throwsA(
        isA<ForceInsertException>().having(
          (e) => e.message,
          'message',
          DownloadService.lockHeldMessage,
        ),
      ),
    );

    expect(await db.getTracksForPlaylist(playlist.id), [existing]);
    expect(await File(existingPath).readAsString(), 'existing');
    expect(Directory(folder).listSync().map((e) => p.basename(e.path)), [
      '00001_Existing.mp4',
    ]);
    expect(
      (await lockFile().readAsString()).split(' ').first,
      DownloadLock.backgroundOwner,
    );
  });

  test("releasing a lock never removes another owner's lock", () async {
    expect(await lock.acquire(DownloadLock.backgroundOwner), isTrue);

    await lock.release(DownloadLock.foregroundOwner);

    expect(await lockFile().exists(), isTrue);
    expect(await lock.isHeldByOther(DownloadLock.foregroundOwner), isTrue);

    await lock.release(DownloadLock.backgroundOwner);
    expect(await lockFile().exists(), isFalse);
  });

  test("leaving the gate keeps another engine's lock", () async {
    // The background engine took the lock after ours went stale.
    final gate = LibraryGate(lock: lock, owner: DownloadLock.foregroundOwner);
    expect(await gate.tryEnter('download'), isNull);
    await writeLock(DownloadLock.backgroundOwner);

    await gate.exit();

    expect(await lockFile().exists(), isTrue);
    expect(await lock.isHeldByOther(DownloadLock.foregroundOwner), isTrue);
  });

  test('an action waits for a short check instead of failing', () async {
    final gate = LibraryGate.unlocked();
    expect(await gate.tryEnter('playlist check'), isNull);
    // Without waiting, it is refused at once.
    expect(await gate.tryEnter('rename'), isNotNull);

    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 100),
      ).then((_) => gate.exit()),
    );
    expect(
      await gate.tryEnter('rename', wait: const Duration(seconds: 2)),
      isNull,
    );
    await gate.exit();

    // A long operation is not waited for.
    expect(await gate.tryEnter('download'), isNull);
    final watch = Stopwatch()..start();
    expect(
      await gate.tryEnter('rename', wait: const Duration(seconds: 2)),
      isNotNull,
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('an unstamped lock left by a dead engine is taken over after a '
      'moment', () async {
    final file = lockFile();
    await file.writeAsString('');
    expect(await lock.isHeldByOther(DownloadLock.foregroundOwner), isTrue);
    expect(await lock.acquire(DownloadLock.foregroundOwner), isFalse);

    await file.setLastModified(
      DateTime.now().subtract(
        DownloadLock.unknownHolderStaleAfter + const Duration(seconds: 1),
      ),
    );
    expect(await lock.isHeldByOther(DownloadLock.foregroundOwner), isFalse);
    expect(await lock.acquire(DownloadLock.foregroundOwner), isTrue);
    expect(
      (await file.readAsString()).startsWith(DownloadLock.foregroundOwner),
      isTrue,
    );
  });
}
