import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/lyrics/captions.dart';
import 'package:woolytube/services/lyrics/lrclib_client.dart';
import 'package:woolytube/services/lyrics/lyrics_files.dart';
import 'package:woolytube/services/lyrics/lyrics_matcher.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_search.dart';
import 'package:woolytube/services/lyrics/lyrics_service.dart';
import 'package:woolytube/services/lyrics/title_parser.dart';
import 'package:woolytube/services/lyrics/ytmusic_lyrics_client.dart';

import '../../helpers/fake_http_client.dart';
import '../../helpers/lyrics_fakes.dart';
import '../../helpers/test_database.dart';

/// Wind Rose's longer recording filed under a 248 s length: its lines run
/// to 5:10 (LRCLIB 32583562, the user's bug).
Map<String, Object?> windRose() => lrclibRecord(
  id: 32583562,
  track: 'Diggy Diggy Hole',
  artist: 'Wind Rose',
  duration: 248,
  plain: 'I am a dwarf and I\'m digging a hole',
  synced:
      '[01:07.26] I am a dwarf and I\'m digging a hole\n'
      '[05:10.15] Diggy diggy hole',
);

/// The Yogscast's own recording, timed to it.
Map<String, Object?> yogscast({int id = 6495352, double duration = 247}) =>
    lrclibRecord(
      id: id,
      track: 'Diggy Diggy Hole',
      artist: 'The Yogscast',
      duration: duration,
      plain: 'I am a dwarf and I\'m digging a hole',
      synced:
          '[00:31.96] I am a dwarf and I\'m digging a hole\n'
          '[03:45.11] Diggy diggy hole',
    );

LrclibRecord record(Map<String, Object?> json) => LrclibRecord.fromJson(json)!;

void main() {
  group('syncedTimingFor', () {
    test('a record whose lines run past its stated length never fits', () {
      final timing = syncedTimingFor(record(windRose()), localSeconds: 249);
      expect(timing.fits, isFalse);
      expect(timing.mislabelled, isTrue);
      expect(
        syncedTimingFor(record(yogscast()), localSeconds: 249).fits,
        isTrue,
      );
    });

    test('the last line must start before the file ends', () {
      final late = record(
        lrclibRecord(
          duration: 250,
          synced: '[00:10.00] First\n[04:08.50] Last',
        ),
      );
      // 248.5 s into a 249 s file: inside the stated length, but too late.
      expect(syncedTimingFor(late, localSeconds: 249).fits, isFalse);
      expect(syncedTimingFor(late, localSeconds: 250).fits, isTrue);
    });

    test('nightcore checks the scaled last line', () {
      final original = record(
        lrclibRecord(
          duration: 236,
          synced: '[00:10.00] First\n[03:50.00] Last',
        ),
      );
      final timing = syncedTimingFor(
        original,
        localSeconds: 181,
        nightcore: true,
      );
      expect(timing.fits, isTrue);
      expect(timing.timeScale, closeTo(181 / 236, 1e-9));
      final mislabelled = record(
        lrclibRecord(
          duration: 236,
          synced: '[00:10.00] First\n[04:30.00] Last',
        ),
      );
      expect(
        syncedTimingFor(mislabelled, localSeconds: 181, nightcore: true).fits,
        isFalse,
      );
    });

    test('a chapter keeps a longer record when its first line is inside', () {
      // A 90 s TV size of a 4 minute song: lines are cut at the end later.
      expect(
        syncedTimingFor(
          record(yogscast()),
          localSeconds: 90,
          chapter: true,
        ).fits,
        isTrue,
      );
      // Its first line comes after the chapter ends.
      expect(
        syncedTimingFor(
          record(yogscast()),
          localSeconds: 30,
          chapter: true,
        ).fits,
        isFalse,
      );
      expect(
        syncedTimingFor(record(windRose()), localSeconds: 249, chapter: true),
        isA<SyncedTiming>().having((t) => t.fits, 'fits', isFalse),
      );
    });
  });

  group('LyricsMatcher', () {
    late FakeLrclib lrclib;
    setUp(() => lrclib = FakeLrclib());

    test(
      'prefers the record whose real line times fit (Diggy Diggy Hole)',
      () async {
        // LRCLIB answers every search with all three records.
        lrclib.http.handler =
            (request) => FakeHttpResponse.json([
              windRose(),
              yogscast(),
              yogscast(id: 22471449, duration: 241.8),
            ]);
        final match = await lrclib.matcher().match(
          parseSongTitle('♪ Diggy Diggy Hole'),
          durationSeconds: 249,
        );
        expect(match.found, isTrue);
        expect(match.record!.id, 6495352);
        expect(match.synced, isTrue);
        expect(match.lines.last.startMs, 225110);
      },
    );

    test(
      'a mislabelled record has no known length without an artist',
      () async {
        lrclib.http.handler = (request) => FakeHttpResponse.json([windRose()]);
        final match = await lrclib.matcher().match(
          parseSongTitle('♪ Diggy Diggy Hole'),
          durationSeconds: 249,
        );
        expect(match.found, isFalse);
      },
    );

    test(
      'with the artist known a mislabelled record is stored plain',
      () async {
        lrclib.exact['Wind Rose|Diggy Diggy Hole'] = windRose();
        final match = await lrclib.matcher().match(
          parseSongTitle('Wind Rose - Diggy Diggy Hole'),
          durationSeconds: 249,
        );
        expect(match.found, isTrue);
        expect(match.record!.id, 32583562);
        expect(match.synced, isFalse);
        expect(match.lines.every((l) => l.startMs == null), isTrue);
      },
    );

    test('a later step can find times that fit for the same song', () async {
      lrclib.exact['Wind Rose|Diggy Diggy Hole'] = windRose();
      lrclib.searches['track_name=Diggy Diggy Hole&artist_name=Wind Rose'] = [
        lrclibRecord(
          id: 5,
          track: 'Diggy Diggy Hole',
          artist: 'Wind Rose',
          duration: 249,
          synced: '[01:07.26] I am a dwarf\n[04:00.00] Diggy diggy hole',
        ),
      ];
      final match = await lrclib.matcher().match(
        parseSongTitle('Wind Rose - Diggy Diggy Hole'),
        durationSeconds: 249,
      );
      expect(match.record!.id, 5);
      expect(match.step, 'search');
      expect(match.synced, isTrue);
    });
  });

  group('picker candidates', () {
    test('show the fit and sort the same song by it', () {
      final candidates = sortCandidatesByFit([
        for (final json in [
          windRose(),
          lrclibRecord(id: 3, track: 'Other Song', artist: 'Someone'),
          yogscast(id: 22471449, duration: 241.8),
          yogscast(),
        ])
          lyricsCandidateFor(record(json), localSeconds: 249),
      ]);
      // Only records of the same artist and title trade places.
      expect(candidates.map((c) => c.id), [32583562, 3, 6495352, 22471449]);
      final fits = candidates[2];
      expect(fits.timingFits, isTrue);
      expect(fits.localSeconds, 249);
      expect(fits.lastLineSeconds, closeTo(225.11, 1e-9));
      expect(candidates.first.timingFits, isFalse);
      expect(candidates.last.timingFits, isFalse);
      expect(lyricsCandidateFor(record(windRose())).timingFits, isNull);
    });
  });

  group('LyricsService', () {
    late AppDatabase db;
    late Directory dir;
    late FakeLrclib lrclib;
    late LyricsService service;
    final now = DateTime(2026, 11, 8, 12);

    setUp(() async {
      db = openTestDatabase();
      dir = await Directory.systemTemp.createTemp('lyrics_timing_test');
      lrclib = FakeLrclib();
      service = LyricsService(
        db,
        LogService(),
        lrclib: LrclibClient(
          http: lrclib.http,
          sleep: (_) async {},
          retryDelays: const [],
        ),
        ytMusic: YtMusicLyricsClient(
          http: FakeHttpClient((_) => FakeHttpResponse.json(nextAnswer())),
        ),
        captions: CaptionsClient(
          http: FakeHttpClient((_) => const FakeHttpResponse(404, '')),
        ),
        captionInfo: (_) async => const {},
        clock: () => now,
        sleep: (_) async {},
      );
    });

    tearDown(() async {
      service.dispose();
      await db.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<(Playlist, Track)> diggy({String? chaptersJson}) async {
      final playlist = await insertTestPlaylist(
        db,
        outputPath: dir.path,
        lyricsMode: 'lyrics',
      );
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'ytWz0qVvBZ0',
        title: '♪ Diggy Diggy Hole',
        filePath: '${dir.path}/1.m4a',
        durationSeconds: 249,
        status: 'complete',
        chaptersJson: chaptersJson,
      );
      return (playlist, track);
    }

    /// What the phone stored before: Wind Rose's lines up to 5:10.
    LyricsDocDraft storedWindRose(int trackId, {bool pinned = false}) =>
        LyricsDocDraft(
          trackId: trackId,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          source: LyricsSource.lrclib,
          sourceRef: '32583562',
          matchedArtist: 'Wind Rose',
          matchedTitle: 'Diggy Diggy Hole',
          synced: true,
          pinned: pinned,
          checkedAt: now,
          attempts: 1,
          lines: const [
            LyricsLineDraft('I am a dwarf', startMs: 67260),
            LyricsLineDraft('Diggy diggy hole', startMs: 298200),
          ],
        );

    void answerAll(List<Map<String, Object?>> records) {
      lrclib.http.handler = (request) {
        final path = request.uri.path;
        if (path.startsWith('/api/get/')) {
          final id = int.parse(path.split('/').last);
          final hit = records.where((r) => r['id'] == id).firstOrNull;
          return hit == null
              ? FakeHttpResponse.json({'statusCode': 404}, statusCode: 404)
              : FakeHttpResponse.json(hit);
        }
        return FakeHttpResponse.json(records);
      };
    }

    test(
      'backfill fetches again automatic lyrics timed past the file',
      () async {
        final (playlist, track) = await diggy();
        await db.replaceLyricsDoc(storedWindRose(track.id));
        answerAll([windRose(), yogscast()]);

        final result = await service.backfillPlaylist(playlist.id);
        expect(result.due, 1);
        final doc = (await db.lyricsDocFor(track.id, null))!;
        expect(doc.sourceRef, '6495352');
        expect(doc.synced, isTrue);
        final lines = await db.lyricsLinesForDoc(doc.id);
        expect(lines.last.startMs, 225110);

        // Fixed: the next run leaves it alone.
        final again = await service.backfillPlaylist(playlist.id);
        expect(again.due, 0);
      },
    );

    test('a failed lookup keeps the old lines; pins are left alone', () async {
      final (playlist, track) = await diggy();
      await db.replaceLyricsDoc(storedWindRose(track.id));
      lrclib.http.handler = (_) => throw const SocketException('offline');
      final result = await service.backfillPlaylist(playlist.id);
      expect(result.failed, 1);
      final doc = (await db.lyricsDocFor(track.id, null))!;
      expect(doc.status, LyricsStatus.found);
      expect(doc.sourceRef, '32583562');
      expect(await db.lyricsLinesForDoc(doc.id), hasLength(2));

      await db.replaceLyricsDoc(storedWindRose(track.id, pinned: true));
      answerAll([yogscast()]);
      expect((await service.backfillPlaylist(playlist.id)).due, 0);
    });

    test('a pick that does not fit is stored plain', () async {
      final (_, track) = await diggy();
      answerAll([windRose(), yogscast()]);
      await service.applyPick(
        track.id,
        null,
        const LyricsPick(source: LyricsSource.lrclib, sourceRef: '32583562'),
      );
      final doc = (await db.lyricsDocFor(track.id, null))!;
      expect(doc.synced, isFalse);
      expect(
        (await db.lyricsLinesForDoc(doc.id)).every((l) => l.startMs == null),
        isTrue,
      );
    });

    test(
      'a timing shift moves every line, is saved and can be undone',
      () async {
        final (playlist, track) = await diggy();
        answerAll([yogscast()]);
        await service.fetchTrack(track);
        expect((await db.lyricsDocFor(track.id, null))!.pinned, isFalse);

        await service.setTimingShift(track.id, null, 1500);
        var doc = (await db.lyricsDocFor(track.id, null))!;
        expect(doc.pinned, isTrue);
        expect(doc.shiftMs, 1500);
        expect((await db.lyricsLinesForDoc(doc.id)).map((l) => l.startMs), [
          33460,
          226610,
        ]);
        final file =
            (await readLyricsFile(dir.path, 'ytWz0qVvBZ0', track.id)).single;
        expect(file.shiftMs, 1500);
        expect(file.lines.first.startMs, 33460);

        // Search plays from the moved time.
        final hits = await LyricsSearch(db).search('dwarf digging');
        expect(hits.first.positionMs, 33460);

        // A shift is relative to the found times, not to the last shift.
        await service.setTimingShift(track.id, null, -40000);
        doc = (await db.lyricsDocFor(track.id, null))!;
        final moved = await db.lyricsLinesForDoc(doc.id);
        expect(moved.first.startMs, 31960 - 40000);
        // A line moved before the start plays from the start.
        expect(
          (await LyricsSearch(db).search('dwarf digging')).first.positionMs,
          0,
        );

        await service.setTimingShift(track.id, null, 0);
        doc = (await db.lyricsDocFor(track.id, null))!;
        expect(doc.shiftMs, 0);
        expect((await db.lyricsLinesForDoc(doc.id)).first.startMs, 31960);
        expect(doc.pinned, isTrue);
        expect(playlist.id, isPositive);
      },
    );

    test('a pin restored from its record adds the shift again', () async {
      final (playlist, track) = await diggy();
      answerAll([yogscast()]);
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: track.id,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          source: LyricsSource.lrclib,
          sourceRef: '6495352',
          pinned: true,
          shiftMs: -2000,
          checkedAt: now,
        ),
      );
      await service.backfillPlaylist(playlist.id);
      final doc = (await db.lyricsDocFor(track.id, null))!;
      expect(doc.synced, isTrue);
      expect(doc.shiftMs, -2000);
      expect((await db.lyricsLinesForDoc(doc.id)).first.startMs, 29960);
    });

    test('"Use without timing" is kept, also through a restore', () async {
      final (playlist, track) = await diggy();
      answerAll([yogscast()]);
      await service.fetchTrack(track);
      await service.setTimingShift(track.id, null, 700);
      await service.useWithoutTiming(track.id, null);
      var doc = (await db.lyricsDocFor(track.id, null))!;
      expect(doc.synced, isFalse);
      expect(doc.pinned, isTrue);
      expect(doc.timingOff, isTrue);
      expect(doc.shiftMs, 0);
      expect(
        (await db.lyricsLinesForDoc(doc.id)).every((l) => l.startMs == null),
        isTrue,
      );
      await expectLater(
        service.setTimingShift(track.id, null, 100),
        throwsStateError,
      );

      // The text is gone (a restore from the sidecar): fetched plain again.
      await db.replaceLyricsDoc(
        draftFromDoc(doc, const []).copyWith(lines: const []),
      );
      await service.fetchTrack(track, force: true);
      doc = (await db.lyricsDocFor(track.id, null))!;
      expect(doc.synced, isFalse);
      expect(doc.timingOff, isTrue);
      expect(playlist.id, isPositive);
      expect(await db.lyricsLinesForDoc(doc.id), hasLength(1));
    });

    test('a chapter pick is shifted, then cut at the chapter end', () async {
      final (_, track) = await diggy(
        chaptersJson:
            const ChapterData(
              downloaded: [
                MediaChapter(id: 'c', title: 'Diggy', startMs: 0, endMs: 60000),
              ],
            ).encode(),
      );
      answerAll([yogscast()]);
      await service.applyPick(
        track.id,
        'c',
        const LyricsPick(
          source: LyricsSource.lrclib,
          sourceRef: '6495352',
          shiftMs: 1000,
        ),
      );
      final doc = (await db.lyricsDocFor(track.id, 'c'))!;
      expect(doc.synced, isTrue);
      expect((await db.lyricsLinesForDoc(doc.id)).map((l) => l.startMs), [
        32960,
      ]);
    });

    test('candidatesFor compares with the track', () async {
      final (_, track) = await diggy();
      lrclib.searches['q=diggy'] = [windRose(), yogscast()];
      final candidates = await service.candidatesFor(
        'diggy',
        trackId: track.id,
      );
      expect(candidates.map((c) => c.id), [32583562, 6495352]);
      expect(candidates.map((c) => c.timingFits), [false, true]);
      expect(candidates.first.localSeconds, 249);
    });
  });

  test('lyrics files and sidecar pins keep the shift', () {
    final doc = LyricsDocDraft(
      trackId: 1,
      kind: LyricsMode.lyrics,
      status: LyricsStatus.found,
      synced: true,
      shiftMs: -1200,
      checkedAt: DateTime.utc(2026, 11, 8),
      lines: const [LyricsLineDraft('a', startMs: 800)],
    );
    final back = lyricsDocsFromJson(lyricsFileJson('v', [doc]), 1).single;
    expect(back.shiftMs, -1200);
    expect(back.timingOff, isFalse);
    expect(back.lines.single.startMs, 800);
    final off =
        lyricsDocsFromJson(
          lyricsFileJson('v', [doc.copyWith(timingOff: true)]),
          1,
        ).single;
    expect(off.timingOff, isTrue);
  });

  test('upgrading from schema 16 adds the timing columns', () async {
    final dir = await Directory.systemTemp.createTemp('lyrics-v16');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/v16.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    final playlist = await insertTestPlaylist(old, lyricsMode: 'lyrics');
    final track = await insertTestTrack(old, playlistId: playlist.id);
    await old.replaceLyricsDoc(
      LyricsDocDraft(
        trackId: track.id,
        kind: LyricsMode.lyrics,
        status: LyricsStatus.found,
        synced: true,
        checkedAt: DateTime(2026, 11, 8),
        lines: const [LyricsLineDraft('kept words', startMs: 1000)],
      ),
    );
    await old.customStatement('ALTER TABLE lyrics_docs DROP COLUMN shift_ms');
    await old.customStatement('ALTER TABLE lyrics_docs DROP COLUMN timing_off');
    await old.customStatement('PRAGMA user_version = 16');
    await old.close();

    final migrated = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(migrated.close);
    final doc = (await migrated.lyricsDocFor(track.id, null))!;
    expect(doc.shiftMs, 0);
    expect(doc.timingOff, isFalse);
    expect(await migrated.lyricsFtsCandidates('kept'), hasLength(1));
    await migrated.replaceLyricsDoc(
      draftFromDoc(
        doc,
        await migrated.lyricsLinesForDoc(doc.id),
      ).copyWith(shiftMs: 500),
    );
    expect((await migrated.lyricsDocFor(track.id, null))!.shiftMs, 500);
  });
}
