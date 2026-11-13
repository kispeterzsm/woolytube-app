import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Playlist playlist;
  late Track track;

  setUp(() async {
    db = openTestDatabase();
    playlist = await insertTestPlaylist(db, lyricsMode: 'lyrics');
    track = await insertTestTrack(db, playlistId: playlist.id);
  });

  tearDown(() => db.close());

  LyricsDocDraft draft(
    List<String> lines, {
    int? trackId,
    String? chapterId,
    bool pinned = false,
    String status = LyricsStatus.found,
    LyricsMode kind = LyricsMode.lyrics,
  }) => LyricsDocDraft(
    trackId: trackId ?? track.id,
    chapterId: chapterId,
    kind: kind,
    status: status,
    source: LyricsSource.lrclib,
    sourceRef: '42',
    synced: true,
    pinned: pinned,
    checkedAt: DateTime(2026),
    lines: [
      for (var i = 0; i < lines.length; i++)
        LyricsLineDraft(lines[i], startMs: i * 1000),
    ],
  );

  Future<List<int>> matchingLines(String expr) async =>
      (await db.lyricsFtsCandidates(expr)).map((c) => c.lineId).toList();

  Future<int> ftsRows() async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM lyrics_fts_docsize')
          .getSingle())
      .read<int>('n');

  test('replaceLyricsDoc stores lines with two-line search windows', () async {
    final docId = await db.replaceLyricsDoc(
      draft(['Hey brother', "There's an endless road", 'Szétszórom']),
    );
    final lines = await db.lyricsLinesForDoc(docId);
    expect(lines.map((l) => l.lineNo), [0, 1, 2]);
    expect(lines.map((l) => l.startMs), [0, 1000, 2000]);
    expect(lines.first.lineText, 'Hey brother');
    expect(lines.map((l) => l.searchText), [
      'hey brother theres an endless road',
      'theres an endless road szetszorom',
      'szetszorom',
    ]);
    final doc = (await db.lyricsDocsForTrack(track.id)).single;
    expect(doc.kind, 'lyrics');
    expect(doc.sourceRef, '42');
    expect(doc.synced, isTrue);
  });

  test('the FTS index follows inserts, replaces and deletes', () async {
    final docId = await db.replaceLyricsDoc(draft(['alpha one', 'beta two']));
    expect((await matchingLines('alpha')).length, 1);
    expect((await matchingLines('beta')).length, 2);

    final sameId = await db.replaceLyricsDoc(draft(['gamma three']));
    expect(sameId, docId);
    expect(await matchingLines('alpha'), isEmpty);
    expect((await matchingLines('gamma')).length, 1);
    expect(await ftsRows(), 1);

    await db.customStatement(
      "UPDATE lyrics_lines SET search_text = 'delta four'",
    );
    expect(await matchingLines('gamma'), isEmpty);
    expect((await matchingLines('delta')).length, 1);

    expect(await db.deleteLyricsDocs(track.id), 1);
    expect(await matchingLines('delta'), isEmpty);
    expect(await ftsRows(), 0);
  });

  test('deleting a track removes its docs and index rows', () async {
    await db.replaceLyricsDoc(draft(['alpha']));
    await db.replaceLyricsDoc(draft(['alpha beta'], chapterId: 'c1'));
    await db.customStatement('DELETE FROM tracks WHERE id = ${track.id}');
    expect(await db.lyricsDocsForTrack(track.id), isEmpty);
    expect(await matchingLines('alpha'), isEmpty);
    expect(await ftsRows(), 0);
  });

  test('deleteTracks and deletePlaylist remove lyrics', () async {
    final other = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'v2',
    );
    await db.replaceLyricsDoc(draft(['alpha']));
    await db.replaceLyricsDoc(draft(['alpha'], trackId: other.id));
    await db.deleteTracks([track.id]);
    expect((await matchingLines('alpha')).length, 1);
    await db.deletePlaylist(playlist.id);
    expect(await matchingLines('alpha'), isEmpty);
  });

  test('one doc per track and chapter', () async {
    await db.replaceLyricsDoc(draft(['whole']));
    await db.replaceLyricsDoc(draft(['first'], chapterId: 'c1'));
    await db.replaceLyricsDoc(draft(['first again'], chapterId: 'c1'));
    await db.replaceLyricsDoc(draft(['second'], chapterId: 'c2'));
    final docs = await db.lyricsDocsForTrack(track.id);
    expect(docs.map((d) => d.chapterId), [null, 'c1', 'c2']);
    expect(
      () => db.customStatement(
        'INSERT INTO lyrics_docs (track_id, chapter_id, kind, status, '
        "checked_at) VALUES (${track.id}, NULL, 'lyrics', 'none', 0)",
      ),
      throwsA(isA<SqliteException>()),
    );
    expect((await db.lyricsDocFor(track.id, 'c1'))!.id, docs[1].id);
    expect((await db.lyricsDocFor(track.id, null))!.id, docs[0].id);
    expect(
      (await db.lyricsLinesForDoc(docs[1].id)).single.lineText,
      'first again',
    );
  });

  test('deleteLyricsDocs and pruneLyricsChapterDocs', () async {
    await db.replaceLyricsDoc(draft(['whole']));
    for (final id in ['c1', 'c2', 'c3']) {
      await db.replaceLyricsDoc(draft([id], chapterId: id));
    }
    expect(await db.pruneLyricsChapterDocs(track.id, {'c1', 'c3'}), 1);
    expect((await db.lyricsDocsForTrack(track.id)).map((d) => d.chapterId), [
      null,
      'c1',
      'c3',
    ]);
    expect(await db.deleteLyricsDocs(track.id, chapterId: 'c1'), 1);
    expect(await db.deleteLyricsDocs(track.id), 1);
    expect((await db.lyricsDocsForTrack(track.id)).map((d) => d.chapterId), [
      'c3',
    ]);
    await db.replaceLyricsDoc(draft(['whole']));
    expect(await db.deleteLyricsDocs(track.id, allChapters: true), 2);
  });

  test('FTS candidates only come from playlists with lyrics on', () async {
    final off = await insertTestPlaylist(db, url: 'off', name: 'Off');
    final offTrack = await insertTestTrack(db, playlistId: off.id);
    await db.replaceLyricsDoc(draft(['endless road']));
    await db.replaceLyricsDoc(draft(['endless road'], trackId: offTrack.id));
    final candidates = await db.lyricsFtsCandidates('endless');
    expect(candidates, hasLength(1));
    final doc = (await db.lyricsDocsForTrack(track.id)).single;
    expect(candidates.single.docId, doc.id);
    expect(candidates.single.lineNo, 0);

    final second = await insertTestPlaylist(
      db,
      url: 'second',
      name: 'Second',
      lyricsMode: 'transcript',
    );
    final secondTrack = await insertTestTrack(db, playlistId: second.id);
    await db.replaceLyricsDoc(
      draft(
        ['endless talk'],
        trackId: secondTrack.id,
        kind: LyricsMode.transcript,
      ),
    );
    expect(await db.lyricsFtsCandidates('endless'), hasLength(2));
    expect(
      await db.lyricsFtsCandidates('endless', playlistId: second.id),
      hasLength(1),
    );
    expect(await db.lyricsFtsCandidates('"endles"*', limit: 1), hasLength(1));
  });

  test('FTS candidates skip docs of the other mode', () async {
    await db.replaceLyricsDoc(draft(['endless road']));
    await db.updatePlaylistFields(
      track.playlistId,
      const PlaylistsCompanion(lyricsMode: Value('transcript')),
    );
    expect(await db.lyricsFtsCandidates('endless'), isEmpty);
  });

  test('FTS candidates are capped per doc', () async {
    final other = await insertTestTrack(
      db,
      playlistId: track.playlistId,
      index: 2,
      videoId: 'video-2',
    );
    await db.replaceLyricsDoc(
      draft([for (var i = 0; i < 40; i++) 'the summer rain']),
    );
    await db.replaceLyricsDoc(
      draft(['walking in the summer rain with you'], trackId: other.id),
    );
    final candidates = await db.lyricsFtsCandidates('rain', limit: 5);
    expect(candidates.map((c) => c.docId).toSet(), hasLength(2));
    final byDoc = <int, int>{};
    for (final c in candidates) {
      byDoc[c.docId] = (byDoc[c.docId] ?? 0) + 1;
    }
    expect(byDoc.values.every((n) => n <= 4), isTrue);
  });

  test('an automatic draft never replaces a pinned doc', () async {
    await db.replaceLyricsDoc(draft(['picked words'], pinned: true));
    await db.replaceLyricsDoc(draft(['automatic words']));
    final doc = (await db.lyricsDocsForTrack(track.id)).single;
    expect(doc.pinned, isTrue);
    expect((await db.lyricsLinesForDoc(doc.id)).map((l) => l.lineText), [
      'picked words',
    ]);
  });

  test('the vocabulary counts lines per term, folded', () async {
    await db.replaceLyricsDoc(draft(['Szívvel szívvel', 'road']));
    final vocab = await db.lyricsVocabulary();
    expect(vocab['szivvel'], 1);
    expect(vocab['road'], 2);
  });

  test('lyricsDocsForPlaylist and lines in a range', () async {
    final docId = await db.replaceLyricsDoc(draft(['a', 'b', 'c', 'd']));
    expect((await db.lyricsDocsForPlaylist(playlist.id)).map((d) => d.id), [
      docId,
    ]);
    expect((await db.lyricsLinesInRange(docId, 1, 2)).map((l) => l.lineText), [
      'b',
      'c',
    ]);
    expect(await db.lyricsDocsByIds([docId, 999]), hasLength(1));
  });

  test('pinned docs raise the playlist revision, others do not', () async {
    final before = await db.playlistRevision(playlist.id);
    await db.replaceLyricsDoc(draft(['auto']));
    expect(await db.playlistRevision(playlist.id), before);
    await db.replaceLyricsDoc(draft(['chosen'], pinned: true));
    final pinned = await db.playlistRevision(playlist.id);
    expect(pinned, greaterThan(before));
    await db.deleteLyricsDocs(track.id);
    expect(await db.playlistRevision(playlist.id), greaterThan(pinned));
  });

  test('changing the lyrics mode raises the playlist revision', () async {
    final before = await db.playlistRevision(playlist.id);
    await db.updatePlaylistFields(
      playlist.id,
      const PlaylistsCompanion(lyricsMode: Value(null)),
    );
    expect(await db.playlistRevision(playlist.id), greaterThan(before));
    expect((await db.getPlaylist(playlist.id)).lyricsMode, isNull);
  });

  test('upgrading from schema 15 adds lyrics tables and the mode', () async {
    final dir = await Directory.systemTemp.createTemp('lyrics-migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/v15.sqlite');
    var old = AppDatabase.forTesting(NativeDatabase(file));
    final oldPlaylist = await insertTestPlaylist(old);
    await insertTestTrack(old, playlistId: oldPlaylist.id);
    await downgradeToSchema15(old);
    await old.close();

    final migrated = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(migrated.close);
    final upgraded = await migrated.getPlaylist(oldPlaylist.id);
    expect(upgraded.lyricsMode, isNull);
    final migratedTrack = (await migrated.getAllTracks()).single;

    await migrated.updatePlaylistFields(
      upgraded.id,
      const PlaylistsCompanion(lyricsMode: Value('lyrics')),
    );
    final revision = await migrated.playlistRevision(upgraded.id);
    await migrated.updatePlaylistFields(
      upgraded.id,
      const PlaylistsCompanion(lyricsMode: Value('transcript')),
    );
    expect(await migrated.playlistRevision(upgraded.id), revision + 1);

    await migrated.replaceLyricsDoc(
      draft(
        ['upgraded words'],
        trackId: migratedTrack.id,
        kind: LyricsMode.transcript,
      ),
    );
    expect(await migrated.lyricsFtsCandidates('upgraded'), hasLength(1));
    expect((await migrated.lyricsVocabulary())['words'], 1);
  });
}

/// Turns a current database into what schema 15 left on a device: no
/// lyrics tables, no `playlists.lyrics_mode`, no subtitle columns and no
/// `playlists.shuffle_chapters`.
Future<void> downgradeToSchema15(AppDatabase db) async {
  for (final name in [
    'trg_lyrics_fts_insert',
    'trg_lyrics_fts_delete',
    'trg_lyrics_fts_update',
    'trg_rev_lyrics_insert',
    'trg_rev_lyrics_update',
    'trg_rev_lyrics_delete',
    // Names lyrics_mode; schema 15 made it without that column.
    'trg_rev_playlists_update',
  ]) {
    await db.customStatement('DROP TRIGGER $name');
  }
  for (final table in [
    'lyrics_vocab',
    'lyrics_fts',
    'lyrics_lines',
    'lyrics_docs',
  ]) {
    await db.customStatement('DROP TABLE $table');
  }
  for (final column in [
    'lyrics_mode',
    'download_subtitles',
    'subtitle_languages',
    'shuffle_chapters',
  ]) {
    await db.customStatement('ALTER TABLE playlists DROP COLUMN $column');
  }
  await db.customStatement('PRAGMA user_version = 15');
}
