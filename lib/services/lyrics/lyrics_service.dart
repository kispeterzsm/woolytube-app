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
import '../track_title.dart';

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
  Future<void> _extractions = Future.value();
  final _trackLocks = <int, Future<void>>{};

  /// LRCLIB records fetched by id lately, so retiming a chapter doc can
  /// rebuild its lines without asking LRCLIB on every tap.
  final _recentRecords = <int, LrclibRecord>{};

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

  /// LRCLIB record [id] (null when it is gone), remembered for a while.
  Future<LrclibRecord?> _recordById(int id, {bool Function()? stop}) async {
    final known = _recentRecords.remove(id);
    final record = known ?? await (await _lrclib()).getById(id, stop: stop);
    if (record != null) {
      _recentRecords[id] = record;
      while (_recentRecords.length > 8) {
        _recentRecords.remove(_recentRecords.keys.first);
      }
    }
    return record;
  }

  YtMusicLyricsClient get _ytMusic =>
      _ytMusicOverride ?? (_ytMusicClient ??= YtMusicLyricsClient(http: _http));

  CaptionsClient get _captions =>
      _captionsOverride ?? (_captionsClient ??= CaptionsClient(http: _http));

  /// Fetches every due doc of [track] by its playlist's mode: the whole
  /// file, or each active chapter of a file that plays as chapters in
  /// lyrics mode. Docs found recently, retried too often, or pinned are
  /// skipped; [force] refetches unpinned ones anyway. Does nothing when the
  /// playlist has lyrics off.
  /// Throws [StateError] when the track cannot be fetched (see
  /// [fetchBlockedReason]).
  Future<void> fetchTrack(Track track, {bool force = false}) async {
    await _checkFetchable(track.id);
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
            _emptyPinDue(doc, now) &&
            (await _db.lyricsLinesInRange(doc.id, 0, 0)).isEmpty) {
          emptyPins.add(doc.id);
        }
      }
    }
    final tracks = await _db.getTracksForPlaylist(playlistId);
    final mistimed = await _mistimedDocs(tracks, docsByTrack);
    for (final track in tracks) {
      if (!_eligible(track, mode) &&
          (docsByTrack[track.id]?.any((d) => _unusable(track, d, mode)) ??
              false)) {
        await _locked(track.id, () => _dropUnusable(track, playlist, mode));
      }
    }
    final due = [
      for (final track in tracks)
        if (_eligible(track, mode) &&
            _slotsFor(track, playlist, mode).any((slot) {
              final doc =
                  docsByTrack[track.id]
                      ?.where((d) => d.chapterId == slot.chapterId)
                      .firstOrNull;
              return _isDue(doc, mode, now) ||
                  emptyPins.contains(doc?.id) ||
                  mistimed.contains(doc?.id);
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
        mistimed: mistimed,
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

  /// LRCLIB search results for the picker's free text [query]. With
  /// [trackId] each result says whether its synced times fit that track's
  /// file (or [chapterId]'s chapter), and results of the same song come
  /// fitting ones first.
  Future<List<LyricsCandidate>> candidatesFor(
    String query, {
    int? trackId,
    String? chapterId,
  }) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final client = await _lrclib();
    var records = await client.searchQ(text);
    if (records.isEmpty) records = await client.search(trackName: text);
    double? localSeconds;
    var nightcore = false;
    final track = trackId == null ? null : await _db.getTrack(trackId);
    if (track != null) {
      if (chapterId != null) {
        final chapter =
            ChapterData.decode(
              track.chaptersJson,
            ).active.where((c) => c.id == chapterId).firstOrNull;
        if (chapter != null) {
          localSeconds = (chapter.endMs - chapter.startMs) / 1000;
        }
      } else if ((track.durationSeconds ?? 0) > 0) {
        localSeconds = track.durationSeconds!.toDouble();
      }
      nightcore = parseSongTitle(track.displayTitle).nightcore;
    }
    return sortCandidatesByFit([
      for (final record in records)
        lyricsCandidateFor(
          record,
          localSeconds: localSeconds,
          nightcore: nightcore,
          chapter: chapterId != null,
        ),
    ]);
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
      track.displayTitle,
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
    // Never drop a pin that nothing could replace.
    await _checkFetchable(trackId);
    await _locked(
      trackId,
      () => _db.deleteLyricsDocs(trackId, chapterId: chapterId),
    );
    await _fetchTrack(track, force: true, single: true, onlyChapter: chapterId);
  }

  /// Moves every line of a synced doc so it starts [shiftMs] later than
  /// the source times it (negative = earlier), and pins the doc so
  /// automatic runs keep it. 0 takes the correction back. The shift is
  /// added to the stored line times and remembered for a restore.
  ///
  /// A chapter's lines are cut at its end after the shift, as a restore
  /// does; an LRCLIB chapter doc is rebuilt from its record, so lines an
  /// earlier cut dropped come back.
  Future<void> setTimingShift(int trackId, String? chapterId, int shiftMs) =>
      _changeDoc(trackId, chapterId, (track, playlist, doc, lines) async {
        if (!doc.synced) {
          throw StateError('These lyrics have no times to move.');
        }
        List<LyricsLineDraft>? rebuilt;
        _Slot? slot;
        if (doc.chapterId != null) {
          try {
            slot = _slotFor(track, playlist, doc.chapterId);
          } on StateError {
            slot = null;
          }
          final id =
              doc.source == LyricsSource.lrclib
                  ? int.tryParse(doc.sourceRef ?? '')
                  : null;
          if (slot != null && id != null) {
            // The sheet waits on this: give up soon and shift what is
            // stored.
            final deadline = _clock().add(const Duration(seconds: 5));
            try {
              final record = await _recordById(
                id,
                stop: () => !_clock().isBefore(deadline),
              );
              if (record != null && record.isSynced) {
                rebuilt = shiftLyricsLines(
                  lyricsLinesFor(
                    record,
                    synced: true,
                    timeScale: doc.timeScale,
                  ),
                  shiftMs,
                );
              }
            } catch (e) {
              _log.warn('Lyrics: could not reload record $id: $e');
            }
          }
        }
        var shifted =
            rebuilt ??
            shiftLyricsLines([
              for (final line in lines)
                LyricsLineDraft(line.lineText, startMs: line.startMs),
            ], shiftMs - doc.shiftMs);
        if (slot != null) {
          final cut = _cutToSlot(shifted, slot, synced: true);
          // Never shift every line out of the chapter.
          if (cut.isNotEmpty) shifted = cut;
        }
        return draftFromDoc(doc, lines).copyWith(
          pinned: true,
          shiftMs: shiftMs,
          sourceRef: _pinnedSourceRef(track, doc),
          lines: shifted,
        );
      });

  /// Keeps a doc's lines without their times, pinned.
  Future<void> useWithoutTiming(int trackId, String? chapterId) => _changeDoc(
    trackId,
    chapterId,
    (track, playlist, doc, lines) async => draftFromDoc(doc, lines).copyWith(
      synced: false,
      pinned: true,
      shiftMs: 0,
      timingOff: true,
      sourceRef: _pinnedSourceRef(track, doc),
      lines: [for (final line in lines) LyricsLineDraft(line.lineText)],
    ),
  );

  /// The source ref a pin of [doc] keeps: automatic caption docs written
  /// before this rule name only the caption track ("en"), which a restore
  /// cannot load, so they get the video id too.
  static String? _pinnedSourceRef(Track track, LyricsDoc doc) {
    final ref = doc.sourceRef;
    final captions =
        doc.source == LyricsSource.ytSubs || doc.source == LyricsSource.ytAuto;
    if (!captions || ref == null || ref.isEmpty || ref.contains(':')) {
      return ref;
    }
    return '${track.videoId}:$ref';
  }

  /// Rewrites the found doc of [trackId]/[chapterId] by [change] and saves
  /// the lyrics file.
  Future<void> _changeDoc(
    int trackId,
    String? chapterId,
    Future<LyricsDocDraft> Function(
      Track track,
      Playlist playlist,
      LyricsDoc doc,
      List<LyricsLine> lines,
    )
    change,
  ) => _locked(trackId, () async {
    final track = await _db.getTrack(trackId);
    if (track == null) throw StateError('The track is gone.');
    final playlist = await _db.getPlaylistOrNull(track.playlistId);
    if (playlist == null) throw StateError('The playlist is gone.');
    final doc = await _db.lyricsDocFor(trackId, chapterId);
    if (doc == null || doc.status != LyricsStatus.found) {
      throw StateError('There are no lyrics to change here.');
    }
    final lines = await _db.lyricsLinesForDoc(doc.id);
    await _db.replaceLyricsDoc(await change(track, playlist, doc, lines));
    await _persist(track, playlist);
    _emit(LyricsChange(trackId, chapterId));
  });

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

  /// Why [track] cannot be fetched in [mode], or null when it can.
  static String? fetchBlockedReason(Track track, LyricsMode mode) {
    if (track.status != 'complete' || track.filePath == null) {
      return 'Download the track first.';
    }
    // A transcript needs the YouTube video's own audio and captions.
    if (mode == LyricsMode.transcript &&
        (track.isLocalReplacement || _isForcedInsert(track))) {
      return 'Transcripts need the YouTube video, and this track plays '
          'another file.';
    }
    return null;
  }

  bool _eligible(Track track, LyricsMode mode) =>
      fetchBlockedReason(track, mode) == null;

  Future<void> _checkFetchable(int trackId) async {
    final track = await _db.getTrack(trackId);
    if (track == null) return;
    final playlist = await _db.getPlaylistOrNull(track.playlistId);
    final mode = LyricsMode.fromDb(playlist?.lyricsMode);
    if (mode == null) return;
    final reason = fetchBlockedReason(track, mode);
    if (reason != null) throw StateError(reason);
  }

  /// The docs a track should have in [mode].
  List<_Slot> _slotsFor(Track track, Playlist playlist, LyricsMode mode) {
    final fileMs =
        track.durationSeconds == null ? null : track.durationSeconds! * 1000;
    final whole = [_Slot(null, 0, fileMs, track.displayTitle)];
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
      track.displayTitle,
    );
  }

  /// Whether a slot with [doc] (null = none yet) should be fetched now.
  bool _isDue(LyricsDoc? doc, LyricsMode mode, DateTime now) {
    if (doc == null) return true;
    // A doc of the other mode does not apply, even a pinned one.
    if (doc.kind != mode.dbValue) return true;
    if (doc.pinned) return false;
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

  /// Whether a draft looked up for [read] and [slot] still applies: the
  /// track plays the same file and can still be fetched in [mode], and a
  /// chapter still exists with the same start and title.
  Future<bool> _slotUnchanged(Track read, _Slot slot, LyricsMode mode) async {
    final track = await _db.getTrack(read.id);
    if (track == null) return false;
    if (track.filePath != read.filePath ||
        track.isLocalReplacement != read.isLocalReplacement ||
        !_eligible(track, mode)) {
      return false;
    }
    if (!slot.isChapter) return true;
    final chapter =
        ChapterData.decode(
          track.chaptersJson,
        ).active.where((c) => c.id == slot.chapterId).firstOrNull;
    return chapter != null &&
        chapter.startMs == slot.offsetMs &&
        chapter.title == slot.title;
  }

  /// Whether [doc] of [track], which cannot be fetched in [mode], must go:
  /// a doc of the other mode, or a transcript of a track that plays
  /// another file than the YouTube video.
  static bool _unusable(Track track, LyricsDoc doc, LyricsMode mode) =>
      doc.kind != mode.dbValue ||
      (mode == LyricsMode.transcript &&
          track.status == 'complete' &&
          track.filePath != null &&
          (track.isLocalReplacement || _isForcedInsert(track)));

  /// Deletes the [_unusable] docs of [track] (a track that cannot be
  /// fetched in [mode] keeps nothing searchable from the old one).
  Future<void> _dropUnusable(
    Track track,
    Playlist playlist,
    LyricsMode mode,
  ) async {
    var dropped = false;
    for (final doc in await _db.lyricsDocsForTrack(track.id)) {
      if (!_unusable(track, doc, mode)) continue;
      await _db.deleteLyricsDocs(track.id, chapterId: doc.chapterId);
      dropped = true;
    }
    if (dropped) {
      await _persist(track, playlist);
      _emit(LyricsChange(track.id));
    }
  }

  /// Whether a pin restored without its text should be fetched again now:
  /// failed restores wait like failed lookups, up to [maxAttempts].
  bool _emptyPinDue(LyricsDoc doc, DateTime now) {
    if (doc.attempts == 0) return true;
    if (doc.attempts >= maxAttempts) return false;
    final wait = errorRetryInterval + Duration(hours: doc.trackId % 6);
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
    Set<int>? mistimed,
  }) => _locked(track.id, () async {
    final outcome = _Outcome();
    final fresh = await _db.getTrack(track.id);
    if (fresh == null) return outcome;
    final playlist = await _db.getPlaylistOrNull(fresh.playlistId);
    final mode = LyricsMode.fromDb(playlist?.lyricsMode);
    if (playlist == null || mode == null) return outcome;
    if (!_eligible(fresh, mode)) {
      await _dropUnusable(fresh, playlist, mode);
      return outcome;
    }
    final slots = _slotsFor(fresh, playlist, mode);
    var existing = await _db.lyricsDocsForTrack(fresh.id);
    var changed = false;

    // Docs the current layout no longer has (a whole-file doc of a file
    // that now plays as chapters, or chapter docs in transcript mode), and
    // docs of the other mode, pinned ones too: they do not apply here.
    final slotIds = slots.map((s) => s.chapterId).toSet();
    for (final doc in existing) {
      final otherKind = doc.kind != mode.dbValue;
      if (!otherKind && (doc.pinned || slotIds.contains(doc.chapterId))) {
        continue;
      }
      if (single && doc.chapterId != onlyChapter) continue;
      await _db.deleteLyricsDocs(fresh.id, chapterId: doc.chapterId);
      changed = true;
    }
    if (changed) existing = await _db.lyricsDocsForTrack(fresh.id);

    final context = _TrackContext(this, fresh, playlist);
    final now = _clock();
    final wrongTiming =
        mistimed ?? await _mistimedDocs([fresh], {fresh.id: existing});
    bool stop() =>
        (cancellation?.isCancelled ?? false) ||
        (deadline != null && !_clock().isBefore(deadline));
    for (final slot in slots) {
      if (single && slot.chapterId != onlyChapter) continue;
      if (stop()) break;
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
        if (!force && !single && !_emptyPinDue(doc, now)) continue;
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
              shiftMs: doc.shiftMs,
              timingOff: doc.timingOff,
            ),
            stop: stop,
          );
        } catch (e) {
          // Stopped (cancel or deadline): not a failed restore.
          if (stop()) break;
          _log.warn(
            'Lyrics: could not restore the pick of ${fresh.displayTitle}: $e',
          );
          // Keep the pin and wait before the next try. A record or captions
          // that are gone are not an outage, so they do not stop a backfill.
          await _db.markLyricsDocTried(doc.id, _clock(), doc.attempts + 1);
          changed = true;
          if (e is! StateError && e is! ArgumentError) outcome.failed++;
          continue;
        }
      } else {
        final retime = doc != null && wrongTiming.contains(doc.id);
        if (!force && !retime && !_isDue(doc, mode, now)) continue;
        outcome.due++;
        final attempts =
            doc != null && doc.kind == mode.dbValue && !force
                ? doc.attempts + 1
                : 1;
        draft = await _fetchSlot(context, slot, mode, attempts, stop);
        // Stopped halfway: not a failed lookup, nothing to store.
        if (draft.status == LyricsStatus.error && stop()) break;
        // Lyrics whose times ran past the file are only replaced by an
        // answer: a failed lookup keeps them for the next try.
        if (retime && !force && draft.status == LyricsStatus.error) {
          await _db.markLyricsDocTried(doc.id, _clock(), doc.attempts);
          outcome.failed++;
          changed = true;
          continue;
        }
        // No record fits any more (the old one is mislabelled, and nothing
        // else names its length): the words were right, so keep them
        // without their times.
        if (retime &&
            !force &&
            draft.status != LyricsStatus.found &&
            draft.status != LyricsStatus.instrumental) {
          final lines = await _db.lyricsLinesForDoc(doc.id);
          draft = draftFromDoc(doc, lines).copyWith(
            synced: false,
            timeScale: 1.0,
            checkedAt: _clock(),
            lines: [for (final line in lines) LyricsLineDraft(line.lineText)],
          );
        }
      }
      // The lookup took a while: a chapter edited meanwhile was looked up
      // under its old title or start, and media replaced meanwhile is
      // another file, so leave it to the next fetch.
      if (!await _slotUnchanged(fresh, slot, mode)) continue;
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
    bool Function() stop,
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
              : await _fetchLyrics(context, slot, attempts, stop);
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
    bool Function() stop,
  ) async {
    final track = context.track;
    final durationSeconds =
        slot.durationMs == null ? null : slot.durationMs! / 1000;
    var query = await context.queryFor(slot);
    // A nightcore title alone matches any song of that name: without the
    // description naming the original, try again later rather than store
    // a guess for good.
    if (!slot.isChapter &&
        query.nightcore &&
        query.artist == null &&
        context.freshInfoFailed) {
      throw StateError('No video description for the nightcore original.');
    }
    final matcher = await _matcher();
    var match = await matcher.match(
      query,
      durationSeconds: durationSeconds,
      chapter: slot.isChapter,
      stop: stop,
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
        lines: _cutToSlot(match.lines, slot, synced: match.synced),
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

    // The video's captions are timed to the YouTube upload, not to a local
    // replacement file (which may be another edit).
    if (youtube && !track.isLocalReplacement) {
      // yt-dlp only now: it takes seconds per video on a phone.
      final info = await context.captionInfo();
      // The video's own info may name the artist when the title does not
      // (a nightcore upload, a "Topic" channel).
      if (info != null && !slot.isChapter) {
        final requery = await context.queryFor(slot);
        if (requery.artist != query.artist || requery.title != query.title) {
          query = requery;
          match = await matcher.match(
            query,
            durationSeconds: durationSeconds,
            stop: stop,
          );
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
            sourceRef: '${track.videoId}:${choice.key}',
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
      sourceRef: '${context.track.videoId}:${choice.key}',
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

  /// Synced lines of a chapter that start before its end: a chapter is
  /// often a shortened version of the song the record times.
  static List<LyricsLineDraft> _cutToSlot(
    List<LyricsLineDraft> lines,
    _Slot slot, {
    required bool synced,
  }) {
    final duration = slot.durationMs;
    if (!synced || !slot.isChapter || duration == null) return lines;
    return [
      for (final line in lines)
        if (line.startMs == null || line.startMs! < duration) line,
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
    LyricsPick pick, {
    bool Function()? stop,
  }) async {
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
      shiftMs: synced ? pick.shiftMs : 0,
      timingOff: pick.timingOff && status == LyricsStatus.found,
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
        final record = await _recordById(id, stop: stop);
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
        // The user chose this record: its times are kept even when they
        // do not fit (another intro or edit), so "Timing off?" can shift
        // them. Only automatic matches drop times that do not fit.
        final (_, scale) = _timingFor(record, slot, track.displayTitle);
        var synced = record.isSynced && !pick.timingOff;
        var lines =
            synced
                ? _cutToSlot(
                  shiftLyricsLines(
                    lyricsLinesFor(record, synced: true, timeScale: scale),
                    pick.shiftMs,
                  ),
                  slot,
                  synced: true,
                )
                : const <LyricsLineDraft>[];
        // Every line starts after the chapter ends: keep the words.
        if (lines.isEmpty) {
          synced = false;
          lines = lyricsLinesFor(record, synced: false);
        }
        return draft(
          LyricsStatus.found,
          source: LyricsSource.lrclib,
          sourceRef: '$id',
          artist: record.artistName,
          title: record.trackName,
          timeScale: synced ? scale : 1.0,
          synced: synced,
          lines: lines,
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
        var videoId = separator < 0 ? ref : ref.substring(0, separator);
        var lang = separator < 0 ? null : ref.substring(separator + 1);
        // An automatic caption doc stored before refs named the video
        // keeps only the caption track ("en"): it is this track's video.
        if (separator < 0 && _looksLikeCaptionKey(ref)) {
          videoId = track.videoId;
          lang = ref;
        }
        if (videoId.isEmpty) throw ArgumentError('No video id in "$ref".');
        final loader = _captionInfo;
        if (loader == null) throw StateError('yt-dlp is not available.');
        final info = await _paced(
          () => loader('https://www.youtube.com/watch?v=$videoId'),
          stop: stop,
        );
        final choice = _captionForPick(info, mode, lang);
        if (choice == null) {
          throw StateError('That video has no captions to use.');
        }
        // Captions are timed to the whole video: a chapter takes its part,
        // timed from its start, shifted and then cut at its end as a live
        // shift does.
        final all = await _captions.fetch(choice.url);
        final lines =
            slot.isChapter && videoId == track.videoId
                ? _cutToSlot(
                  shiftLyricsLines(_sliceForSlot(all, slot), pick.shiftMs),
                  slot,
                  synced: true,
                )
                : shiftLyricsLines(all, pick.shiftMs);
        if (lines.isEmpty) throw StateError('Those captions are empty.');
        return draft(
          LyricsStatus.found,
          source: choice.automatic ? LyricsSource.ytAuto : LyricsSource.ytSubs,
          sourceRef: '$videoId:${choice.key}',
          artist: pick.artist,
          title: pick.title ?? (info['title'] is String ? info['title'] : null),
          synced: !pick.timingOff,
          lang: choice.lang,
          lines:
              pick.timingOff
                  ? [for (final line in lines) LyricsLineDraft(line.text)]
                  : lines,
        );
      default:
        throw ArgumentError('Unknown lyrics source ${pick.source}');
    }
  }

  /// Whether a bare [ref] is a caption track key ("en", "en-US",
  /// "cs-orig", "en-nP7-2PuUl7o") and not a video id (always 11 chars).
  static bool _looksLikeCaptionKey(String ref) =>
      ref.length != 11 && RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]+)*$').hasMatch(ref);

  /// The caption track named by [key] (exact, else by language), or the
  /// best one: manual captions first, speech-to-text only for transcripts.
  static CaptionChoice? _captionForPick(
    Map<String, dynamic> info,
    LyricsMode mode,
    String? key,
  ) {
    // The user chose this video, so any manual track fits; speech-to-text
    // only for spoken content.
    final usable =
        mode == LyricsMode.transcript
            ? info
            : {...info, 'automatic_captions': null};
    if (key != null && key.isNotEmpty) {
      for (final group in ['subtitles', 'automatic_captions']) {
        final captions = usable[group];
        if (captions is! Map || captions[key] == null) continue;
        final exact = pickCaption({
          group: {key: captions[key]},
        }, mode: LyricsMode.transcript);
        if (exact != null) return exact;
      }
      return pickCaption(usable, mode: LyricsMode.transcript, onlyLang: key);
    }
    return pickCaption(usable, mode: LyricsMode.transcript);
  }

  /// Whether a chosen record's times fit the slot (see
  /// [syncedTimingFor]), and their scale.
  static (bool, double) _timingFor(
    LrclibRecord record,
    _Slot slot,
    String fileTitle,
  ) {
    final timing = syncedTimingFor(
      record,
      localSeconds: slot.durationMs == null ? null : slot.durationMs! / 1000,
      nightcore: parseSongTitle(fileTitle).nightcore,
      chapter: slot.isChapter,
    );
    return timing.fits ? (true, timing.timeScale) : (false, 1.0);
  }

  /// The automatic LRCLIB whole-file docs among [docsByTrack] whose synced
  /// lines start after their file ends (a record of a longer recording
  /// whose stated length was wrong): fetched again by the next run.
  /// Chapter docs are cut at the chapter's end, so they never show it.
  Future<Set<int>> _mistimedDocs(
    Iterable<Track> tracks,
    Map<int, List<LyricsDoc>> docsByTrack,
  ) async {
    final durationMs = <int, int>{};
    for (final track in tracks) {
      final seconds = track.durationSeconds;
      if (seconds == null || seconds <= 0) continue;
      for (final doc in docsByTrack[track.id] ?? const <LyricsDoc>[]) {
        if (!doc.pinned &&
            doc.chapterId == null &&
            doc.status == LyricsStatus.found &&
            doc.synced &&
            doc.source == LyricsSource.lrclib) {
          // The stored length is whole seconds: allow the rest of one.
          durationMs[doc.id] = (seconds + 1) * 1000;
        }
      }
    }
    if (durationMs.isEmpty) return const {};
    final lastStarts = await _db.lyricsLastLineStarts(durationMs.keys);
    return {
      for (final MapEntry(key: id, value: last) in lastStarts.entries)
        if (!syncedLinesFit(last, durationMs[id]!)) id,
    };
  }

  /// Runs one yt-dlp extraction at a time, at least [extractionGap] after
  /// the previous one ended. A [stop] that fires while waiting throws.
  Future<T> _paced<T>(Future<T> Function() run, {bool Function()? stop}) async {
    final previous = _extractions;
    final done = Completer<void>();
    _extractions = done.future;
    try {
      await previous;
      final last = _lastExtraction;
      if (last != null) {
        final since = _clock().difference(last);
        if (since < extractionGap) await _sleep(extractionGap - since);
      }
      if (stop?.call() ?? false) {
        throw const LyricsStoppedException();
      }
      try {
        return await run();
      } finally {
        _lastExtraction = _clock();
      }
    } finally {
      done.complete();
    }
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
      _log.warn(
        'Lyrics: could not save the lyrics file of ${track.displayTitle}: $e',
      );
    }
  }
}

/// A lookup stopped (cancelled or out of time) before it started.
class LyricsStoppedException implements Exception {
  const LyricsStoppedException();

  @override
  String toString() => 'The lyrics lookup was stopped.';
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
      shiftMs: doc.shiftMs,
      timingOff: doc.timingOff,
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

  /// yt-dlp was there but its extraction failed (rate limit, offline).
  bool freshInfoFailed = false;
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
      _freshInfo = await service._paced(
        () => loader('https://www.youtube.com/watch?v=${track.videoId}'),
      );
    } catch (e) {
      if (required) rethrow;
      freshInfoFailed = true;
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
      return parseChapterTitle(slot.title, parentTitle: track.displayTitle);
    }
    var info = await this.info();
    var query = parseSongTitle(
      track.displayTitle,
      meta: info == null ? null : VideoMeta.fromInfo(info),
    );
    if (query.nightcore &&
        query.artist == null &&
        info?['description'] is! String &&
        !_freshInfoTried) {
      info = await captionInfo();
      if (info != null) {
        query = parseSongTitle(
          track.displayTitle,
          meta: VideoMeta.fromInfo(info),
        );
      }
    }
    return query;
  }
}

/// Rewrites the lyrics file of [trackId] in its playlist's folder from the
/// database, or deletes it when the track has no docs. Throws on I/O errors.
Future<void> persistLyricsFile(AppDatabase db, int trackId) async {
  final track = await db.getTrack(trackId);
  if (track == null) return;
  final playlist = await db.getPlaylistOrNull(track.playlistId);
  if (playlist == null) return;
  final drafts = [
    for (final doc in await db.lyricsDocsForTrack(trackId))
      draftFromDoc(doc, await db.lyricsLinesForDoc(doc.id)),
  ];
  await writeLyricsFile(playlist.outputPath, track.videoId, drafts);
}

/// Keeps lyrics docs in step after a track's chapters were written as
/// [data]: docs of chapters that are gone are deleted, and unpinned docs of
/// chapters whose title or start changed since [previous] too (synced ones
/// also when the end moved), so the next fetch looks them up again. A
/// pinned doc whose chapter moved follows its new start (its lines are
/// timed from the song's start) and loses synced lines past its end. When anything
/// changed, the lyrics file is rewritten. Returns how many docs changed.
Future<int> syncLyricsChapterDocs(
  AppDatabase db,
  int trackId,
  ChapterData data, {
  ChapterData? previous,
}) async {
  final active = {for (final chapter in data.active) chapter.id: chapter};
  var changed = await db.pruneLyricsChapterDocs(trackId, active.keys.toSet());
  final before = {
    for (final chapter in previous?.active ?? const <MediaChapter>[])
      chapter.id: chapter,
  };
  for (final doc in await db.lyricsDocsForTrack(trackId)) {
    final id = doc.chapterId;
    if (id == null) continue;
    final now = active[id];
    if (now == null) continue;
    if (doc.pinned) {
      // Synced lines past a shortened chapter's end belong to the next one.
      final duration = now.endMs - now.startMs;
      if (doc.synced) {
        final lines = await db.lyricsLinesForDoc(doc.id);
        final kept = [
          for (final line in lines)
            if (line.startMs == null || line.startMs! < duration) line,
        ];
        if (kept.length != lines.length) {
          await db.replaceLyricsDoc(draftFromDoc(doc, kept));
          changed++;
        }
      }
      if (doc.offsetMs != now.startMs) {
        await db.setLyricsDocOffset(doc.id, now.startMs);
        changed++;
      }
      continue;
    }
    final then = before[id];
    if (then == null) continue;
    // A synced doc was cut at the chapter's old end: its lines no longer
    // fit a chapter whose end moved.
    if (now.title != then.title ||
        now.startMs != then.startMs ||
        (doc.synced && now.endMs != then.endMs)) {
      changed += await db.deleteLyricsDocs(trackId, chapterId: id);
    }
  }
  if (changed > 0) {
    try {
      await persistLyricsFile(db, trackId);
    } catch (_) {
      // The database is right; the next fetch rewrites the file.
    }
  }
  return changed;
}

/// After a track's media was replaced by another file (a local file or a
/// reupload): drops the docs timed to the old file. Chapter docs (pinned
/// too; the old chapters are gone), transcripts (they need the YouTube
/// video's own audio) and unpinned synced whole-file docs go; the lyrics
/// file is rewritten. Returns how many docs were dropped.
Future<int> dropLyricsForReplacedMedia(AppDatabase db, int trackId) async {
  final dropped = await db.deleteLyricsDocsTimedToMedia(trackId);
  if (dropped > 0) {
    try {
      await persistLyricsFile(db, trackId);
    } catch (_) {
      // The database is right; the next fetch rewrites the file.
    }
  }
  return dropped;
}
