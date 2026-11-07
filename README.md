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
- **Album chapters** -- play and shuffle chapters within an album before moving to another playlist entry; add or edit your own chapters without changing the media file
- **Persistent storage** -- files are saved to accessible folders that survive app uninstall; nothing you downloaded is deleted to make room for a new copy until that copy has finished
- **Audio-only mode** -- download and play just the audio from any video
- **Offline covers** -- every download keeps its cover as a file, so covers show offline and after YouTube deletes the video
- **Your order** -- new videos go where you put them in the YouTube playlist; tracks already downloaded keep their order even when YouTube reorders or deletes videos. File names start with the position, so the folder sorts in playlist order
- **Plays without the app** -- each playlist folder has a `.m3u8` playlist, files carry title/artist/album tags and cover art, and video downloads prefer H.264 so they play on almost any device
- **Library backup** -- Settings > Library backup exports everything (covers, playlist files, a copy of the app data) and restores playlists from any copied folder
- **Audio focus** -- playback pauses for calls and resumes when they end, lowers volume for short prompts, and pauses when headphones disconnect

## Installation

1. Download the APK from the link above
2. On your Android device, enable **Install from unknown sources** if prompted
3. Open the APK and install

**Requirements:** Android 7.0 (API 24) or higher.

## Playlists and downloads

Tap the update icon on a playlist to sync it with YouTube and download new entries; while a download runs the same control cancels it, keeping finished tracks. Download problems are shown in the app with a **Details** action. Deleting a playlist offers to remove its downloaded files too; if they are kept, the folder is no longer offered for import on the next launch. Switching a playlist between video and audio-only uses a new folder: tracks YouTube no longer has (and your own files) move along, every other track keeps playing its current file until the new format has downloaded, and switching back reuses the earlier folder.

## Album chapters

Enable **Play chapters as tracks** in playlist settings. Shuffle plays the current album's chapters in random order, then chooses another playlist entry. Each album and chapter is visited once per playback cycle. Scheduled up-next requests play after the current album finishes.

Open **Chapters** from the player's list icon, or long-press a playlist entry and choose **Playback settings → Chapters**. **Album playback** can inherit the playlist setting or override it with **Whole video** or **Chapters**. Individual chapters have play and queue actions.

New downloads retain YouTube chapter metadata automatically. For older downloads, use **Fetch YouTube chapters** on an album or **Fetch missing chapters for downloaded files** in playlist settings. Missing chapters fall back to whole-file playback.

Use **Mark chapters** to play the full file, mark a start and end, and name the range. The **+** button also accepts manual timestamps. Tap a chapter to edit it; its menu includes deletion. Custom edits are kept separately from downloaded chapters, and **Restore downloaded chapters** switches back. Changes take effect when starting playback again.

All chapter data lives in WoolyTube's database and `woolytube_meta.json`. The complete audio/video file remains unchanged and independently playable in other apps. Replacing a file disables its old chapter timings.

## Building from Source

**Prerequisites:** Flutter SDK >= 3.7.2, Java 11, Android SDK

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter build apk --split-per-abi
```

The built APKs will be in `build/app/outputs/flutter-apk/`.

## Tech Stack

- [Flutter](https://flutter.dev/) -- UI framework
- [Riverpod](https://riverpod.dev/) -- state management
- [Drift](https://drift.simonbinder.eu/) -- local SQLite database
- [media_kit](https://github.com/media-kit/media-kit) -- video and audio playback
- [audio_service](https://pub.dev/packages/audio_service) -- background audio and media controls
- [youtubedl-android](https://github.com/JunkFood02/youtubedl-android) -- yt-dlp and ffmpeg for Android

## License

This project is licensed under the GNU General Public License v3.0 -- see the [LICENSE.txt](LICENSE.txt) file for details.
