import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_processing.dart';

typedef PreferencesLoader = Future<SharedPreferences> Function();

class AppSettingsService {
  AppSettingsService({PreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const autoDownloadWithMobileDataKey = 'auto_download_with_mobile_data';

  /// The app-wide subtitle setting of earlier versions. Subtitles are now a
  /// playlist setting; these are only read to move the old choice there,
  /// and skipped when an old settings backup is restored.
  static const legacyDownloadSubtitlesKey = 'download_subtitles';
  static const legacySubtitleLanguagesKey = 'subtitle_languages';

  static const pauseOnAudioInterruptionKey = 'pause_on_audio_interruption';
  static const dismissedImportUrlsKey = 'dismissed_import_urls';
  static const lastYtDlpUpdateAttemptKey = 'last_ytdlp_update_attempt';
  static const evenOutVolumeKey = 'even_out_volume';
  static const planeModeStrengthKey = 'plane_mode_strength';
  static const planeModeTipShownKey = 'plane_mode_tip_shown';
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

  /// Plays every song at a similar loudness.
  Future<bool> getEvenOutVolume() async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(evenOutVolumeKey) ?? false;
  }

  Future<void> setEvenOutVolume(bool enabled) async {
    final preferences = await _preferencesLoader();
    await preferences.setBool(evenOutVolumeKey, enabled);
  }

  Future<PlaneModeStrength> getPlaneModeStrength() async {
    final preferences = await _preferencesLoader();
    return PlaneModeStrength.fromName(
      preferences.getString(planeModeStrengthKey),
    );
  }

  Future<void> setPlaneModeStrength(PlaneModeStrength strength) async {
    final preferences = await _preferencesLoader();
    await preferences.setString(planeModeStrengthKey, strength.name);
  }

  /// Whether the tips shown the first time plane mode is switched on were
  /// already shown.
  Future<bool> getPlaneModeTipShown() async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(planeModeTipShownKey) ?? false;
  }

  Future<void> setPlaneModeTipShown() async {
    final preferences = await _preferencesLoader();
    await preferences.setBool(planeModeTipShownKey, true);
  }

  /// The app-wide subtitle setting of versions before subtitles became a
  /// playlist setting: whether it was on and its languages. Null when
  /// neither is stored (never set, or already moved to the playlists by
  /// `migrateLegacySubtitleSetting`).
  Future<({bool enabled, String? languages})?>
  readLegacySubtitleSetting() async {
    final preferences = await _preferencesLoader();
    // The app and the scheduled update run in different engines.
    await preferences.reload();
    if (!preferences.containsKey(legacyDownloadSubtitlesKey) &&
        !preferences.containsKey(legacySubtitleLanguagesKey)) {
      return null;
    }
    final enabled = preferences.get(legacyDownloadSubtitlesKey);
    final languages = preferences.get(legacySubtitleLanguagesKey);
    return (
      enabled: enabled == true,
      languages: languages is String ? languages : null,
    );
  }

  Future<void> clearLegacySubtitleSetting() async {
    final preferences = await _preferencesLoader();
    await preferences.remove(legacyDownloadSubtitlesKey);
    await preferences.remove(legacySubtitleLanguagesKey);
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
  /// dismissed imports, nor the old app-wide subtitle setting (subtitles
  /// are chosen per playlist now). Returns how many settings were applied.
  Future<int> importSettings(Map<String, Object?> values) async {
    final preferences = await _preferencesLoader();
    var applied = 0;
    for (final key in const [
      autoDownloadWithMobileDataKey,
      pauseOnAudioInterruptionKey,
      evenOutVolumeKey,
    ]) {
      final value = values[key];
      if (value is bool) {
        await preferences.setBool(key, value);
        applied++;
      }
    }
    final strength = values[planeModeStrengthKey];
    if (strength is String &&
        PlaneModeStrength.values.any((s) => s.name == strength)) {
      await preferences.setString(planeModeStrengthKey, strength);
      applied++;
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
