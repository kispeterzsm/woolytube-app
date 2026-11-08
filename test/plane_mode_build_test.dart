import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Plane mode sends mpv a filter graph with acompressor, alimiter and
/// volume. media_kit's default libmpv is built without them, and mpv then
/// plays the next song with no sound at all, so the app must keep using the
/// vendored copy that downloads the "encoders-gpl" build.
void main() {
  test('the app uses the vendored libmpv with audio filters', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(
        r'dependency_overrides:\s*(?:#[^\n]*\n\s*)*'
        r'media_kit_libs_android_video:\s*\n\s*path: '
        r'plugins/media_kit_libs_android_video',
      ).hasMatch(pubspec),
      isTrue,
      reason: 'pubspec.yaml must override media_kit_libs_android_video',
    );
    final lock = File('pubspec.lock').readAsStringSync();
    expect(lock, contains('path: "plugins/media_kit_libs_android_video"'));
  });

  test('the vendored plugin downloads the encoders-gpl jars', () {
    final gradle =
        File(
          'plugins/media_kit_libs_android_video/android/build.gradle',
        ).readAsStringSync();
    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86']) {
      expect(gradle, contains('encoders-gpl-$abi.jar'));
    }
    expect(gradle, isNot(contains('default-arm64-v8a.jar')));
  });
}
