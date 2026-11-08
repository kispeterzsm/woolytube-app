/// Shared types of the lyrics and transcript feature.
library;

/// What a playlist fetches for search. Stored in `Playlists.lyricsMode`;
/// null there means off.
enum LyricsMode {
  /// Song lyrics: LRCLIB, YouTube Music, then the uploader's own captions.
  lyrics('lyrics'),

  /// Spoken content: manual captions, then the original-language
  /// speech-to-text track.
  transcript('transcript');

  const LyricsMode(this.dbValue);

  /// The value in `Playlists.lyricsMode` and `LyricsDocs.kind`.
  final String dbValue;

  /// The mode stored as [value]; null (off) for null or an unknown value.
  static LyricsMode? fromDb(String? value) {
    for (final mode in values) {
      if (mode.dbValue == value) return mode;
    }
    return null;
  }

  /// The column value for [mode]; null = off.
  static String? toDb(LyricsMode? mode) => mode?.dbValue;
}

/// Whether a playlist's stored `lyricsMode` turns the feature on.
bool lyricsModeIsOn(String? value) => LyricsMode.fromDb(value) != null;

/// Values of `LyricsDocs.status`.
abstract final class LyricsStatus {
  static const found = 'found';
  static const none = 'none';
  static const instrumental = 'instrumental';
  static const error = 'error';
}

/// Values of `LyricsDocs.source`.
abstract final class LyricsSource {
  static const lrclib = 'lrclib';
  static const ytmusic = 'ytmusic';

  /// Manual (uploader-written) YouTube captions.
  static const ytSubs = 'yt_subs';

  /// YouTube speech-to-text captions (`<lang>-orig`).
  static const ytAuto = 'yt_auto';
}

/// One line to store. [startMs] is relative to the doc and already scaled by
/// its time scale; null for plain text.
class LyricsLineDraft {
  final int? startMs;
  final String text;

  const LyricsLineDraft(this.text, {this.startMs});

  @override
  bool operator ==(Object other) =>
      other is LyricsLineDraft &&
      other.startMs == startMs &&
      other.text == text;

  @override
  int get hashCode => Object.hash(startMs, text);

  @override
  String toString() => 'LyricsLineDraft(${startMs}ms, "$text")';
}

/// A whole doc to store with `AppDatabase.replaceLyricsDoc`: it replaces
/// the doc of the same (track, chapter) and all its lines.
class LyricsDocDraft {
  final int trackId;

  /// `MediaChapter.id`; null = the whole file.
  final String? chapterId;

  /// Chapter start in the file; line times are relative to it.
  final int offsetMs;
  final LyricsMode kind;

  /// One of [LyricsStatus].
  final String status;

  /// One of [LyricsSource]; null when nothing was found.
  final String? source;
  final String? sourceRef;
  final String? matchedArtist;
  final String? matchedTitle;
  final double timeScale;
  final bool synced;
  final bool pinned;

  /// The user's timing correction: already added to every line's start
  /// (after the time scale). Kept so a restore from [sourceRef] adds it
  /// again, and so it can be taken back.
  final int shiftMs;

  /// The user chose to use the lines without times.
  final bool timingOff;
  final String? lang;
  final DateTime checkedAt;

  /// Automatic tries so far (for the retry limit).
  final int attempts;

  /// Empty unless [status] is found.
  final List<LyricsLineDraft> lines;

  const LyricsDocDraft({
    required this.trackId,
    this.chapterId,
    this.offsetMs = 0,
    required this.kind,
    required this.status,
    this.source,
    this.sourceRef,
    this.matchedArtist,
    this.matchedTitle,
    this.timeScale = 1.0,
    this.synced = false,
    this.pinned = false,
    this.shiftMs = 0,
    this.timingOff = false,
    this.lang,
    required this.checkedAt,
    this.attempts = 0,
    this.lines = const [],
  });

  /// This doc with other fields.
  LyricsDocDraft copyWith({
    String? sourceRef,
    double? timeScale,
    bool? synced,
    bool? pinned,
    int? shiftMs,
    bool? timingOff,
    DateTime? checkedAt,
    List<LyricsLineDraft>? lines,
  }) => LyricsDocDraft(
    trackId: trackId,
    chapterId: chapterId,
    offsetMs: offsetMs,
    kind: kind,
    status: status,
    source: source,
    sourceRef: sourceRef ?? this.sourceRef,
    matchedArtist: matchedArtist,
    matchedTitle: matchedTitle,
    timeScale: timeScale ?? this.timeScale,
    synced: synced ?? this.synced,
    pinned: pinned ?? this.pinned,
    shiftMs: shiftMs ?? this.shiftMs,
    timingOff: timingOff ?? this.timingOff,
    lang: lang,
    checkedAt: checkedAt ?? this.checkedAt,
    attempts: attempts,
    lines: lines ?? this.lines,
  );
}

/// [lines] with [deltaMs] added to every timed start. Starts may become
/// negative (a line sung before the file starts); readers clamp them.
List<LyricsLineDraft> shiftLyricsLines(
  List<LyricsLineDraft> lines,
  int deltaMs,
) =>
    deltaMs == 0
        ? lines
        : [
          for (final line in lines)
            LyricsLineDraft(
              line.text,
              startMs: line.startMs == null ? null : line.startMs! + deltaMs,
            ),
        ];

/// What the user chose in the picker for a track or chapter.
class LyricsPick {
  /// One of [LyricsSource]; null with [none].
  final String? source;

  /// LRCLIB id, or `<videoId>:<lang>` for YouTube captions.
  final String? sourceRef;
  final String? artist;
  final String? title;

  /// "No lyrics here": stored as status none, pinned.
  final bool none;

  /// The user's timing correction, added to every line (see
  /// [LyricsDocDraft.shiftMs]).
  final int shiftMs;

  /// Store the lines without times even when they would fit.
  final bool timingOff;

  const LyricsPick({
    required String this.source,
    required String this.sourceRef,
    this.artist,
    this.title,
    this.shiftMs = 0,
    this.timingOff = false,
  }) : none = false;

  /// An LRCLIB record chosen from the picker.
  LyricsPick.lrclib(LyricsCandidate candidate)
    : source = LyricsSource.lrclib,
      sourceRef = '${candidate.id}',
      artist = candidate.artist,
      title = candidate.title,
      shiftMs = 0,
      timingOff = false,
      none = false;

  /// The track or chapter has no lyrics.
  const LyricsPick.none()
    : source = null,
      sourceRef = null,
      artist = null,
      title = null,
      shiftMs = 0,
      timingOff = false,
      none = true;
}

/// An LRCLIB search result shown in the picker.
class LyricsCandidate {
  /// LRCLIB record id.
  final int id;
  final String artist;
  final String title;
  final String? album;
  final double? durationSeconds;
  final bool synced;
  final bool instrumental;

  /// The plain lyrics (or synced text without times), for the preview.
  final String plainPreview;

  /// When the last synced line starts in the record; null when not synced.
  final double? lastLineSeconds;

  /// The length of the user's file (or chapter) it was compared with.
  final double? localSeconds;

  /// Whether its synced times fit the user's file; null when unknown (not
  /// synced, or no local length to compare with).
  final bool? timingFits;

  const LyricsCandidate({
    required this.id,
    required this.artist,
    required this.title,
    this.album,
    this.durationSeconds,
    required this.synced,
    required this.instrumental,
    required this.plainPreview,
    this.lastLineSeconds,
    this.localSeconds,
    this.timingFits,
  });
}

/// A character range [start, end) in a line's raw text to highlight.
class LyricsHighlight {
  final int start;
  final int end;

  const LyricsHighlight(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is LyricsHighlight && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'LyricsHighlight($start, $end)';
}

/// One search result: the best matching line of one doc.
class LyricsHit {
  final int trackId;

  /// The doc's chapter; for a whole-file transcript the UI maps
  /// [positionMs] to a chapter itself.
  final String? chapterId;
  final int docId;

  /// The matched line's id and number in the doc.
  final int lineId;
  final int lineNo;

  /// The matched lines as shown (raw text; a span of several lines is
  /// joined with ' / ').
  final String lineText;

  /// Ranges in [lineText] to highlight.
  final List<LyricsHighlight> highlightRanges;

  /// File time of the line (doc offset + line start); null for plain text.
  final int? positionMs;
  final double score;
  final LyricsMode kind;

  const LyricsHit({
    required this.trackId,
    this.chapterId,
    required this.docId,
    required this.lineId,
    required this.lineNo,
    required this.lineText,
    this.highlightRanges = const [],
    this.positionMs,
    required this.score,
    required this.kind,
  });

  @override
  String toString() =>
      'LyricsHit(track $trackId, chapter $chapterId, doc $docId, '
      'line $lineNo "$lineText", ${positionMs}ms, '
      'score ${score.toStringAsFixed(2)})';
}

/// Progress of a backfill run.
class LyricsFetchProgress {
  final int done;
  final int total;

  const LyricsFetchProgress({required this.done, required this.total});
}

/// Outcome of `LyricsService.backfillPlaylist`.
class LyricsBackfillResult {
  /// Tracks and chapters that were due.
  final int due;

  /// Docs stored with lyrics or a transcript.
  final int found;

  /// Docs stored as none or instrumental.
  final int missing;

  /// Lookups that failed (offline, rate limited, ...).
  final int failed;

  /// Whether the run stopped early because it was cancelled.
  final bool cancelled;

  /// Whether the run stopped early because its time budget ran out.
  final bool outOfTime;

  const LyricsBackfillResult({
    this.due = 0,
    this.found = 0,
    this.missing = 0,
    this.failed = 0,
    this.cancelled = false,
    this.outOfTime = false,
  });
}

/// Stops a running backfill between tracks.
class LyricsCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}
