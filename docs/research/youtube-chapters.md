# YouTube chapters as shuffleable tracks

Research date: 2026-09-13. The source findings and proposal below were followed by implementation and Android validation on the same date. See the implementation status at the end.

## Recommendation

Keep one complete, ordinary media file per downloaded video, usable independently in other apps. Chapter playback and editing are a WoolyTube metadata layer over that file. When enabled, shuffle all eligible chapters of the current album before randomly selecting another playlist entry. Support a playlist default, a per-album override, and locally authored chapters.

These are the user's revised requirements. Splitting, partial downloads, and rewriting media to save custom chapters are outside this feature. Other apps can play the complete file without WoolyTube or its metadata; displaying WoolyTube's custom chapter list in other apps is not required. Preserve the existing media format and full timeline. Compatibility still depends on each external player's supported formats and codecs.

## Obtaining chapters

yt-dlp's YouTube extractor tries player-bar chapter data, engagement-panel markers, then timestamp/title lines from the video description. It can return no chapters. The extracted chapter representation does not carry a reliable creator-versus-automatic provenance flag. Treat chapter availability and musical usefulness separately. [YouTube extractor source](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/youtube/_video.py)

The common extractor reads chapter titles and start times; description parsing supports timestamp-first or timestamp-last lines. It requires a known duration and rejects some invalid starts. [Common extractor source](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/common.py)

Processed JSON contains a `chapters` array with `title`, `start_time`, and `end_time` in seconds, for example:

```json
{
  "chapters": [
    {"title": "Song A", "start_time": 0.0, "end_time": 243.5},
    {"title": "Song B", "start_time": 243.5, "end_time": 501.0}
  ]
}
```

The numbers above are illustrative. yt-dlp processing fills missing ends from the next start or video duration, supplies missing titles, and can insert an initial unnamed chapter before the first supplied timestamp. Consequently, do not assume every returned chapter corresponds to a named song. [yt-dlp metadata normalization](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/YoutubeDL.py)

YouTube supports uploader-authored and automatic chapters. Authored chapters override automatic ones; even eligible videos need not receive automatic chapters. An album may therefore have no usable chapter data. [YouTube Help](https://support.google.com/youtube/answer/9884579?hl=en)

Recommendation: retain valid ranges with millisecond precision; reject nonfinite, negative, empty, or out-of-duration ranges; preserve the whole video as the fallback. Fetch detailed metadata per video rather than relying on a flat playlist listing. Avoid adding a separate description scraper initially because yt-dlp already has that fallback.

## Metadata, splitting, and partial downloads

The following is a capability comparison from the initial research. The selected design uses saved metadata only; splitting and partial downloads are not planned. Embedding chapter markers is also unnecessary for the WoolyTube layer.

| Approach | Supported operation | Implication |
| --- | --- | --- |
| Save chapter metadata | Read the processed JSON chapter array | Supports app-managed ranges without splitting |
| Embed markers | `--embed-chapters` | Adds navigational metadata to the file; the app still needs queue expansion to shuffle chapters |
| Separate files | `--split-chapters` | Creates one output per chapter; `chapter:` output templates expose `section_number`, `section_title`, `section_start`, and `section_end` |
| Selected downloads | `--download-sections` with chapter-title regex or `*start-end` | Requires FFmpeg; useful when only selected songs are wanted |

yt-dlp also offers `--force-keyframes-at-cuts`, which re-encodes and is documented as slow. [Official yt-dlp options](https://github.com/yt-dlp/yt-dlp#usage-and-options)

The splitting postprocessor cuts the already downloaded file with FFmpeg, normally stream-copies, and leaves the original file in place. Missing chapters produce a message and no split files. Inference: retaining the album plus all its split tracks increases storage roughly by another album, and video cuts need verification around keyframes. [FFmpeg split postprocessor](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/postprocessor/ffmpeg.py)

The Android wrapper supports yt-dlp options and requires its FFmpeg module to be included and initialized for FFmpeg features. [Android wrapper documentation](https://github.com/yausername/youtubedl-android#ffmpeg) WoolyTube already depends on both wrapper modules at 0.18.1 in `plugins/woolytube_ytdlp/android/build.gradle` and initializes FFmpeg in `YtDlpPlugin.kt`. Inference: splitting needs integration and device verification, but not a new FFmpeg dependency. Codec support, cutting accuracy, temporary storage, CPU time, and battery cost remain unmeasured on this app's Android build.

## Playback support and traps

The repository locks `media_kit` to 1.2.6. Its public `Media` constructor accepts `start` and `end` durations. [Media API](https://pub.dev/documentation/media_kit/1.2.6/media_kit/Media-class.html)

Inspection of installed package 1.2.6 shows that the native player applies these ranges as mpv `start`/`end` options during loading and clears them during unloading. It forwards raw mpv position/duration and sends absolute seeks. Its `setShuffle` reconstructs entries from URI strings using `Media.new`, losing range bounds. Keep shuffle in the application's queue and open the selected bounded item individually. This last sentence is a recommendation based on source inspection, not a device-tested workaround. [Native player source](https://github.com/media-kit/media-kit/blob/main/media_kit/lib/src/player/native/player/real.dart)

`Media` equality/hashCode use only the URI, and cached `extras` are also keyed by URI. Different songs from one album therefore need distinct application-level identities; do not use `Media` equality or its cached extras to identify chapters. [Native Media source](https://github.com/media-kit/media-kit/blob/main/media_kit/lib/src/models/media/media_native.dart)

mpv documents `start=30` with `end=40` as ten seconds of playback. `time-pos` is position within the source file and `duration` is source-file duration. Range options therefore do not provide a zero-based chapter timeline. [mpv playback options](https://mpv.io/manual/stable/#options-start), [mpv properties](https://mpv.io/manual/stable/#properties)

The app should expose `chapterDuration = end - start`, display position clamped from `sourcePosition - start`, and translate user seeks to `start + chapterPosition`. Apply this consistently to screen controls and Android media notifications. Clamp all seek entry points because a start option is not a substitute for enforcing the chapter's lower seek boundary.

## Remaining validation

Before committing to the playback design, run a small device experiment with two different ranges of the same local album: open, auto-complete, next/previous, repeat, shuffle, seek, pause/resume, and return to whole-file playback. Check both audio and video formats, boundary overshoot, notification timing, and whether reloading introduces audible gaps. Gapless album transitions are not established by this research. Check real chapter-bearing, chapter-free, description-only, and automatic-chapter videos using the actual on-device yt-dlp version; the wrapper can update its executable independently of Gradle dependencies.


## Proposed WoolyTube behavior

The recommendation below is a design proposal, based on the source findings above and the current working tree at commit `b2da490` (including existing uncommitted changes). This investigation does not implement chapter support.

Download each source video once, retain its chapter metadata, and optionally expose chapters as individual playback items. For an hour-long album containing twelve chapters, the app would store one media file and present twelve songs for playback and shuffle.

Proposed controls implementing the revised requirements:

- A playlist setting, **Play chapters as tracks**, off by default. When enabled, each chaptered video becomes a group of chapter playback items; ordinary videos remain whole tracks.
- A per-video override: **Use playlist setting / Whole video / Chapters**. This also allows one album in a mixed playlist to behave as songs without turning every chaptered podcast into separate items.
- An expandable chapter list with titles and durations, and actions to play or queue a chapter. The parent video retains its download status and file actions.
- A **Chapters** editor and **Mark chapter start / Finish chapter** control for creating named local ranges, including for files with no YouTube chapters.
- Whole-video playback remains available. It should not also appear in an automatically expanded queue, which would play the album twice.

With chapters enabled, ordered playback follows playlist order and then chapter order. Shuffle has two levels: choose a playlist entry, then shuffle its chapters to completion before selecting another entry. For example: album A/song 4, album A/song 1, the rest of album A in random order, an ordinary song, then every chapter of album B in random order. An album has one place in the outer shuffle cycle, regardless of its number of songs.

Proposed cycle rules: choose from unvisited eligible playlist entries without replacement, and from unvisited eligible chapters within an album without replacement. A directly selected chapter plays first and the remaining chapters follow in shuffled order. With a single album, only its chapters shuffle. After the playlist cycle is exhausted, stop, matching the current finite queue behavior. A future repeat option would explicitly start a new cycle.

Keep the remaining chapter order and the outer playlist order as separate state. Previous follows actual playback history, including across album transitions; replaying a chapter through Previous does not reset the remaining shuffle pool. Manual Next consumes the current chapter and advances within the album; a separate explicit selection can leave the album immediately. Changing shuffle preserves the current item and already consumed entries, reordering only the remainder.

Proposed manual up-next behavior: scheduled additions run at the next album boundary, after all remaining chapters of the current album. An explicitly queued chapter is a single requested item; an album queued using its parent entry follows that album's override. Explicit Play selections take effect immediately. This changes the current per-track up-next priority and must be visible in the queue UI.

Missing or unusable chapter metadata falls back to the whole video. An explicit whole-video selection should remain a whole-video item for that selection. Playlist option changes should take effect on the next queue build, keeping the current song and its seek range stable.

## Where this fits the existing app

| Existing code | Finding and proposed change |
| --- | --- |
| [YtDlpPlugin.kt](../../plugins/woolytube_ytdlp/android/src/main/kotlin/com/woolytube/ytdlp/YtDlpPlugin.kt) and [ytdlp_service.dart](../../lib/services/ytdlp_service.dart) | Playlist discovery uses flat entries and returns a reduced set of fields. Full-video info already exists, but the download call returns no metadata. Capture chapters from the actual per-video extraction, or use the full-video info path for existing downloads. |
| [database.dart](../../lib/database/database.dart) | A `Track` currently owns the source video, local file, download status, and playlist index. Add chapter records belonging to that track, plus playback preferences. Keep file ownership on the parent. |
| [download_service.dart](../../lib/services/download_service.dart) | Download completion and existing-file reuse are separate paths. New downloads should persist chapters; existing files need metadata backfill without downloading media again. Metadata failure should not turn a successful media download into a failed download. |
| [playlist_service.dart](../../lib/services/playlist_service.dart) | Sync matches entries by video ID. Keep chapter records out of this source-track list so syncing one album cannot confuse its songs with separate YouTube videos. Local replacement and forced insertion also need explicit chapter handling. |
| [metadata_service.dart](../../lib/services/metadata_service.dart) | `woolytube_meta.json` preserves downloads across import/reconciliation. Extend its write, parse, and import paths with optional chapter data and settings; old metadata should load with no chapters and whole-video playback. |
| [playback_service.dart](../../lib/services/playback_service.dart) | Both the source queue and manual up-next queue are `List<Track>`. Shuffle uses queue indices, and each transition opens one `Media`. Introduce playback items and album groups, with separate outer playlist and inner chapter shuffle state and playback history. Keep shuffle in the app. |
| [playback_providers.dart](../../lib/providers/playback_providers.dart), [player_page.dart](../../lib/pages/player_page.dart), [mini_player.dart](../../lib/widgets/mini_player.dart) | Publish the current playback item, title, and duration while retaining access to its parent track for artwork and file information. Update highlighting so chapters sharing a parent are distinguishable. |
| [playback_notification_controller.dart](../../lib/services/playback_notification_controller.dart) and [audio_handler.dart](../../lib/services/audio_handler.dart) | System playback currently identifies and displays the parent track. Publish a chapter-specific media ID, title, duration, and position; update Android Auto browsing and media-ID dispatch as well as lock-screen controls. |

## Storage and metadata acquisition

A chapter record needs a stable ID, parent track ID, chapter-set ID, chapter order, title, start milliseconds, and end milliseconds. Distinguish downloaded chapter sets from the user's custom set, with an explicit active-set selection. Use distinct playback identities for whole tracks and chapters; the file path and YouTube ID cannot identify a chapter by themselves. Give repeated manual queue entries their own occurrence identity for queue editing and playback history.

Prefer collecting chapter information during the existing download extraction, using a temporary info JSON file or structured result from the plugin, and persisting only the needed fields in Drift and `woolytube_meta.json`. This avoids a second extraction for each new download. Keep flat playlist discovery fast; it should not resolve every video's full metadata just to list a playlist.

For existing downloads, offer a metadata-only chapter refresh, deduplicating network lookups by video ID and respecting the app's network policy. Record the difference between not checked, checked with no chapters, and a failed check. Cache successful results, preserve known chapters on transient failures, and avoid repeatedly probing chapterless videos on every sync.

Validate finite numeric times, positive ranges, ordering, and media-duration limits. Fill a missing end from the next chapter start or a known source duration; fall back to whole-video playback if a safe bounded chapter list cannot be formed. Treat real metadata gaps explicitly rather than silently extending a named song through unrelated material. Keep milliseconds instead of rounding chapter starts to integer seconds.

Cached chapters describe a particular downloaded file. Do not automatically overwrite their timings on routine playlist refresh: a creator may have edited the online video since download. A replacement local file must disable inherited YouTube chapters until timings are confirmed or replaced. Keep downloaded chapter metadata usable offline even if the source later disappears.

Local chapters also belong to the particular file they were marked against. Replacing its content invalidates those timings until reviewed; renaming or moving the same file does not. Metadata export/import must preserve custom chapters, their stable identities, active chapter-set selection, and the per-album playback override. Chapter edits must never rewrite, truncate, rename, or split the media file.

## Custom chapter creation and editing

Reuse the interaction pattern of [segment_mark_button.dart](../../lib/widgets/segment_mark_button.dart) and the skip-segment editor in [playlist_detail_page.dart](../../lib/pages/playlist_detail_page.dart), with separate chapter state and storage. Chapters are playable named ranges and must not be stored as SponsorBlock skip segments.

1. Open **Chapters** for a downloaded album and choose **Add chapter**. Author against the full-file timeline so the user can reach any song, even when chapter playback is enabled.
2. Seek or listen to the beginning and tap **Mark chapter start**. Show a persistent pending marker. The user can continue listening or seek to the end.
3. Tap **Finish chapter** to capture the end immediately, then open a sheet with **Title**, **Start**, and **End**. Freeze both captured times before opening the sheet so typing a title cannot move the boundary.
4. Save the chapter, or discard the pending range. Allow manual timestamp entry as an alternative to listening through the range. Chapter creation works offline for both audio and video files.

List chapters in timestamp order with title, start/end, duration, and a preview action. Allow rename, timing adjustment, and deletion. Reject empty or reversed ranges, out-of-file times, and overlaps within the active chapter set; allow adjacent chapters to share a boundary. Allow intentional gaps for intros or unmarked material, clearly showing that those gaps are omitted during chapter playback. Whole-file playback still includes everything.

On the first edit to downloaded chapters, create an editable local copy of the chapter set and make it active. If no downloaded chapters exist, start with an empty local set. Additions to an existing covered interval must explicitly edit or split that chapter instead of producing overlapping songs. Retain the downloaded set separately so **Restore downloaded chapters** is possible. Network refreshes never overwrite the custom set, and local chapters do not require SponsorBlock to be enabled.

Bind pending marks to the source file and cancel them when playback switches to another source, stops, or the user discards them. Prevent automatic source transitions while actively marking. Save all times in source-file milliseconds. Apply edits to the next playback session so the current chapter's end and the current album's remaining shuffle order stay stable; label that behavior in the editor.

Deleting the final custom chapter leaves the chosen custom set empty and falls back to whole-file playback. Do not silently reactivate downloaded chapters the user intentionally replaced. Restoring the downloaded set is a separate explicit action.

## Playback module and timeline rules

Put album grouping, chapter order, shuffle history, and time translation behind the playback module's interface. Callers should select a playback item, read its title/position/duration, and seek within it; screens should not calculate chapter offsets or shuffle pools independently. Internally, a playback item combines the parent track with optional chapter bounds.

For a chapter at source time 12:30–16:45:

- Open the same local file with start 12:30 and end 16:45.
- Expose duration 4:15 and initial position 0:00.
- Translate a user seek to 1:00 into source time 13:30, clamping all seek inputs to the chapter range.
- Make Previous's existing three-second restart rule use chapter-relative position and restart at 12:30.
- At the chapter end, advance once to a remaining chapter of this album. Once the album is exhausted, consume a scheduled up-next item or choose the next playlist entry. With autoplay off, stop at the current chapter's end.

Use native end bounds for stopping playback, with a serialized transition path that rejects stale completion events after a manual Next or another open. Position polling alone is unsuitable as the only chapter-end mechanism in background playback. Reset projected position/duration on an item change so the previous album's timestamps cannot briefly appear as the next song's progress.

SponsorBlock remains stored in source-file time. Intersect its displayed segments with the current chapter and translate them for the progress bar. A skip crossing the chapter end must complete that chapter under the same autoplay rules, rather than seeking into another song. Newly marked local segments must convert back to source time before saving. Embedded subtitle timing stays on the source timeline.

This design gives file lifecycle operations one owner and concentrates chapter playback rules in one module. Creating extra ordinary `Track` rows with the same file would spread shared-file deletion, synchronization, and download-count problems through existing callers.

## Implementation order and verification

This is a moderate feature spanning persistence and playback, rather than a download-flag change. Suggested delivery order:

1. Prove bounded playback on Android using several ranges of the same M4A and MP4 file. Check exact starts, chapter-end completion, repeated same-file opens, rapid Next, background playback, seeking, pause/resume after completion, and transition back to a whole file. Measure audible gaps; do not promise gapless album playback without evidence.
2. Add chapter parsing, migration, persistence, metadata import/export, and metadata-only backfill. Test missing/malformed chapters, fractional times, old metadata, replacement files, interrupted-download recovery, and preservation of custom sets during refresh.
3. Add playback items, album groups, and both shuffle levels. Test that albums finish before another entry starts, chapters and parent entries do not repeat within their cycles, single-album playlists work, and Previous follows history. Cover parent Always skip inheritance, direct chapter selection, album overrides, scheduled up-next at album boundaries, deleted/missing files, and exactly-once advancement.
4. Add the playlist setting, album override, chapter selection, and custom editor. Test immediate timestamp capture before title entry, cancel/save, manual time edits, overlap validation, custom-set restoration, offline operation, and metadata round trips. Check that editing chapters leaves media bytes unchanged and that the full file still plays in an external Android player.
5. Add consistent player/notification/Android Auto presentation. Test translated seek/restart behavior and SponsorBlock intersections through the playback interface.

For implementation, run the repository's host suite with `/home/wooly/flutter/bin/flutter test --concurrency=1` and run `./build-apk.sh` after code modifications, as required by AGENTS.md. On this machine run tests and builds separately to avoid exhausting RAM. Host tests cannot establish native Android clipping accuracy or transition audio quality.

## Implementation status

Implemented chapter metadata capture, existing-download metadata fetch, playlist and album playback preferences, custom marking/editing/restoration, chapter-relative playback and system controls, and album-first shuffle. Playback uses native start/end bounds over the original file. Drift schema 10 stores chapter sets as JSON on the owning source track, with a nullable per-track override and playlist preference. A separate playback queue owns the album and chapter shuffle pools and history.

Host coverage includes parsing, migration from schema 9, custom metadata persistence/import, unchanged media bytes, album ordering and shuffle cycles, manual queue priority, chapter identity, relative seeking, duplicate completion, SponsorBlock intersections, replacement invalidation, and chapter editing dialogs.

Device validation used the connected ASUS phone and its Vibe Mix playlist, with Thousand Foot Krutch's “The End is Where We Begin.” YouTube metadata supplied 15 chapters. “We Are” opened at 0:00 / 3:18 in WoolyTube and the Android media session. Seeking near its end advanced automatically to another chapter. Shuffled navigation visited 14 distinct songs before selecting another playlist entry; the existing SponsorBlock intro rule skipped the introduction. Custom start/end marking and saving worked; the temporary custom set was then removed by restoring downloaded chapters. The album's SHA-256 was identical before and after editing, and VLC opened the same complete M4A file successfully.

This device check establishes functional chapter playback on that phone and album. It does not establish gapless transitions across all codecs or devices. Chapter data availability still depends on the source video and yt-dlp extraction.
