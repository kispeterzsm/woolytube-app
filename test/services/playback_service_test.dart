import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/audio_focus_controller.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/playback_service.dart';

import '../helpers/test_database.dart';
import 'playback_fakes.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = openTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  test('automatic playback filters always-skipped tracks', () async {
    final playlist = await insertTestPlaylist(db);
    final playable = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'playable',
      status: 'complete',
      filePath: '/tmp/playable.m4a',
    );
    final skipped = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'skip-me',
      status: 'complete',
      filePath: '/tmp/skip-me.m4a',
      alwaysSkip: true,
    );
    final pending = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 3,
      videoId: 'pending',
    );

    final automatic = playableTracksForPlayback([playable, skipped, pending]);

    expect(automatic.map((track) => track.id), [playable.id]);
    expect(isTrackAutomaticallyPlayable(skipped), isFalse);
  });

  test('a direct tap may play its own always-skipped track', () async {
    final playlist = await insertTestPlaylist(db);
    final selected = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'selected',
      status: 'complete',
      filePath: '/tmp/selected.m4a',
      alwaysSkip: true,
    );
    final otherSkipped = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'other-skipped',
      status: 'complete',
      filePath: '/tmp/other-skipped.m4a',
      alwaysSkip: true,
    );
    final playable = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 3,
      videoId: 'playable',
      status: 'complete',
      filePath: '/tmp/playable.m4a',
    );

    final direct = playableTracksForPlayback([
      selected,
      otherSkipped,
      playable,
    ], directlySelectedTrackId: selected.id);

    expect(direct.map((track) => track.id), [selected.id, playable.id]);
  });

  group('PlaybackService', () {
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
      String extension = 'm4a',
      ChapterData? chapters,
    }) async {
      final path = '${dir.path}/$name.$extension';
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

    const threeChapters = ChapterData(
      downloaded: [
        MediaChapter(id: 'one', title: 'First song', startMs: 0, endMs: 20000),
        MediaChapter(
          id: 'two',
          title: 'Second song',
          startMs: 20000,
          endMs: 40000,
        ),
        MediaChapter(
          id: 'three',
          title: 'Third song',
          startMs: 40000,
          endMs: 60000,
        ),
      ],
    );

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 30));

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('woolytube-playback-');
      playlist = await insertTestPlaylist(db);
      nextIndex = 1;
      player = FakePlayer();
      session = FakeAudioSession();
      messages = [];
      playback = PlaybackService(db, player: player);
      playback.messages.listen(messages.add);
      await playback.initializeAudioFocus(
        pauseOnAudioInterruption: true,
        audioSession: session,
      );
    });

    tearDown(() async {
      await playback.dispose();
      await session.dispose();
      await dir.delete(recursive: true);
    });

    test('a tapped track with a missing file keeps current playback', () async {
      final playing = await addTrack('playing');
      final missing = await addTrack('missing', fileExists: false);
      await playback.playTrack(playing, [playing, missing]);
      await playback.playTrack(missing, [playing, missing]);
      await settle();

      expect(playback.currentTrack!.id, playing.id);
      expect(playback.queue.map((t) => t.id), [playing.id, missing.id]);
      expect(playback.queueIndex, 0);
      expect(player.opened, hasLength(1));
      expect(player.state.playing, isTrue);
      expect(messages, ['File not found: missing']);
    });

    test('playing a list without playable tracks is a no-op', () async {
      final playing = await addTrack('playing');
      final pending = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 50,
        videoId: 'pending',
      );
      await playback.playTrack(playing, [playing]);
      await playback.playAll([pending]);
      await settle();

      expect(playback.currentTrack!.id, playing.id);
      expect(playback.queue.map((t) => t.id), [playing.id]);
      expect(player.state.playing, isTrue);
      expect(messages, ['Nothing to play']);
    });

    test('automatic advancement skips missing files and says so', () async {
      final first = await addTrack('first');
      final missing = await addTrack('missing', fileExists: false);
      final third = await addTrack('third');
      await playback.playAll([first, missing, third]);
      await playback.next();
      await settle();

      expect(playback.currentTrack!.id, third.id);
      expect(player.opened, hasLength(2));
      expect(messages, ['Skipped "missing": file not found']);
    });

    test('denied audio focus leaves everything untouched', () async {
      final track = await addTrack('track');
      session.grantFocus = false;
      await playback.playTrack(track, [track]);
      await settle();

      expect(playback.currentTrack, isNull);
      expect(playback.queue, isEmpty);
      expect(player.opened, isEmpty);
      expect(messages, ['Another app is using audio']);

      session.grantFocus = true;
      await playback.playTrack(track, [track]);
      expect(playback.currentTrack!.id, track.id);
      expect(session.activeChanges, [true]);
    });

    test('resume after stop neither takes focus nor plays', () async {
      final track = await addTrack('track');
      await playback.playTrack(track, [track]);
      await playback.stop();
      session.activeChanges.clear();

      await playback.resume();
      await playback.togglePlayPause();

      expect(player.plays, 0);
      expect(session.activeChanges, isEmpty);
      expect(playback.currentTrack, isNull);
    });

    test('transient focus loss pauses and resumes the player', () async {
      final track = await addTrack('track');
      await playback.playTrack(track, [track]);
      expect(player.state.playing, isTrue);

      session.interrupt(begin: true, type: AudioInterruptionType.pause);
      await settle();
      expect(player.state.playing, isFalse);
      expect(session.activeChanges, [true], reason: 'focus is kept');

      session.interrupt(begin: false, type: AudioInterruptionType.pause);
      await settle();
      expect(player.state.playing, isTrue);
      expect(player.plays, 1);
    });

    test('skipping re-arms after a near-end segment pauses playback', () async {
      final track = await addTrack('track');
      for (final range in const [(5000, 8000), (56000, 60000)]) {
        await db.insertSegment(
          SponsorBlockSegmentsCompanion.insert(
            trackId: track.id,
            videoId: track.videoId,
            source: 'local',
            category: 'sponsor',
            startMs: range.$1,
            endMs: range.$2,
            createdAt: DateTime.now(),
          ),
        );
      }
      playback.setAutoplayEnabled(false);
      await playback.playTrack(track, [track]);

      player.tick(const Duration(seconds: 57));
      await settle();
      expect(player.state.playing, isFalse);
      expect(player.seeks, isEmpty);

      await playback.seekTo(Duration.zero);
      await playback.resume();
      player.tick(const Duration(seconds: 6));
      await settle();
      expect(player.seeks.last, const Duration(milliseconds: 8250));
    });

    test('a sleep timer that fires mid-load still pauses', () async {
      final track = await addTrack('track');
      playback.startSleepTimer(const Duration(milliseconds: 20));
      player.openGate = Completer<void>();
      final loading = playback.playTrack(track, [track]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(playback.sleepTimerRemaining, isNull);

      player.openGate!.complete();
      player.openGate = null;
      await loading;
      await settle();

      expect(player.opened, hasLength(1));
      expect(player.state.playing, isFalse);
    });

    test('completion followed by an immediate next advances once', () async {
      final track = await addTrack('album', chapters: threeChapters);
      await playback.playTrack(track, [track]);

      player.finish();
      await playback.next();
      await settle();

      expect(playback.currentTrack!.title, 'Second song');
      expect(player.opened, hasLength(2));
    });

    test('previous at the first item restarts it', () async {
      final track = await addTrack('album', chapters: threeChapters);
      await playback.playTrack(track, [track], chapterId: 'two');
      player.tick(const Duration(seconds: 21));
      expect(playback.position, const Duration(seconds: 1));

      await playback.previous();

      expect(playback.currentTrack!.title, 'Second song');
      expect(player.seeks.last, const Duration(seconds: 20));
      expect(playback.position, Duration.zero);
    });

    test(
      'advancing uses the current chapter bounds and skips removed ones',
      () async {
        final track = await addTrack('album', chapters: threeChapters);
        await playback.playTrack(track, [track]);

        await db.writeTrackChapters(
          track.id,
          threeChapters.withCustom(const [
            MediaChapter(
              id: 'one',
              title: 'First song',
              startMs: 0,
              endMs: 20000,
            ),
            MediaChapter(
              id: 'two',
              title: 'Second song',
              startMs: 20000,
              endMs: 30000,
            ),
            MediaChapter(
              id: 'three',
              title: 'Third song',
              startMs: 30000,
              endMs: 60000,
            ),
          ]),
        );
        await playback.next();
        expect(playback.currentTrack!.title, 'Second song');
        expect(player.opened.last.end, const Duration(seconds: 30));
        expect(playback.duration, const Duration(seconds: 10));

        await db.writeTrackChapters(
          track.id,
          threeChapters.withCustom(const [
            MediaChapter(
              id: 'one',
              title: 'First song',
              startMs: 0,
              endMs: 20000,
            ),
            MediaChapter(
              id: 'two',
              title: 'Second song',
              startMs: 20000,
              endMs: 30000,
            ),
          ]),
        );
        await playback.next();
        expect(playback.currentTrack!.title, 'Second song');
        expect(player.opened, hasLength(2));
      },
    );

    test(
      'video detection follows the loaded file and clears on stop',
      () async {
        final video = await addTrack('clip', extension: 'mp4');
        final audio = await addTrack('song');
        final seen = <bool>[];
        final subscription = playback.isVideoContentStream.listen(seen.add);
        addTearDown(subscription.cancel);

        await playback.playTrack(video, [video, audio]);
        expect(playback.isVideoContent, isTrue);
        await playback.next();
        expect(playback.isVideoContent, isFalse);
        await playback.stop();
        await settle();

        expect(playback.isVideoContent, isFalse);
        expect(seen, [false, true, false, false]);
      },
    );
  });
}
