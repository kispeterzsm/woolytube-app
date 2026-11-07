import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef PreferencesLoader = Future<SharedPreferences> Function();

class AppSettingsService {
  AppSettingsService({PreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const autoDownloadWithMobileDataKey = 'auto_download_with_mobile_data';
  static const downloadSubtitlesKey = 'download_subtitles';
  static const subtitleLanguagesKey = 'subtitle_languages';
  static const pauseOnAudioInterruptionKey = 'pause_on_audio_interruption';
  static const dismissedImportUrlsKey = 'dismissed_import_urls';
  static const lastYtDlpUpdateAttemptKey = 'last_ytdlp_update_attempt';
  static const _backgroundChannel = MethodChannel('com.woolytube/background');

  final PreferencesLoader _preferencesLoader;

  Future<bool> getAutoDownloadWithMobileData() async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(autoDownloadWithMobileDataKey) ?? false;
  }

  Future<void> setAutoDownloadWithMobileData(bool enabled) async {
    final preferences = await _preferencesLoader();
    await preferences.setBool(autoDownloadWithMobileDataKey, enabled);
    await scheduleAutoUpdate();
  }

  Future<bool> getPauseOnAudioInterruption() async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(pauseOnAudioInterruptionKey) ?? true;
  }

  Future<void> setPauseOnAudioInterruption(bool enabled) async {
    final preferences = await _preferencesLoader();
    await preferences.setBool(pauseOnAudioInterruptionKey, enabled);
  }

  Future<bool> getDownloadSubtitles() async {
    final preferences = await _preferencesLoader();
    // Background downloads run in another engine; refresh its preference cache.
    await preferences.reload();
    return preferences.getBool(downloadSubtitlesKey) ?? false;
  }

  Future<void> setDownloadSubtitles(bool enabled) async {
    final preferences = await _preferencesLoader();
    await preferences.setBool(downloadSubtitlesKey, enabled);
  }

  Future<String> getSubtitleLanguages() async {
    final preferences = await _preferencesLoader();
    await preferences.reload();
    return preferences.getString(subtitleLanguagesKey) ?? 'en';
  }

  Future<void> setSubtitleLanguages(String languages) async {
    final normalized = normalizeSubtitleLanguages(languages);
    final preferences = await _preferencesLoader();
    await preferences.setString(subtitleLanguagesKey, normalized);
  }

  /// Checks and tidies a comma-separated list of subtitle language codes
  /// for yt-dlp. Spaces and empty items (a trailing comma) are dropped. A
  /// code may end in `.*` to also match its regional variants (`en.*` for
  /// en-US and en-GB captions). 'all' is refused: it would download
  /// hundreds of automatic translations.
  static String normalizeSubtitleLanguages(String value) {
    final languages =
        value
            .split(',')
            .map((code) => code.trim())
            .where((code) => code.isNotEmpty)
            .toSet();
    if (languages.isEmpty ||
        languages.any(
          (code) =>
              code.toLowerCase() == 'all' ||
              !RegExp(
                r'^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]+)*(?:\.\*)?$',
              ).hasMatch(code),
        )) {
      throw const FormatException(
        'Enter language codes separated by commas, such as en, hu, de.',
      );
    }
    return languages.join(',');
  }

  /// Playlist URLs whose on-disk folders should not be offered for import
  /// again, because the user deleted the playlist in-app or dismissed the
  /// import banner.
  Future<Set<String>> getDismissedImportUrls() async {
    final preferences = await _preferencesLoader();
    return (preferences.getStringList(dismissedImportUrlsKey) ?? const [])
        .toSet();
  }

  Future<void> addDismissedImportUrls(Iterable<String> urls) async {
    final preferences = await _preferencesLoader();
    final merged = {
      ...?preferences.getStringList(dismissedImportUrlsKey),
      ...urls,
    };
    await preferences.setStringList(dismissedImportUrlsKey, merged.toList());
  }

  Future<void> removeDismissedImportUrl(String url) async {
    final preferences = await _preferencesLoader();
    final current = preferences.getStringList(dismissedImportUrlsKey);
    if (current == null || !current.contains(url)) return;
    await preferences.setStringList(
      dismissedImportUrlsKey,
      current.where((entry) => entry != url).toList(),
    );
  }

  /// When the app last tried to self-update yt-dlp, successful or not.
  Future<DateTime?> getLastYtDlpUpdateAttempt() async {
    final preferences = await _preferencesLoader();
    final millis = preferences.getInt(lastYtDlpUpdateAttemptKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> setLastYtDlpUpdateAttempt(DateTime at) async {
    final preferences = await _preferencesLoader();
    await preferences.setInt(
      lastYtDlpUpdateAttemptKey,
      at.millisecondsSinceEpoch,
    );
  }

  /// Every stored setting by key, for the library backup. Values are JSON
  /// types (bool, int, double, String, list of String).
  Future<Map<String, Object?>> exportSettings() async {
    final preferences = await _preferencesLoader();
    await preferences.reload();
    final keys = preferences.getKeys().toList()..sort();
    return {for (final key in keys) key: preferences.get(key)};
  }

  /// Applies settings from a library backup (see [exportSettings]). Only
  /// the owner's preferences are restored, never app bookkeeping such as
  /// dismissed imports. Returns how many settings were applied.
  Future<int> importSettings(Map<String, Object?> values) async {
    final preferences = await _preferencesLoader();
    var applied = 0;
    for (final key in const [
      autoDownloadWithMobileDataKey,
      downloadSubtitlesKey,
      pauseOnAudioInterruptionKey,
    ]) {
      final value = values[key];
      if (value is bool) {
        await preferences.setBool(key, value);
        applied++;
      }
    }
    final languages = values[subtitleLanguagesKey];
    if (languages is String) {
      // A hand-edited backup must not hand yt-dlp something the settings
      // page would refuse.
      try {
        await preferences.setString(
          subtitleLanguagesKey,
          normalizeSubtitleLanguages(languages),
        );
        applied++;
      } on FormatException {
        // Keep the current languages.
      }
    }
    if (applied > 0) await scheduleAutoUpdate();
    return applied;
  }

  Future<void> scheduleAutoUpdate() async {
    final allowMobileData = await getAutoDownloadWithMobileData();
    try {
      await _backgroundChannel.invokeMethod('scheduleAutoUpdate', {
        'allowMobileData': allowMobileData,
      });
    } catch (_) {
      // Scheduling is non-critical and unavailable on non-Android platforms.
    }
  }
}
