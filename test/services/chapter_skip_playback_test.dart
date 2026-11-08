import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/playback_service.dart';

import '../helpers/test_database.dart';
import 'playback_fakes.dart';

ChapterData _threeChapters([Set<String> skipped = const {}]) => ChapterData(
  downloaded: const [
    MediaChapter(id: 'one', title: 'First song', startMs: 0, endMs: 20000),
    MediaChapter(id: 'two', title: 'Second song', startMs: 20000, endMs: 40000),
    MediaChapter(
      id: 'three',
      title: 'Third song',
      startMs: 40000,
      endMs: 60000,
    ),
  ],
  skippedChapterIds: skipped,
);

/// Playback of chapters marked Always skip, and seeking in files whose
/// stored length is missing.
void main() {
  late AppDatabase db;
  late Directory dir;
  late Playlist playlist;
  late FakePlayer player;
  late FakeAudioSession session;
  late PlaybackService playback;
  var nextIndex = 1;

  Future<Track> addTrack(
    String name, {
    ChapterData? chapters,
    int? durationSeconds = 60,
  }) async {
    final path = '${dir.path}/$name.m4a';
    await File(path).writeAsString(name);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: nextIndex++,
      videoId: name,
      title: name,
      status: 'complete',
      filePath: path,
      durationSeconds: durationSeconds,
    );
    if (chapters != null) await db.writeTrackChapters(track.id, chapters);
    return (await db.getTrack(track.id))!;
  }

  Future<void> settle([int ms = 30]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<PlaybackService> createPlayback({FakePlayer? withPlayer}) async {
    player = withPlayer ?? FakePlayer();
    final service = PlaybackService(db, player: player);
    await service.initializeAudioFocus(
      pauseOnAudioInterruption: true,
      audioSession: session,
    );
    return service;
  }

  Future<void> usePlayer(FakePlayer replacement) async {
    await playback.dispose();
    playback = await createPlayback(withPlayer: replacement);
  }

  Future<void> setPlayChapters(bool enabled) => db.updatePlaylistFields(
    playlist.id,
    PlaylistsCompanion(playChapters: Value(enabled)),
  );

  setUp(() async {
    db = openTestDatabase();
    dir = await Directory.systemTemp.createTemp('woolytube-chapter-skip-');
    playlist = await insertTestPlaylist(db);
    nextIndex = 1;
    session = FakeAudioSession();
    playback = await createPlayback();
  });

  tearDown(() async {
    await playback.dispose();
    await session.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  group('a whole file whose stored length is 0', () {
    test('seeks where asked instead of to the start', () async {
      await usePlayer(FakePlayer(duration: const Duration(minutes: 72)));
      final mix = await addTrack('mix', durationSeconds: 0);
      await playback.playTrack(mix, [mix]);
      expect(playback.currentItem!.chapter, isNull);

      await playback.seekTo(const Duration(minutes: 30));
      expect(player.seeks.last, const Duration(minutes: 30));
      expect(playback.position, const Duration(minutes: 30));

      // Only the player's real length limits a seek.
      await playback.seekTo(const Duration(minutes: 90));
      expect(player.seeks.last, const Duration(minutes: 72));
    });

    test('a seek right after opening waits until the file is loaded', () async {
      await usePlayer(FakePlayer(duration: Duration.zero));
      final mix = await addTrack('mix', durationSeconds: 0);
      await playback.playTrack(mix, [mix]);

      final seek = playback.seekTo(const Duration(minutes: 30));
      await settle();
      expect(player.seeks, isEmpty, reason: 'mpv would drop it now');

      player.state = player.state.copyWith(
        duration: const Duration(minutes: 72),
      );
      player.stream.durations.add(const Duration(minutes: 72));
      await seek;
      expect(player.seeks, [const Duration(minutes: 30)]);
    });
  });

  group('chapters marked Always skip', () {
    setUp(() => setPlayChapters(true));

    test('are passed over by automatic playback', () async {
      final album = await addTrack('album', chapters: _threeChapters({'two'}));
      final after = await addTrack('after');
      await playback.playTrack(album, [album, after]);
      expect(playback.currentItem!.chapter!.id, 'one');
      expect(playback.queue.map((t) => t.title), [
        'First song',
        'Third song',
        'after',
      ]);

      await playback.next();
      expect(playback.currentItem!.chapter!.id, 'three');
      await playback.next();
      expect(playback.currentTrack!.id, after.id);
    });

    test(
      'a chapter tapped directly plays, then the next unskipped one',
      () async {
        final album = await addTrack(
          'album',
          chapters: _threeChapters({'one', 'two'}),
        );
        await playback.playTrack(album, [album], chapterId: 'two');
        expect(playback.currentItem!.chapter!.id, 'two');
        expect(player.opened.last.start, const Duration(seconds: 20));

        await playback.next();
        expect(playback.currentItem!.chapter!.id, 'three');
      },
    );

    test('a file with every chapter skipped is passed over', () async {
      final first = await addTrack('first');
      final skipped = await addTrack(
        'skipped',
        chapters: _threeChapters({'one', 'two', 'three'}),
      );
      final last = await addTrack('last');
      await playback.playTrack(first, [first, skipped, last]);
      expect(playback.queue.map((t) => t.title), ['first', 'last']);

      await playback.next();
      expect(playback.currentTrack!.id, last.id);

      // Tapping it still plays it.
      await playback.playTrack(skipped, [first, skipped, last]);
      expect(playback.currentItem!.track.id, skipped.id);
      expect(playback.currentItem!.chapter!.id, 'one');
    });

    test(
      'a tapped file whose chapters are all skipped plays them all',
      () async {
        final skipped = await addTrack(
          'skipped',
          chapters: _threeChapters({'one', 'two', 'three'}),
        );
        final last = await addTrack('last');
        await playback.playTrack(skipped, [skipped, last]);
        expect(playback.currentItem!.chapter!.id, 'one');

        // Gaplessly into the next chapter.
        player.tick(const Duration(milliseconds: 20050));
        await settle();
        expect(playback.currentItem!.chapter!.id, 'two');

        await playback.next();
        expect(playback.currentItem!.chapter!.id, 'three');
        await playback.next();
        expect(playback.currentTrack!.id, last.id);
      },
    );

    test('Previous goes back to a tapped skipped chapter', () async {
      final album = await addTrack(
        'album',
        chapters: _threeChapters({'one', 'two'}),
      );
      await playback.playTrack(album, [album], chapterId: 'two');
      await playback.next();
      expect(playback.currentItem!.chapter!.id, 'three');

      await playback.previous();
      expect(playback.currentItem!.chapter!.id, 'two');
    });

    test('a chapter skipped while the queue plays is passed over', () async {
      final album = await addTrack('album', chapters: _threeChapters());
      await playback.playTrack(album, [album]);
      expect(playback.currentItem!.chapter!.id, 'one');

      await db.writeTrackChapters(album.id, _threeChapters({'two'}));
      await playback.next();
      expect(playback.currentItem!.chapter!.id, 'three');
    });

    test('a skipped chapter of the playing file can still be chosen', () async {
      final album = await addTrack('album', chapters: _threeChapters());
      await playback.playTrack(album, [album]);
      await db.writeTrackChapters(album.id, _threeChapters({'three'}));

      expect(
        await playback.playChapterOfCurrentFile(album.id, 'three'),
        isTrue,
      );
      expect(playback.currentItem!.chapter!.id, 'three');
    });

    test('cannot be queued', () async {
      final playing = await addTrack('playing');
      final album = await addTrack('album', chapters: _threeChapters({'two'}));
      await playback.playTrack(playing, [playing]);

      expect(await playback.addToUpNextQueue(album, chapterId: 'two'), isFalse);
      expect(await playback.playNext(album, chapterId: 'two'), isFalse);
      expect(playback.upNextQueue, isEmpty);

      expect(await playback.addToUpNextQueue(album, chapterId: 'one'), isTrue);
      // The whole file queues without its skipped chapter.
      expect(await playback.addToUpNextQueue(album), isTrue);
      expect(playback.upNextQueue, hasLength(2));

      final allSkipped = await addTrack(
        'all',
        chapters: _threeChapters({'one', 'two', 'three'}),
      );
      expect(await playback.addToUpNextQueue(allSkipped), isFalse);
    });
  });

  group('while the file plays whole', () {
    setUp(() => setPlayChapters(false));

    test(
      'skipped chapters are jumped over, also without SponsorBlock',
      () async {
        await db.updatePlaylistFields(
          playlist.id,
          const PlaylistsCompanion(sponsorBlockEnabled: Value(false)),
        );
        final album = await addTrack(
          'album',
          chapters: _threeChapters({'two'}),
        );
        await playback.playTrack(album, [album]);
        expect(playback.currentItem!.chapter, isNull);

        player.tick(const Duration(seconds: 10));
        await settle();
        expect(player.seeks, isEmpty);

        player.tick(const Duration(milliseconds: 20100));
        await settle();
        expect(player.seeks, [const Duration(milliseconds: 40250)]);
      },
    );

    test('a skipped chapter at the end ends the file', () async {
      final album = await addTrack(
        'album',
        chapters: _threeChapters({'three'}),
      );
      final after = await addTrack('after');
      await playback.playTrack(album, [album, after]);
      player.tick(const Duration(milliseconds: 40100));
      await settle();
      expect(playback.currentTrack!.id, after.id);
    });

    test('seeking into a skipped chapter plays it', () async {
      final album = await addTrack('album', chapters: _threeChapters({'two'}));
      await playback.playTrack(album, [album]);

      await playback.seekTo(const Duration(seconds: 25));
      await settle();
      player.tick(const Duration(seconds: 26));
      await settle();
      expect(player.seeks, [const Duration(seconds: 25)]);
    });

    test(
      'a skipped chapter right after a chosen one is still jumped over',
      () async {
        final album = await addTrack(
          'album',
          chapters: _threeChapters({'one', 'two'}),
        );
        await playback.playTrack(album, [album]);
        await settle();
        player.seeks.clear();

        await playback.seekTo(const Duration(seconds: 5));
        player.tick(const Duration(seconds: 6));
        await settle();
        expect(player.seeks, [const Duration(seconds: 5)]);

        player.tick(const Duration(milliseconds: 20100));
        await settle();
        expect(player.seeks.last, const Duration(milliseconds: 40250));
      },
    );

    test(
      'a restart with Previous jumps over a skipped first chapter',
      () async {
        final album = await addTrack(
          'album',
          chapters: _threeChapters({'one'}),
        );
        await playback.playTrack(album, [album]);
        player.tick(const Duration(milliseconds: 100));
        await settle();
        expect(player.seeks.last, const Duration(milliseconds: 20250));
        // A skip ignores position reports for a moment after its seek.
        await settle(450);

        player.tick(const Duration(seconds: 25));
        await settle();
        await playback.previous();
        await settle();
        // Back to the start, and over the skipped chapter again.
        expect(player.seeks, [
          const Duration(milliseconds: 20250),
          Duration.zero,
          const Duration(milliseconds: 20250),
        ]);
      },
    );

    test(
      'a skip set during playback applies after trackChaptersChanged',
      () async {
        final album = await addTrack('album', chapters: _threeChapters());
        await playback.playTrack(album, [album]);
        await db.writeTrackChapters(album.id, _threeChapters({'two'}));
        await playback.trackChaptersChanged(album);

        player.tick(const Duration(milliseconds: 20100));
        await settle();
        expect(player.seeks, [const Duration(milliseconds: 40250)]);
      },
    );

    test('nothing is skipped while chapters are being edited', () async {
      final album = await addTrack('album', chapters: _threeChapters({'two'}));
      await playback.playTrack(album, [album]);
      await playback.beginChapterEditing(album);

      player.tick(const Duration(milliseconds: 20100));
      await settle();
      expect(player.seeks, isEmpty);
      playback.endChapterEditing();
    });
  });
}
