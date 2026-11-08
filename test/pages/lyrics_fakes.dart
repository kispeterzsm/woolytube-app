import 'dart:async';

import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_service.dart';

/// A lyrics service without network: records calls, and writes docs to the
/// test database the way the real one would.
class FakeLyricsService implements LyricsService {
  FakeLyricsService([this.db]);

  final AppDatabase? db;
  final calls = <String>[];

  /// What [candidatesFor] returns, and the queries it got.
  List<LyricsCandidate> candidates = const [];
  final queries = <String>[];
  final candidateSlots = <(int?, String?)>[];
  String pickerQuery = 'Avicii Hey Brother';

  /// Thrown by [applyPick] when set.
  Object? applyError;

  /// Stored by [fetchTrack] when set.
  LyricsDocDraft Function(Track track)? fetched;

  // Backfill: one track per [step], [backfillTotal] tracks.
  LyricsCancellation? cancellation;
  Completer<void>? _gate;
  int backfillTotal = 3;
  bool failWhenStopped = false;

  /// Finishes the track the backfill is on.
  void step() {
    final gate = _gate;
    _gate = null;
    gate?.complete();
  }

  /// Lets a backfill end at once (no steps needed).
  bool instantBackfill = false;

  @override
  Future<void> onChaptersChanged(int trackId) async {
    calls.add('chapters $trackId');
  }

  @override
  Future<void> fetchTrack(Track track, {bool force = false}) async {
    calls.add('fetch ${track.id}');
    final draft = fetched?.call(track);
    if (draft != null) await db!.replaceLyricsDoc(draft);
  }

  @override
  Future<LyricsBackfillResult> backfillPlaylist(
    int playlistId, {
    void Function(LyricsFetchProgress progress)? onProgress,
    LyricsCancellation? cancellation,
    Duration? budget,
  }) async {
    calls.add('backfill $playlistId');
    this.cancellation = cancellation;
    final total = backfillTotal;
    var done = 0;
    if (instantBackfill) {
      return LyricsBackfillResult(due: total, found: total);
    }
    onProgress?.call(LyricsFetchProgress(done: 0, total: total));
    while (done < total) {
      await (_gate = Completer<void>()).future;
      done++;
      onProgress?.call(LyricsFetchProgress(done: done, total: total));
      if (cancellation?.isCancelled ?? false) break;
    }
    if (failWhenStopped && (cancellation?.isCancelled ?? false)) {
      throw StateError('No element');
    }
    return LyricsBackfillResult(
      due: total,
      found: done,
      cancelled: cancellation?.isCancelled ?? false,
    );
  }

  @override
  Future<List<LyricsCandidate>> candidatesFor(
    String query, {
    int? trackId,
    String? chapterId,
  }) async {
    queries.add(query);
    candidateSlots.add((trackId, chapterId));
    return candidates;
  }

  @override
  Future<String> pickerQueryFor(int trackId, String? chapterId) async =>
      pickerQuery;

  @override
  Future<void> applyPick(
    int trackId,
    String? chapterId,
    LyricsPick pick,
  ) async {
    calls.add(
      pick.none
          ? 'none $trackId $chapterId'
          : 'pick $trackId $chapterId ${pick.source} ${pick.sourceRef}',
    );
    final error = applyError;
    if (error != null) throw error;
    await db?.replaceLyricsDoc(
      LyricsDocDraft(
        trackId: trackId,
        chapterId: chapterId,
        kind: LyricsMode.lyrics,
        status: pick.none ? LyricsStatus.none : LyricsStatus.found,
        source: pick.source,
        sourceRef: pick.sourceRef,
        matchedArtist: pick.artist,
        matchedTitle: pick.title,
        pinned: true,
        checkedAt: DateTime(2026, 11, 8),
        lines: pick.none ? const [] : const [LyricsLineDraft('Picked line')],
      ),
    );
  }

  @override
  Future<void> setTimingShift(
    int trackId,
    String? chapterId,
    int shiftMs,
  ) async {
    calls.add('shift $trackId $chapterId $shiftMs');
    final doc = await db!.lyricsDocFor(trackId, chapterId);
    if (doc == null) return;
    final lines = await db!.lyricsLinesForDoc(doc.id);
    await db!.replaceLyricsDoc(
      draftFromDoc(doc, lines).copyWith(
        pinned: true,
        shiftMs: shiftMs,
        lines: shiftLyricsLines([
          for (final line in lines)
            LyricsLineDraft(line.lineText, startMs: line.startMs),
        ], shiftMs - doc.shiftMs),
      ),
    );
  }

  @override
  Future<void> useWithoutTiming(int trackId, String? chapterId) async {
    calls.add('untimed $trackId $chapterId');
  }

  @override
  Future<void> refetch(int trackId, String? chapterId) async {
    calls.add('refetch $trackId $chapterId');
  }

  @override
  Stream<LyricsChange> get changes => const Stream.empty();

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
