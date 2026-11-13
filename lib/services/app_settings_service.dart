import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/update_frequency_dropdown.dart';
import 'add_playlist_defaults.dart';
import 'audio_processing.dart';
import 'playback_settings_store.dart';
import 'settings_changes.dart';

typedef PreferencesLoader = Future<SharedPreferences> Function();

/// A setting the owner chooses, as the settings backup keeps it.
class BackedUpSetting {
  const BackedUpSetting(this.section, this.key, this.accept);

  /// The part of the backup file it is listed under.
  final String section;

  /// Its key in the app's preferences.
  final String key;

  /// The value to store for [value] from a backup, or null when the value
  /// is not one this setting takes (a hand-edited or damaged backup).
  final Object? Function(Object? value) accept;
}

Object? _acceptBool(Object? value) => value is bool ? value : null;

Object? _acceptStrength(Object? value) =>
    value is String && PlaneModeStrength.values.any((s) => s.name == value)
        ? value
        : null;

Object? _acceptEvenOutMode(Object? value) =>
    value is String && EvenOutMode.values.any((m) => m.name == value)
        ? value
        : null;

Object? _acceptFrequency(Object? value) =>
    value is num ? nearestUpdateFrequency(value.toInt()) : null;

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
  static const evenOutModeKey = 'even_out_mode';
  static const loudnessOnlyWhileChargingKey = 'loudness_only_while_charging';
  static const planeModeStrengthKey = 'plane_mode_strength';
  static const planeModeTipShownKey = 'plane_mode_tip_shown';

  /// Bookkeeping of the settings file in the library folder: the hash of
  /// the content this install last wrote there (or found it already held),
  /// and of the last settings file restored from there. A settings file
  /// matching neither came from elsewhere (see
  /// `LibraryExportService.writeSettingsFile`).
  static const settingsFileHashKey = 'settings_file_hash';
  static const restoredSettingsFileHashKey = 'restored_settings_file_hash';
  static const _backgroundChannel = MethodChannel('com.woolytube/background');

  /// The sections of the settings backup.
  static const appSection = 'app';
  static const playerSection = 'player';
  static const newPlaylistDefaultsSection = 'newPlaylistDefaults';

  /// Every setting the owner chooses: what the settings backup keeps and a
  /// restore brings back. App bookkeeping is left out on purpose: dismissed
  /// imports, the last yt-dlp update, whether the plane mode tips were
  /// shown, the old app-wide subtitle setting and the last song played
  /// (which names database rows that mean nothing on another phone).
  static const backedUpSettings = [
    BackedUpSetting(appSection, autoDownloadWithMobileDataKey, _acceptBool),
    BackedUpSetting(appSection, pauseOnAudioInterruptionKey, _acceptBool),
    BackedUpSetting(appSection, evenOutVolumeKey, _acceptBool),
    BackedUpSetting(appSection, evenOutModeKey, _acceptEvenOutMode),
    BackedUpSetting(appSection, loudnessOnlyWhileChargingKey, _acceptBool),
    BackedUpSetting(appSection, planeModeStrengthKey, _acceptStrength),
    BackedUpSetting(
      playerSection,
      SharedPreferencesPlaybackSettingsStore.planeModeKey,
      _acceptBool,
    ),
    BackedUpSetting(
      playerSection,
      SharedPreferencesPlaybackSettingsStore.shuffleKey,
      _acceptBool,
    ),
    BackedUpSetting(
      playerSection,
      SharedPreferencesPlaybackSettingsStore.autoplayKey,
      _acceptBool,
    ),
    BackedUpSetting(
      playerSection,
      SharedPreferencesPlaybackSettingsStore.audioOnlyKey,
      _acceptBool,
    ),
    BackedUpSetting(
      newPlaylistDefaultsSection,
      AddPlaylistDefaults.audioOnlyKey,
      _acceptBool,
    ),
    BackedUpSetting(
      newPlaylistDefaultsSection,
      AddPlaylistDefaults.autoUpdateKey,
      _acceptBool,
    ),
    BackedUpSetting(
      newPlaylistDefaultsSection,
      AddPlaylistDefaults.frequencyKey,
      _acceptFrequency,
    ),
    BackedUpSetting(
      newPlaylistDefaultsSection,
      AddPlaylistDefaults.playChaptersKey,
      _acceptBool,
    ),
    BackedUpSetting(
      newPlaylistDefaultsSection,
      AddPlaylistDefaults.includeThumbnailsKey,
      _acceptBool,
    ),
  ];

  final PreferencesLoader _preferencesLoader;

  Future<bool> getAutoDownloadWithMobileData() async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(autoDownloadWithMobileDataKey) ?? false;
  }

  Future<void> setAutoDownloadWithMobileData(bool enabled) async {
    final preferences = await _preferencesLoader();
    await preferences.setBool(autoDownloadWithMobileDataKey, enabled);
    SettingsChanges.notify();
    await scheduleAutoUpdate();
  }

  Future<bool> getPauseOnAudioInterruption() async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(pauseOnAudioInterruptionKey) ?? true;
  }

  Future<void> setPauseOnAudioInterruption(bool enabled) async {
    final preferences = await _preferencesLoader();
    await preferences.setBool(pauseOnAudioInterruptionKey, enabled);
    SettingsChanges.notify();
  }

  /// Plays every song at a similar loudness.
  Future<bool> getEvenOutVolume() async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(evenOutVolumeKey) ?? false;
  }

  Future<void> setEvenOutVolume(bool enabled) async {
    final preferences = await _preferencesLoader();
    await preferences.setBool(evenOutVolumeKey, enabled);
    SettingsChanges.notify();
  }

  /// How "Even out volume" levels songs: Normal or Quiet.
  Future<EvenOutMode> getEvenOutMode() async {
    final preferences = await _preferencesLoader();
    return EvenOutMode.fromName(preferences.getString(evenOutModeKey));
  }

  Future<void> setEvenOutMode(EvenOutMode mode) async {
    final preferences = await _preferencesLoader();
    await preferences.setString(evenOutModeKey, mode.name);
    SettingsChanges.notify();
  }

  /// Whether the library's loudness is only measured while the phone is
  /// plugged in. The songs the player is about to play are measured either
  /// way.
  Future<bool> getLoudnessOnlyWhileCharging() async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(loudnessOnlyWhileChargingKey) ?? true;
  }

  Future<void> setLoudnessOnlyWhileCharging(bool enabled) async {
    final preferences = await _preferencesLoader();
    await preferences.setBool(loudnessOnlyWhileChargingKey, enabled);
    SettingsChanges.notify();
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
    SettingsChanges.notify();
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

  /// See [settingsFileHashKey]. Bookkeeping: changing it does not count as
  /// a settings change.
  Future<int?> getSettingsFileHash() => _getInt(settingsFileHashKey);

  Future<void> setSettingsFileHash(int hash) =>
      _setInt(settingsFileHashKey, hash);

  /// See [restoredSettingsFileHashKey].
  Future<int?> getRestoredSettingsFileHash() =>
      _getInt(restoredSettingsFileHashKey);

  Future<void> setRestoredSettingsFileHash(int hash) =>
      _setInt(restoredSettingsFileHashKey, hash);

  Future<int?> _getInt(String key) async {
    final preferences = await _preferencesLoader();
    final value = preferences.get(key);
    return value is int ? value : null;
  }

  Future<void> _setInt(String key, int value) async {
    final preferences = await _preferencesLoader();
    await preferences.setInt(key, value);
  }

  /// The stored [backedUpSettings] by key, for the settings backup. A
  /// setting never changed is left out. Values are JSON types (bool, int,
  /// String).
  Future<Map<String, Object?>> exportSettings() async {
    final preferences = await _preferencesLoader();
    await preferences.reload();
    return {
      for (final setting in backedUpSettings)
        if (preferences.get(setting.key) case final value?) setting.key: value,
    };
  }

  /// [exportSettings], by section of the backup file.
  Future<Map<String, Map<String, Object?>>> exportSettingsBySection() async {
    final values = await exportSettings();
    final sections = <String, Map<String, Object?>>{};
    for (final setting in backedUpSettings) {
      final section = sections.putIfAbsent(setting.section, () => {});
      if (values.containsKey(setting.key)) {
        section[setting.key] = values[setting.key];
      }
    }
    return sections;
  }

  /// Applies settings from a backup (see [exportSettings]). Only the
  /// owner's [backedUpSettings] are restored, never app bookkeeping such as
  /// dismissed imports, nor the old app-wide subtitle setting (subtitles
  /// are chosen per playlist now). Values a setting does not take are
  /// skipped. Returns how many settings were applied.
  Future<int> importSettings(Map<String, Object?> values) async {
    final preferences = await _preferencesLoader();
    var applied = 0;
    for (final setting in backedUpSettings) {
      final value = setting.accept(values[setting.key]);
      switch (value) {
        case bool value:
          await preferences.setBool(setting.key, value);
        case int value:
          await preferences.setInt(setting.key, value);
        case String value:
          await preferences.setString(setting.key, value);
        default:
          continue;
      }
      applied++;
    }
    if (applied > 0) {
      SettingsChanges.notify();
      await scheduleAutoUpdate();
    }
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
