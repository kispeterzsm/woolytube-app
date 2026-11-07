import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

abstract interface class PictureInPicturePlaybackController {
  Stream<bool> get isPlayingStream;
  Stream<bool> get isVideoContentStream;
  Stream<double?> get videoAspectStream;

  bool get isPlaying;
  bool get isVideoContent;
  bool get audioOnlyMode;

  Future<void> togglePlayPause();
  Future<void> next();
  Future<void> setAudioOnlyMode(bool enabled);

  /// Audio-only until [restoreTemporaryAudioOnly]; does nothing when the
  /// user already chose audio-only.
  Future<void> enableTemporaryAudioOnly();

  /// Switches video back on if [enableTemporaryAudioOnly] switched it off
  /// and the user did not change the mode since.
  Future<void> restoreTemporaryAudioOnly();
}

class PictureInPictureService {
  static const channelName = 'com.woolytube/playback';

  final PictureInPicturePlaybackController _playback;
  final MethodChannel _channel;
  final bool _platformEnabled;
  final BehaviorSubject<bool> _mode = BehaviorSubject<bool>.seeded(false);
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  bool _syncScheduled = false;
  bool _initialized = false;
  double? _aspectRatio;

  PictureInPictureService(
    this._playback, {
    MethodChannel? channel,
    bool? platformEnabled,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _platformEnabled = platformEnabled ?? Platform.isAndroid;

  Stream<bool> get modeStream => _mode.stream;
  bool get isInPictureInPictureMode => _mode.value;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(handlePlatformCall);

    _subscriptions.addAll([
      _playback.isPlayingStream.listen((_) => _scheduleSync()),
      _playback.isVideoContentStream.listen((_) => _scheduleSync()),
      _playback.videoAspectStream.listen((aspect) {
        _aspectRatio = aspect;
        _scheduleSync();
      }),
    ]);
    await _syncPlatformState();
  }

  @visibleForTesting
  Future<dynamic> handlePlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'pictureInPictureChanged':
        final enabled = call.arguments == true;
        if (_mode.value != enabled) _mode.add(enabled);
        return null;
      case 'enableAudioOnly':
      // The PiP window was closed while a video kept playing: nobody can
      // see the picture, so stop decoding it.
      case 'pipDismissed':
        // The PiP headphone action is a background convenience, unlike the
        // persistent audio-only toggle in the player UI. Video comes back
        // when the user explicitly brings WoolyTube to the foreground, but
        // only if this switched it off.
        await _playback.enableTemporaryAudioOnly();
        return null;
      case 'togglePlayPause':
        await _playback.togglePlayPause();
        return null;
      case 'skipNext':
        await _playback.next();
        return null;
      default:
        throw MissingPluginException('Unknown playback method ${call.method}');
    }
  }

  /// Call when the app returns to the foreground: switches video back on
  /// after a temporary audio-only mode (PiP headphone button, closed PiP
  /// window, the app hidden during a video, or playback from the car).
  Future<void> handleAppResumed() async {
    try {
      await _playback.restoreTemporaryAudioOnly();
    } catch (error) {
      debugPrint('Could not restore video after audio-only mode: $error');
    }
  }

  /// Call when the app is hidden (AppLifecycleState.hidden). A video that
  /// keeps playing without a picture-in-picture window is invisible, so
  /// only its audio is kept until [handleAppResumed].
  Future<void> handleAppBackgrounded() async {
    if (_mode.value || !_playback.isVideoContent || _playback.audioOnlyMode) {
      return;
    }
    try {
      await _playback.enableTemporaryAudioOnly();
    } catch (error) {
      debugPrint('Could not stop video decoding in the background: $error');
    }
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    scheduleMicrotask(() async {
      _syncScheduled = false;
      await _syncPlatformState();
    });
  }

  Future<void> _syncPlatformState() async {
    if (!_platformEnabled) return;
    try {
      await _channel.invokeMethod<void>('updatePictureInPicture', {
        'videoActive': _playback.isVideoContent,
        'playing': _playback.isPlaying,
        'aspectRatio': _aspectRatio ?? 16 / 9,
      });
    } on MissingPluginException {
      // Host tests and unsupported embedders have no Android implementation.
    } on PlatformException catch (error) {
      debugPrint('Could not update picture-in-picture state: $error');
    }
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _channel.setMethodCallHandler(null);
    await _mode.close();
  }
}
