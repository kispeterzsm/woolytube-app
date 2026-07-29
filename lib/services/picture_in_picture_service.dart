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

  Future<void> togglePlayPause();
  Future<void> next();
  Future<void> setAudioOnlyMode(bool enabled);
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
  bool _restoreVideoOnNextForeground = false;
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
        // The PiP headphone action is a background convenience, unlike the
        // persistent audio-only toggle in the player UI. Restore video when
        // the user explicitly brings WoolyTube back to the foreground.
        _restoreVideoOnNextForeground = true;
        await _playback.setAudioOnlyMode(true);
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

  Future<void> handleAppResumed() async {
    if (!_restoreVideoOnNextForeground) return;
    _restoreVideoOnNextForeground = false;
    try {
      await _playback.setAudioOnlyMode(false);
    } catch (error) {
      _restoreVideoOnNextForeground = true;
      debugPrint('Could not restore video after PiP audio-only mode: $error');
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
