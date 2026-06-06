import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../services/playback_service.dart';
import '../services/audio_handler.dart';

// These are overridden in main() with real instances
final playbackServiceProvider = Provider<PlaybackService>((ref) {
  throw UnimplementedError('Must be overridden');
});

final audioHandlerProvider = Provider<WoolyTubeAudioHandler>((ref) {
  throw UnimplementedError('Must be overridden');
});

final currentTrackProvider = StreamProvider<Track?>((ref) {
  return ref.watch(playbackServiceProvider).currentTrackStream;
});

final currentPlaylistProvider = StreamProvider<Playlist?>((ref) {
  return ref.watch(playbackServiceProvider).currentPlaylistStream;
});

final isPlayingProvider = StreamProvider<bool>((ref) {
  return ref.watch(playbackServiceProvider).isPlayingStream;
});

final positionProvider = StreamProvider<Duration>((ref) {
  return ref.watch(playbackServiceProvider).positionStream;
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

/// True while the full-screen VLC-style video view is mounted. The global
/// MiniPlayerBar uses this to hide itself so the video can go edge-to-edge.
/// Plain ValueNotifier (not Riverpod) so the video page can flip it from
/// initState/dispose without violating lifecycle rules.
final ValueNotifier<bool> videoFullscreenNotifier = ValueNotifier<bool>(false);

final shuffleEnabledProvider = StreamProvider<bool>((ref) {
  return ref.watch(playbackServiceProvider).shuffleEnabledStream;
});

final autoplayEnabledProvider = StreamProvider<bool>((ref) {
  return ref.watch(playbackServiceProvider).autoplayEnabledStream;
});

final audioOnlyModeProvider = StreamProvider<bool>((ref) {
  return ref.watch(playbackServiceProvider).audioOnlyModeStream;
});

final queueProvider = StreamProvider<List<Track>>((ref) {
  return ref.watch(playbackServiceProvider).queueStream;
});
