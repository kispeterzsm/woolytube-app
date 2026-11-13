import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'settings_changes.dart';

/// Where the player was when the app last ran, so it can come back paused.
class PlaybackSession {
  final int playlistId;
  final int trackId;
  final String? chapterId;

  /// Position on the file's own timeline (not relative to a chapter).
  final int positionMs;

  /// The file was playing as one piece although it has chapters.
  final bool whole;

  const PlaybackSession({
    required this.playlistId,
    required this.trackId,
    this.chapterId,
    this.positionMs = 0,
    this.whole = false,
  });

  Map<String, Object?> toJson() => {
    'playlistId': playlistId,
    'trackId': trackId,
    'chapterId': chapterId,
    'positionMs': positionMs,
    'whole': whole,
  };

  static PlaybackSession? fromJson(Object? value) {
    if (value is! Map) return null;
    final playlistId = value['playlistId'];
    final trackId = value['trackId'];
    if (playlistId is! int || trackId is! int) return null;
    final position = value['positionMs'];
    final chapterId = value['chapterId'];
    return PlaybackSession(
      playlistId: playlistId,
      trackId: trackId,
      chapterId: chapterId is String ? chapterId : null,
      positionMs: position is int && position > 0 ? position : 0,
      whole: value['whole'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackSession &&
      other.playlistId == playlistId &&
      other.trackId == trackId &&
      other.chapterId == chapterId &&
      other.positionMs == positionMs &&
      other.whole == whole;

  @override
  int get hashCode =>
      Object.hash(playlistId, trackId, chapterId, positionMs, whole);
}

/// The player options remembered across app restarts.
class PlaybackPreferences {
  final bool? shuffle;
  final bool? autoplay;
  final bool? audioOnly;
  final bool? planeMode;
  final PlaybackSession? session;

  const PlaybackPreferences({
    this.shuffle,
    this.autoplay,
    this.audioOnly,
    this.planeMode,
    this.session,
  });

  PlaybackPreferences copyWith({
    bool? shuffle,
    bool? autoplay,
    bool? audioOnly,
    bool? planeMode,
    PlaybackSession? session,
    bool clearSession = false,
  }) => PlaybackPreferences(
    shuffle: shuffle ?? this.shuffle,
    autoplay: autoplay ?? this.autoplay,
    audioOnly: audioOnly ?? this.audioOnly,
    planeMode: planeMode ?? this.planeMode,
    session: clearSession ? null : (session ?? this.session),
  );
}

/// Persistence for [PlaybackPreferences]. Failures are swallowed by the
/// caller: losing a remembered option must never break playback.
abstract interface class PlaybackSettingsStore {
  Future<PlaybackPreferences> load();
  Future<void> saveShuffle(bool enabled);
  Future<void> saveAutoplay(bool enabled);
  Future<void> saveAudioOnly(bool enabled);
  Future<void> savePlaneMode(bool enabled);

  /// Null forgets the session (after an explicit stop).
  Future<void> saveSession(PlaybackSession? session);
}

class SharedPreferencesPlaybackSettingsStore implements PlaybackSettingsStore {
  SharedPreferencesPlaybackSettingsStore({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const shuffleKey = 'playback_shuffle';
  static const autoplayKey = 'playback_autoplay';
  static const audioOnlyKey = 'playback_audio_only';
  static const planeModeKey = 'playback_plane_mode';
  static const sessionKey = 'playback_last_session';

  final Future<SharedPreferences> Function() _preferencesLoader;

  @override
  Future<PlaybackPreferences> load() async {
    final preferences = await _preferencesLoader();
    PlaybackSession? session;
    final raw = preferences.getString(sessionKey);
    if (raw != null) {
      try {
        session = PlaybackSession.fromJson(jsonDecode(raw));
      } catch (_) {}
    }
    return PlaybackPreferences(
      shuffle: preferences.getBool(shuffleKey),
      autoplay: preferences.getBool(autoplayKey),
      audioOnly: preferences.getBool(audioOnlyKey),
      planeMode: preferences.getBool(planeModeKey),
      session: session,
    );
  }

  @override
  Future<void> saveShuffle(bool enabled) => _saveOption(shuffleKey, enabled);

  @override
  Future<void> saveAutoplay(bool enabled) => _saveOption(autoplayKey, enabled);

  @override
  Future<void> saveAudioOnly(bool enabled) =>
      _saveOption(audioOnlyKey, enabled);

  @override
  Future<void> savePlaneMode(bool enabled) =>
      _saveOption(planeModeKey, enabled);

  /// Stores one of the owner's options, which the settings backup keeps.
  /// The last song ([saveSession]) is not one of them.
  Future<void> _saveOption(String key, bool enabled) async {
    await (await _preferencesLoader()).setBool(key, enabled);
    SettingsChanges.notify();
  }

  @override
  Future<void> saveSession(PlaybackSession? session) async {
    final preferences = await _preferencesLoader();
    if (session == null) {
      await preferences.remove(sessionKey);
    } else {
      await preferences.setString(sessionKey, jsonEncode(session.toJson()));
    }
    ResumePointChanges.notify();
  }
}

/// Keeps everything in memory; for tests and for hosts without storage.
class MemoryPlaybackSettingsStore implements PlaybackSettingsStore {
  MemoryPlaybackSettingsStore([this.preferences = const PlaybackPreferences()]);

  PlaybackPreferences preferences;
  final sessions = <PlaybackSession?>[];

  @override
  Future<PlaybackPreferences> load() async => preferences;

  @override
  Future<void> saveShuffle(bool enabled) async {
    preferences = preferences.copyWith(shuffle: enabled);
  }

  @override
  Future<void> saveAutoplay(bool enabled) async {
    preferences = preferences.copyWith(autoplay: enabled);
  }

  @override
  Future<void> saveAudioOnly(bool enabled) async {
    preferences = preferences.copyWith(audioOnly: enabled);
  }

  @override
  Future<void> savePlaneMode(bool enabled) async {
    preferences = preferences.copyWith(planeMode: enabled);
  }

  @override
  Future<void> saveSession(PlaybackSession? session) async {
    sessions.add(session);
    preferences = preferences.copyWith(
      session: session,
      clearSession: session == null,
    );
  }
}
