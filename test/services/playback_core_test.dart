import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as kit;
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playback_settings_store.dart';

import '../helpers/test_database.dart';
import 'playback_fakes.dart';

/// A settings store whose [load] waits for [gate], like shared preferences
/// that are slow to open at a cold start.
class _GatedStore implements PlaybackSettingsStore {
  final MemoryPlaybackSettingsStore inner;
  final Future<void> gate;
  _GatedStore(this.inner, this.gate);

  @override
  Future<PlaybackPreferences> load() async {
    await gate;
    return inner.load();
  }

  @override
  Future<void> saveShuffle(bool enabled) => inner.saveShuffle(enabled);
  @override
  Future<void> saveAutoplay(bool enabled) => inner.saveAutoplay(enabled);
  @override
  Future<void> saveAudioOnly(bool enabled) => inner.saveAudioOnly(enabled);
  @override
  Future<void> saveSession(PlaybackSession? session) =>
      inner.saveSession(session);
}

const _threeChapters = ChapterData(
  downloaded: [
    MediaChapter(id: 'one', title: 'First song', startMs: 0, endMs: 20000),
    MediaChapter(id: 'two', title: 'Second song', startMs: 20000, endMs: 40000),
    MediaChapter(
      id: 'three',
      title: 'Third song',
      startMs: 40000,
      endMs: 60000,
    ),
  ],
);

void main() {
  late AppDatabase db;
  late Directory dir;
  late Playlist playlist;
  late FakePlayer player;
  late FakeAudioSession session;
  late PlaybackService playback;
  late List<String> messages;
  var nextIndex = 1;

  Future<Track> addTrack(
    String name, {
    bool fileExists = true,
    ChapterData? chapters,
  }) async {
    final path = '${dir.path}/$name.m4a';
    if (fileExists) await File(path).writeAsString(name);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: nextIndex++,
      videoId: name,
      title: name,
      status: 'complete',
      filePath: path,
      durationSeconds: 60,
    );
    if (chapters != null) await db.writeTrackChapters(track.id, chapters);
    return (await db.getTrack(track.id))!;
  }

  Future<List<Track>> addTracks(int count) async => [
    for (var i = 0; i < count; i++) await addTrack('t$i'),
  ];

  Future<void> settle([int ms = 30]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<PlaybackService> createPlayback({
    FakePlayer? withPlayer,
    PlaybackSettingsStore? store,
  }) async {
    player = withPlayer ?? FakePlayer();
    final service = PlaybackService(db, player: player, settingsStore: store);
    service.messages.listen(messages.add);
    await service.initializeAudioFocus(
      pauseOnAudioInterruption: true,
      audioSession: session,
    );
    return service;
  }

  setUp(() async {
    db = openTestDatabase();
    dir = await Directory.systemTemp.createTemp('woolytube-core-');
    playlist = await insertTestPlaylist(db);
    nextIndex = 1;
    session = FakeAudioSession();
    messages = [];
    playback = await createPlayback();
  });

  tearDown(() async {
    await playback.dispose();
    await session.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  group('published state', () {
    test('playing does not flash false while the next track opens', () async {
      final tracks = await addTracks(3);
      await playback.playTrack(tracks[0], tracks);
      final seen = <bool>[];
      final sub = playback.isPlayingStream.listen(seen.add);
      addTearDown(sub.cancel);
      await settle();
      await playback.next();
      await playback.next();
      await settle();
      expect(seen, [true], reason: 'one replayed value, no blips');
      expect(player.opened, hasLength(3));
    });

    test('a late listener gets the current playing state at once', () async {
      final track = await addTrack('song');
      await playback.playTrack(track, [track]);
      expect(await playback.isPlayingStream.first, isTrue);
    });

    test(
      'the UI position is rate-limited but lands on the last value',
      () async {
        final track = await addTrack('song');
        await playback.playTrack(track, [track]);
        final seen = <Duration>[];
        final sub = playback.positionStream.listen(seen.add);
        addTearDown(sub.cancel);
        await settle(5);
        seen.clear();
        for (var ms = 10; ms <= 300; ms += 10) {
          player.tick(Duration(milliseconds: ms));
        }
        expect(playback.position, const Duration(milliseconds: 300));
        expect(seen.length, lessThan(5));
        await settle(PlaybackService.uiPositionInterval.inMilliseconds + 50);
        expect(seen.last, const Duration(milliseconds: 300));
      },
    );

    test('a seek shows up in the UI position immediately', () async {
      final track = await addTrack('song');
      await playback.playTrack(track, [track]);
      player.tick(const Duration(milliseconds: 100));
      final seen = <Duration>[];
      final sub = playback.positionStream.listen(seen.add);
      addTearDown(sub.cancel);
      await playback.seekTo(const Duration(seconds: 40));
      expect(seen.last, const Duration(seconds: 40));
    });

    test('the known length stays while the player has none yet', () async {
      final noLength = FakePlayer(duration: Duration.zero);
      await playback.dispose();
      playback = await createPlayback(withPlayer: noLength);
      final track = await addTrack('song');
      await playback.playTrack(track, [track]);
      expect(playback.duration, const Duration(seconds: 60));
      await playback.stop();
    });

    test('a plain advance does not re-publish an unchanged queue', () async {
      final tracks = await addTracks(4);
      await playback.playTrack(tracks[0], tracks);
      var queueEvents = 0;
      final sub = playback.queueStream.skip(1).listen((_) => queueEvents++);
      addTearDown(sub.cancel);
      await playback.next();
      await playback.next();
      await settle();
      expect(queueEvents, 0);
      expect(playback.queueIndex, 2);
    });
  });

  group('queue', () {
    test('previous at the tapped song plays the song above it', () async {
      final tracks = await addTracks(5);
      await playback.playTrack(tracks[3], tracks);
      expect(playback.queueIndex, 3, reason: 'the real playlist position');
      expect(playback.queue, hasLength(5));

      await playback.previous();
      expect(playback.currentTrack!.id, tracks[2].id);
      expect(playback.queueIndex, 2);
    });

    test(
      'shuffle on mid-play keeps the song and reaches every other',
      () async {
        final tracks = await addTracks(6);
        await playback.playTrack(tracks[4], tracks);
        playback.setShuffleEnabled(true);
        await settle();
        expect(playback.currentTrack!.id, tracks[4].id);
        final played = <int>{};
        for (var i = 0; i < 5; i++) {
          await playback.next();
          played.add(playback.currentTrack!.id);
        }
        expect(played, tracks.map((t) => t.id).toSet()..remove(tracks[4].id));
      },
    );

    test('shuffle off continues after the current song', () async {
      final tracks = await addTracks(6);
      playback.setShuffleEnabled(true);
      await playback.playTrack(tracks[2], tracks);
      playback.setShuffleEnabled(false);
      await playback.next();
      expect(playback.currentTrack!.id, tracks[3].id);
    });

    test('rapid Next presses open only the song they end on', () async {
      final tracks = await addTracks(6);
      await playback.playTrack(tracks[0], tracks);
      await Future.wait([playback.next(), playback.next(), playback.next()]);
      expect(playback.currentTrack!.id, tracks[3].id);
      expect(player.opened, hasLength(2));
      expect(playback.queueIndex, 3);
    });

    test('rapid Previous presses step back once per press', () async {
      final tracks = await addTracks(6);
      await playback.playTrack(tracks[5], tracks);
      await Future.wait([playback.previous(), playback.previous()]);
      expect(playback.currentTrack!.id, tracks[3].id);
      expect(player.opened, hasLength(2));
    });

    test('a tapped track that is no longer playable keeps playback', () async {
      final tracks = await addTracks(3);
      await playback.playTrack(tracks[0], tracks);
      await db.updateTrackStatus(tracks[2].id, 'pending');
      for (final shuffle in [false, true]) {
        playback.setShuffleEnabled(shuffle);
        await playback.playTrack(tracks[2], tracks);
        expect(playback.currentTrack!.id, tracks[0].id);
        expect(player.opened, hasLength(1));
      }
      await settle();
      expect(messages, everyElement(contains("can't be played right now")));
      expect(messages, hasLength(2));
    });

    test('Play after the end starts songs queued up next', () async {
      final tracks = await addTracks(2);
      await playback.playTrack(tracks[0], [tracks[0]]);
      player.finish();
      await settle();
      expect(await playback.addToUpNextQueue(tracks[1]), isTrue);

      await playback.resume();
      expect(playback.currentTrack!.id, tracks[1].id);
      expect(player.opened, hasLength(2));
    });

    test('adding to Up next after the end starts it right away', () async {
      final tracks = await addTracks(2);
      await playback.playTrack(tracks[0], [tracks[0]]);
      player.finish();
      await settle();
      await playback.addToUpNextQueue(tracks[1]);
      expect(await playback.startUpNextQueueIfIdle(), isTrue);
      expect(playback.currentTrack!.id, tracks[1].id);
    });

    test('a seek after the end makes Play replay the song', () async {
      final tracks = await addTracks(2);
      await playback.playTrack(tracks[0], [tracks[0]]);
      player.finish();
      await settle();
      await playback.addToUpNextQueue(tracks[1]);
      await playback.seekTo(const Duration(seconds: 10));
      await playback.resume();
      expect(playback.currentTrack!.id, tracks[0].id);
      expect(player.plays, 1);
    });

    test('audio focus is released when the queue runs out', () async {
      final track = await addTrack('song');
      await playback.playTrack(track, [track]);
      player.finish();
      await settle();
      expect(session.activeChanges, [true, false]);
    });

    test('stop after this song pauses at its end', () async {
      final tracks = await addTracks(2);
      await playback.playTrack(tracks[0], tracks);
      playback.setStopAfterCurrent(true);
      player.finish();
      await settle();
      // The next song is ready but paused, and focus goes back.
      expect(playback.currentTrack!.id, tracks[1].id);
      expect(player.state.playing, isFalse);
      expect(playback.isPlaying, isFalse);
      expect(playback.stopAfterCurrent, isFalse);
      expect(session.activeChanges.last, isFalse);

      await playback.resume();
      expect(player.state.playing, isTrue);
      expect(player.opened, hasLength(2));
    });

    test('Play pressed while the next song opens paused plays it', () async {
      final tracks = await addTracks(2);
      await playback.playTrack(tracks[0], tracks);
      playback.setStopAfterCurrent(true);
      final gate = player.openGate = Completer<void>();
      player.finish();
      await settle();
      await playback.resume();
      gate.complete();
      await settle();
      expect(playback.currentTrack!.id, tracks[1].id);
      expect(player.state.playing, isTrue);
      expect(playback.isPlaying, isTrue);
    });

    test(
      'Next over missing files at the end keeps the queue position',
      () async {
        final song = await addTrack('song');
        final gone = [
          await addTrack('gone1', fileExists: false),
          await addTrack('gone2', fileExists: false),
        ];
        await playback.playTrack(song, [song, ...gone]);
        await playback.next();
        expect(playback.currentTrack!.id, song.id);
        expect(playback.queueIndex, 0);

        await playback.previous();
        expect(player.opened, hasLength(1), reason: 'nothing to reload');
        expect(playback.currentTrack!.id, song.id);
      },
    );

    test('removing from Up next removes the entry the user saw', () async {
      final tracks = await addTracks(4);
      await playback.playTrack(tracks[0], [tracks[0]]);
      await playback.addToUpNextQueue(tracks[1]);
      await playback.addToUpNextQueue(tracks[2]);
      await playback.addToUpNextQueue(tracks[3]);
      playback.removeUpNextQueueAt(1);
      expect(playback.upNextQueue.map((t) => t.id), [
        tracks[1].id,
        tracks[3].id,
      ]);
    });

    test('Play next puts the song at the front of Up next', () async {
      final tracks = await addTracks(4);
      await playback.playTrack(tracks[0], [tracks[0]]);
      await playback.addToUpNextQueue(tracks[1]);
      await playback.addToUpNextQueue(tracks[2]);
      expect(await playback.playNext(tracks[3]), isTrue);
      expect(playback.upNextQueue.map((t) => t.id), [
        tracks[3].id,
        tracks[1].id,
        tracks[2].id,
      ]);
    });

    test('Up next entries can be reordered', () async {
      final tracks = await addTracks(4);
      await playback.playTrack(tracks[0], [tracks[0]]);
      for (final t in tracks.skip(1)) {
        await playback.addToUpNextQueue(t);
      }
      playback.moveUpNextQueue(2, 0);
      expect(playback.upNextQueue.map((t) => t.id), [
        tracks[3].id,
        tracks[1].id,
        tracks[2].id,
      ]);
      playback.moveUpNextQueue(0, 2);
      expect(playback.upNextQueue.map((t) => t.id), [
        tracks[1].id,
        tracks[2].id,
        tracks[3].id,
      ]);
    });

    test('an Up next entry can be played right away', () async {
      final tracks = await addTracks(4);
      await playback.playTrack(tracks[0], [tracks[0]]);
      for (final t in tracks.skip(1)) {
        await playback.addToUpNextQueue(t);
      }
      await playback.playUpNextAt(1);
      await settle();
      expect(playback.currentTrack!.id, tracks[2].id);
      expect(playback.upNextQueue.map((t) => t.id), [
        tracks[1].id,
        tracks[3].id,
      ]);
    });

    test('a deleted playlist leaves the queue and Up next', () async {
      final tracks = await addTracks(3);
      final other = await insertTestPlaylist(db, name: 'Other');
      final otherPath = '${dir.path}/other.m4a';
      await File(otherPath).writeAsString('other');
      final foreign = await insertTestTrack(
        db,
        playlistId: other.id,
        index: 1,
        videoId: 'other',
        title: 'other',
        status: 'complete',
        filePath: otherPath,
        durationSeconds: 60,
      );
      await playback.playTrack(tracks[0], tracks);
      await playback.addToUpNextQueue(foreign);
      await playback.addToUpNextQueue(tracks[2]);

      await playback.playlistRemoved(other.id);
      expect(playback.currentTrack!.id, tracks[0].id);
      expect(playback.upNextQueue.map((t) => t.id), [tracks[2].id]);
      expect(playback.queue.map((t) => t.playlistId).toSet(), {playlist.id});

      // The current song's playlist: playback stops.
      await playback.playlistRemoved(playlist.id);
      expect(playback.currentTrack, isNull);
      expect(playback.queue, isEmpty);
      expect(playback.upNextQueue, isEmpty);
    });

    test('removed tracks leave the queue and Up next', () async {
      final tracks = await addTracks(4);
      await playback.playTrack(tracks[0], tracks);
      await playback.addToUpNextQueue(tracks[3]);
      await playback.addToUpNextQueue(tracks[2]);

      await playback.tracksRemoved({tracks[1].id, tracks[3].id});
      expect(playback.currentTrack!.id, tracks[0].id);
      expect(playback.upNextQueue.map((t) => t.id), [tracks[2].id]);
      expect(
        playback.queue.map((t) => t.id),
        isNot(anyOf(contains(tracks[1].id), contains(tracks[3].id))),
      );

      // The current song: playback stops.
      await playback.tracksRemoved({tracks[0].id});
      expect(playback.currentTrack, isNull);
    });

    test('a deleted playlist does not come back with shuffle while a song '
        'from Up next plays', () async {
      final tracks = await addTracks(3);
      final other = await insertTestPlaylist(db, name: 'Other');
      final otherPath = '${dir.path}/other.m4a';
      await File(otherPath).writeAsString('other');
      final foreign = await insertTestTrack(
        db,
        playlistId: other.id,
        index: 1,
        videoId: 'other',
        title: 'other',
        status: 'complete',
        filePath: otherPath,
        durationSeconds: 60,
      );
      await playback.playTrack(tracks[0], tracks);
      await playback.addToUpNextQueue(foreign);
      await playback.next();
      await settle();
      expect(playback.currentTrack!.id, foreign.id);

      await playback.playlistRemoved(playlist.id);
      expect(playback.currentTrack!.id, foreign.id);
      expect(playback.queue.map((t) => t.id), [foreign.id]);
      expect(playback.queueIndex, 0);
      playback.setShuffleEnabled(true);
      await settle();
      expect(playback.queue.map((t) => t.id), [foreign.id]);
      playback.setShuffleEnabled(false);
      await settle();
      expect(playback.queue.map((t) => t.id), [foreign.id]);
    });

    test('playlist settings apply to songs that have not started', () async {
      final album = await addTrack('album', chapters: _threeChapters);
      final first = await addTrack('first');
      await db.updatePlaylistFields(
        playlist.id,
        const PlaylistsCompanion(playChapters: Value(true)),
      );
      await playback.playTrack(first, [album, first]);
      // Chapters are on: the album is three items in the queue.
      expect(playback.queue, hasLength(4));

      await db.updatePlaylistFields(
        playlist.id,
        const PlaylistsCompanion(playChapters: Value(false)),
      );
      await playback.playlistSettingsChanged(playlist.id);
      expect(playback.queue, hasLength(2));
      expect(playback.currentTrack!.id, first.id);
    });
  });

  group('files that do not play', () {
    test('a file the player refuses is skipped with a message', () async {
      final tracks = await addTracks(3);
      player.openFails = (media) => media.uri.contains('t1.m4a');
      await playback.playTrack(tracks[0], tracks);
      await playback.next();
      await settle();
      expect(playback.currentTrack!.id, tracks[2].id);
      expect(messages, ['Could not play "t1"']);
    });

    test('a tapped file the player refuses moves on to the next', () async {
      final tracks = await addTracks(2);
      player.openFails = (media) => media.uri.contains('t0.m4a');
      await playback.playTrack(tracks[0], tracks);
      await settle();
      expect(playback.currentTrack!.id, tracks[1].id);
      expect(messages, ['Could not play "t0"']);
    });

    test('a file that opens but never plays is skipped', () async {
      await playback.dispose();
      playback = await createPlayback(
        withPlayer: FakePlayer(duration: Duration.zero),
      );
      final tracks = await addTracks(2);
      await playback.playTrack(tracks[0], tracks);
      player.state = player.state.copyWith(position: Duration.zero);
      player.stream.errors.add('Failed to recognize file format.');
      await settle(PlaybackService.loadErrorGrace.inMilliseconds + 100);
      expect(playback.currentTrack!.id, tracks[1].id);
      expect(messages, ['Could not play "t0"']);
      await playback.stop();
    });

    test('a decode error in a file that plays changes nothing', () async {
      final tracks = await addTracks(2);
      await playback.playTrack(tracks[0], tracks);
      player.stream.errors.add('Error decoding audio.');
      await settle();
      expect(playback.currentTrack!.id, tracks[0].id);
      expect(messages, isEmpty);
    });
  });

  group('SponsorBlock at the end of a song', () {
    Future<Track> trackWithOutro() async {
      final track = await addTrack('song');
      await db.insertSegment(
        SponsorBlockSegmentsCompanion.insert(
          trackId: track.id,
          videoId: track.videoId,
          source: 'local',
          category: 'sponsor',
          startMs: 55000,
          endMs: 60000,
          createdAt: DateTime.now(),
        ),
      );
      return track;
    }

    test('Play after the cut restarts the song instead of pausing', () async {
      final track = await trackWithOutro();
      playback.setAutoplayEnabled(false);
      await playback.playTrack(track, [track]);
      player.tick(const Duration(seconds: 56));
      await settle();
      expect(player.state.playing, isFalse);

      await playback.resume();
      expect(player.seeks.last, Duration.zero);
      player.tick(const Duration(seconds: 1));
      await settle();
      expect(player.state.playing, isTrue);
    });

    test('the cut keeps audio focus and advances once', () async {
      final track = await trackWithOutro();
      final next = await addTrack('next');
      final after = await addTrack('after');
      await playback.playTrack(track, [track, next, after]);
      player.tick(const Duration(seconds: 56));
      await playback.next();
      await settle();
      expect(playback.currentTrack!.id, next.id);
      expect(session.activeChanges, [true]);
    });
  });

  group('chapters', () {
    setUp(() async {
      await db.updatePlaylistFields(
        playlist.id,
        const PlaylistsCompanion(playChapters: Value(true)),
      );
    });

    test(
      'a chapter of the playing file plays from the queue, which stays',
      () async {
        final album = await addTrack('album', chapters: _threeChapters);
        final after = await addTrack('after');
        final upNext = await addTrack('up');
        await playback.playTrack(album, [album, after]);
        await playback.addToUpNextQueue(upNext);
        expect(playback.currentItem!.chapter!.id, 'one');

        expect(
          await playback.playChapterOfCurrentFile(album.id, 'three'),
          isTrue,
        );
        expect(playback.currentItem!.chapter!.id, 'three');
        expect(player.opened.last.start, const Duration(seconds: 40));
        expect(playback.upNextQueue.map((t) => t.id), [upNext.id]);
        expect(playback.queue.map((t) => t.title), [
          'First song',
          'Second song',
          'Third song',
          'up',
          'after',
        ]);

        // The chapter skipped over counts as played.
        await playback.previous();
        await settle();
        expect(playback.currentItem!.chapter!.id, 'two');

        // Only for the file that is playing.
        final opened = player.opened.length;
        expect(
          await playback.playChapterOfCurrentFile(after.id, 'one'),
          isFalse,
        );
        expect(player.opened, hasLength(opened));
      },
    );

    test('continuing chapters change without reopening the file', () async {
      final album = await addTrack('album', chapters: _threeChapters);
      await playback.playTrack(album, [album]);
      expect(player.opened.single.end, const Duration(seconds: 60));
      player.tick(const Duration(seconds: 19));
      player.tick(const Duration(milliseconds: 20050));
      await settle();
      expect(playback.currentTrack!.title, 'Second song');
      expect(playback.position, const Duration(milliseconds: 50));
      expect(playback.duration, const Duration(seconds: 20));
      expect(player.opened, hasLength(1));
      expect(player.state.playing, isTrue);
    });

    test('with autoplay off playback stops at the chapter end', () async {
      final album = await addTrack('album', chapters: _threeChapters);
      await playback.playTrack(album, [album]);
      playback.setAutoplayEnabled(false);
      player.tick(const Duration(milliseconds: 20050));
      await settle();
      expect(playback.currentTrack!.title, 'First song');
      expect(player.state.playing, isFalse);
      expect(player.opened, hasLength(1));
    });

    test('editing chapters keeps the queue and the interrupted spot', () async {
      final tracks = await addTracks(3);
      final album = await addTrack('album', chapters: _threeChapters);
      await playback.playTrack(tracks[0], [...tracks, album]);
      player.tick(const Duration(seconds: 12));

      await playback.beginChapterEditing(album);
      expect(playback.currentTrack!.id, album.id);
      expect(playback.currentItem!.chapter, isNull);
      playback.endChapterEditing();

      await playback.next();
      expect(playback.currentTrack!.id, tracks[0].id);
      expect(
        player.opened.last.start,
        const Duration(seconds: 12),
        reason: 'the interrupted song continues where it was',
      );
      await playback.next();
      expect(playback.currentTrack!.id, tracks[1].id);
      expect(player.opened.last.start, isNull);
      await playback.previous();
      await playback.previous();
      expect(playback.currentTrack!.id, album.id);
    });

    test('editing a paused chapter keeps it paused', () async {
      final album = await addTrack('album', chapters: _threeChapters);
      await playback.playTrack(album, [album], chapterId: 'two');
      player.tick(const Duration(seconds: 25));
      await playback.pause();

      await playback.beginChapterEditing(album);
      expect(playback.currentItem!.chapter, isNull);
      expect(player.opened.last.start, const Duration(seconds: 25));
      expect(player.state.playing, isFalse);
      expect(playback.isPlaying, isFalse);
    });

    test(
      'a chapter whose file fails to reopen for editing stays current',
      () async {
        final album = await addTrack('album', chapters: _threeChapters);
        await playback.playTrack(album, [album], chapterId: 'two');
        player.tick(const Duration(seconds: 25));
        final queue = playback.queue;
        player.openFails = (media) => media.end == null;

        await expectLater(
          playback.beginChapterEditing(album),
          throwsA(isA<StateError>()),
        );
        expect(playback.currentItem!.chapter!.id, 'two');
        expect(playback.queue, queue);
        expect(playback.hasLoadedMedia, isFalse);
        expect(playback.position, const Duration(seconds: 5));

        player.openFails = null;
        await playback.resume();
        expect(player.opened.last.start, const Duration(seconds: 25));
        expect(playback.currentItem!.chapter!.id, 'two');
      },
    );

    test('a paused chapter opens for editing without audio focus', () async {
      final album = await addTrack('album', chapters: _threeChapters);
      await playback.playTrack(album, [album], chapterId: 'two');
      await playback.pause();
      session.grantFocus = false;
      await playback.beginChapterEditing(album);
      expect(playback.currentItem!.chapter, isNull);
      expect(player.state.playing, isFalse);
    });

    test('a file that will not open for editing starts nothing else', () async {
      final tracks = await addTracks(2);
      player.openFails = (media) => media.uri.contains('t0.m4a');

      await expectLater(
        playback.beginChapterEditing(tracks[0], tracks),
        throwsA(isA<StateError>()),
      );
      expect(player.opened, isEmpty);
      expect(playback.currentTrack, isNull);
      expect(playback.queue, isEmpty);
      expect(player.state.playing, isFalse);
    });

    test('editing the chapter that plays keeps the spot', () async {
      final album = await addTrack('album', chapters: _threeChapters);
      final next = await addTrack('next');
      await playback.playTrack(album, [album, next], chapterId: 'two');
      player.tick(const Duration(seconds: 25));

      await playback.beginChapterEditing(album);
      expect(playback.currentItem!.chapter, isNull);
      expect(player.opened.last.start, const Duration(seconds: 25));
      expect(player.opened.last.end, isNull);
      playback.endChapterEditing();

      await playback.next();
      expect(playback.currentTrack!.id, next.id);
    });

    test('editing the whole file that plays reloads nothing', () async {
      final album = await addTrack('album', chapters: _threeChapters);
      await playback.playTrack(album, [album], whole: true);
      await playback.beginChapterEditing(album);
      expect(player.opened, hasLength(1));
    });
  });

  group('remembered settings', () {
    test('shuffle, autoplay and the audio-only choice are saved', () async {
      final store = MemoryPlaybackSettingsStore();
      await playback.dispose();
      playback = await createPlayback(store: store);
      await settle();
      playback.setShuffleEnabled(true);
      playback.setAutoplayEnabled(false);
      await playback.toggleAudioOnlyMode();
      await settle();
      expect(store.preferences.shuffle, isTrue);
      expect(store.preferences.autoplay, isFalse);
      expect(store.preferences.audioOnly, isTrue);
    });

    test('temporary audio-only is neither saved nor kept', () async {
      final store = MemoryPlaybackSettingsStore();
      await playback.dispose();
      playback = await createPlayback(store: store);
      await playback.enableTemporaryAudioOnly();
      expect(playback.audioOnlyMode, isTrue);
      await playback.restoreTemporaryAudioOnly();
      expect(playback.audioOnlyMode, isFalse);
      expect(store.preferences.audioOnly, isNull);

      await playback.setAudioOnlyPreference(true);
      await playback.enableTemporaryAudioOnly();
      await playback.restoreTemporaryAudioOnly();
      expect(playback.audioOnlyMode, isTrue, reason: 'the user chose it');
    });

    test('the last song comes back paused where it was', () async {
      final tracks = await addTracks(3);
      final store = MemoryPlaybackSettingsStore();
      await playback.dispose();
      playback = await createPlayback(store: store);
      await playback.playTrack(tracks[1], tracks);
      player.tick(const Duration(seconds: 42));
      await playback.pause();
      await settle();
      expect(store.preferences.session?.positionMs, 42000);
      await playback.dispose();
      session.activeChanges.clear();

      playback = await createPlayback(store: store);
      await settle();
      expect(playback.currentTrack!.id, tracks[1].id);
      expect(playback.hasLoadedMedia, isFalse);
      expect(playback.position, const Duration(seconds: 42));
      expect(playback.queueIndex, 1);
      expect(player.opened, isEmpty);
      expect(session.activeChanges, isEmpty, reason: 'no focus at start-up');

      await playback.resume();
      expect(player.opened.single.start, const Duration(seconds: 42));
      expect(playback.hasLoadedMedia, isTrue);
    });

    test('Play while the last song is still being restored opens it', () async {
      final tracks = await addTracks(2);
      final store = MemoryPlaybackSettingsStore();
      await playback.dispose();
      playback = await createPlayback(store: store);
      await playback.playTrack(tracks[1], tracks);
      player.tick(const Duration(seconds: 30));
      await playback.pause();
      await settle();
      await playback.dispose();

      final gate = Completer<void>();
      playback = await createPlayback(store: _GatedStore(store, gate.future));
      final play = playback.resume();
      await settle();
      expect(player.opened, isEmpty);
      gate.complete();
      await play;
      expect(playback.currentTrack!.id, tracks[1].id);
      expect(player.opened.single.start, const Duration(seconds: 30));
      expect(player.state.playing, isTrue);
    });

    test('an explicit stop forgets the last song', () async {
      final track = await addTrack('song');
      final store = MemoryPlaybackSettingsStore();
      await playback.dispose();
      playback = await createPlayback(store: store);
      await playback.playTrack(track, [track]);
      await playback.stop();
      await settle();
      expect(store.preferences.session, isNull);
    });
  });

  test(
    'an audio-only file in a video container is not shown as video',
    () async {
      final path = '${dir.path}/clip.mp4';
      await File(path).writeAsString('clip');
      final clip = await insertTestTrack(
        db,
        playlistId: playlist.id,
        videoId: 'clip',
        title: 'clip',
        status: 'complete',
        filePath: path,
      );
      await playback.playTrack(clip, [clip]);
      expect(playback.isVideoContent, isTrue, reason: 'guessed from .mp4');

      player.stream.trackLists.add(
        kit.Tracks(
          video: [kit.VideoTrack.auto(), kit.VideoTrack.no()],
          audio: [kit.AudioTrack.auto(), kit.AudioTrack('1', null, null)],
        ),
      );
      expect(playback.isVideoContent, isFalse);
    },
  );
}
