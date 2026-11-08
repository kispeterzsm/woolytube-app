# Lyrics and transcript search: design

Goal: type a half-remembered line and find every track, or chapter of a long mix, that contains it. Lyrics are fetched automatically, the user can point a track or chapter at the right song when the match is wrong, and spoken playlists (podcasts, audiobooks, talks) use YouTube transcripts. It is set per playlist and is off by default.

Research behind this (live tests against the real library, 2026-11-08) is summarised at the end.

## 1. Playlist setting

`Playlists.lyricsMode`: nullable text, `null` = off (the default).
- `'lyrics'`: song lyrics. Sources in order: LRCLIB, YouTube Music, then the video's own manual (uploader-written) captions. Never speech-to-text captions.
- `'transcript'`: spoken content. Sources: manual captions first, then the original-language speech-to-text track (`<lang>-orig`). Never machine translations.

UI: in `playlist_settings_page.dart`, a `ListTile` (key `playlist-lyrics-mode`) under the Playback section that opens a picker: *Off*, *Song lyrics*, *Spoken transcript*. Below it, while the mode isn't off, a Tools tile `_FetchLyricsTile` (copy of `_FetchChaptersTile`) shows the backfill progress with a Stop button. Turning the mode on asks `confirmManualDownload` and starts the backfill. The add-playlist page doesn't need the option.

The mode is mirrored in the sidecar playlist block (`"lyricsMode": "lyrics"`, left out when off) and read back on import.

## 2. Storage (schema 15 → 16)

Drift tables:

```dart
class LyricsDocs extends Table {          // one per track, or per chapter of a mix
  IntColumn get id => integer().autoIncrement()();
  IntColumn get trackId => integer().references(Tracks, #id, onDelete: KeyAction.cascade)();
  TextColumn get chapterId => text().nullable()();   // MediaChapter.id; null = whole file
  IntColumn get offsetMs => integer().withDefault(const Constant(0))(); // chapter start; line times are relative to it
  TextColumn get kind => text()();                   // 'lyrics' | 'transcript'
  TextColumn get status => text()();                 // 'found' | 'none' | 'instrumental' | 'error'
  TextColumn get source => text().nullable()();      // 'lrclib' | 'ytmusic' | 'yt_subs' | 'yt_auto'
  TextColumn get sourceRef => text().nullable()();   // LRCLIB id, ytmusic browseId, caption language key, or a YouTube video id
  TextColumn get matchedArtist => text().nullable()();
  TextColumn get matchedTitle => text().nullable()();
  RealColumn get timeScale => real().withDefault(const Constant(1.0))(); // nightcore: localDur / originalDur
  BoolColumn get synced => boolean().withDefault(const Constant(false))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))(); // user chose this; automatic runs never replace it
  TextColumn get lang => text().nullable()();
  DateTimeColumn get checkedAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
}
// unique index on (track_id, COALESCE(chapter_id, ''))

class LyricsLines extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get docId => integer().references(LyricsDocs, #id, onDelete: KeyAction.cascade)();
  IntColumn get lineNo => integer()();
  IntColumn get startMs => integer().nullable()();   // already scaled by timeScale; relative to the doc (add offsetMs for file time)
  TextColumn get text => text()();                   // raw, for display
  TextColumn get searchText => text()();             // folded line i + ' ' + folded line i+1
}
```

FTS (created with `customStatement` in `onCreate` and the v16 step; Drift doesn't know fts5):

```sql
CREATE VIRTUAL TABLE lyrics_fts USING fts5(search_text, content='lyrics_lines', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE lyrics_vocab USING fts5vocab(lyrics_fts, 'row');
-- AFTER INSERT / DELETE / UPDATE triggers on lyrics_lines using the external-content 'delete' idiom
```

- `refreshIfChangedExternally` notifies the two new tables (the background worker writes through a second connection).
- `deletePlaylist`/`deleteTracks` delete docs explicitly, as they do segments.
- `Playlists.lyricsMode` needs the playlist revision trigger recreated (see the comment at `database.dart` L327).
- Chapters: a chapter doc is keyed by `MediaChapter.id`. When chapters change (edit, re-recognition, undo), docs whose `chapterId` is no longer active are deleted and the new chapters become due. A whole-file doc is not made for a file that plays as chapters in lyrics mode (the chapters cover it); in transcript mode the whole file gets one doc, and hits map to a chapter by time.

### Persistence across reinstall
- Text goes to `<playlist>/.woolytube_info/<safeId>.lyrics.json` (next to the info files, written tmp-then-rename like `keepVideoInfo`; deleted and moved at the same `playlist_service.dart` sites as info files). It holds every doc of the track with its lines.
- The main sidecar gets only user choices: per track `"lyricsPins": [{chapterId, status, source, sourceRef, matchedArtist, matchedTitle}]` when any doc is pinned. Import restores docs from the `.lyrics.json` files first and re-applies pins; pinned docs without a file are refetched by their `sourceRef`.

## 3. Fetching (`lib/services/lyrics/`)

Plain Dart services built from `(AppDatabase, LogService, …)` so they run in the app and in the headless background worker. All HTTP through `dart:io` `HttpClient` injected for tests.

- `lyrics_text.dart`: `foldForSearch` (NFKD-ish accent strip incl. Hungarian ő/ű, lower case, drop `'’`, other punctuation → space, collapse spaces), LRC parsing (`[mm:ss.xx]` with several stamps per line), json3 caption parsing (join segs, drop blank and `[Music]`-style lines, merge the rolling duplicate lines of ASR), building `LyricsLine`s and two-line search windows.
- `title_parser.dart`: rules R1–R9 from the library research: normalise brackets/symbols, detect nightcore, classify bracket groups (feat / noise / version / other = bracket artist), quoted titles, split on separators (2 parts = swappable), `X by Y`, metadata wins (info.json `artist`/`track`, `Provided to YouTube by` description, `Artist - Topic` uploader), nightcore description artist patterns, Shazam chapter titles split on ` — `, and a context word from the parent title for title-only chapters. Output: `SongQuery{artist?, title, swappable, nightcore, rawTitle, contextWord?}`.
- `lrclib_client.dart`: `get(artist, track, duration)`, `search(trackName, artistName)`, `searchQ(q)`, `getById(id)`. UA `WoolyTube/<version> (https://github.com/kispeterzsm/WoolyTube)`, ≥1 s between requests, 429/5xx back-off.
- `ytmusic_lyrics_client.dart`: innertube WEB_REMIX `next` → lyrics tab `browseId` (skip when `unselectable`) → `browse` → description runs. Plain text.
- `captions.dart`: pick a caption track from info.json `subtitles`/`automatic_captions` (json3, never m3u8 protocol, never translations); fetch over HTTP; parse.
- `lyrics_matcher.dart`: LRCLIB lookup order and acceptance rule (below), scoring, and nightcore time scale.
- `lyrics_service.dart`: `fetchTrack(track, {force})`, `backfillPlaylist(playlistId, {onProgress, cancellation})`, `applyPick(trackId, chapterId, LyricsPick)`, `clearPin`, `markNone`, `candidatesFor(query)` (for the picker), `writeLyricsFile`/`restoreFromFiles` for persistence.

Metadata per track: read `.woolytube_info/<id>.info.json` when present (artist, track, uploader, description, language, and caption URLs only if still present). For tracks without it, or when caption URLs are needed (stripped on save, valid ~6 h), call a new plugin method `getCaptionInfo(url)` that runs `--dump-json --no-playlist --skip-download` and returns `id, title, duration, language, description, uploader, channel, artist, track, alt_title` plus trimmed caption maps: for each `subtitles` key and for `-orig` keys of `automatic_captions` only, the json3 entry `{url, name}` (Kotlin `YtDlpPlugin.kt`, next to `handleGetVideoInfo`, using `executeInfoRequest`). In lyrics mode the extraction is only needed when LRCLIB and YT Music both missed (captions fallback) or when the title parse has no artist for a nightcore track (description artist); otherwise skip it — it costs seconds per track on a phone.

### LRCLIB lookup and acceptance
Order, stopping at the first accepted result: `get(A, T, duration)` (not for nightcore or chapters); `search(track_name=T, artist_name=A)`; if swappable the same swapped; `q="A T"` (with context word for chapters); `track_name=T` alone only when no artist is known.

Accept only when lyrics are non-empty and not instrumental, folded title similarity ≥ 0.75, and: when an artist is known, artist similarity ≥ 0.6; otherwise duration within ±4 s (whole files) or, for nightcore, local/original duration ratio within 0.70–0.93. Duration never gates chapters (they're often TV-size cuts); it only breaks ties. Prefer synced, then closest duration. An `instrumental: true` exact match → status `instrumental`.

Nightcore with a synced original: `timeScale = localDur / lrclibDur` when within the window; line times are scaled when stored.

### Retry and budget
`status` none/error docs are retried after 7 days (+ spread by track id, as SponsorBlock does), at most 4 attempts, unless pinned. The download service runs `_backfillMissingLyrics(playlist)` next to `_backfillMissingSponsorBlockSegments` (both call sites), gated on `lyricsMode != null`, stopping on cancel and on a time budget so the scheduled update stays inside its 7-minute soft limit. Chapters that come from recognition are fetched when they are applied (`recognition_review_page` after `applyRecognition`) if the playlist has lyrics on, and otherwise by the next backfill.

## 4. Search

`lib/services/lyrics/lyrics_search.dart`, `LyricsSearch(AppDatabase)`:
1. Fold the query, split, drop stop words (English + Hungarian) unless nothing would remain.
2. Typo expansion: words not in `lyrics_vocab` → up to 5 vocabulary words within edit distance 1 (≤5 letters) or 2, most frequent first, never stop words. Vocabulary cached in memory, invalidated on lyrics table updates.
3. One FTS OR query (last word as prefix when ≥4 letters) ordered by bm25, LIMIT 150, joined to docs/tracks/playlists with `lyrics_mode IS NOT NULL`.
4. Rerank in Dart over spans of 1–3 lines around each candidate: per query word best match (exact 1.0, prefix 0.9, else 1 − lev/maxLen, < 0.7 → 0), stop words weigh 0.3; `score = 0.85·coverage + 0.15·in-order fraction − 0.02·(extra lines)`; tie-breaks: line-word coverage, then bm25.
5. Best span per doc, cut at 0.65, sorted by score. Result: `LyricsHit{trackId, chapterId?, docId, lineText, highlightRanges, positionMs? (file time = offsetMs + startMs), score, kind}`.
6. Debounced ~200 ms in the UI; runs on Drift's background isolate.

UI:
- Home search: a "Lyrics" section after Tracks (`_SearchHeader('Lyrics')`), rows showing the track (and chapter) title and the matched line with highlights and a timestamp. Tap → play the track at the chapter, and seek to 2 s before the line when synced.
- Playlist detail search: lyric matches are added to the filter; the single subtitle line shows `“…line…” · 1:23`.
- `PlaybackService.playTrack` gets `Duration? startAt` (file time), threaded through `_startQueue` to `_loadAndPlay`, converted to item-relative time when playing chapters.

## 5. Viewing and correcting

`LyricsPage(track, chapterId?)`, opened from the track actions sheet (`track-actions-lyrics`, after chapters) and the chapter actions sheet (`chapter-actions-lyrics`):
- Header: matched "Artist – Title", source and whether it is automatic or chosen; for a file with chapters, a chapter selector listing each chapter with its status.
- Body: the lines; synced lines show times and tapping one plays from there.
- Actions: **Wrong song?** opens the picker; **No lyrics here** (status none, pinned); **Refetch automatically** (drops the pin, fetches again).
- Picker (`LyricsPickerSheet`): search field prefilled with the parsed `Artist Title`; results from LRCLIB `search` (`artist – title · album · m:ss · synced/plain/instrumental`) with an expandable lyrics preview; choosing one stores it pinned with `source='lrclib', sourceRef=id`. A second tab "From YouTube" takes a video link (e.g. an official lyric video) and uses its manual captions (`yt_subs`, `sourceRef=<videoId>:<lang>`), and in transcript mode this is the only tab.

## 6. Research summary
- LRCLIB: 82% correct on a 40-track sample with the full rules, 0 wrong; most hits synced. `q` doesn't search lyric text. Nightcore durations are 0.77–0.89 of the original in ~90% of nightcore tracks.
- YouTube Music lyrics: 2/10 (official uploads only), plain text, no login.
- YouTube captions: excellent for talks; for music 11/21 had none, 4/21 had uploader lyrics (one was a translation), 5/21 speech-to-text garbage.
- Search prototype: FTS5 + vocabulary typo expansion + Dart rerank ranked the right song first for 21/21 misremembered queries; 2–10 ms per query at 5,000 songs without stop words.
