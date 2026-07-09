# WoolyTube

WoolyTube is a Flutter Android app for downloading YouTube videos and audio with yt-dlp, organizing downloads into playlists, keeping playlists updated on device, and playing downloaded media in the app.

The project is fully client-side. Downloads, metadata, playlist state, background work, and playback all run on the Android device without a server.

The repository root is the Flutter app root. Main Dart code lives in `lib/`, Android platform code lives in `android/`, and tests live in `test/`.

Run `flutter test` to validate the host-side test suite without a connected phone. These tests cover version comparison, Drift database behavior with an in-memory database, metadata file writing/import/reconciliation, cleanup of playlist folders, and playlist sync behavior using fake yt-dlp responses.

On this machine, `flutter`, `dart`, `java`, and `javac` may not be on the non-interactive shell `PATH`. Flutter is installed at `/home/wooly/flutter/bin/flutter`; use `/home/wooly/flutter/bin/flutter test`, `/home/wooly/flutter/bin/flutter pub run build_runner build --delete-conflicting-outputs`, and `/home/wooly/flutter/bin/dart format ...` if the bare commands are not found. The build and release scripts already fall back to `/home/wooly/flutter/bin/flutter`, or you can set `FLUTTER_BIN`.

Use Java 21 for Android builds. The scripts default to `/usr/lib/jvm/java-21-openjdk`, but that path may not exist on this machine. A working local JDK 21 is installed at `/home/wooly/.local/share/jdks/jdk-21.0.11+10`; run builds as `JAVA_21_HOME=/home/wooly/.local/share/jdks/jdk-21.0.11+10 ./build-apk.sh` if `./build-apk.sh` reports `Missing Java 21 at /usr/lib/jvm/java-21-openjdk`. Use the same `JAVA_21_HOME=...` prefix for `./release-apk.sh <version>`.

After every code modification, run `./build-apk.sh` to verify the app still builds. It runs `flutter pub get`, builds a local release APK, and copies it to `build/releases/woolytube-local.apk`. It does not require a clean working tree and does not upload anything to GitHub.

For public releases, run `./release-apk.sh <version>` with a `MAJOR.MINOR.PATCH` version such as `./release-apk.sh 1.1.1`. The release script requires a clean working tree, updates `pubspec.yaml`, builds the release APK, commits and pushes the version bump, and creates the GitHub release with the APK asset.
