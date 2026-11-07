import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show SubtitleTrack;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../services/chapter_playback.dart';
import '../services/playback_service.dart';
import '../services/audio_handler.dart';
import '../services/picture_in_picture_service.dart';

// These are overridden in main() with real instances
final playbackServiceProvider = Provider<PlaybackService>((ref) {
  throw UnimplementedError('Must be overridden');
});

final audioHandlerProvider = Provider<WoolyTubeAudioHandler>((ref) {
  throw UnimplementedError('Must be overridden');
});

final pictureInPictureServiceProvider = Provider<PictureInPictureService>((
  ref,
) {
  throw UnimplementedError('Must be overridden');
});

final isInPictureInPictureProvider = StreamProvider<bool>((ref) {
  return ref.watch(pictureInPictureServiceProvider).modeStream;
});

final currentTrackProvider = StreamProvider<Track?>((ref) {
  return ref.watch(playbackServiceProvider).currentTrackStream;
});

final currentPlaylistProvider = StreamProvider<Playlist?>((ref) {
  return ref.watch(playbackServiceProvider).currentPlaylistStream;
});

final isPlayingProvider = StreamProvider<bool>((ref) {
  return _seededPlayingStream(ref.watch(playbackServiceProvider));
});

/// media_kit's `playing` stream does not replay its last value, so a listener
/// that subscribes after playback started would otherwise show 'Play' while
/// audio is playing until the next state change.
Stream<bool> _seededPlayingStream(PlaybackService service) async* {
  yield service.isPlaying;
  yield* service.isPlayingStream;
}

/// Playback position at UI rate.
///
/// libmpv reports the position once per audio buffer or video frame. Widgets
/// only need about five updates a second, so this drops updates that stay in
/// the same 200 ms bucket. Seeks and track loads land in a new bucket and
/// still show immediately. `PlaybackService.position` stays exact for code
/// that needs the precise value (seeking by 10 s, the notification).
final positionProvider = StreamProvider<Duration>((ref) {
  return ref
      .watch(playbackServiceProvider)
      .positionStream
      .distinct((a, b) => a.inMilliseconds ~/ 200 == b.inMilliseconds ~/ 200);
});

/// Whole seconds of [positionProvider], for clock labels that only need to
/// rebuild once a second.
final positionSecondsProvider = Provider<int>((ref) {
  return ref.watch(
    positionProvider.select((value) => value.valueOrNull?.inSeconds ?? 0),
  );
});

final durationProvider = StreamProvider<Duration>((ref) {
  return ref.watch(playbackServiceProvider).durationStream;
});

final isVideoContentProvider = StreamProvider<bool>((ref) {
  return ref.watch(playbackServiceProvider).isVideoContentStream;
});

final videoAspectProvider = StreamProvider<double?>((ref) {
  return ref.watch(playbackServiceProvider).videoAspectStream;
});

/// The item that is playing: a whole track, or one chapter of it when the
/// playlist plays chapters as separate tracks.
final currentPlaybackItemProvider = StreamProvider<PlaybackItem?>((ref) {
  return ref.watch(playbackServiceProvider).currentItemStream;
});

/// True while the current item is a chapter played as its own track. Only
/// then does 'Next file' (skip the rest of the file) differ from 'Next'.
final isChapterItemProvider = Provider<bool>((ref) {
  return ref.watch(
    currentPlaybackItemProvider.select(
      (value) => value.valueOrNull?.chapter != null,
    ),
  );
});

/// True while the player is expanded to full-screen video. The persistent
/// player in `lib/player/player_shell.dart` owns this value.
final ValueNotifier<bool> videoFullscreenNotifier = ValueNotifier<bool>(false);

/// Logical pixels the EXPANDED audio panel covers above the mini-player strip
/// that the page area always reserves while a track is loaded. It is 0 while
/// the player is collapsed (and for full-screen video). It switches to the
/// panel's covered height as soon as the panel starts to expand, and back to
/// 0 once it has fully collapsed, so lists pad their bottom once rather than
/// on every animation frame.
final ValueNotifier<double> audioPlayerOverlayHeightNotifier =
    ValueNotifier<double>(0);

final shuffleEnabledProvider = StreamProvider<bool>((ref) {
  return ref.watch(playbackServiceProvider).shuffleEnabledStream;
});

final autoplayEnabledProvider = StreamProvider<bool>((ref) {
  return ref.watch(playbackServiceProvider).autoplayEnabledStream;
});

final audioOnlyModeProvider = StreamProvider<bool>((ref) {
  return ref.watch(playbackServiceProvider).audioOnlyModeStream;
});

final sleepTimerRemainingProvider = StreamProvider<Duration?>((ref) {
  return ref.watch(playbackServiceProvider).sleepTimerRemainingStream;
});

final pendingSegmentMarkStartProvider = StreamProvider<Duration?>((ref) {
  return ref.watch(playbackServiceProvider).pendingSegmentMarkStartStream;
});

final playbackSponsorBlockSegmentsProvider =
    StreamProvider<List<PlaybackSponsorBlockSegment>>((ref) {
      return ref.watch(playbackServiceProvider).sponsorBlockSegmentsStream;
    });

final queueProvider = StreamProvider<List<Track>>((ref) {
  return ref.watch(playbackServiceProvider).queueStream;
});

/// Tracks explicitly added by the user to play ahead of the current playlist.
final upNextQueueProvider = StreamProvider<List<Track>>((ref) {
  return ref.watch(playbackServiceProvider).upNextQueueStream;
});

final queueIndexProvider = StreamProvider<int>((ref) {
  return ref.watch(playbackServiceProvider).queueIndexStream;
});

final subtitleTracksProvider = StreamProvider<List<SubtitleTrack>>((ref) {
  return ref.watch(playbackServiceProvider).subtitleTracksStream;
});

final selectedSubtitleTrackProvider = StreamProvider<SubtitleTrack>((ref) {
  return ref.watch(playbackServiceProvider).selectedSubtitleTrackStream;
});

/// User-facing playback notices (missing file, denied audio focus, ...).
final playbackMessagesProvider = StreamProvider<String>((ref) {
  return ref.watch(playbackServiceProvider).messages;
});
