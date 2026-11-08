import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/lyrics/lyrics_files.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/metadata_service.dart';

import '../../helpers/test_database.dart';

/// Lyrics survive a reinstall: their text in `.woolytube_info`, the user's
/// choices in the sidecar.
void main() {
  late AppDatabase db;
  late Directory tempDir;
  late String folder;
  late MetadataService metadata;

  setUp(() async {
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_lyrics_');
    final audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
    LibraryLayout.overrideBasePathsForTesting(
      audio: audioBase,
      video: p.join(tempDir.path, 'Movies', 'WoolyTube'),
    );
    folder = p.join(audioBase, 'Songs');
    await Directory(folder).create(recursive: true);
    metadata = MetadataService(db);
  });

  tearDown(() async {
    LibraryLayout.resetBasePathsForTesting();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  final checkedAt = DateTime.utc(2026, 11, 8);
  const lines = [
    LyricsLineDraft('first line', startMs: 1000),
    LyricsLineDraft('second line', startMs: 2000),
  ];

  test('pins go to the sidecar and come back with the kept text', () async {
    final playlist = await insertTestPlaylist(
      db,
      outputPath: folder,
      lyricsMode: 'lyrics',
    );
    final chapters =
        ChapterData(
          downloaded: const [
            MediaChapter(id: 'c1', title: 'A — One', startMs: 0, endMs: 1000),
          ],
        ).encode();
    Future<Track> track(int index, String videoId) async {
      await File(p.join(folder, '$index.m4a')).writeAsString('media');
      return insertTestTrack(
        db,
        playlistId: playlist.id,
        index: index,
        videoId: videoId,
        title: 'Song $index',
        filePath: p.join(folder, '$index.m4a'),
        status: 'complete',
        chaptersJson: chapters,
      );
    }

    final kept = await track(1, 'kept');
    final lost = await track(2, 'lost');
    final automatic = await track(3, 'auto');

    // A pinned pick with its file, a pinned chapter pick whose file is
    // gone, and an automatic doc with its file.
    final keptDoc = LyricsDocDraft(
      trackId: kept.id,
      kind: LyricsMode.lyrics,
      status: LyricsStatus.found,
      source: LyricsSource.lrclib,
      sourceRef: '77',
      matchedArtist: 'Artist',
      matchedTitle: 'Song',
      synced: true,
      pinned: true,
      shiftMs: 300,
      checkedAt: checkedAt,
      lines: lines,
    );
    await db.replaceLyricsDoc(keptDoc);
    await writeLyricsFile(folder, 'kept', [keptDoc]);
    await db.replaceLyricsDoc(
      LyricsDocDraft(
        trackId: lost.id,
        chapterId: 'c1',
        kind: LyricsMode.lyrics,
        status: LyricsStatus.found,
        source: LyricsSource.lrclib,
        sourceRef: '88',
        pinned: true,
        checkedAt: checkedAt,
        lines: lines,
      ),
    );
    final autoDoc = LyricsDocDraft(
      trackId: automatic.id,
      kind: LyricsMode.lyrics,
      status: LyricsStatus.found,
      source: LyricsSource.ytmusic,
      sourceRef: 'MPLYt_x',
      checkedAt: checkedAt,
      lines: lines,
    );
    await db.replaceLyricsDoc(autoDoc);
    await writeLyricsFile(folder, 'auto', [autoDoc]);

    await metadata.writeMetadataFor(playlist.id);
    final sidecar =
        jsonDecode(
              await File(p.join(folder, 'woolytube_meta.json')).readAsString(),
            )
            as Map<String, dynamic>;
    final tracks = (sidecar['tracks'] as List).cast<Map<String, dynamic>>();
    expect(tracks[0]['lyricsPins'], [
      {
        'chapterId': null,
        'status': 'found',
        'source': 'lrclib',
        'sourceRef': '77',
        'matchedArtist': 'Artist',
        'matchedTitle': 'Song',
        'shiftMs': 300,
      },
    ]);
    expect((tracks[1]['lyricsPins'] as List).single['chapterId'], 'c1');
    expect(tracks[2].containsKey('lyricsPins'), isFalse);

    // Reinstall: an empty database imports the folder.
    await db.deletePlaylist(playlist.id);
    expect(await db.lyricsDocsForPlaylist(playlist.id), isEmpty);
    final discovered = (await metadata.readFolder(folder))!;
    expect(discovered.tracks[0].lyricsPins.single.sourceRef, '77');
    final id = await metadata.importPlaylist(discovered);
    final byVideo = {
      for (final t in await db.getTracksForPlaylist(id)) t.videoId: t,
    };

    final restoredKept = (await db.lyricsDocFor(byVideo['kept']!.id, null))!;
    expect(restoredKept.pinned, isTrue);
    expect(restoredKept.synced, isTrue);
    expect(restoredKept.shiftMs, 300);
    final keptLines = await db.lyricsLinesForDoc(restoredKept.id);
    expect(keptLines, hasLength(2));
    // The file's lines already carry the shift.
    expect(keptLines.first.startMs, lines.first.startMs);

    // The pin without a file is there, without text, for a refetch.
    final restoredLost = (await db.lyricsDocFor(byVideo['lost']!.id, 'c1'))!;
    expect(restoredLost.pinned, isTrue);
    expect(restoredLost.sourceRef, '88');
    expect(await db.lyricsLinesForDoc(restoredLost.id), isEmpty);

    final restoredAuto = (await db.lyricsDocFor(byVideo['auto']!.id, null))!;
    expect(restoredAuto.pinned, isFalse);
    expect(restoredAuto.source, LyricsSource.ytmusic);
    expect(await db.lyricsLinesForDoc(restoredAuto.id), hasLength(2));
  });

  test('a chapter doc for a chapter that is gone is not restored', () async {
    final playlist = await insertTestPlaylist(db, outputPath: folder);
    await File(p.join(folder, '1.m4a')).writeAsString('media');
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'v',
      filePath: p.join(folder, '1.m4a'),
      status: 'complete',
    );
    await writeLyricsFile(folder, 'v', [
      LyricsDocDraft(
        trackId: track.id,
        chapterId: 'gone',
        kind: LyricsMode.lyrics,
        status: LyricsStatus.none,
        checkedAt: checkedAt,
      ),
    ]);
    await metadata.writeMetadataFor(playlist.id);
    await db.deletePlaylist(playlist.id);
    final id = await metadata.importPlaylist(
      (await metadata.readFolder(folder))!,
    );
    final imported = (await db.getTracksForPlaylist(id)).single;
    expect(await db.lyricsDocsForTrack(imported.id), isEmpty);
  });
}
