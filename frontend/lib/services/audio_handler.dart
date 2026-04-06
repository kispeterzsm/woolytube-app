import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:rxdart/rxdart.dart';
import 'playback_service.dart';

class WoolyTubeAudioHandler extends BaseAudioHandler with SeekHandler {
  final PlaybackService _playbackService;
  final List<StreamSubscription> _subscriptions = [];

  WoolyTubeAudioHandler(this._playbackService) {
    // Sync playing state to notification
    _subscriptions.add(
      _playbackService.isPlayingStream.listen((playing) {
        _broadcastState();
      }),
    );

    // Sync current track to notification media item
    _subscriptions.add(
      _playbackService.currentTrackStream.listen((track) {
        if (track == null) {
          mediaItem.add(null);
          _broadcastState();
          return;
        }
        mediaItem.add(MediaItem(
          id: track.id.toString(),
          title: track.title,
          duration: track.durationSeconds != null
              ? Duration(seconds: track.durationSeconds!)
              : null,
          artUri: track.thumbnailUrl != null && track.thumbnailUrl!.isNotEmpty
              ? Uri.parse(track.thumbnailUrl!)
              : null,
        ));
        _broadcastState();
      }),
    );

    // Update position in notification periodically (throttled to 1/sec)
    _subscriptions.add(
      _playbackService.positionStream
          .throttleTime(const Duration(seconds: 1))
          .listen((_) {
        _broadcastState();
      }),
    );

    // Sync duration when it becomes available
    _subscriptions.add(
      _playbackService.durationStream.listen((duration) {
        final current = mediaItem.value;
        if (current != null && duration > Duration.zero) {
          mediaItem.add(current.copyWith(duration: duration));
        }
      }),
    );
  }

  void _broadcastState() {
    final playing = _playbackService.isPlaying;
    final currentTrack = _playbackService.currentTrack;

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: currentTrack != null
          ? AudioProcessingState.ready
          : AudioProcessingState.idle,
      playing: playing,
      updatePosition: _playbackService.position,
      speed: 1.0,
    ));
  }

  @override
  Future<void> play() async => await _playbackService.resume();

  @override
  Future<void> pause() async => await _playbackService.pause();

  @override
  Future<void> stop() async {
    await _playbackService.stop();
    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    await super.stop();
  }

  @override
  Future<void> skipToNext() async => _playbackService.next();

  @override
  Future<void> skipToPrevious() async => _playbackService.previous();

  @override
  Future<void> seek(Duration position) async =>
      await _playbackService.seekTo(position);

  @override
  Future<void> onTaskRemoved() async {
    // Keep playing when task is removed (user swipes away from recents)
    // Only stop if nothing is playing
    if (!_playbackService.isPlaying) {
      await _playbackService.stop();
      await super.onTaskRemoved();
    }
  }

  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
  }
}
