import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/lyrics/lyrics_files.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lyrics_files_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  final checkedAt = DateTime.utc(2026, 11, 8, 12);

  test('writes every doc with its lines and reads them back', () async {
    final docs = [
      LyricsDocDraft(
        trackId: 1,
        kind: LyricsMode.lyrics,
        status: LyricsStatus.found,
        source: LyricsSource.lrclib,
        sourceRef: '3651383',
        matchedArtist: 'Europe',
        matchedTitle: 'The Final Countdown',
        timeScale: 0.8,
        synced: true,
        pinned: true,
        checkedAt: checkedAt,
        attempts: 2,
        lines: const [
          LyricsLineDraft("We're leaving together", startMs: 87770),
          LyricsLineDraft('But still it\'s farewell', startMs: 91170),
        ],
      ),
      LyricsDocDraft(
        trackId: 1,
        chapterId: 'recognition-r1-0-60000',
        offsetMs: 60000,
        kind: LyricsMode.lyrics,
        status: LyricsStatus.none,
        checkedAt: checkedAt,
      ),
      LyricsDocDraft(
        trackId: 1,
        chapterId: 'c2',
        kind: LyricsMode.transcript,
        status: LyricsStatus.found,
        source: LyricsSource.ytAuto,
        sourceRef: 'en-orig',
        lang: 'en',
        checkedAt: checkedAt,
        lines: const [LyricsLineDraft('plain line')],
      ),
    ];
    await writeLyricsFile(dir.path, 'abc:1', docs);

    final path = LibraryLayout.lyricsJsonPath(dir.path, 'abc:1');
    expect(path, endsWith('.woolytube_info/abc_1.lyrics.json'));
    expect(File(path).existsSync(), isTrue);
    expect(
      File('${LibraryLayout.infoDir(dir.path)}/.nomedia').existsSync(),
      isTrue,
    );
    final json = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(json['videoId'], 'abc:1');

    final read = await readLyricsFile(dir.path, 'abc:1', 7);
    expect(read, hasLength(3));
    final first = read.first;
    expect(first.trackId, 7);
    expect(first.chapterId, isNull);
    expect(first.kind, LyricsMode.lyrics);
    expect(first.sourceRef, '3651383');
    expect(first.timeScale, 0.8);
    expect(first.synced, isTrue);
    expect(first.pinned, isTrue);
    expect(first.attempts, 2);
    expect(first.checkedAt.toUtc(), checkedAt);
    expect(first.lines, docs.first.lines);
    expect(read[1].offsetMs, 60000);
    expect(read[1].status, LyricsStatus.none);
    expect(read[1].lines, isEmpty);
    expect(read[2].kind, LyricsMode.transcript);
    expect(read[2].lines, const [LyricsLineDraft('plain line')]);
  });

  test('no docs deletes the file; broken files read as nothing', () async {
    await writeLyricsFile(dir.path, 'v', [
      LyricsDocDraft(
        trackId: 1,
        kind: LyricsMode.lyrics,
        status: LyricsStatus.none,
        checkedAt: checkedAt,
      ),
    ]);
    await writeLyricsFile(dir.path, 'v', const []);
    expect(
      File(LibraryLayout.lyricsJsonPath(dir.path, 'v')).existsSync(),
      isFalse,
    );
    expect(await readLyricsFile(dir.path, 'v', 1), isEmpty);

    File(LibraryLayout.lyricsJsonPath(dir.path, 'w'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    expect(await readLyricsFile(dir.path, 'w', 1), isEmpty);
    expect(
      lyricsDocsFromJson({
        'docs': [
          {'kind': 'unknown', 'status': 'found', 'checkedAt': '2026-01-01'},
          {'kind': 'lyrics', 'status': 'found'},
        ],
      }, 1),
      isEmpty,
    );
  });
}
