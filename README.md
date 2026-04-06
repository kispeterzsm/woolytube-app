# WoolyTube

A lightweight Android app that downloads YouTube videos and audio using [yt-dlp](https://github.com/yt-dlp/yt-dlp), organizes content into playlists, keeps them automatically up to date, and provides built-in media playback. Fully client-side -- no server required.

## Download

[**Download latest APK**](https://github.com/kispeterzsm/woolytube-app/releases/latest/download/woolytube-universal.apk)

Per-architecture APKs are also available on the [Releases page](https://github.com/kispeterzsm/woolytube-app/releases).

## Features

- **Download** YouTube videos and audio directly on your device using yt-dlp
- **Playlists** -- add playlist URLs, organize and manage your content
- **Auto-update** -- playlists sync automatically on a configurable schedule (1 hour to 1 week)
- **Media playback** -- built-in video player with mini-player and background audio support
- **Shuffle & autoplay** -- queue controls with search within playlists
- **Persistent storage** -- files are saved to accessible folders that survive app uninstall
- **Audio-only mode** -- download and play just the audio from any video
- **Thumbnails** -- download and display video thumbnails

## Installation

1. Download the APK from the link above
2. On your Android device, enable **Install from unknown sources** if prompted
3. Open the APK and install

**Requirements:** Android 7.0 (API 24) or higher.

## Building from Source

**Prerequisites:** Flutter SDK >= 3.7.2, Java 11, Android SDK

```bash
cd frontend
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter build apk --split-per-abi
```

The built APKs will be in `frontend/build/app/outputs/flutter-apk/`.

## Tech Stack

- [Flutter](https://flutter.dev/) -- UI framework
- [Riverpod](https://riverpod.dev/) -- state management
- [Drift](https://drift.simonbinder.eu/) -- local SQLite database
- [media_kit](https://github.com/media-kit/media-kit) -- video and audio playback
- [audio_service](https://pub.dev/packages/audio_service) -- background audio and media controls
- [youtubedl-android](https://github.com/JunkFood02/youtubedl-android) -- yt-dlp and ffmpeg for Android

## License

This project is licensed under the GNU General Public License v3.0 -- see the [LICENSE](LICENSE) file for details.
