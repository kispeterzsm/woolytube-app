import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import '../../database/database.dart';
import '../chapters.dart';
import '../library_layout.dart';
import '../log_service.dart';
import '../playlist_service.dart';
import '../ytdlp_service.dart';
import 'captions.dart';
import 'lrclib_client.dart';
import 'lyrics_files.dart';
import 'lyrics_matcher.dart';
import 'lyrics_models.dart';
import 'title_parser.dart';
import 'ytmusic_lyrics_client.dart';

/// A track's or chapter's lyrics changed (fetched, picked, cleared).
class LyricsChange {
  final int trackId;

  /// null = the whole-file doc, or several docs of the track at once.
  final String? chapterId;

  const LyricsChange(this.trackId, [this.chapterId]);
}

/// Reads yt-dlp's info for a video URL (see `YtDlpService.getCaptionInfo`).
typedef CaptionInfoLoader = Future<Map<String, dynamic>> Function(String url);

/// One thing a doc is about: the whole file or one chapter.
class _Slot {
  final String? chapterId;
  final int offsetMs;
  final int? durationMs;
  final String title;

  const _Slot(this.chapterId, this.offsetMs, this.durationMs, this.title);

  bool get isChapter => chapterId != null;
}

/// What one track's fetch did.
class _Outcome {
  int due = 0;
  int found = 0;
  int missing = 0;
  int failed = 0;
}

/// Fetches lyrics and transcripts, stores them as lyrics docs and applies
/// the user's corrections. Plain Dart: runs in the app and in the headless
/// background worker.
class LyricsService {
  LyricsService(
    this._db,
    this._log, {
    HttpClient? http,
    YtDlpService? ytdlp,
    String? appVersion,
    DateTime Function()? clock,
    LrclibClient? lrclib,
    YtMusicLyricsClient? ytMusic,
    CaptionsClient? captions,
    CaptionInfoLoader? captionInfo,
    Future<void> Function(Duration)? sleep,
    this.extractionGap = const Duration(seconds: 2),
  }) : _http = http,
       _appVersion = appVersion,
       _clock = clock ?? DateTime.now,
       _lrclibOverride = lrclib,
       _ytMusicOverride = ytMusic,
       _captionsOverride = captions,
       _captionInfo = captionInfo ?? ytdlp?.getCaptionInfo,
       _sleep = sleep ?? Future<void>.delayed;

  final AppDatabase _db;
  final LogService _log;
  final HttpClient? _http;
  final String? _appVersion;
  final DateTime Function() _clock;
  final LrclibClient? _lrclibOverride;
  final YtMusicLyricsClient? _ytMusicOverride;
  final CaptionsClient? _captionsOverride;
  final CaptionInfoLoader? _captionInfo;
  final Future<void> Function(Duration) _sleep;
  final _changes = StreamController<LyricsChange>.broadcast();

  /// Shortest gap between two yt-dlp extractions (seconds each on a phone,
  /// and YouTube rate-limits caption downloads).
  final Duration extractionGap;

  /// Docs without lyrics are tried this often, at most [maxAttempts] times.
  static const missingRetryInterval = Duration(days: 7);

  /// Failed lookups (offline, rate limited) are tried again sooner.
  static const errorRetryInterval = Duration(hours: 6);
  static const maxAttempts = 4;

  /// A backfill stops after this many tracks in a row failed: the service
  /// is down or the phone offline.
  static const _maxFailuresInARow = 3;

  LrclibClient? _lrclibClient;
  YtMusicLyricsClient? _ytMusicClient;
  CaptionsClient? _captionsClient;
  LyricsMatcher? _lyricsMatcher;
  DateTime? _lastExtraction;
  final _trackLocks = <int, Future<void>>{};

  /// Fires after this service wrote a track's lyrics.
  Stream<LyricsChange> get changes => _changes.stream;

  Future<LrclibClient> _lrclib() async {
    final override = _lrclibOverride;
    if (override != null) return override;
    final existing = _lrclibClient;
    if (existing != null) return existing;
    var version = _appVersion;
    if (version == null) {
      try {
        version = (await PackageInfo.fromPlatform()).version;
      } catch (_) {
        version = null;
      }
    }
    return _lrclibClient ??= LrclibClient(
      http: _http,
      userAgent: lyricsUserAgent(version),
    );
  }

  Future<LyricsMatcher> _matcher() async =>
      _lyricsMatcher ??= LyricsMatcher(await _lrclib());

  YtMusicLyricsClient get _ytMusic =>
      _ytMusicOverride ?? (_ytMusicClient ??= YtMusicLyricsClient(http: _http));

  CaptionsClient get _captions =>
      _captionsOverride ?? (_captionsClient ??= CaptionsClient(http: _http));

  /// Fetches every due doc of [track] by its playlist's mode: the whole
  /// file, or each active chapter of a file that plays as chapters in
  /// lyrics mode. Docs found recently, retried too often, or pinned are
  /// skipped; [force] refetches unpinned ones anyway. Does nothing when the
  /// playlist has lyrics off.
  Future<void> fetchTrack(Track track, {bool force = false}) async {
    await _fetchTrack(track, force: force);
  }

  /// Fetches the due docs of every downloaded track of a playlist, one
  /// track at a time, until done, [cancellation] or [budget] runs out.
  Future<LyricsBackfillResult> backfillPlaylist(
    int playlistId, {
    void Function(LyricsFetchProgress progress)? onProgress,
    LyricsCancellation? cancellation,
    Duration? budget,
  }) async {
    final playlist = await _db.getPlaylistOrNull(playlistId);
    final mode = LyricsMode.fromDb(playlist?.lyricsMode);
    if (playlist == null || mode == null) return const LyricsBackfillResult();
    final deadline = budget == null ? null : _clock().add(budget);

    final docsByTrack = <int, List<LyricsDoc>>{};
    for (final doc in await _db.lyricsDocsForPlaylist(playlistId)) {
      docsByTrack.putIfAbsent(doc.trackId, () => []).add(doc);
    }
    final now = _clock();
    // Pins restored from the sidecar without their text.
    final emptyPins = <int>{};
    for (final docs in docsByTrack.values) {
      for (final doc in docs) {
        if (doc.pinned &&
            doc.status == LyricsStatus.found &&
            (await _db.lyricsLinesInRange(doc.id, 0, 0)).isEmpty) {
          emptyPins.add(doc.id);
        }
      }
    }
    final due = [
      for (final track in await _db.getTracksForPlaylist(playlistId))
        if (_eligible(track, mode) &&
            _slotsFor(track, playlist, mode).any((slot) {
              final doc =
                  docsByTrack[track.id]
                      ?.where((d) => d.chapterId == slot.chapterId)
                      .firstOrNull;
              return _isDue(doc, mode, now) || emptyPins.contains(doc?.id);
            }))
          track,
    ];

    var total = _Outcome();
    var cancelled = false;
    var outOfTime = false;
    var failuresInARow = 0;
    onProgress?.call(LyricsFetchProgress(done: 0, total: due.length));
    for (final (index, track) in due.indexed) {
      if (cancellation?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      if (deadline != null && !_clock().isBefore(deadline)) {
        outOfTime = true;
        break;
      }
      final outcome = await _fetchTrack(
        track,
        cancellation: cancellation,
        deadline: deadline,
      );
      total
        ..due += outcome.due
        ..found += outcome.found
        ..missing += outcome.missing
        ..failed += outcome.failed;
      failuresInARow =
          outcome.failed > 0 && outcome.found + outcome.missing == 0
              ? failuresInARow + 1
              : 0;
      onProgress?.call(LyricsFetchProgress(done: index + 1, total: due.length));
      if (failuresInARow >= _maxFailuresInARow) {
        _log.warn(
          'Lyrics: stopping "${playlist.name}" after $failuresInARow '
          'failed tracks in a row',
        );
        break;
      }
    }
    if (cancellation?.isCancelled ?? false) cancelled = true;
    if (total.due > 0) {
      _log.info(
        'Lyrics: "${playlist.name}": ${total.found} found, '
        '${total.missing} without, ${total.failed} failed'
        '${cancelled ? ' (stopped)' : ''}${outOfTime ? ' (out of time)' : ''}',
      );
    }
    return LyricsBackfillResult(
      due: total.due,
      found: total.found,
      missing: total.missing,
      failed: total.failed,
      cancelled: cancelled,
      outOfTime: outOfTime,
    );
  }

  /// LRCLIB search results for the picker's free text [query].
  Future<List<LyricsCandidate>> candidatesFor(String query) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final client = await _lrclib();
    var records = await client.searchQ(text);
    if (records.isEmpty) records = await client.search(trackName: text);
    return [for (final record in records) record.toCandidate()];
  }

  /// The picker's starting query for a track or chapter: the parsed
  /// "Artist Title", or the matched one when a doc exists.
  Future<String> pickerQueryFor(int trackId, String? chapterId) async {
    final doc = await _db.lyricsDocFor(trackId, chapterId);
    if (doc != null && doc.matchedTitle != null) {
      return [
        if (doc.matchedArtist != null) doc.matchedArtist!,
        doc.matchedTitle!,
      ].join(' ');
    }
    final track = await _db.getTrack(trackId);
    if (track == null) return '';
    if (chapterId != null) {
      final chapter =
          ChapterData.decode(
            track.chaptersJson,
          ).active.where((c) => c.id == chapterId).firstOrNull;
      if (chapter != null) {
        return parseChapterTitle(chapter.title).searchText;
      }
    }
    final playlist = await _db.getPlaylistOrNull(track.playlistId);
    final meta =
        playlist == null ? null : await _readInfo(playlist.outputPath, track);
    return parseSongTitle(
      track.title,
      meta: meta == null ? null : VideoMeta.fromInfo(meta),
    ).searchText;
  }

  /// Stores what the user chose, pinned: fetches the chosen record, or
  /// marks the doc as having no lyrics for [LyricsPick.none].
  ///
  /// For YouTube captions ([LyricsSource.ytSubs]) [LyricsPick.sourceRef] is
  /// `<videoId>:<lang>`, or just `<videoId>` to let the service choose the
  /// video's caption track; the stored ref names the track it took.
  Future<void> applyPick(int trackId, String? chapterId, LyricsPick pick) {
    return _locked(trackId, () async {
      final track = await _db.getTrack(trackId);
      if (track == null) throw StateError('The track is gone.');
      final playlist = await _db.getPlaylistOrNull(track.playlistId);
      if (playlist == null) throw StateError('The playlist is gone.');
      final mode = LyricsMode.fromDb(playlist.lyricsMode) ?? LyricsMode.lyrics;
      final slot = _slotFor(track, playlist, chapterId);
      final draft = await _draftForPick(track, slot, mode, pick);
      await _db.replaceLyricsDoc(draft);
      await _persist(track, playlist);
      _emit(LyricsChange(trackId, chapterId));
    });
  }

  /// Drops the pin of a doc and fetches it again automatically.
  Future<void> refetch(int trackId, String? chapterId) async {
    final track = await _db.getTrack(trackId);
    if (track == null) return;
    await _locked(
      trackId,
      () => _db.deleteLyricsDocs(trackId, chapterId: chapterId),
    );
    await _fetchTrack(track, force: true, single: true, onlyChapter: chapterId);
  }

  /// After a track's chapters changed (edit, recognition, undo): deletes
  /// docs of chapters that are gone and fetches the new ones when the
  /// playlist has lyrics on.
  Future<void> onChaptersChanged(int trackId) async {
    final track = await _db.getTrack(trackId);
    if (track == null) return;
    final active =
        ChapterData.decode(track.chaptersJson).active.map((c) => c.id).toSet();
    final pruned = await _db.pruneLyricsChapterDocs(trackId, active);
    final playlist = await _db.getPlaylistOrNull(track.playlistId);
    if (playlist == null) return;
    if (pruned > 0) {
      await _persist(track, playlist);
      _emit(LyricsChange(trackId));
    }
    if (lyricsModeIsOn(playlist.lyricsMode)) await _fetchTrack(track);
  }

  void dispose() {
    _changes.close();
    _lrclibClient?.close();
    _ytMusicClient?.close();
    _captionsClient?.close();
  }

  // ---------------------------------------------------------------------
  // Fetching

  void _emit(LyricsChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  /// Runs [action] after any other work on the same track.
  Future<T> _locked<T>(int trackId, Future<T> Function() action) {
    final previous = _trackLocks[trackId] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _trackLocks[trackId] = tail;
    tail.whenComplete(() {
      if (identical(_trackLocks[trackId], tail)) _trackLocks.remove(trackId);
    });
    return result;
  }

  static bool _isForcedInsert(Track track) =>
      track.videoId.startsWith(PlaylistService.forcedInsertVideoIdPrefix);

  bool _eligible(Track track, LyricsMode mode) {
    if (track.status != 'complete' || track.filePath == null) return false;
    // A transcript needs the YouTube video's own audio and captions.
    if (mode == LyricsMode.transcript &&
        (track.isLocalReplacement || _isForcedInsert(track))) {
      return false;
    }
    return true;
  }

  /// The docs a track should have in [mode].
  List<_Slot> _slotsFor(Track track, Playlist playlist, LyricsMode mode) {
    final fileMs =
        track.durationSeconds == null ? null : track.durationSeconds! * 1000;
    final whole = [_Slot(null, 0, fileMs, track.title)];
    if (mode == LyricsMode.transcript) return whole;
    if (!(track.chaptersEnabled ?? playlist.playChapters ?? true)) return whole;
    final chapters = ChapterData.decode(track.chaptersJson).active;
    if (chapters.isEmpty) return whole;
    return [
      for (final chapter in chapters)
        _Slot(
          chapter.id,
          chapter.startMs,
          chapter.endMs - chapter.startMs,
          chapter.title,
        ),
    ];
  }

  /// The slot of [chapterId] (null = the whole file), even when the track
  /// does not play as chapters now.
  _Slot _slotFor(Track track, Playlist playlist, String? chapterId) {
    if (chapterId != null) {
      final chapter =
          ChapterData.decode(
            track.chaptersJson,
          ).active.where((c) => c.id == chapterId).firstOrNull;
      if (chapter == null) throw StateError('The chapter is gone.');
      return _Slot(
        chapter.id,
        chapter.startMs,
        chapter.endMs - chapter.startMs,
        chapter.title,
      );
    }
    return _Slot(
      null,
      0,
      track.durationSeconds == null ? null : track.durationSeconds! * 1000,
      track.title,
    );
  }

  /// Whether a slot with [doc] (null = none yet) should be fetched now.
  bool _isDue(LyricsDoc? doc, LyricsMode mode, DateTime now) {
    if (doc == null) return true;
    if (doc.pinned) return false;
    if (doc.kind != mode.dbValue) return true;
    if (doc.status == LyricsStatus.found ||
        doc.status == LyricsStatus.instrumental) {
      return false;
    }
    if (doc.attempts >= maxAttempts) return false;
    final wait =
        doc.status == LyricsStatus.error
            ? errorRetryInterval + Duration(hours: doc.trackId % 6)
            : missingRetryInterval + Duration(hours: doc.trackId % 48);
    return now.difference(doc.checkedAt) >= wait;
  }

  /// Fetches the due docs of [track]; with [single] only the doc of
  /// [onlyChapter] (null = the whole file).
  Future<_Outcome> _fetchTrack(
    Track track, {
    bool force = false,
    bool single = false,
    String? onlyChapter,
    LyricsCancellation? cancellation,
    DateTime? deadline,
  }) => _locked(track.id, () async {
    final outcome = _Outcome();
    final fresh = await _db.getTrack(track.id);
    if (fresh == null) return outcome;
    final playlist = await _db.getPlaylistOrNull(fresh.playlistId);
    final mode = LyricsMode.fromDb(playlist?.lyricsMode);
    if (playlist == null || mode == null || !_eligible(fresh, mode)) {
      return outcome;
    }
    final slots = _slotsFor(fresh, playlist, mode);
    final existing = await _db.lyricsDocsForTrack(fresh.id);
    var changed = false;

    // Docs the current layout no longer has (a whole-file doc of a file
    // that now plays as chapters, or chapter docs in transcript mode).
    final slotIds = slots.map((s) => s.chapterId).toSet();
    for (final doc in existing) {
      if (doc.pinned || slotIds.contains(doc.chapterId)) continue;
      if (single && doc.chapterId != onlyChapter) continue;
      await _db.deleteLyricsDocs(fresh.id, chapterId: doc.chapterId);
      changed = true;
    }

    final context = _TrackContext(this, fresh, playlist);
    final now = _clock();
    for (final slot in slots) {
      if (single && slot.chapterId != onlyChapter) continue;
      if (cancellation?.isCancelled ?? false) break;
      if (deadline != null && !_clock().isBefore(deadline)) break;
      final doc =
          existing.where((d) => d.chapterId == slot.chapterId).firstOrNull;
      LyricsDocDraft? draft;
      if (doc != null && doc.pinned) {
        // A pin restored from the sidecar without its text: fetch the
        // chosen record again.
        if (doc.status != LyricsStatus.found ||
            (await _db.lyricsLinesInRange(doc.id, 0, 0)).isNotEmpty) {
          continue;
        }
        outcome.due++;
        try {
          draft = await _draftForPick(
            fresh,
            slot,
            mode,
            LyricsPick(
              source: doc.source ?? LyricsSource.lrclib,
              sourceRef: doc.sourceRef ?? '',
              artist: doc.matchedArtist,
              title: doc.matchedTitle,
            ),
          );
        } catch (e) {
          _log.warn('Lyrics: could not restore the pick of ${fresh.title}: $e');
          outcome.failed++;
          continue;
        }
      } else {
        if (!force && !_isDue(doc, mode, now)) continue;
        outcome.due++;
        final attempts =
            doc != null && doc.kind == mode.dbValue && !force
                ? doc.attempts + 1
                : 1;
        draft = await _fetchSlot(context, slot, mode, attempts);
      }
      await _db.replaceLyricsDoc(draft);
      changed = true;
      switch (draft.status) {
        case LyricsStatus.found:
          outcome.found++;
        case LyricsStatus.error:
          outcome.failed++;
        default:
          outcome.missing++;
      }
    }
    if (changed) {
      await _persist(fresh, playlist);
      _emit(LyricsChange(fresh.id, single ? onlyChapter : null));
    }
    return outcome;
  });

  /// Looks one slot up and returns what to store. Never throws: failures
  /// become an error doc that is retried later.
  Future<LyricsDocDraft> _fetchSlot(
    _TrackContext context,
    _Slot slot,
    LyricsMode mode,
    int attempts,
  ) async {
    LyricsDocDraft status(String status) => LyricsDocDraft(
      trackId: context.track.id,
      chapterId: slot.chapterId,
      offsetMs: slot.offsetMs,
      kind: mode,
      status: status,
      checkedAt: _clock(),
      attempts: attempts,
    );
    try {
      final draft =
          mode == LyricsMode.transcript
              ? await _fetchTranscript(context, slot, attempts)
              : await _fetchLyrics(context, slot, attempts);
      return draft ?? status(LyricsStatus.none);
    } catch (e) {
      _log.warn('Lyrics: lookup failed for "${slot.title}": $e');
      return status(LyricsStatus.error);
    }
  }

  Future<LyricsDocDraft?> _fetchLyrics(
    _TrackContext context,
    _Slot slot,
    int attempts,
  ) async {
    final track = context.track;
    final durationSeconds =
        slot.durationMs == null ? null : slot.durationMs! / 1000;
    var query = await context.queryFor(slot);
    final matcher = await _matcher();
    var match = await matcher.match(
      query,
      durationSeconds: durationSeconds,
      chapter: slot.isChapter,
    );
    LyricsDocDraft fromLrclib(LyricsMatch match) {
      final record = match.record!;
      return LyricsDocDraft(
        trackId: track.id,
        chapterId: slot.chapterId,
        offsetMs: slot.offsetMs,
        kind: LyricsMode.lyrics,
        status: match.status,
        source: LyricsSource.lrclib,
        sourceRef: '${record.id}',
        matchedArtist: record.artistName,
        matchedTitle: record.trackName,
        timeScale: match.timeScale,
        synced: match.synced,
        checkedAt: _clock(),
        attempts: attempts,
        lines: match.lines,
      );
    }

    bool settled(LyricsMatch match) =>
        match.found || match.status == LyricsStatus.instrumental;
    if (settled(match)) return fromLrclib(match);

    final youtube = !_isForcedInsert(track);
    if (!slot.isChapter && youtube) {
      try {
        final ytm = await _ytMusic.lyricsFor(track.videoId);
        final lines =
            ytm == null ? const <LyricsLineDraft>[] : _plainLines(ytm.text);
        if (ytm != null && lines.isNotEmpty) {
          return LyricsDocDraft(
            trackId: track.id,
            kind: LyricsMode.lyrics,
            status: LyricsStatus.found,
            source: LyricsSource.ytmusic,
            sourceRef: ytm.browseId,
            matchedArtist: query.artist,
            matchedTitle: query.title,
            checkedAt: _clock(),
            attempts: attempts,
            lines: lines,
          );
        }
      } catch (e) {
        _log.warn('Lyrics: YouTube Music failed for ${track.videoId}: $e');
      }
    }

    if (youtube) {
      // yt-dlp only now: it takes seconds per video on a phone.
      final info = await context.captionInfo();
      // The video's own info may name the artist when the title does not
      // (a nightcore upload, a "Topic" channel).
      if (info != null && !slot.isChapter) {
        final requery = await context.queryFor(slot);
        if (requery.artist != query.artist || requery.title != query.title) {
          query = requery;
          match = await matcher.match(query, durationSeconds: durationSeconds);
          if (settled(match)) return fromLrclib(match);
        }
      }

      // The uploader's own captions, when they are in the song's language.
      final choice =
          info == null ? null : pickCaption(info, mode: LyricsMode.lyrics);
      if (choice != null) {
        final lines = _sliceForSlot(await context.captionLines(choice), slot);
        if (lines.isNotEmpty) {
          return LyricsDocDraft(
            trackId: track.id,
            chapterId: slot.chapterId,
            offsetMs: slot.offsetMs,
            kind: LyricsMode.lyrics,
            status: LyricsStatus.found,
            source: LyricsSource.ytSubs,
            sourceRef: choice.key,
            synced: true,
            lang: choice.lang,
            checkedAt: _clock(),
            attempts: attempts,
            lines: lines,
          );
        }
      }
    }
    return null;
  }

  Future<LyricsDocDraft?> _fetchTranscript(
    _TrackContext context,
    _Slot slot,
    int attempts,
  ) async {
    final info = await context.captionInfo(required: true);
    if (info == null) return null;
    final choice = pickCaption(info, mode: LyricsMode.transcript);
    if (choice == null) return null;
    final lines = _sliceForSlot(await context.captionLines(choice), slot);
    if (lines.isEmpty) return null;
    return LyricsDocDraft(
      trackId: context.track.id,
      chapterId: slot.chapterId,
      offsetMs: slot.offsetMs,
      kind: LyricsMode.transcript,
      status: LyricsStatus.found,
      source: choice.automatic ? LyricsSource.ytAuto : LyricsSource.ytSubs,
      sourceRef: choice.key,
      synced: true,
      lang: choice.lang,
      checkedAt: _clock(),
      attempts: attempts,
      lines: lines,
    );
  }

  /// The caption lines inside a chapter, timed from its start (all of them
  /// for the whole file).
  static List<LyricsLineDraft> _sliceForSlot(
    List<LyricsLineDraft> lines,
    _Slot slot,
  ) {
    if (!slot.isChapter) return lines;
    final end =
        slot.durationMs == null ? null : slot.offsetMs + slot.durationMs!;
    return [
      for (final line in lines)
        if (line.startMs != null &&
            line.startMs! >= slot.offsetMs &&
            (end == null || line.startMs! < end))
          LyricsLineDraft(line.text, startMs: line.startMs! - slot.offsetMs),
    ];
  }

  static List<LyricsLineDraft> _plainLines(String text) => [
    for (final line in const LineSplitter().convert(text))
      if (line.trim().isNotEmpty) LyricsLineDraft(line.trim()),
  ];

  /// The doc for a pick, pinned. Throws when the chosen record is gone.
  Future<LyricsDocDraft> _draftForPick(
    Track track,
    _Slot slot,
    LyricsMode mode,
    LyricsPick pick,
  ) async {
    LyricsDocDraft draft(
      String status, {
      String? source,
      String? sourceRef,
      String? artist,
      String? title,
      double timeScale = 1.0,
      bool synced = false,
      String? lang,
      List<LyricsLineDraft> lines = const [],
    }) => LyricsDocDraft(
      trackId: track.id,
      chapterId: slot.chapterId,
      offsetMs: slot.offsetMs,
      kind: mode,
      status: status,
      source: source,
      sourceRef: sourceRef,
      matchedArtist: artist,
      matchedTitle: title,
      timeScale: timeScale,
      synced: synced,
      pinned: true,
      lang: lang,
      checkedAt: _clock(),
      lines: lines,
    );

    if (pick.none) return draft(LyricsStatus.none);
    final ref = pick.sourceRef ?? '';
    switch (pick.source) {
      case LyricsSource.lrclib:
        final id = int.tryParse(ref);
        if (id == null) throw ArgumentError('Not an LRCLIB id: $ref');
        final record = await (await _lrclib()).getById(id);
        if (record == null) throw StateError('That lyrics record is gone.');
        if (record.instrumental) {
          return draft(
            LyricsStatus.instrumental,
            source: LyricsSource.lrclib,
            sourceRef: '$id',
            artist: record.artistName,
            title: record.trackName,
          );
        }
        final (synced, scale) = _timingFor(record, slot, track.title);
        return draft(
          LyricsStatus.found,
          source: LyricsSource.lrclib,
          sourceRef: '$id',
          artist: record.artistName,
          title: record.trackName,
          timeScale: scale,
          synced: synced,
          lines: lyricsLinesFor(record, synced: synced, timeScale: scale),
        );
      case LyricsSource.ytmusic:
        final ytm = await _ytMusic.lyricsFor(ref.isEmpty ? track.videoId : ref);
        if (ytm == null) throw StateError('YouTube Music has no lyrics here.');
        return draft(
          LyricsStatus.found,
          source: LyricsSource.ytmusic,
          sourceRef: ytm.browseId,
          artist: pick.artist,
          title: pick.title,
          lines: _plainLines(ytm.text),
        );
      case LyricsSource.ytSubs || LyricsSource.ytAuto:
        final separator = ref.indexOf(':');
        final videoId = separator < 0 ? ref : ref.substring(0, separator);
        final lang = separator < 0 ? null : ref.substring(separator + 1);
        if (videoId.isEmpty) throw ArgumentError('No video id in "$ref".');
        final loader = _captionInfo;
        if (loader == null) throw StateError('yt-dlp is not available.');
        await _paceExtraction();
        final info = await loader('https://www.youtube.com/watch?v=$videoId');
        final choice = _captionForPick(info, mode, lang);
        if (choice == null) {
          throw StateError('That video has no captions to use.');
        }
        final lines = await _captions.fetch(choice.url);
        if (lines.isEmpty) throw StateError('Those captions are empty.');
        return draft(
          LyricsStatus.found,
          source: choice.automatic ? LyricsSource.ytAuto : LyricsSource.ytSubs,
          sourceRef: '$videoId:${choice.key}',
          artist: pick.artist,
          title: pick.title ?? (info['title'] is String ? info['title'] : null),
          synced: true,
          lang: choice.lang,
          lines: lines,
        );
      default:
        throw ArgumentError('Unknown lyrics source ${pick.source}');
    }
  }

  /// The caption track named by [key] (exact, else by language), or the
  /// best one: manual captions first, speech-to-text only for transcripts.
  static CaptionChoice? _captionForPick(
    Map<String, dynamic> info,
    LyricsMode mode,
    String? key,
  ) {
    if (key != null && key.isNotEmpty) {
      for (final group in ['subtitles', 'automatic_captions']) {
        final captions = info[group];
        if (captions is! Map || captions[key] == null) continue;
        final exact = pickCaption({
          group: {key: captions[key]},
        }, mode: LyricsMode.transcript);
        if (exact != null) return exact;
      }
      return pickCaption(info, mode: LyricsMode.transcript, onlyLang: key);
    }
    // The user chose this video, so any manual track fits; speech-to-text
    // only for spoken content.
    final manualOnly = {...info, 'automatic_captions': null};
    return pickCaption(
      mode == LyricsMode.transcript ? info : manualOnly,
      mode: LyricsMode.transcript,
    );
  }

  /// Whether a chosen record's times fit the slot, and their scale.
  static (bool, double) _timingFor(
    LrclibRecord record,
    _Slot slot,
    String fileTitle,
  ) {
    if (!record.isSynced) return (false, 1.0);
    if (slot.isChapter) return (true, 1.0);
    final local = slot.durationMs == null ? null : slot.durationMs! / 1000;
    final remote = record.duration;
    if (local == null || remote == null || remote <= 0) return (false, 1.0);
    if ((local - remote).abs() <= durationToleranceSeconds) return (true, 1.0);
    final ratio = local / remote;
    if (parseSongTitle(fileTitle).nightcore &&
        ratio >= nightcoreMinRatio &&
        ratio <= nightcoreMaxRatio) {
      return (true, ratio);
    }
    return (false, 1.0);
  }

  Future<void> _paceExtraction() async {
    final last = _lastExtraction;
    if (last != null) {
      final since = _clock().difference(last);
      if (since < extractionGap) await _sleep(extractionGap - since);
    }
    _lastExtraction = _clock();
  }

  Future<Map<String, dynamic>?> _readInfo(String folder, Track track) async {
    try {
      final file = File(LibraryLayout.infoJsonPath(folder, track.videoId));
      if (!await file.exists()) return null;
      final info = jsonDecode(await file.readAsString());
      return info is Map<String, dynamic> ? info : null;
    } catch (_) {
      return null;
    }
  }

  /// Writes the track's lyrics file from the database.
  Future<void> _persist(Track track, Playlist playlist) async {
    try {
      final docs = await _db.lyricsDocsForTrack(track.id);
      final drafts = [
        for (final doc in docs)
          draftFromDoc(doc, await _db.lyricsLinesForDoc(doc.id)),
      ];
      await writeLyricsFile(playlist.outputPath, track.videoId, drafts);
    } catch (e) {
      _log.warn('Lyrics: could not save the lyrics file of ${track.title}: $e');
    }
  }
}

/// A stored doc and its lines as a draft (to write to a file or copy).
LyricsDocDraft draftFromDoc(LyricsDoc doc, List<LyricsLine> lines) =>
    LyricsDocDraft(
      trackId: doc.trackId,
      chapterId: doc.chapterId,
      offsetMs: doc.offsetMs,
      kind: LyricsMode.fromDb(doc.kind) ?? LyricsMode.lyrics,
      status: doc.status,
      source: doc.source,
      sourceRef: doc.sourceRef,
      matchedArtist: doc.matchedArtist,
      matchedTitle: doc.matchedTitle,
      timeScale: doc.timeScale,
      synced: doc.synced,
      pinned: doc.pinned,
      lang: doc.lang,
      checkedAt: doc.checkedAt,
      attempts: doc.attempts,
      lines: [
        for (final line in lines)
          LyricsLineDraft(line.lineText, startMs: line.startMs),
      ],
    );

/// What one track's fetch reads at most once: its info and captions.
class _TrackContext {
  _TrackContext(this.service, this.track, this.playlist);

  final LyricsService service;
  final Track track;
  final Playlist playlist;

  Map<String, dynamic>? _keptInfo;
  bool _keptInfoRead = false;
  Map<String, dynamic>? _freshInfo;
  bool _freshInfoTried = false;
  final _captionLines = <String, List<LyricsLineDraft>>{};

  Future<Map<String, dynamic>?> _kept() async {
    if (!_keptInfoRead) {
      _keptInfoRead = true;
      _keptInfo = await service._readInfo(playlist.outputPath, track);
    }
    return _keptInfo;
  }

  /// The best known info: a fresh extraction, else the kept info.json.
  Future<Map<String, dynamic>?> info() async => _freshInfo ?? await _kept();

  /// Info with caption URLs from yt-dlp, run at most once per track. In
  /// [required] mode (transcripts) a failure throws, so it is retried.
  Future<Map<String, dynamic>?> captionInfo({bool required = false}) async {
    if (_freshInfoTried) return _freshInfo;
    _freshInfoTried = true;
    final loader = service._captionInfo;
    if (loader == null || LyricsService._isForcedInsert(track)) {
      if (required) throw StateError('yt-dlp is not available.');
      return null;
    }
    try {
      await service._paceExtraction();
      _freshInfo = await loader(
        'https://www.youtube.com/watch?v=${track.videoId}',
      );
    } catch (e) {
      if (required) rethrow;
      service._log.warn('Lyrics: no video info for ${track.videoId}: $e');
    }
    return _freshInfo;
  }

  Future<List<LyricsLineDraft>> captionLines(CaptionChoice choice) async =>
      _captionLines[choice.key] ??= await service._captions.fetch(choice.url);

  /// The song query of [slot]. For the whole file a nightcore title that
  /// names no artist reads the video's description (running yt-dlp when
  /// no info is kept).
  Future<SongQuery> queryFor(_Slot slot) async {
    if (slot.isChapter) {
      return parseChapterTitle(slot.title, parentTitle: track.title);
    }
    var info = await this.info();
    var query = parseSongTitle(
      track.title,
      meta: info == null ? null : VideoMeta.fromInfo(info),
    );
    if (query.nightcore &&
        query.artist == null &&
        info?['description'] is! String &&
        !_freshInfoTried) {
      info = await captionInfo();
      if (info != null) {
        query = parseSongTitle(track.title, meta: VideoMeta.fromInfo(info));
      }
    }
    return query;
  }
}

/// Keeps lyrics docs in step after a track's chapters were written as
/// [data]: docs of chapters that are gone are deleted, and unpinned docs of
/// chapters whose title or start changed since [previous] too, so the next
/// fetch looks them up again.
Future<void> syncLyricsChapterDocs(
  AppDatabase db,
  int trackId,
  ChapterData data, {
  ChapterData? previous,
}) async {
  final active = {for (final chapter in data.active) chapter.id: chapter};
  await db.pruneLyricsChapterDocs(trackId, active.keys.toSet());
  if (previous == null) return;
  final before = {for (final chapter in previous.active) chapter.id: chapter};
  for (final doc in await db.lyricsDocsForTrack(trackId)) {
    final id = doc.chapterId;
    if (id == null || doc.pinned) continue;
    final now = active[id];
    final then = before[id];
    if (now == null || then == null) continue;
    if (now.title != then.title || now.startMs != then.startMs) {
      await db.deleteLyricsDocs(trackId, chapterId: id);
    }
  }
}
