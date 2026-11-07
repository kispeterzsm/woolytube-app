import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/update_frequency_dropdown.dart';

/// The options a new playlist starts with on the Add playlist page.
class AddPlaylistOptions {
  const AddPlaylistOptions({
    this.audioOnly = false,
    this.autoUpdate = true,
    this.updateFrequencyHours = 24,
    this.playChapters = true,
    this.includeThumbnails = true,
  });

  final bool audioOnly;
  final bool autoUpdate;
  final int updateFrequencyHours;
  final bool playChapters;
  final bool includeThumbnails;
}

/// Remembers the options of the last playlist added, so the next one starts
/// with them (most people add only audio, or only video).
class AddPlaylistDefaults {
  AddPlaylistDefaults({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  static const audioOnlyKey = 'new_playlist_audio_only';
  static const autoUpdateKey = 'new_playlist_auto_update';
  static const frequencyKey = 'new_playlist_update_frequency_hours';
  static const playChaptersKey = 'new_playlist_play_chapters';
  static const includeThumbnailsKey = 'new_playlist_include_thumbnails';

  Future<AddPlaylistOptions> load() async {
    const fallback = AddPlaylistOptions();
    final prefs = await _preferences();
    return AddPlaylistOptions(
      audioOnly: prefs.getBool(audioOnlyKey) ?? fallback.audioOnly,
      autoUpdate: prefs.getBool(autoUpdateKey) ?? fallback.autoUpdate,
      updateFrequencyHours: nearestUpdateFrequency(
        prefs.getInt(frequencyKey) ?? fallback.updateFrequencyHours,
      ),
      playChapters: prefs.getBool(playChaptersKey) ?? fallback.playChapters,
      includeThumbnails:
          prefs.getBool(includeThumbnailsKey) ?? fallback.includeThumbnails,
    );
  }

  Future<void> save(AddPlaylistOptions options) async {
    final prefs = await _preferences();
    await prefs.setBool(audioOnlyKey, options.audioOnly);
    await prefs.setBool(autoUpdateKey, options.autoUpdate);
    await prefs.setInt(frequencyKey, options.updateFrequencyHours);
    await prefs.setBool(playChaptersKey, options.playChapters);
    await prefs.setBool(includeThumbnailsKey, options.includeThumbnails);
  }
}
