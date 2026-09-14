import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapter_service.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';
import '../helpers/test_database.dart';

class _Ytdlp extends YtDlpService {
  int calls = 0;
  bool fail = false;
  @override
  Future<Map<String, dynamic>> getVideoInfo(String url) async {
    calls++;
    if (fail) throw StateError('Offline');
    return {
      'duration': 60,
      'chapters': [
        {'title': 'First', 'start_time': 0, 'end_time': 30},
        {'title': 'Second', 'start_time': 30, 'end_time': 60},
      ],
    };
  }
}

void main() {
  late AppDatabase db;
  late Directory dir;
  late File media;
  late Track track;
  late _Ytdlp ytdlp;
  late ChapterService service;
  setUp(() async {
    db = openTestDatabase();
    dir = await Directory.systemTemp.createTemp('woolytube-chapters-');
    media = await File(
      '${dir.path}/00001_album.m4a',
    ).writeAsBytes([0, 1, 2, 3, 255]);
    final playlist = await insertTestPlaylist(db, outputPath: dir.path);
    track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      status: 'complete',
      filePath: media.path,
      durationSeconds: 60,
    );
    ytdlp = _Ytdlp();
    service = ChapterService(db, ytdlp);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('fractional starts, missing ends, and malformed ranges', () {
    final data = ChapterData.fromVideoInfo({
      'duration': 90,
      'chapters': [
        {'title': 'First', 'start_time': 0},
        {'title': 'Second', 'start_time': 30.125},
      ],
    });
    expect(data.active.first.endMs, 30125);
    expect(data.active.last.endMs, 90000);
    for (final bad in [-1, double.nan, double.infinity, 100]) {
      expect(
        ChapterData.fromVideoInfo({
          'duration': 60,
          'chapters': [
            {'title': 'Bad', 'start_time': bad, 'end_time': 60},
          ],
        }).active,
        isEmpty,
      );
    }
    expect(parseChapterTimestamp('1:02:03.125'), 3723125);
    expect(parseChapterTimestamp('1:99'), isNull);
    expect(parseChapterTimestamp('NaN'), isNull);
  });

  test(
    'custom editing preserves media bytes and survives YouTube refresh',
    () async {
      await service.refresh(track);
      track = (await db.getTrack(track.id))!;
      final first = ChapterData.decode(track.chaptersJson).active.first;
      await service.save(
        track,
        MediaChapter(id: first.id, title: 'My title', startMs: 0, endMs: 30000),
      );
      await service.refresh(track);
      final data = ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      );
      expect(data.active.first.title, 'My title');
      expect(data.downloaded.first.title, 'First');
      expect(await media.readAsBytes(), [0, 1, 2, 3, 255]);
      await service.delete(track, first.id);
      await service.delete(track, data.active.last.id);
      expect(
        ChapterData.decode((await db.getTrack(track.id))!.chaptersJson).active,
        isEmpty,
      );
      await service.restore(track);
      expect(
        ChapterData.decode((await db.getTrack(track.id))!.chaptersJson).active,
        hasLength(2),
      );
    },
  );

  test('rejects overlaps and out-of-file custom chapters', () async {
    await service.refresh(track);
    await expectLater(
      service.save(
        track,
        const MediaChapter(
          id: 'local',
          title: 'Overlap',
          startMs: 1000,
          endMs: 2000,
        ),
      ),
      throwsFormatException,
    );
    await expectLater(
      service.save(
        track,
        const MediaChapter(
          id: 'local',
          title: 'Too long',
          startMs: 60000,
          endMs: 61000,
        ),
      ),
      throwsFormatException,
    );
  });

  test(
    'failed refresh preserves data; replaced files invalidate old timings',
    () async {
      await service.refresh(track);
      final before = (await db.getTrack(track.id))!.chaptersJson;
      ytdlp.fail = true;
      await expectLater(service.refresh(track), throwsStateError);
      expect((await db.getTrack(track.id))!.chaptersJson, before);
      await db.invalidateTrackChapters(track.id);
      expect(
        ChapterData.decode((await db.getTrack(track.id))!.chaptersJson).active,
        isEmpty,
      );
    },
  );

  test('download sidecar provides chapters and cannot modify media', () async {
    final sidecar = File('${dir.path}/00001_album.info.json');
    await sidecar.writeAsString(
      jsonEncode({
        'id': track.videoId,
        'duration': 60,
        'chapters': [
          {'title': 'Song', 'start_time': 0, 'end_time': 60},
        ],
      }),
    );
    await MetadataService(db).captureChapterMetadata(track, dir.path);
    expect(
      ChapterData.decode(
        (await db.getTrack(track.id))!.chaptersJson,
      ).active.single.title,
      'Song',
    );
    expect(await sidecar.exists(), isFalse);
    expect(await media.readAsBytes(), [0, 1, 2, 3, 255]);
  });

  test(
    'folder metadata round trip preserves custom chapters and album override',
    () async {
      await service.refresh(track);
      track = (await db.getTrack(track.id))!;
      final data = ChapterData.decode(track.chaptersJson);
      await service.save(
        track,
        MediaChapter(
          id: data.active.first.id,
          title: 'Local title',
          startMs: 0,
          endMs: 30000,
        ),
      );
      await service.setOverride(track, true);
      final contents =
          jsonDecode(
                await File('${dir.path}/woolytube_meta.json').readAsString(),
              )
              as Map;
      final saved = (contents['tracks'] as List).single as Map;
      final imported = openTestDatabase();
      try {
        await MetadataService(imported).importPlaylist(
          DiscoveredPlaylist(
            folderPath: dir.path,
            url: 'imported',
            name: 'Album',
            audioOnly: true,
            autoUpdate: false,
            updateFrequencyHours: 24,
            includeThumbnails: false,
            sponsorBlockEnabled: false,
            sponsorBlockCategories: '[]',
            createdAt: DateTime.now(),
            playChapters: true,
            tracks: [
              DiscoveredTrack(
                index: 1,
                videoId: track.videoId,
                title: track.title,
                status: 'complete',
                fileName: saved['fileName'] as String,
                chaptersJson: ChapterData.fromJson(saved['chapters']).encode(),
                chaptersEnabled: saved['chaptersEnabled'] as bool?,
              ),
            ],
          ),
        );
        final result = (await imported.getAllTracks()).single;
        expect(result.chaptersEnabled, isTrue);
        expect(
          ChapterData.decode(result.chaptersJson).active.first.title,
          'Local title',
        );
        expect((await imported.getAllPlaylists()).single.playChapters, isTrue);
      } finally {
        await imported.close();
      }
    },
  );

  test(
    'v9 migration keeps existing tracks playable with chapters disabled',
    () async {
      final file = File('${dir.path}/migration.sqlite');
      var database = AppDatabase.forTesting(NativeDatabase(file));
      final playlist = await insertTestPlaylist(database);
      final oldTrack = await insertTestTrack(
        database,
        playlistId: playlist.id,
        status: 'complete',
        filePath: media.path,
      );
      await database.customStatement(
        'ALTER TABLE playlists DROP COLUMN play_chapters',
      );
      await database.customStatement(
        'ALTER TABLE tracks DROP COLUMN chapters_json',
      );
      await database.customStatement(
        'ALTER TABLE tracks DROP COLUMN chapters_enabled',
      );
      await database.customStatement('PRAGMA user_version = 9');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));
      try {
        final migrated = (await database.getTrack(oldTrack.id))!;
        expect(migrated.status, 'complete');
        expect(migrated.filePath, media.path);
        expect(migrated.chaptersJson, isNull);
        expect(migrated.chaptersEnabled, isNull);
        expect((await database.getPlaylist(playlist.id)).playChapters, isNull);
      } finally {
        await database.close();
      }
    },
  );
}
