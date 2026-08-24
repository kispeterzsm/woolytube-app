import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/audio_handler.dart';
import 'package:woolytube/services/playback_notification_controller.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Playlist playlist;
  late Track track;
  late _FakePlaybackController playback;
  late WoolyTubeAudioHandler handler;

  setUp(() async {
    db = openTestDatabase();
    playlist = await insertTestPlaylist(db);
    track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      videoId: 'fallback-video-id',
      status: 'complete',
      filePath: '/tmp/track.m4a',
    );
    playback = _FakePlaybackController(track);
    handler = WoolyTubeAudioHandler(
      playback,
      db,
      mediaButtonDoubleClickInterval: const Duration(milliseconds: 20),
    );
    await _flushStreams();
  });

  tearDown(() async {
    handler.dispose();
    await playback.dispose();
    await db.close();
  });

  test('publishes working media actions without a stop control', () async {
    final state = handler.playbackState.value;

    expect(state.controls.map((control) => control.action), [
      MediaAction.skipToPrevious,
      MediaAction.play,
      MediaAction.skipToNext,
      MediaAction.custom,
    ]);
    expect(
      state.controls.any((control) => control.action == MediaAction.stop),
      isFalse,
    );
    expect(state.androidCompactActionIndices, [0, 1, 2]);
    expect(state.processingState, AudioProcessingState.ready);

    await handler.play();
    await handler.pause();
    await handler.skipToNext();
    await handler.skipToPrevious();
    await handler.seek(const Duration(seconds: 42));

    expect(playback.resumeCalls, 1);
    expect(playback.pauseCalls, 1);
    expect(playback.nextCalls, 1);
    expect(playback.previousCalls, 1);
    expect(playback.seekPositions, [const Duration(seconds: 42)]);
  });

  test('routes next and previous media-button callbacks to playback', () async {
    await handler.click(MediaButton.next);
    await handler.click(MediaButton.previous);

    expect(playback.nextCalls, 1);
    expect(playback.previousCalls, 1);
  });

  test('a single headset-button click toggles playback', () async {
    await handler.click(MediaButton.media);
    expect(playback.resumeCalls, 0);

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(playback.resumeCalls, 1);

    playback.setPlaying(true);
    await _flushStreams();
    await handler.click(MediaButton.media);
    expect(playback.pauseCalls, 0);

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(playback.pauseCalls, 1);
  });

  test('a double headset-button click skips to the next track', () async {
    await handler.click(MediaButton.media);
    await handler.click(MediaButton.media);

    expect(playback.nextCalls, 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(playback.resumeCalls, 0);
    expect(playback.pauseCalls, 0);
  });

  test('stopping cancels a pending headset-button click', () async {
    await handler.click(MediaButton.media);
    await handler.stop();

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(playback.resumeCalls, 0);
  });

  test('shuffle control updates both its action and system state', () async {
    final offControl = handler.playbackState.value.controls.last;
    expect(offControl.customAction?.name, 'toggleShuffle');
    expect(offControl.label, 'Shuffle on');
    expect(
      handler.playbackState.value.shuffleMode,
      AudioServiceShuffleMode.none,
    );

    await handler.customAction('toggleShuffle');
    await _flushStreams();

    final onState = handler.playbackState.value;
    expect(onState.controls.last.customAction?.name, 'toggleShuffle');
    expect(onState.controls.last.label, 'Shuffle off');
    expect(onState.shuffleMode, AudioServiceShuffleMode.all);
  });

  test(
    'updates notification artwork whenever the current track changes',
    () async {
      expect(
        handler.mediaItem.value?.artUri,
        Uri.parse('https://i.ytimg.com/vi/fallback-video-id/hqdefault.jpg'),
      );

      final nextTrack = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'next-video-id',
        title: 'Next track',
        thumbnailUrl: 'https://example.com/next-thumbnail.jpg',
        status: 'complete',
        filePath: '/tmp/next.m4a',
      );
      playback.setCurrentTrack(nextTrack);
      await _flushStreams();

      expect(handler.mediaItem.value?.id, nextTrack.id.toString());
      expect(
        handler.mediaItem.value?.artUri,
        Uri.parse('https://example.com/next-thumbnail.jpg'),
      );
    },
  );

  test(
    'prefers a downloaded thumbnail and falls back from a bad URL',
    () async {
      final temp = await Directory.systemTemp.createTemp('woolytube-art-test-');
      addTearDown(() => temp.delete(recursive: true));
      final thumbnail = File('${temp.path}/thumbnail.jpg');
      await thumbnail.writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);

      playback.setCurrentTrack(
        track.copyWith(
          thumbnailPath: Value(thumbnail.path),
          thumbnailUrl: const Value('https://example.com/remote.jpg'),
        ),
      );
      await _flushStreams();
      expect(handler.mediaItem.value?.artUri, Uri.file(thumbnail.path));

      playback.setCurrentTrack(
        track.copyWith(
          videoId: 'safe-fallback',
          thumbnailPath: const Value('/missing/thumbnail.jpg'),
          thumbnailUrl: const Value('not a web URL'),
        ),
      );
      await _flushStreams();
      expect(
        handler.mediaItem.value?.artUri,
        Uri.parse('https://i.ytimg.com/vi/safe-fallback/hqdefault.jpg'),
      );

      playback.setCurrentTrack(
        track.copyWith(
          videoId: 'force-insert:123',
          thumbnailPath: const Value(null),
          thumbnailUrl: const Value(null),
        ),
      );
      await _flushStreams();
      expect(handler.mediaItem.value?.artUri, null);
    },
  );
}

Future<void> _flushStreams() => Future<void>.delayed(Duration.zero);

class _FakePlaybackController implements PlaybackNotificationController {
  final BehaviorSubject<Track?> _currentTrack;
  final BehaviorSubject<bool> _playing = BehaviorSubject.seeded(false);
  final BehaviorSubject<Duration> _position = BehaviorSubject.seeded(
    Duration.zero,
  );
  final BehaviorSubject<Duration> _duration = BehaviorSubject.seeded(
    Duration.zero,
  );
  final BehaviorSubject<bool> _shuffle = BehaviorSubject.seeded(false);

  int resumeCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  int toggleShuffleCalls = 0;
  final List<Duration> seekPositions = [];
  bool audioOnlyMode = false;
  Track? playedTrack;
  List<Track>? playedQueue;
  Playlist? playedPlaylist;

  _FakePlaybackController(Track track)
    : _currentTrack = BehaviorSubject.seeded(track);

  @override
  Stream<Track?> get currentTrackStream => _currentTrack.stream;

  @override
  Stream<bool> get isPlayingStream => _playing.stream;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Stream<bool> get shuffleEnabledStream => _shuffle.stream;

  @override
  Track? get currentTrack => _currentTrack.value;

  @override
  bool get isPlaying => _playing.value;

  @override
  Duration get position => _position.value;

  @override
  bool get shuffleEnabled => _shuffle.value;

  void setCurrentTrack(Track? track) => _currentTrack.add(track);

  void setPlaying(bool playing) => _playing.add(playing);

  @override
  Future<void> resume() async {
    resumeCalls++;
    setPlaying(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    setPlaying(false);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    setPlaying(false);
    setCurrentTrack(null);
  }

  @override
  Future<void> next() async {
    nextCalls++;
  }

  @override
  Future<void> previous() async {
    previousCalls++;
  }

  @override
  Future<void> seekTo(Duration position) async {
    seekPositions.add(position);
    _position.add(position);
  }

  @override
  void toggleShuffle() {
    toggleShuffleCalls++;
    _shuffle.add(!_shuffle.value);
  }

  @override
  Future<void> setAudioOnlyMode(bool enabled) async {
    audioOnlyMode = enabled;
  }

  @override
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
  }) async {
    playedTrack = track;
    playedQueue = allTracks;
    playedPlaylist = playlist;
  }

  Future<void> dispose() async {
    await _currentTrack.close();
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _shuffle.close();
  }
}
