import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../services/chapter_preview_player.dart';
import '../services/metadata_service.dart';
import '../services/recognition/audio_window_decoder.dart';
import '../services/waveform_service.dart';
import 'playback_providers.dart';

/// Makes the preview player for one file.
typedef ChapterPreviewPlayerFactory =
    ChapterPreviewPlayer Function(String filePath);

/// Preview players for the chapter editor and the recognition review.
/// Tests override this with players around a fake media_kit player.
final chapterPreviewPlayerFactoryProvider =
    Provider<ChapterPreviewPlayerFactory>((ref) {
      return (filePath) => ChapterPreviewPlayer(
        filePath: filePath,
        pauseMainPlayer: () {
          // Read on use, so the factory works before playback is set up.
          final playback = ref.read(playbackServiceProvider);
          return playback.isPlaying ? playback.pause() : Future.value();
        },
        mainPlaying: () => ref.read(playbackServiceProvider).isPlayingStream,
      );
    });

/// Waveforms for the chapter editor. One cache for the whole app.
final waveformServiceProvider = Provider<WaveformService>((ref) {
  return WaveformService(const PlatformAudioWindowDecoder());
});

/// The media file of [track] on disk, or null when it is missing. Resolves
/// the stored path the same way the playback service does.
String? resolveTrackMediaPath(Track track) {
  final stored = track.filePath;
  return stored == null ? null : MetadataService.resolveStoredFilePath(stored);
}
