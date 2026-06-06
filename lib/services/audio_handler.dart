import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:rxdart/rxdart.dart';
import '../database/database.dart';
import 'playback_service.dart';

class WoolyTubeAudioHandler extends BaseAudioHandler with SeekHandler {
  final PlaybackService _playbackService;
  final AppDatabase _db;
  final List<StreamSubscription> _subscriptions = [];

  WoolyTubeAudioHandler(this._playbackService, this._db) {
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
          artUri: _resolveArt(track.thumbnailPath, track.thumbnailUrl),
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

    // Sync shuffle state to notification button
    _subscriptions.add(
      _playbackService.shuffleEnabledStream.listen((_) {
        _broadcastState();
      }),
    );
  }

  static final _shuffleOnControl = MediaControl.custom(
    androidIcon: 'drawable/ic_shuffle_on',
    label: 'Shuffle off',
    name: 'toggleShuffle',
  );

  static final _shuffleOffControl = MediaControl.custom(
    androidIcon: 'drawable/ic_shuffle_off',
    label: 'Shuffle on',
    name: 'toggleShuffle',
  );

  void _broadcastState() {
    final playing = _playbackService.isPlaying;
    final currentTrack = _playbackService.currentTrack;
    final shuffleOn = _playbackService.shuffleEnabled;

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
        shuffleOn ? _shuffleOnControl : _shuffleOffControl,
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

  Uri? _resolveArt(String? localPath, String? remoteUrl) {
    if (localPath != null &&
        localPath.isNotEmpty &&
        File(localPath).existsSync()) {
      return Uri.file(localPath);
    }
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      return Uri.parse(remoteUrl);
    }
    return null;
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    if (parentMediaId == AudioService.browsableRootId) {
      final playlists = await _db.getAllPlaylists();
      return [
        for (final p in playlists)
          MediaItem(
            id: 'playlist:${p.id}',
            title: p.name,
            playable: false,
            artUri: _resolveArt(p.thumbnailPath, p.thumbnailUrl),
          ),
      ];
    }
    if (parentMediaId.startsWith('playlist:')) {
      final playlistId =
          int.parse(parentMediaId.substring('playlist:'.length));
      final tracks = await _db.getTracksForPlaylist(playlistId);
      return [
        for (final t in tracks)
          if (t.status == 'complete' && t.filePath != null)
            MediaItem(
              id: 'track:${t.id}:$playlistId',
              title: t.title,
              duration: t.durationSeconds != null
                  ? Duration(seconds: t.durationSeconds!)
                  : null,
              playable: true,
              artUri: _resolveArt(t.thumbnailPath, t.thumbnailUrl),
            ),
      ];
    }
    return const [];
  }

  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    if (!mediaId.startsWith('track:')) return;
    final parts = mediaId.split(':');
    if (parts.length < 3) return;
    final trackId = int.tryParse(parts[1]);
    final playlistId = int.tryParse(parts[2]);
    if (trackId == null || playlistId == null) return;

    final playlist = await _db.getPlaylist(playlistId);
    final tracks = await _db.getTracksForPlaylist(playlistId);
    final track = tracks.where((t) => t.id == trackId).firstOrNull;
    if (track == null) return;

    // Force audio-only when launched from the car so libmpv doesn't allocate
    // a video surface that has no rendering target.
    _playbackService.setAudioOnlyMode(true);
    await _playbackService.playTrack(track, tracks, playlist: playlist);
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
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    if (name == 'toggleShuffle') {
      _playbackService.toggleShuffle();
      return;
    }
    return super.customAction(name, extras);
  }

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
