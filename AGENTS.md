# WoolyTube

WoolyTube is a Flutter Android app for downloading YouTube videos and audio with yt-dlp, organizing downloads into playlists, keeping playlists updated on device, and playing downloaded media in the app.

The project is fully client-side. Downloads, metadata, playlist state, background work, and playback all run on the Android device without a server.

The repository root is the Flutter app root. Main Dart code lives in `lib/`, Android platform code lives in `android/`, and tests live in `test/`.

Use Java 21 for Android builds. The local machine has Java 21 at `/usr/lib/jvm/java-21-openjdk`; `release-apk.sh` and `build-apk.sh` force `JAVA_HOME` to that path automatically. If another machine stores JDK 21 elsewhere, set `JAVA_21_HOME` before running either script.

After every code modification, run `./build-apk.sh` to verify the app still builds. It runs `flutter pub get`, builds a local release APK, and copies it to `build/releases/woolytube-local.apk`. It does not require a clean working tree and does not upload anything to GitHub.

For public releases, run `./release-apk.sh <version>` with a `MAJOR.MINOR.PATCH` version such as `./release-apk.sh 1.1.1`. The release script requires a clean working tree, updates `pubspec.yaml`, builds the release APK, commits and pushes the version bump, and creates the GitHub release with the APK asset.
