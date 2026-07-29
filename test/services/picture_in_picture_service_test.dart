import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:woolytube/services/picture_in_picture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.woolytube/playback-test');
  late _FakePipPlayback playback;
  late PictureInPictureService service;
  late List<MethodCall> calls;

  setUp(() async {
    playback = _FakePipPlayback();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    service = PictureInPictureService(
      playback,
      channel: channel,
      platformEnabled: true,
    );
    await service.initialize();
  });

  tearDown(() async {
    await service.dispose();
    await playback.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sends current video, playing, and aspect state to Android', () async {
    playback.setVideo(true);
    playback.setPlaying(true);
    playback.setAspect(4 / 3);
    await _flushStreams();

    final update = calls.lastWhere(
      (call) => call.method == 'updatePictureInPicture',
    );
    expect(update.arguments, {
      'videoActive': true,
      'playing': true,
      'aspectRatio': 4 / 3,
    });
  });

  test('routes PiP mode and headphone callbacks', () async {
    expect(service.isInPictureInPictureMode, isFalse);

    await service.handlePlatformCall(
      const MethodCall('pictureInPictureChanged', true),
    );
    expect(service.isInPictureInPictureMode, isTrue);

    await service.handlePlatformCall(const MethodCall('enableAudioOnly'));
    expect(playback.audioOnlyCalls, [true]);

    await service.handleAppResumed();
    expect(playback.audioOnlyCalls, [true, false]);

    await service.handleAppResumed();
    expect(playback.audioOnlyCalls, [true, false]);
  });

  test('routes play-pause and next callbacks', () async {
    await service.handlePlatformCall(const MethodCall('togglePlayPause'));
    await service.handlePlatformCall(const MethodCall('skipNext'));

    expect(playback.togglePlayPauseCalls, 1);
    expect(playback.nextCalls, 1);
  });

  test('does not change normal audio-only mode on foregrounding', () async {
    await service.handleAppResumed();
    expect(playback.audioOnlyCalls, isEmpty);
  });
}

Future<void> _flushStreams() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakePipPlayback implements PictureInPicturePlaybackController {
  final BehaviorSubject<bool> _playing = BehaviorSubject.seeded(false);
  final BehaviorSubject<bool> _video = BehaviorSubject.seeded(false);
  final BehaviorSubject<double?> _aspect = BehaviorSubject.seeded(null);
  final List<bool> audioOnlyCalls = [];
  int togglePlayPauseCalls = 0;
  int nextCalls = 0;

  @override
  Stream<bool> get isPlayingStream => _playing.stream;

  @override
  Stream<bool> get isVideoContentStream => _video.stream;

  @override
  Stream<double?> get videoAspectStream => _aspect.stream;

  @override
  bool get isPlaying => _playing.value;

  @override
  bool get isVideoContent => _video.value;

  void setPlaying(bool value) => _playing.add(value);
  void setVideo(bool value) => _video.add(value);
  void setAspect(double? value) => _aspect.add(value);

  @override
  Future<void> togglePlayPause() async {
    togglePlayPauseCalls++;
  }

  @override
  Future<void> next() async {
    nextCalls++;
  }

  @override
  Future<void> setAudioOnlyMode(bool enabled) async {
    audioOnlyCalls.add(enabled);
  }

  Future<void> dispose() async {
    await _playing.close();
    await _video.close();
    await _aspect.close();
  }
}
