import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/lyrics/captions.dart';
import 'package:woolytube/services/lyrics/lrclib_client.dart';
import 'package:woolytube/services/lyrics/lyrics_files.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_service.dart';
import 'package:woolytube/services/lyrics/ytmusic_lyrics_client.dart';

import '../../helpers/fake_http_client.dart';
import '../../helpers/lyrics_fakes.dart';
import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Directory dir;
  late FakeLrclib lrclib;
  late FakeHttpClient ytMusicHttp;
  late FakeHttpClient captionsHttp;
  late Map<String, dynamic>? captionInfo;
  late List<String> captionInfoUrls;
  late DateTime now;
  late LyricsService service;

  LyricsService buildService() => LyricsService(
    db,
    LogService(),
    lrclib: LrclibClient(
      http: lrclib.http,
      sleep: (_) async {},
      retryDelays: const [],
    ),
    ytMusic: YtMusicLyricsClient(http: ytMusicHttp),
    captions: CaptionsClient(http: captionsHttp),
    captionInfo: (url) async {
      captionInfoUrls.add(url);
      final info = captionInfo;
      if (info == null) throw Exception('extraction failed');
      return info;
    },
    clock: () => now,
    sleep: (_) async {},
  );

  setUp(() async {
    db = openTestDatabase();
    dir = await Directory.systemTemp.createTemp('lyrics_service_test');
    lrclib = FakeLrclib();
    ytMusicHttp = FakeHttpClient((_) => FakeHttpResponse.json(nextAnswer()));
    captionsHttp = FakeHttpClient((_) => const FakeHttpResponse(404, ''));
    captionInfo = const {};
    captionInfoUrls = [];
    now = DateTime(2026, 11, 8, 12);
    service = buildService();
  });

  tearDown(() async {
    service.dispose();
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<Playlist> playlist({String? mode = 'lyrics', bool? playChapters}) =>
      insertTestPlaylist(
        db,
        outputPath: dir.path,
        lyricsMode: mode,
        playChapters: playChapters,
      );

  Future<Track> track(
    Playlist playlist, {
    String title = 'Europe - The Final Countdown',
    String videoId = 'vid1',
    int index = 1,
    int duration = 296,
    String? chaptersJson,
  }) => insertTestTrack(
    db,
    playlistId: playlist.id,
    index: index,
    videoId: videoId,
    title: title,
    filePath: '${dir.path}/$index.m4a',
    durationSeconds: duration,
    status: 'complete',
    chaptersJson: chaptersJson,
  );

  String chapters(List<(String, String, int, int)> list) =>
      ChapterData(
        downloaded: [
          for (final (id, title, start, end) in list)
            MediaChapter(id: id, title: title, startMs: start, endMs: end),
        ],
      ).encode();

  group('fetchTrack', () {
    test('stores LRCLIB lyrics for the whole file and its file', () async {
      lrclib.exact['Europe|The Final Countdown'] = lrclibRecord(id: 42);
      final p = await playlist();
      final t = await track(p);
      final changes = <LyricsChange>[];
      final sub = service.changes.listen(changes.add);

      await service.fetchTrack(t);
      await pumpEventQueue();

      final doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.status, LyricsStatus.found);
      expect(doc.source, LyricsSource.lrclib);
      expect(doc.sourceRef, '42');
      expect(doc.matchedArtist, 'Europe');
      expect(doc.synced, isTrue);
      expect(doc.pinned, isFalse);
      expect(doc.attempts, 1);
      final lines = await db.lyricsLinesForDoc(doc.id);
      expect(lines.first.lineText, "We're leaving together");
      expect(lines.first.startMs, 87770);
      expect(changes.single.trackId, t.id);
      // No yt-dlp run was needed.
      expect(captionInfoUrls, isEmpty);

      final file = await readLyricsFile(dir.path, 'vid1', t.id);
      expect(file.single.sourceRef, '42');
      expect(file.single.lines, hasLength(2));
      await sub.cancel();
    });

    test('does nothing when the playlist has lyrics off', () async {
      lrclib.exact['Europe|The Final Countdown'] = lrclibRecord();
      final p = await playlist(mode: null);
      final t = await track(p);
      await service.fetchTrack(t);
      expect(await db.lyricsDocsForTrack(t.id), isEmpty);
      expect(lrclib.http.requests, isEmpty);
    });

    test('found docs are not fetched again unless forced', () async {
      lrclib.exact['Europe|The Final Countdown'] = lrclibRecord(id: 1);
      final p = await playlist();
      final t = await track(p);
      await service.fetchTrack(t);
      final requests = lrclib.http.requests.length;
      await service.fetchTrack(t);
      expect(lrclib.http.requests.length, requests);

      lrclib.exact['Europe|The Final Countdown'] = lrclibRecord(id: 2);
      await service.fetchTrack(t, force: true);
      expect((await db.lyricsDocFor(t.id, null))!.sourceRef, '2');
    });

    test('falls back to YouTube Music, then the uploader captions', () async {
      final p = await playlist();
      final t = await track(p, title: 'Some Song Nobody Has');
      ytMusicHttp.handler = (request) {
        if (request.uri.path.endsWith('/next')) {
          return FakeHttpResponse.json(nextAnswer(browseId: 'MPLYt_x'));
        }
        return FakeHttpResponse.json(browseAnswer('Line one\r\nLine two'));
      };
      await service.fetchTrack(t);
      var doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.source, LyricsSource.ytmusic);
      expect(doc.sourceRef, 'MPLYt_x');
      expect(doc.synced, isFalse);
      expect((await db.lyricsLinesForDoc(doc.id)).map((l) => l.lineText), [
        'Line one',
        'Line two',
      ]);

      // Without YouTube Music lyrics: the manual English captions.
      ytMusicHttp.handler = (_) => FakeHttpResponse.json(nextAnswer());
      final json3 =
          await File(
            'test/fixtures/lyrics/manual_music.en.json3',
          ).readAsString();
      captionInfo = {
        'title': 'Some Song Nobody Has',
        'subtitles': {
          'en-nP7-2PuUl7o': [
            {'ext': 'json3', 'url': 'https://caps/en'},
          ],
        },
      };
      captionsHttp.handler = (_) => FakeHttpResponse(200, json3);
      await service.fetchTrack(t, force: true);
      doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.source, LyricsSource.ytSubs);
      expect(doc.sourceRef, 'vid1:en-nP7-2PuUl7o');
      expect(doc.lang, 'en');
      expect(doc.synced, isTrue);
      expect(captionInfoUrls.single, 'https://www.youtube.com/watch?v=vid1');
    });

    test('a nightcore title without an artist reads the description', () async {
      lrclib.searches['track_name=Takeover&artist_name=Zardonic'] = [
        lrclibRecord(
          id: 7,
          track: 'Takeover',
          artist: 'Zardonic',
          duration: 250,
          synced: '[00:10.00] Oh',
        ),
      ];
      captionInfo = {'description': 'Original Artist: Zardonic\nSubscribe!'};
      final p = await playlist();
      final t = await track(
        p,
        title: 'Nightcore - Takeover [HD]',
        duration: 206,
      );
      await service.fetchTrack(t);
      final doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.sourceRef, '7');
      expect(doc.timeScale, closeTo(206 / 250, 1e-9));
      final line = (await db.lyricsLinesForDoc(doc.id)).single;
      expect(line.startMs, (10000 * 206 / 250).round());
      expect(captionInfoUrls, hasLength(1));
    });

    test('the kept info file is read before running yt-dlp', () async {
      lrclib.exact['The Longest Johns|Oak & Ash & Thorn'] = lrclibRecord(
        track: 'Oak & Ash & Thorn',
        artist: 'The Longest Johns',
        duration: 249,
      );
      final p = await playlist();
      final t = await track(p, title: 'Oak & Ash & Thorn', duration: 249);
      File(LibraryLayout.infoJsonPath(dir.path, 'vid1'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({'uploader': 'The Longest Johns - Topic'}),
        );
      await service.fetchTrack(t);
      expect((await db.lyricsDocFor(t.id, null))!.status, LyricsStatus.found);
      expect(captionInfoUrls, isEmpty);
    });

    test('a file that plays as chapters gets one doc per chapter', () async {
      lrclib.searches['track_name=Levels&artist_name=Avicii'] = [
        lrclibRecord(
          id: 1,
          track: 'Levels',
          artist: 'Avicii',
          duration: 200,
          synced: '[00:05.00] Oh, sometimes',
        ),
      ];
      final p = await playlist();
      final t = await track(
        p,
        title: 'Best of 2011 mix',
        duration: 600,
        chaptersJson: chapters([
          ('c1', 'Avicii — Levels', 0, 180000),
          ('c2', 'Unrecognized section', 180000, 600000),
        ]),
      );
      // A whole-file doc from before the chapters existed goes away.
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: t.id,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.none,
          checkedAt: now,
        ),
      );
      await service.fetchTrack(t);
      final docs = await db.lyricsDocsForTrack(t.id);
      expect(docs.map((d) => d.chapterId), ['c1', 'c2']);
      expect(docs.first.status, LyricsStatus.found);
      expect(docs.first.offsetMs, 0);
      expect(docs[1].status, LyricsStatus.none);
      expect(docs[1].offsetMs, 180000);
      // Chapters never use the exact lookup or YouTube Music.
      expect(lrclib.paths, isNot(contains('get')));
      expect(ytMusicHttp.requests, isEmpty);
    });

    test('manual captions are cut per chapter', () async {
      final p = await playlist();
      final t = await track(
        p,
        title: 'Mix',
        duration: 20,
        chaptersJson: chapters([
          ('c1', 'First', 0, 10000),
          ('c2', 'Second', 10000, 20000),
        ]),
      );
      captionInfo = {
        'title': 'Mix',
        'subtitles': {
          'en': [
            {'ext': 'json3', 'url': 'https://caps/en'},
          ],
        },
      };
      captionsHttp.handler =
          (_) => FakeHttpResponse.json({
            'events': [
              {
                'tStartMs': 1000,
                'segs': [
                  {'utf8': 'one'},
                ],
              },
              {
                'tStartMs': 12000,
                'segs': [
                  {'utf8': 'two'},
                ],
              },
            ],
          });
      await service.fetchTrack(t);
      final second = (await db.lyricsDocFor(t.id, 'c2'))!;
      final lines = await db.lyricsLinesForDoc(second.id);
      expect(lines.single.lineText, 'two');
      expect(lines.single.startMs, 2000);
      expect(second.offsetMs, 10000);
      // One extraction and one caption download serve every chapter.
      expect(captionInfoUrls, hasLength(1));
      expect(captionsHttp.requests, hasLength(1));
    });

    test('transcript mode takes speech-to-text for the whole file', () async {
      final p = await playlist(mode: 'transcript');
      final t = await track(
        p,
        title: 'A talk',
        chaptersJson: chapters([('c1', 'Intro', 0, 10000)]),
      );
      captionInfo = {
        'language': 'cs',
        'automatic_captions': {
          'cs-orig': [
            {'ext': 'json3', 'url': 'https://caps/cs-orig'},
          ],
        },
      };
      captionsHttp.handler =
          (_) async => FakeHttpResponse(
            200,
            await File(
              'test/fixtures/lyrics/asr_music.cs-orig.json3',
            ).readAsString(),
          );
      await service.fetchTrack(t);
      final docs = await db.lyricsDocsForTrack(t.id);
      expect(docs.single.chapterId, isNull);
      expect(docs.single.kind, 'transcript');
      expect(docs.single.source, LyricsSource.ytAuto);
      expect(docs.single.sourceRef, 'vid1:cs-orig');
      expect(docs.single.lang, 'cs');
      expect(await db.lyricsLinesForDoc(docs.single.id), isNotEmpty);
      expect(lrclib.http.requests, isEmpty);
    });

    test('failures become error docs that are retried sooner', () async {
      final p = await playlist(mode: 'transcript');
      final t = await track(p);
      captionInfo = null;
      await service.fetchTrack(t);
      final doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.status, LyricsStatus.error);
      expect(doc.attempts, 1);

      // Not due again right away...
      captionInfo = const {};
      await service.fetchTrack(t);
      expect((await db.lyricsDocFor(t.id, null))!.attempts, 1);
      // ...but after the error interval.
      now = now.add(const Duration(hours: 12));
      await service.fetchTrack(t);
      final retried = (await db.lyricsDocFor(t.id, null))!;
      expect(retried.status, LyricsStatus.none);
      expect(retried.attempts, 2);
    });
  });

  group('backfillPlaylist', () {
    test('fetches due tracks with progress, skipping fresh ones', () async {
      lrclib.exact['Europe|The Final Countdown'] = lrclibRecord();
      final p = await playlist();
      final a = await track(p);
      final b = await track(
        p,
        index: 2,
        videoId: 'vid2',
        title: 'Nothing Here',
      );
      await insertTestTrack(db, playlistId: p.id, index: 3, videoId: 'vid3');
      final progress = <(int, int)>[];
      final result = await service.backfillPlaylist(
        p.id,
        onProgress: (e) => progress.add((e.done, e.total)),
      );
      expect(result.due, 2);
      expect(result.found, 1);
      expect(result.missing, 1);
      expect(progress, [(0, 2), (1, 2), (2, 2)]);
      expect((await db.lyricsDocFor(a.id, null))!.status, LyricsStatus.found);
      expect((await db.lyricsDocFor(b.id, null))!.status, LyricsStatus.none);

      // Nothing is due a day later; a week later the miss is retried.
      now = now.add(const Duration(days: 1));
      expect((await service.backfillPlaylist(p.id)).due, 0);
      now = now.add(const Duration(days: 9));
      expect((await service.backfillPlaylist(p.id)).due, 1);
      expect((await db.lyricsDocFor(b.id, null))!.attempts, 2);
    });

    test('stops after the fourth try of a miss', () async {
      final p = await playlist();
      final t = await track(p, title: 'Nothing Here');
      for (var i = 0; i < 6; i++) {
        await service.backfillPlaylist(p.id);
        now = now.add(const Duration(days: 30));
      }
      expect((await db.lyricsDocFor(t.id, null))!.attempts, 4);
    });

    test('stops on cancel and when the budget runs out', () async {
      final p = await playlist();
      for (var i = 1; i <= 3; i++) {
        await track(p, index: i, videoId: 'v$i', title: 'Song $i');
      }
      final cancellation = LyricsCancellation();
      final cancelled = await service.backfillPlaylist(
        p.id,
        cancellation: cancellation,
        onProgress: (e) {
          if (e.done == 1) cancellation.cancel();
        },
      );
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.due, 1);

      // Each track takes "a minute" of the fake clock.
      lrclib.http.handler = (_) {
        now = now.add(const Duration(minutes: 1));
        return FakeHttpResponse.json(const []);
      };
      final timed = await service.backfillPlaylist(
        p.id,
        budget: const Duration(seconds: 30),
      );
      expect(timed.outOfTime, isTrue);
      expect(timed.due, 1);
    });

    test('stops when the service keeps failing', () async {
      lrclib.http.handler = (_) => const FakeHttpResponse(503, 'down');
      final p = await playlist();
      for (var i = 1; i <= 5; i++) {
        await track(p, index: i, videoId: 'v$i', title: 'Song $i');
      }
      final result = await service.backfillPlaylist(p.id);
      expect(result.failed, 3);
      expect(result.due, 3);
    });
  });

  group('picks', () {
    test('an LRCLIB pick is stored pinned and never replaced', () async {
      lrclib.http.handler = (request) {
        if (request.uri.path == '/api/get/77') {
          return FakeHttpResponse.json(
            lrclibRecord(id: 77, track: 'Right Song', artist: 'Right Artist'),
          );
        }
        return FakeHttpResponse.json(const []);
      };
      final p = await playlist();
      final t = await track(p, title: 'Wrong Guess');
      await service.applyPick(
        t.id,
        null,
        const LyricsPick(source: LyricsSource.lrclib, sourceRef: '77'),
      );
      final doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.pinned, isTrue);
      expect(doc.matchedTitle, 'Right Song');
      // 296 s record against a 296 s file: the times fit.
      expect(doc.synced, isTrue);

      await service.fetchTrack(t, force: true);
      expect((await db.lyricsDocFor(t.id, null))!.sourceRef, '77');
      expect(
        (await readLyricsFile(dir.path, 'vid1', t.id)).single.pinned,
        isTrue,
      );
    });

    test('"No lyrics here" and refetch', () async {
      lrclib.exact['Europe|The Final Countdown'] = lrclibRecord(id: 5);
      final p = await playlist();
      final t = await track(p);
      await service.applyPick(t.id, null, const LyricsPick.none());
      var doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.status, LyricsStatus.none);
      expect(doc.pinned, isTrue);

      await service.refetch(t.id, null);
      doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.pinned, isFalse);
      expect(doc.status, LyricsStatus.found);
      expect(doc.sourceRef, '5');
    });

    test('captions of another YouTube video', () async {
      captionInfo = {
        'title': 'Hey Brother (Lyric Video)',
        'subtitles': {
          'en': [
            {'ext': 'json3', 'url': 'https://caps/other'},
          ],
        },
        'automatic_captions': {
          'en-orig': [
            {'ext': 'json3', 'url': 'https://caps/asr'},
          ],
        },
      };
      captionsHttp.handler =
          (_) => FakeHttpResponse.json({
            'events': [
              {
                'tStartMs': 4278,
                'segs': [
                  {'utf8': '♪ Hey brother ♪'},
                ],
              },
            ],
          });
      final p = await playlist();
      final t = await track(p, title: 'Avicii - Hey Brother');
      await service.applyPick(
        t.id,
        null,
        const LyricsPick(source: LyricsSource.ytSubs, sourceRef: 'other'),
      );
      final doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.source, LyricsSource.ytSubs);
      expect(doc.sourceRef, 'other:en');
      expect(doc.pinned, isTrue);
      expect(captionInfoUrls.single, 'https://www.youtube.com/watch?v=other');
      final line = (await db.lyricsLinesForDoc(doc.id)).single;
      expect(line.lineText, 'Hey brother');
      expect(line.startMs, 4278);
    });

    test('a pin restored without its text is fetched again', () async {
      lrclib.http.handler =
          (request) => FakeHttpResponse.json(
            request.uri.path == '/api/get/9'
                ? lrclibRecord(id: 9)
                : const <Object>[],
          );
      final p = await playlist();
      final t = await track(p);
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: t.id,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          source: LyricsSource.lrclib,
          sourceRef: '9',
          pinned: true,
          checkedAt: now,
        ),
      );
      await service.backfillPlaylist(p.id);
      final doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.pinned, isTrue);
      expect(await db.lyricsLinesForDoc(doc.id), hasLength(2));
    });

    test('candidatesFor and pickerQueryFor', () async {
      lrclib.searches['q=europe countdown'] = [lrclibRecord(id: 3)];
      final candidates = await service.candidatesFor('europe countdown');
      expect(candidates.single.id, 3);
      expect(candidates.single.synced, isTrue);
      expect(await service.candidatesFor('  '), isEmpty);

      final p = await playlist();
      final t = await track(
        p,
        title: 'Nightcore - Takeover [Zardonic]',
        chaptersJson: chapters([('c1', 'Daft Punk — Get Lucky', 0, 1000)]),
      );
      expect(await service.pickerQueryFor(t.id, null), 'Zardonic Takeover');
      expect(await service.pickerQueryFor(t.id, 'c1'), 'Daft Punk Get Lucky');
    });
  });

  test('onChaptersChanged and syncLyricsChapterDocs drop stale docs', () async {
    final p = await playlist(mode: null);
    final t = await track(
      p,
      chaptersJson: chapters([
        ('c1', 'A — One', 0, 1000),
        ('c2', 'B — Two', 1000, 2000),
      ]),
    );
    for (final id in ['c1', 'c2']) {
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: t.id,
          chapterId: id,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.none,
          checkedAt: now,
        ),
      );
    }
    final old = ChapterData.decode(t.chaptersJson);
    final renamed = ChapterData(
      downloaded: [
        const MediaChapter(
          id: 'c1',
          title: 'A — Changed',
          startMs: 0,
          endMs: 1000,
        ),
        const MediaChapter(
          id: 'c2',
          title: 'B — Two',
          startMs: 1000,
          endMs: 2000,
        ),
      ],
    );
    await db.writeTrackChapters(t.id, renamed);
    await syncLyricsChapterDocs(db, t.id, renamed, previous: old);
    expect((await db.lyricsDocsForTrack(t.id)).map((d) => d.chapterId), ['c2']);

    await db.writeTrackChapters(t.id, const ChapterData());
    await service.onChaptersChanged(t.id);
    expect(await db.lyricsDocsForTrack(t.id), isEmpty);
  });

  group('review fixes', () {
    LyricsDocDraft pin(
      Track t, {
      String? chapterId,
      int offsetMs = 0,
      LyricsMode kind = LyricsMode.lyrics,
      String source = LyricsSource.lrclib,
      String sourceRef = '404',
      List<LyricsLineDraft> lines = const [],
    }) => LyricsDocDraft(
      trackId: t.id,
      chapterId: chapterId,
      offsetMs: offsetMs,
      kind: kind,
      status: LyricsStatus.found,
      source: source,
      sourceRef: sourceRef,
      pinned: true,
      checkedAt: now,
      lines: lines,
    );

    test('a pin that cannot be restored waits and does not stop the '
        'backfill', () async {
      lrclib.exact['Europe|The Final Countdown'] = lrclibRecord();
      final p = await playlist();
      final pinned = [
        for (var i = 1; i <= 3; i++)
          await track(p, index: i, videoId: 'v$i', title: 'Pinned $i'),
      ];
      for (final t in pinned) {
        await db.replaceLyricsDoc(pin(t));
      }
      final last = await track(p, index: 4, videoId: 'v4');

      final first = await service.backfillPlaylist(p.id);
      expect(first.failed, 0);
      expect(
        (await db.lyricsDocFor(last.id, null))!.status,
        LyricsStatus.found,
      );
      final doc = (await db.lyricsDocFor(pinned.first.id, null))!;
      expect(doc.pinned, isTrue);
      expect(doc.attempts, 1);

      // Not tried again at once; after the error interval, up to the cap.
      final requests = lrclib.http.requests.length;
      expect((await service.backfillPlaylist(p.id)).due, 0);
      expect(lrclib.http.requests.length, requests);
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(days: 1));
        await service.backfillPlaylist(p.id);
      }
      final tried = (await db.lyricsDocFor(pinned.first.id, null))!;
      expect(tried.attempts, LyricsService.maxAttempts);
      expect(tried.pinned, isTrue);
    });

    test('pinned docs of the other mode give way after a switch', () async {
      final p = await playlist(mode: 'transcript');
      final t = await track(
        p,
        chaptersJson: chapters([('c1', 'Intro', 0, 10000)]),
      );
      await db.replaceLyricsDoc(
        pin(t, lines: const [LyricsLineDraft('old lyric')]),
      );
      await db.replaceLyricsDoc(
        pin(t, chapterId: 'c1', lines: const [LyricsLineDraft('old lyric')]),
      );
      captionInfo = {
        'automatic_captions': {
          'en-orig': [
            {'ext': 'json3', 'url': 'https://caps/asr'},
          ],
        },
      };
      captionsHttp.handler =
          (_) => FakeHttpResponse.json({
            'events': [
              {
                'tStartMs': 1000,
                'segs': [
                  {'utf8': 'spoken words'},
                ],
              },
            ],
          });
      await service.backfillPlaylist(p.id);
      final docs = await db.lyricsDocsForTrack(t.id);
      expect(docs.single.kind, 'transcript');
      expect(docs.single.chapterId, isNull);
    });

    test('an ineligible track loses its docs of the other mode', () async {
      final p = await playlist(mode: 'transcript');
      final t = await insertTestTrack(
        db,
        playlistId: p.id,
        videoId: 'local',
        title: 'Local',
        filePath: '${dir.path}/l.m4a',
        status: 'complete',
        isLocalReplacement: true,
      );
      await db.replaceLyricsDoc(
        pin(t, lines: const [LyricsLineDraft('old lyric')]),
      );
      await service.backfillPlaylist(p.id);
      expect(await db.lyricsDocsForTrack(t.id), isEmpty);
    });

    test('a pinned chapter doc follows its chapter and the file is '
        'rewritten', () async {
      final p = await playlist();
      final t = await track(
        p,
        chaptersJson: chapters([
          ('c1', 'A — One', 60000, 120000),
          ('c2', 'B — Two', 120000, 180000),
        ]),
      );
      await db.replaceLyricsDoc(
        pin(
          t,
          chapterId: 'c1',
          offsetMs: 60000,
          lines: const [LyricsLineDraft('line', startMs: 1000)],
        ),
      );
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: t.id,
          chapterId: 'c2',
          offsetMs: 120000,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          checkedAt: now,
          lines: const [LyricsLineDraft('wrong song')],
        ),
      );
      await persistLyricsFile(db, t.id);
      final old = ChapterData.decode(t.chaptersJson);
      final edited = ChapterData(
        downloaded: const [
          MediaChapter(
            id: 'c1',
            title: 'A — One',
            startMs: 90000,
            endMs: 120000,
          ),
          MediaChapter(
            id: 'c2',
            title: 'B — Right',
            startMs: 120000,
            endMs: 180000,
          ),
        ],
      );
      await db.writeTrackChapters(t.id, edited);
      expect(await syncLyricsChapterDocs(db, t.id, edited, previous: old), 2);
      final docs = await db.lyricsDocsForTrack(t.id);
      expect(docs.single.chapterId, 'c1');
      expect(docs.single.offsetMs, 90000);
      final file = await readLyricsFile(dir.path, 'vid1', t.id);
      expect(file.single.chapterId, 'c1');
      expect(file.single.offsetMs, 90000);
    });

    test(
      'a chapter edited during its lookup is left for the next fetch',
      () async {
        final p = await playlist();
        final t = await track(
          p,
          title: 'Mix',
          chaptersJson: chapters([('c1', 'Avicii — Levels', 0, 180000)]),
        );
        lrclib.http.handler = (_) async {
          final moved = ChapterData(
            downloaded: const [
              MediaChapter(
                id: 'c1',
                title: 'Avicii — Levels',
                startMs: 5000,
                endMs: 180000,
              ),
            ],
          );
          await db.writeTrackChapters(t.id, moved);
          return FakeHttpResponse.json(const []);
        };
        await service.fetchTrack(t);
        expect(await db.lyricsDocFor(t.id, 'c1'), isNull);
      },
    );

    test(
      'restoring a captions pin in lyrics mode skips speech-to-text',
      () async {
        final p = await playlist();
        final t = await track(p);
        await db.replaceLyricsDoc(
          pin(t, source: LyricsSource.ytSubs, sourceRef: 'other:en-gone'),
        );
        captionInfo = {
          'automatic_captions': {
            'en-orig': [
              {'ext': 'json3', 'url': 'https://caps/asr'},
            ],
          },
        };
        captionsHttp.handler = (_) => FakeHttpResponse.json({'events': []});
        await service.backfillPlaylist(p.id);
        final doc = (await db.lyricsDocFor(t.id, null))!;
        expect(doc.source, LyricsSource.ytSubs);
        expect(await db.lyricsLinesForDoc(doc.id), isEmpty);
        expect(captionsHttp.requests, isEmpty);
      },
    );

    test('yt-dlp runs are spaced from the end of the previous one', () async {
      final sleeps = <Duration>[];
      final paced = LyricsService(
        db,
        LogService(),
        lrclib: LrclibClient(
          http: lrclib.http,
          sleep: (_) async {},
          retryDelays: const [],
        ),
        captions: CaptionsClient(http: captionsHttp),
        captionInfo: (url) async {
          now = now.add(const Duration(seconds: 5));
          return const {};
        },
        clock: () => now,
        sleep: (d) async {
          sleeps.add(d);
          now = now.add(d);
        },
      );
      addTearDown(paced.dispose);
      final p = await playlist(mode: 'transcript');
      await track(p, index: 1, videoId: 'a');
      await track(p, index: 2, videoId: 'b');
      await paced.backfillPlaylist(p.id);
      expect(sleeps, [const Duration(seconds: 2)]);
    });

    test('a local replacement does not take the video captions', () async {
      final p = await playlist();
      final t = await insertTestTrack(
        db,
        playlistId: p.id,
        videoId: 'vid1',
        title: 'Some Song Nobody Has',
        filePath: '${dir.path}/l.m4a',
        durationSeconds: 200,
        status: 'complete',
        isLocalReplacement: true,
      );
      captionInfo = {
        'subtitles': {
          'en': [
            {'ext': 'json3', 'url': 'https://caps/en'},
          ],
        },
      };
      captionsHttp.handler =
          (_) => FakeHttpResponse.json({
            'events': [
              {
                'tStartMs': 1000,
                'segs': [
                  {'utf8': 'a lyric'},
                ],
              },
            ],
          });
      await service.fetchTrack(t);
      expect((await db.lyricsDocFor(t.id, null))!.status, LyricsStatus.none);
      expect(captionInfoUrls, isEmpty);
    });

    test('LRCLIB lines of a chapter end with the chapter', () async {
      lrclib.searches['track_name=Africa&artist_name=Toto'] = [
        lrclibRecord(
          track: 'Africa',
          artist: 'Toto',
          duration: 295,
          synced:
              '[00:20.00] I hear the drums\n[03:56.68] Gonna take some time',
        ),
      ];
      final p = await playlist();
      final t = await track(
        p,
        title: 'Mix',
        duration: 345,
        chaptersJson: chapters([
          ('t1', 'Toto — Africa', 0, 120000),
          ('t2', 'Unrecognized section', 120000, 345000),
        ]),
      );
      await service.fetchTrack(t);
      final doc = (await db.lyricsDocFor(t.id, 't1'))!;
      expect(doc.status, LyricsStatus.found);
      expect((await db.lyricsLinesForDoc(doc.id)).map((l) => l.lineText), [
        'I hear the drums',
      ]);
    });

    test('fetch and refetch say why a track cannot be fetched', () async {
      final p = await playlist(mode: 'transcript');
      final t = await insertTestTrack(
        db,
        playlistId: p.id,
        videoId: 'local',
        title: 'Local',
        filePath: '${dir.path}/l.m4a',
        status: 'complete',
        isLocalReplacement: true,
      );
      await db.replaceLyricsDoc(
        pin(
          t,
          kind: LyricsMode.transcript,
          source: LyricsSource.ytSubs,
          sourceRef: 'x:en',
          lines: const [LyricsLineDraft('picked')],
        ),
      );
      expect(
        LyricsService.fetchBlockedReason(t, LyricsMode.transcript),
        isNotNull,
      );
      await expectLater(service.fetchTrack(t), throwsStateError);
      await expectLater(service.refetch(t.id, null), throwsStateError);
      expect((await db.lyricsDocFor(t.id, null))!.pinned, isTrue);

      final pending = await insertTestTrack(
        db,
        playlistId: p.id,
        index: 2,
        videoId: 'p',
      );
      await expectLater(service.fetchTrack(pending), throwsStateError);
    });
  });
  group('second review fixes', () {
    Map<String, dynamic> asrInfo() => {
      'language': 'en',
      'automatic_captions': {
        'en-orig': [
          {'ext': 'json3', 'url': 'https://caps/en-orig'},
        ],
      },
    };
    FakeHttpResponse oneLine(FakeHttpRequest _) => FakeHttpResponse.json({
      'events': [
        {
          'tStartMs': 1000,
          'segs': [
            {'utf8': 'old video words'},
          ],
        },
      ],
    });

    test('media replaced during a lookup is not written over', () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final slow = LyricsService(
        db,
        LogService(),
        lrclib: LrclibClient(
          http: lrclib.http,
          sleep: (_) async {},
          retryDelays: const [],
        ),
        captions: CaptionsClient(http: captionsHttp),
        captionInfo: (url) async {
          started.complete();
          await gate.future;
          return asrInfo();
        },
        clock: () => now,
        sleep: (_) async {},
      );
      addTearDown(slow.dispose);
      captionsHttp.handler = oneLine;
      final p = await playlist(mode: 'transcript');
      final t = await track(p);
      final fetch = slow.backfillPlaylist(p.id);
      await started.future;
      await db.updateTrackStatus(
        t.id,
        'complete',
        filePath: '${dir.path}/local.m4a',
        isLocalReplacement: true,
      );
      await dropLyricsForReplacedMedia(db, t.id);
      gate.complete();
      await fetch;
      expect(await db.lyricsDocsForTrack(t.id), isEmpty);
    });

    test('a stale transcript of a local replacement is dropped', () async {
      final p = await playlist(mode: 'transcript');
      final t = await insertTestTrack(
        db,
        playlistId: p.id,
        videoId: 'local',
        title: 'Local',
        filePath: '${dir.path}/l.m4a',
        status: 'complete',
        isLocalReplacement: true,
      );
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: t.id,
          kind: LyricsMode.transcript,
          status: LyricsStatus.found,
          source: LyricsSource.ytAuto,
          checkedAt: now,
          lines: const [LyricsLineDraft('old video words', startMs: 0)],
        ),
      );
      await service.backfillPlaylist(p.id);
      expect(await db.lyricsDocsForTrack(t.id), isEmpty);
    });

    test('yt-dlp runs never overlap', () async {
      var active = 0;
      var most = 0;
      final paced = LyricsService(
        db,
        LogService(),
        lrclib: LrclibClient(
          http: lrclib.http,
          sleep: (_) async {},
          retryDelays: const [],
        ),
        captions: CaptionsClient(http: captionsHttp),
        captionInfo: (url) async {
          active++;
          if (active > most) most = active;
          for (var i = 0; i < 5; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          active--;
          return const {};
        },
        clock: () => now,
        sleep: (d) async => now = now.add(d),
      );
      addTearDown(paced.dispose);
      final a = await playlist(mode: 'transcript');
      final b = await playlist(mode: 'transcript');
      await track(a, index: 1, videoId: 'a');
      await track(b, index: 1, videoId: 'b');
      await Future.wait([
        paced.backfillPlaylist(a.id),
        paced.backfillPlaylist(b.id),
      ]);
      expect(most, 1);
    });

    test('a pin restore stops on cancel without using an attempt', () async {
      final sleeps = <Duration>[];
      final cancellation = LyricsCancellation();
      final restoring = LyricsService(
        db,
        LogService(),
        lrclib: LrclibClient(
          http: lrclib.http,
          sleep: (d) async => sleeps.add(d),
          retryDelays: const [Duration(seconds: 3), Duration(seconds: 10)],
        ),
        captions: CaptionsClient(http: captionsHttp),
        clock: () => now,
        sleep: (_) async {},
      );
      addTearDown(restoring.dispose);
      lrclib.http.handler = (_) {
        cancellation.cancel();
        return const FakeHttpResponse(429, '');
      };
      final p = await playlist();
      final t = await track(p);
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: t.id,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          source: LyricsSource.lrclib,
          sourceRef: '404',
          pinned: true,
          checkedAt: now,
        ),
      );
      final result = await restoring.backfillPlaylist(
        p.id,
        cancellation: cancellation,
      );
      expect(result.failed, 0);
      expect(lrclib.http.requests, hasLength(1));
      expect(sleeps.where((d) => d >= const Duration(seconds: 3)), isEmpty);
      final doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.pinned, isTrue);
      expect(doc.attempts, 0);
    });

    test('a nightcore title without a description is retried later', () async {
      lrclib.searches['q=Come Clean'] = [
        lrclibRecord(
          id: 8,
          track: 'Come Clean',
          artist: 'Somebody',
          duration: 230,
        ),
      ];
      captionInfo = null;
      final p = await playlist();
      final t = await track(p, title: 'Nightcore - Come Clean', duration: 184);
      await service.fetchTrack(t);
      final doc = (await db.lyricsDocFor(t.id, null))!;
      expect(doc.status, LyricsStatus.error);
    });

    test('a shortened chapter loses its synced lines past the end', () async {
      final p = await playlist();
      final t = await track(
        p,
        title: 'Mix',
        chaptersJson: chapters([
          ('c1', 'A — One', 0, 60000),
          ('c2', 'B — Two', 60000, 120000),
        ]),
      );
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: t.id,
          chapterId: 'c1',
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          source: LyricsSource.lrclib,
          sourceRef: '1',
          synced: true,
          pinned: true,
          checkedAt: now,
          lines: const [
            LyricsLineDraft('early', startMs: 10000),
            LyricsLineDraft('late', startMs: 50000),
          ],
        ),
      );
      await db.replaceLyricsDoc(
        LyricsDocDraft(
          trackId: t.id,
          chapterId: 'c2',
          offsetMs: 60000,
          kind: LyricsMode.lyrics,
          status: LyricsStatus.found,
          source: LyricsSource.lrclib,
          sourceRef: '2',
          synced: true,
          checkedAt: now,
          lines: const [LyricsLineDraft('second', startMs: 50000)],
        ),
      );
      final old = ChapterData.decode(t.chaptersJson);
      final edited = ChapterData(
        downloaded: const [
          MediaChapter(id: 'c1', title: 'A — One', startMs: 0, endMs: 30000),
          MediaChapter(
            id: 'c2',
            title: 'B — Two',
            startMs: 60000,
            endMs: 100000,
          ),
        ],
      );
      await db.writeTrackChapters(t.id, edited);
      await syncLyricsChapterDocs(db, t.id, edited, previous: old);
      final docs = await db.lyricsDocsForTrack(t.id);
      expect(docs.single.chapterId, 'c1');
      expect(docs.single.pinned, isTrue);
      expect(
        (await db.lyricsLinesForDoc(docs.single.id)).map((l) => l.lineText),
        ['early'],
      );
    });
  });
}
