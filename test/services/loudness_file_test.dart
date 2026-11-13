import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/loudness_file.dart';
import 'package:woolytube/services/loudness_mirror.dart';
import 'package:woolytube/services/metadata_service.dart';

import '../helpers/test_database.dart';

/// `.woolytube_info/loudness.json` keeps each playlist's loudness
/// measurements in its folder, so a reinstall or another phone does not
/// measure every song again.
void main() {
  late AppDatabase db;
  late Directory tempDir;
  late String folder;
  late Playlist playlist;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_loudness_');
    final audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
    LibraryLayout.overrideBasePathsForTesting(
      audio: audioBase,
      video: p.join(tempDir.path, 'Movies', 'WoolyTube'),
    );
    folder = p.join(audioBase, 'Mix');
    await Directory(folder).create(recursive: true);
    playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      audioOnly: true,
    );
  });

  tearDown(() async {
    LibraryLayout.resetBasePathsForTesting();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  File loudnessFile() => File(LibraryLayout.loudnessJsonPath(folder));

  Future<Map<String, dynamic>> fileJson() async =>
      jsonDecode(await loudnessFile().readAsString()) as Map<String, dynamic>;

  /// A downloaded song of [bytes] bytes.
  Future<Track> song(
    AppDatabase db,
    Playlist playlist,
    int index,
    String videoId, {
    int bytes = 1000,
  }) async {
    final path = p.join(playlist.outputPath, '${index}_$videoId.m4a');
    await File(path).writeAsBytes(List.filled(bytes, index));
    return insertTestTrack(
      db,
      playlistId: playlist.id,
      index: index,
      videoId: videoId,
      title: videoId,
      status: 'complete',
      filePath: path,
    );
  }

  Future<void> measure(
    Track track, {
    double integrated = -14.5,
    double? cabin = -17.25,
    double? peak = -0.75,
    DateTime? at,
  }) async {
    final stat = await File(track.filePath!).stat();
    await db.saveLoudnessMeasurement(
      LoudnessMeasurementsCompanion.insert(
        trackId: Value(track.id),
        filePath: track.filePath!,
        fileSize: stat.size,
        fileModifiedMs: stat.modified.millisecondsSinceEpoch,
        integratedLufs: Value(integrated),
        cabinLufs: Value(cabin),
        peakDb: Value(peak),
        measuredAt: at ?? DateTime.utc(2026, 11, 10, 8),
      ),
    );
  }

  test('writes the measurements by video id with the file size', () async {
    final a = await song(db, playlist, 1, 'aaa', bytes: 1200);
    final b = await song(db, playlist, 2, 'bbb', bytes: 900);
    await song(db, playlist, 3, 'unmeasured');
    await measure(a);
    await measure(b, integrated: -9, cabin: null, peak: null);

    expect(await writeLoudnessFile(db, playlist), isTrue);
    final json = await fileJson();
    expect(json['version'], loudnessFileVersion);
    expect(json['files'], {
      'aaa': {
        'file': '1_aaa.m4a',
        'size': 1200,
        'integrated': -14.5,
        'cabin': -17.25,
        'peak': -0.75,
        'measuredAt': '2026-11-10T08:00:00.000Z',
      },
      'bbb': {
        'file': '2_bbb.m4a',
        'size': 900,
        'integrated': -9.0,
        'measuredAt': '2026-11-10T08:00:00.000Z',
      },
    });
    expect(
      await File(p.join(LibraryLayout.infoDir(folder), '.nomedia')).exists(),
      isTrue,
    );

    // Unchanged: not written again.
    final modified = (await loudnessFile().stat()).modified;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await writeLoudnessFile(db, playlist), isFalse);
    expect((await loudnessFile().stat()).modified, modified);
  });

  test('a reinstall takes the measurements back for the same files, even '
      'with a new modification time', () async {
    final a = await song(db, playlist, 1, 'aaa', bytes: 1200);
    final b = await song(db, playlist, 2, 'bbb', bytes: 900);
    await measure(a);
    await measure(b, integrated: -9.125, cabin: null, peak: null);
    await MetadataService(db).writeMetadataFor(playlist.id);
    await writeLoudnessFile(db, playlist);
    // Copying to a PC and back gives the files a new time.
    for (final track in [a, b]) {
      await File(track.filePath!).setLastModified(DateTime(2027, 1, 2, 3));
    }

    final fresh = openTestDatabase();
    addTearDown(fresh.close);
    // Other ids than before.
    final other = await insertTestPlaylist(
      fresh,
      url: 'https://www.youtube.com/playlist?list=other',
      outputPath: p.join(tempDir.path, 'elsewhere'),
    );
    await insertTestTrack(fresh, playlistId: other.id, videoId: 'zzz');
    final restore = MetadataService(fresh);
    final found = await restore.scanDirectory(tempDir.path);
    final id = await restore.importPlaylist(
      found.singleWhere((d) => d.folderPath == folder),
    );

    final tracks = {
      for (final t in await fresh.getTracksForPlaylist(id)) t.videoId: t,
    };
    final rows = await fresh.getLoudnessMeasurements();
    final ra = rows[tracks['aaa']!.id]!;
    expect(ra.integratedLufs, -14.5);
    expect(ra.cabinLufs, -17.25);
    expect(ra.peakDb, -0.75);
    expect(ra.fileSize, 1200);
    expect(ra.filePath, a.filePath);
    expect(
      ra.fileModifiedMs,
      DateTime(2027, 1, 2, 3).millisecondsSinceEpoch,
      reason: 'the file as it is now, so the player trusts it',
    );
    expect(ra.measuredAt.toUtc(), DateTime.utc(2026, 11, 10, 8));
    final rb = rows[tracks['bbb']!.id]!;
    expect(rb.integratedLufs, -9.125);
    expect(rb.cabinLufs, isNull);
    expect(rb.peakDb, isNull);
  });

  test('a file of another size is not given the old measurement', () async {
    final a = await song(db, playlist, 1, 'aaa', bytes: 1200);
    await measure(a);
    await writeLoudnessFile(db, playlist);

    final fresh = openTestDatabase();
    addTearDown(fresh.close);
    final copy = await insertTestPlaylist(fresh, outputPath: folder);
    // Replaced by another download meanwhile.
    await File(a.filePath!).writeAsBytes(List.filled(1300, 1));
    final track = await insertTestTrack(
      fresh,
      playlistId: copy.id,
      videoId: 'aaa',
      status: 'complete',
      filePath: a.filePath,
    );
    expect(await seedLoudnessFromFolder(fresh, copy), 0);
    expect(await fresh.getLoudnessMeasurement(track.id), isNull);
  });

  test('a measurement the app has is never replaced from the file', () async {
    final a = await song(db, playlist, 1, 'aaa', bytes: 1200);
    await measure(a, integrated: -20);
    await writeLoudnessFile(db, playlist);
    // Measured again here since.
    await measure(a, integrated: -11, at: DateTime.utc(2026, 11, 12));

    expect(await seedLoudnessFromFolder(db, playlist), 0);
    final row = (await db.getLoudnessMeasurement(a.id))!;
    expect(row.integratedLufs, -11);
    expect(row.measuredAt.toUtc(), DateTime.utc(2026, 11, 12));
    // And the file follows the app.
    await writeLoudnessFile(db, playlist);
    expect(((await fileJson())['files'] as Map)['aaa']['integrated'], -11.0);
  });

  test('writing keeps what the app has not taken back yet and drops songs '
      'that left the playlist', () async {
    final a = await song(db, playlist, 1, 'aaa', bytes: 1200);
    final b = await song(db, playlist, 2, 'bbb', bytes: 900);
    await measure(a);
    await measure(b);
    await writeLoudnessFile(db, playlist);

    final fresh = openTestDatabase();
    addTearDown(fresh.close);
    final copy = await insertTestPlaylist(fresh, outputPath: folder);
    final newA = await insertTestTrack(
      fresh,
      playlistId: copy.id,
      videoId: 'aaa',
      status: 'complete',
      filePath: a.filePath,
    );
    // bbb is no longer in the playlist; ccc has no measurement anywhere.
    await song(fresh, copy, 3, 'ccc');
    // Not taken back yet.
    expect(await fresh.getLoudnessMeasurement(newA.id), isNull);

    expect(await writeLoudnessFile(fresh, copy), isTrue);
    final files = (await fileJson())['files'] as Map;
    expect(files.keys, ['aaa']);
    expect(files['aaa']['integrated'], -14.5);
  });

  test('two files of one video keep a measurement each', () async {
    final a = await song(db, playlist, 1, 'aaa', bytes: 1200);
    final twice = await song(db, playlist, 2, 'aaa', bytes: 1500);
    await measure(a, integrated: -10);
    await measure(twice, integrated: -20);
    await writeLoudnessFile(db, playlist);
    final files = (await fileJson())['files'] as Map;
    expect(files, hasLength(2));
    expect(files['aaa']['size'], 1200);
    expect(files['aaa/2_aaa.m4a'], containsPair('videoId', 'aaa'));

    final fresh = openTestDatabase();
    addTearDown(fresh.close);
    final copy = await insertTestPlaylist(fresh, outputPath: folder);
    final first = await insertTestTrack(
      fresh,
      playlistId: copy.id,
      videoId: 'aaa',
      status: 'complete',
      filePath: a.filePath,
    );
    final second = await insertTestTrack(
      fresh,
      playlistId: copy.id,
      index: 2,
      videoId: 'aaa',
      status: 'complete',
      filePath: twice.filePath,
    );
    expect(await seedLoudnessFromFolder(fresh, copy), 2);
    expect((await fresh.getLoudnessMeasurement(first.id))!.integratedLufs, -10);
    expect(
      (await fresh.getLoudnessMeasurement(second.id))!.integratedLufs,
      -20,
    );
  });

  test('a newer file, a broken file and a missing folder', () async {
    final a = await song(db, playlist, 1, 'aaa');
    await measure(a);
    await Directory(LibraryLayout.infoDir(folder)).create(recursive: true);

    await loudnessFile().writeAsString('{broken');
    expect(await seedLoudnessFromFolder(db, playlist), 0);
    expect(await writeLoudnessFile(db, playlist), isTrue);

    await loudnessFile().writeAsString(
      jsonEncode({'version': 2, 'files': <String, dynamic>{}, 'more': 1}),
    );
    expect(await writeLoudnessFile(db, playlist), isFalse);
    expect((await fileJson())['more'], 1);

    await Directory(folder).delete(recursive: true);
    expect(await writeLoudnessFile(db, playlist), isFalse);
    expect(await Directory(folder).exists(), isFalse);
  });

  group('LoudnessMirror', () {
    late LoudnessMirror mirror;

    tearDown(() => mirror.dispose());

    test('takes measurements back first, then writes every folder', () async {
      final a = await song(db, playlist, 1, 'aaa', bytes: 1200);
      final b = await song(db, playlist, 2, 'bbb', bytes: 900);
      await Directory(LibraryLayout.infoDir(folder)).create(recursive: true);
      await loudnessFile().writeAsString(
        jsonEncode(
          loudnessFileJson([
            LoudnessFileEntry(
              videoId: 'aaa',
              fileName: '1_aaa.m4a',
              size: 1200,
              integratedLufs: -8,
              measuredAt: DateTime.utc(2026),
            ),
          ]),
        ),
      );
      await measure(b, integrated: -12);
      final seeded = <int>[];
      mirror = LoudnessMirror(
        db,
        LibraryGate.unlocked(),
        onSeeded: seeded.add,
        startDelay: const Duration(hours: 1),
      );
      await mirror.flush();
      expect(seeded, [1]);
      expect((await db.getLoudnessMeasurement(a.id))!.integratedLufs, -8);
      final files = (await fileJson())['files'] as Map;
      expect(files.keys, ['aaa', 'bbb']);
      expect(files['bbb']['integrated'], -12.0);
    });

    test('writes at most once per interval, or after a batch', () async {
      final tracks = [
        for (var i = 1; i <= 4; i++) await song(db, playlist, i, 'v$i'),
      ];
      mirror = LoudnessMirror(
        db,
        LibraryGate.unlocked(),
        interval: const Duration(milliseconds: 400),
        batch: 3,
        startDelay: const Duration(hours: 1),
      );
      mirror.start();
      await measure(tracks[0]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await loudnessFile().exists(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(((await fileJson())['files'] as Map).keys, ['v1']);

      final slow = LoudnessMirror(
        db,
        LibraryGate.unlocked(),
        interval: const Duration(hours: 1),
        batch: 3,
        startDelay: const Duration(hours: 1),
      );
      addTearDown(slow.dispose);
      await mirror.dispose();
      slow.start();
      for (final track in tracks.skip(1)) {
        await measure(track);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(((await fileJson())['files'] as Map).keys, [
        'v1',
        'v2',
        'v3',
        'v4',
      ]);
    });

    test('waits while a playlist folder is moved or deleted', () async {
      final a = await song(db, playlist, 1, 'aaa');
      await measure(a);
      final gate = LibraryGate.unlocked();
      mirror = LoudnessMirror(
        db,
        gate,
        interval: const Duration(milliseconds: 100),
        startDelay: const Duration(hours: 1),
      );
      await gate.run('playlist deletion', () async {
        await mirror.flush();
        expect(await loudnessFile().exists(), isFalse);
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await loudnessFile().exists(), isTrue);
    });
  });
}
