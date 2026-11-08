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
          synced: '[00:10.00] First\n[04:09.20] Last',
        ),
      );
      // 249.2 s into a 249 s file: inside the stated length, but too late.
      expect(syncedTimingFor(late, localSeconds: 249).fits, isFalse);
      expect(syncedTimingFor(late, localSeconds: 250).fits, isTrue);
    });

    test('a last word sung in the file\'s final seconds still fits', () {
      // The upload is 2 s shorter (fade-out trimmed); "Hey!" at 3:17.5
      // still starts inside it.
      final hey = record(
        lrclibRecord(
          duration: 200,
          synced: '[00:10.00] First\n[03:17.50] Hey!',
        ),
      );
      expect(syncedTimingFor(hey, localSeconds: 198).fits, isTrue);
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

  group('LyricsMatcher untimed records', () {
    late FakeLrclib lrclib;
    setUp(() => lrclib = FakeLrclib());

    /// The right song, 10 s shorter than the 310 s file (a video intro).
    Map<String, Object?> battery() => lrclibRecord(
      id: 1,
      track: 'Battery',
      artist: 'Metallica',
      duration: 300,
      synced: '[00:20.00] Lashing out the action\n[04:50.00] Battery',
    );

    test('another reading of the title does not replace them', () async {
      lrclib.exact['Metallica|Battery'] = battery();
      // The swapped reading finds another "song" whose length fits.
      lrclib.searches['track_name=Metallica&artist_name=Battery'] = [
        lrclibRecord(
          id: 2,
          track: 'Metallica',
          artist: 'Battery',
          duration: 310,
          synced: '[00:20.00] Other words\n[05:00.00] Other end',
        ),
      ];
      final match = await lrclib.matcher().match(
        parseSongTitle('Metallica - Battery'),
        durationSeconds: 310,
      );
      expect(match.record!.id, 1);
      expect(match.synced, isFalse);
    });

    test('a three-part title does not swap in another song', () async {
      lrclib.searches['track_name=Battery&artist_name=Metallica'] = [battery()];
      lrclib.searches['track_name=Master of Puppets&artist_name=Metallica'] = [
        lrclibRecord(
          id: 3,
          track: 'Master of Puppets',
          artist: 'Metallica',
          duration: 310,
          synced: '[00:20.00] End of passion\n[05:00.00] Master',
        ),
      ];
      final query = parseSongTitle('Metallica - Master of Puppets - Battery');
      final match = await lrclib.matcher().match(query, durationSeconds: 310);
      expect(match.found, isTrue);
      expect(match.record!.id, isNot(3));
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

    test(
      'a pick keeps its times when they do not fit, to be shifted',
      () async {
        final (_, track) = await diggy();
        // 241.8 s against the 249 s file: "Timing off" in the picker.
        answerAll([yogscast(id: 22471449, duration: 241.8)]);
        await service.applyPick(
          track.id,
          null,
          const LyricsPick(source: LyricsSource.lrclib, sourceRef: '22471449'),
        );
        var doc = (await db.lyricsDocFor(track.id, null))!;
        expect(doc.synced, isTrue);
        expect(doc.pinned, isTrue);
        expect((await db.lyricsLinesForDoc(doc.id)).first.startMs, 31960);

        // "Timing off?" can now move them to the longer intro.
        await service.setTimingShift(track.id, null, 7000);
        doc = (await db.lyricsDocFor(track.id, null))!;
        expect(doc.shiftMs, 7000);
        expect((await db.lyricsLinesForDoc(doc.id)).first.startMs, 38960);

        // A restore of the pin gives the same lines.
        await db.replaceLyricsDoc(
          draftFromDoc(doc, const []).copyWith(lines: const []),
        );
        await service.fetchTrack(track, force: true);
        doc = (await db.lyricsDocFor(track.id, null))!;
        expect(doc.synced, isTrue);
        expect((await db.lyricsLinesForDoc(doc.id)).map((l) => l.startMs), [
          38960,
          232110,
        ]);
      },
    );

    test('a timing-off pick of a mislabelled record keeps no times', () async {
      final (_, track) = await diggy();
      answerAll([windRose()]);
      await service.applyPick(
        track.id,
        null,
        const LyricsPick(
          source: LyricsSource.lrclib,
          sourceRef: '32583562',
          timingOff: true,
        ),
      );
      final doc = (await db.lyricsDocFor(track.id, null))!;
      expect(doc.synced, isFalse);
      expect(
        (await db.lyricsLinesForDoc(doc.id)).every((l) => l.startMs == null),
        isTrue,
      );
    });

    test('the repair keeps the words when no record fits any more', () async {
      final (playlist, track) = await diggy();
      await db.replaceLyricsDoc(storedWindRose(track.id));
      // Only the mislabelled record: nothing is accepted on its length.
      answerAll([windRose()]);
      final result = await service.backfillPlaylist(playlist.id);
      expect(result.due, 1);
      final doc = (await db.lyricsDocFor(track.id, null))!;
      expect(doc.status, LyricsStatus.found);
      expect(doc.sourceRef, '32583562');
      expect(doc.synced, isFalse);
      final lines = await db.lyricsLinesForDoc(doc.id);
      expect(lines.map((l) => l.lineText), [
        'I am a dwarf',
        'Diggy diggy hole',
      ]);
      expect(lines.every((l) => l.startMs == null), isTrue);
      // Not looked up again.
      expect((await service.backfillPlaylist(playlist.id)).due, 0);
    });

    test('the repair leaves a last line in the final second alone', () async {
      final (playlist, track) = await diggy();
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: track.id,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          source: LyricsSource.lrclib,
          sourceRef: '6495352',
          synced: true,
          checkedAt: now,
          attempts: 1,
          lines: const [
            LyricsLineDraft('first', startMs: 31960),
            // 249.4 s: the stored 249 s length is rounded.
            LyricsLineDraft('Hey!', startMs: 249400),
          ],
        ),
      );
      answerAll([yogscast()]);
      expect((await service.backfillPlaylist(playlist.id)).due, 0);
    });

    test('a chapter shift is cut at its end and gives back lines', () async {
      final (_, track) = await diggy(
        chaptersJson:
            const ChapterData(
              downloaded: [
                MediaChapter(id: 'c', title: 'Diggy', startMs: 0, endMs: 60000),
              ],
            ).encode(),
      );
      answerAll([
        lrclibRecord(
          id: 7,
          track: 'Diggy Diggy Hole',
          artist: 'The Yogscast',
          duration: 247,
          synced: '[00:10.00] one\n[00:59.00] two\n[01:02.00] three',
        ),
      ]);
      await service.applyPick(
        track.id,
        'c',
        const LyricsPick(source: LyricsSource.lrclib, sourceRef: '7'),
      );
      Future<List<int?>> starts() async => [
        for (final line in await db.lyricsLinesForDoc(
          (await db.lyricsDocFor(track.id, 'c'))!.id,
        ))
          line.startMs,
      ];
      expect(await starts(), [10000, 59000]);

      // Later: "two" moves past the chapter's end and is cut.
      await service.setTimingShift(track.id, 'c', 2000);
      expect(await starts(), [12000]);
      // Earlier: "two" comes back, and "three" now fits.
      await service.setTimingShift(track.id, 'c', -3000);
      expect(await starts(), [7000, 56000, 59000]);

      // A restore of the same pin gives the same lines.
      final doc = (await db.lyricsDocFor(track.id, 'c'))!;
      await db.replaceLyricsDoc(
        draftFromDoc(doc, const []).copyWith(lines: const []),
      );
      await service.fetchTrack(track, force: true);
      expect(await starts(), [7000, 56000, 59000]);
    });

    test(
      'a pinned caption doc is restored from its video, per chapter',
      () async {
        final (_, track) = await diggy(
          chaptersJson:
              const ChapterData(
                downloaded: [
                  MediaChapter(
                    id: 'c',
                    title: 'Diggy',
                    startMs: 10000,
                    endMs: 20000,
                  ),
                ],
              ).encode(),
        );
        final infoUrls = <String>[];
        final captions = LyricsService(
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
            http: FakeHttpClient(
              (_) => FakeHttpResponse.json({
                'events': [
                  for (final (ms, text) in [
                    (5000, 'before'),
                    (12000, 'in one'),
                    (18000, 'in two'),
                    (25000, 'after'),
                  ])
                    {
                      'tStartMs': ms,
                      'dDurationMs': 1000,
                      'segs': [
                        {'utf8': text},
                      ],
                    },
                ],
              }),
            ),
          ),
          captionInfo: (url) async {
            infoUrls.add(url);
            return {
              'subtitles': {
                'en': [
                  {'ext': 'json3', 'url': 'https://caps/en'},
                ],
              },
            };
          },
          clock: () => now,
          sleep: (_) async {},
        );
        addTearDown(captions.dispose);

        // An automatic caption doc stored with only its caption key.
        await db.replaceLyricsDoc(
          LyricsDocDraft(
            trackId: track.id,
            chapterId: 'c',
            offsetMs: 10000,
            kind: LyricsMode.lyrics,
            status: LyricsStatus.found,
            source: LyricsSource.ytSubs,
            sourceRef: 'en',
            synced: true,
            lang: 'en',
            checkedAt: now,
            lines: const [
              LyricsLineDraft('in one', startMs: 2000),
              LyricsLineDraft('in two', startMs: 8000),
            ],
          ),
        );
        await captions.setTimingShift(track.id, 'c', 500);
        var doc = (await db.lyricsDocFor(track.id, 'c'))!;
        expect(doc.pinned, isTrue);
        expect(doc.sourceRef, 'ytWz0qVvBZ0:en');

        Future<void> restore(String ref) async {
          await db.replaceLyricsDoc(
            draftFromDoc(
              doc,
              const [],
            ).copyWith(sourceRef: ref, lines: const []),
          );
          await captions.fetchTrack(track, force: true);
          doc = (await db.lyricsDocFor(track.id, 'c'))!;
          expect(doc.synced, isTrue);
          expect(doc.shiftMs, 500);
          final lines = await db.lyricsLinesForDoc(doc.id);
          expect(lines.map((l) => l.lineText), ['in one', 'in two']);
          expect(lines.map((l) => l.startMs), [2500, 8500]);
        }

        await restore('ytWz0qVvBZ0:en');
        // A pin written before refs named the video still restores.
        await restore('en');
        expect(infoUrls, everyElement(contains('v=ytWz0qVvBZ0')));
        expect(infoUrls, hasLength(2));
      },
    );

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
