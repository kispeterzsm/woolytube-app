# media_kit_libs_android_video (WoolyTube copy)

This is media_kit_libs_android_video 1.3.8 from pub.dev (MIT, see [LICENSE](./LICENSE)), used through `dependency_overrides` in the app's `pubspec.yaml`. The only change is in `android/build.gradle`: it downloads the v1.1.11 `encoders-gpl` libmpv jars instead of the v1.1.7 `default` ones, because plane mode needs FFmpeg's audio filters (acompressor, alimiter, volume, aresample).

To update, copy the new upstream package over this folder (without `example/`), then point the four `filesToDownload` entries at the `encoders-gpl` jars of a [libmpv-android-video-build release](https://github.com/media-kit/libmpv-android-video-build/releases) with the same mpv commit, using `md5sum` of each downloaded jar. Check that `nm -D --defined-only lib/arm64-v8a/libmpv.so | grep ' mpv_'` matches the upstream jar before shipping.
