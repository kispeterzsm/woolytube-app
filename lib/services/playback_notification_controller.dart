import '../database/database.dart';

/// The playback surface used by the system media notification.
///
/// Keeping this contract separate from the native player makes the notification
/// action wiring testable without starting libmpv.
abstract interface class PlaybackNotificationController {
  Stream<Track?> get currentTrackStream;
  Stream<bool> get isPlayingStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get shuffleEnabledStream;

  Track? get currentTrack;
  bool get isPlaying;
  Duration get position;
  bool get shuffleEnabled;

  Future<void> resume();
  Future<void> pause();
  Future<void> stop();
  Future<void> next();
  Future<void> previous();
  Future<void> seekTo(Duration position);
  void toggleShuffle();
  void setAudioOnlyMode(bool enabled);
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
  });
}
