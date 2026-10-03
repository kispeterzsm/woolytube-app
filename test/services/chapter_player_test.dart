import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/audio_handler.dart';
import 'package:woolytube/services/playback_service.dart';
import '../helpers/test_database.dart';
import 'playback_fakes.dart';

void main() {
  late AppDatabase db;
  late Directory dir;
  late FakePlayer player;
  late PlaybackService playback;
  late Track track;
  late Playlist playlist;
  setUp(() async {
    db = openTestDatabase();
    dir = await Directory.systemTemp.createTemp('woolytube-chapter-player-');
    final file = await File('${dir.path}/album.m4a').writeAsString('unchanged');
    playlist = await insertTestPlaylist(db);
    await db.updatePlaylist(
      playlist.copyWith(playChapters: const Value(true)).toCompanion(true),
    );
    track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      status: 'complete',
      filePath: file.path,
      durationSeconds: 60,
    );
    await db.writeTrackChapters(
      track.id,
      const ChapterData(
        downloaded: [
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
            endMs: 40000,
          ),
          MediaChapter(
            id: 'three',
            title: 'Third song',
            startMs: 40000,
            endMs: 60000,
          ),
        ],
      ),
    );
    track = (await db.getTrack(track.id))!;
    player = FakePlayer();
    playback = PlaybackService(db, player: player);
  });
  tearDown(() async {
    await playback.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'bounded opens, relative seeks, restart, and whole-file restoration',
    () async {
      await playback.playTrack(track, [track], chapterId: 'two');
      expect(player.opened.single.start, const Duration(seconds: 20));
      expect(player.opened.single.end, const Duration(seconds: 40));
      expect(playback.currentTrack!.title, 'Second song');
      expect(playback.currentMediaId, contains('two'));
      expect(playback.duration, const Duration(seconds: 20));
      expect(playback.position, Duration.zero);
      await playback.seekTo(const Duration(seconds: 7));
      expect(player.seeks.last, const Duration(seconds: 27));
      await playback.previous();
      expect(player.seeks.last, const Duration(seconds: 20));
      await playback.playTrack(track, [track], whole: true);
      expect(player.opened.last.start, isNull);
      expect(player.opened.last.end, isNull);
      expect(playback.duration, const Duration(seconds: 60));
    },
  );

  test(
    'duplicate completion advances exactly once and autoplay off holds chapter',
    () async {
      await playback.playTrack(track, [track]);
      player.finish();
      player.finish();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(player.opened, hasLength(2));
      expect(playback.currentTrack!.title, 'Second song');
      playback.setAutoplayEnabled(false);
      player.finish();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(player.opened, hasLength(2));
      playback.setAutoplayEnabled(true);
      await playback.resume();
      player.finish();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(player.opened, hasLength(3));
    },
  );

  test(
    'SponsorBlock display intersects chapter and a skip cannot cross its end',
    () async {
      await db.insertSegment(
        SponsorBlockSegmentsCompanion.insert(
          trackId: track.id,
          videoId: track.videoId,
          source: 'local',
          category: 'sponsor',
          startMs: 38000,
          endMs: 45000,
          createdAt: DateTime.now(),
        ),
      );
      playback.setAutoplayEnabled(false);
      await playback.playTrack(track, [track], chapterId: 'two');
      final segment = playback.sponsorBlockSegments.single;
      expect(segment.startMs, 18000);
      expect(segment.endMs, 20000);
      player.tick(const Duration(seconds: 39));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(player.state.playing, isFalse);
      expect(player.seeks, isEmpty);
      expect(player.opened, hasLength(1));
    },
  );

  test(
    'default playback starts the first chapter with its own progress',
    () async {
      await db.updatePlaylist(
        playlist.copyWith(playChapters: const Value(null)).toCompanion(true),
      );
      playback.setShuffleEnabled(true);
      await playback.playTrack(track, [track]);
      expect(playback.currentTrack!.title, 'First song');
      expect(playback.duration, const Duration(seconds: 20));
      player.tick(const Duration(seconds: 7));
      expect(playback.position, const Duration(seconds: 7));
      await playback.next();
      expect(playback.currentTrack!.title, 'Second song');
      expect(playback.position, Duration.zero);
    },
  );

  test(
    'notification next chapter and next file open the correct media',
    () async {
      final nextFile = await File('${dir.path}/next.m4a').writeAsString('next');
      final next = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'next',
        title: 'Next file',
        status: 'complete',
        filePath: nextFile.path,
      );
      final handler = WoolyTubeAudioHandler(playback, db);
      addTearDown(handler.dispose);
      await playback.playTrack(track, [track, next]);
      await Future<void>.delayed(Duration.zero);
      expect(handler.mediaItem.value!.title, 'First song');
      expect(handler.mediaItem.value!.duration, const Duration(seconds: 20));
      final controls = handler.playbackState.value.controls;
      expect(controls[3].label, 'Next file');
      expect(controls[3].androidIcon, 'drawable/ic_next_file');
      await handler.skipToNext();
      await handler.seek(const Duration(seconds: 5));
      expect(playback.currentTrack!.title, 'Second song');
      expect(player.seeks.last, const Duration(seconds: 25));
      await handler.customAction(controls[3].customAction!.name);
      await Future<void>.delayed(Duration.zero);
      expect(playback.currentTrack!.id, next.id);
      expect(player.opened, hasLength(3));
      expect(player.opened.last.start, isNull);
      expect(handler.mediaItem.value!.title, 'Next file');
      expect(handler.playbackState.value.controls, hasLength(4));
      expect(
        handler.playbackState.value.controls.any(
          (control) => control.customAction?.name == 'nextFile',
        ),
        isFalse,
      );
    },
  );

  test('next file at the end pauses and discards remaining chapters', () async {
    await playback.playTrack(track, [track]);
    await playback.nextFile();
    expect(player.state.playing, isFalse);
    await playback.next();
    expect(player.opened, hasLength(1));
  });

  test('a replaced source cannot reuse queued chapter bounds', () async {
    await playback.playTrack(track, [track]);
    await db.invalidateTrackChapters(track.id);
    await playback.next();
    expect(player.opened, hasLength(1));
  });
}
