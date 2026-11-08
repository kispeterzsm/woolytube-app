// Fields are unused until the bodies are written.
// ignore_for_file: unused_field

import 'dart:async';
import 'dart:io';

import '../../database/database.dart';
import '../log_service.dart';
import '../ytdlp_service.dart';
import 'lyrics_models.dart';

/// A track's or chapter's lyrics changed (fetched, picked, cleared).
class LyricsChange {
  final int trackId;

  /// null = the whole-file doc, or several docs of the track at once.
  final String? chapterId;

  const LyricsChange(this.trackId, [this.chapterId]);
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
  }) : _http = http,
       _ytdlp = ytdlp,
       _appVersion = appVersion,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final LogService _log;
  final HttpClient? _http;
  final YtDlpService? _ytdlp;
  final String? _appVersion;
  final DateTime Function() _clock;
  final _changes = StreamController<LyricsChange>.broadcast();

  /// Fires after this service wrote a track's lyrics.
  Stream<LyricsChange> get changes => _changes.stream;

  /// Fetches every due doc of [track] by its playlist's mode: the whole
  /// file, or each active chapter of a file that plays as chapters in
  /// lyrics mode. Docs found recently, retried too often, or pinned are
  /// skipped; [force] refetches unpinned ones anyway. Does nothing when the
  /// playlist has lyrics off.
  Future<void> fetchTrack(Track track, {bool force = false}) {
    throw UnimplementedError();
  }

  /// Fetches the due docs of every downloaded track of a playlist, one
  /// track at a time, until done, [cancellation] or [budget] runs out.
  Future<LyricsBackfillResult> backfillPlaylist(
    int playlistId, {
    void Function(LyricsFetchProgress progress)? onProgress,
    LyricsCancellation? cancellation,
    Duration? budget,
  }) {
    throw UnimplementedError();
  }

  /// LRCLIB search results for the picker's free text [query].
  Future<List<LyricsCandidate>> candidatesFor(String query) {
    throw UnimplementedError();
  }

  /// The picker's starting query for a track or chapter: the parsed
  /// "Artist Title", or the matched one when a doc exists.
  Future<String> pickerQueryFor(int trackId, String? chapterId) {
    throw UnimplementedError();
  }

  /// Stores what the user chose, pinned: fetches the chosen record, or
  /// marks the doc as having no lyrics for [LyricsPick.none].
  Future<void> applyPick(int trackId, String? chapterId, LyricsPick pick) {
    throw UnimplementedError();
  }

  /// Drops the pin of a doc and fetches it again automatically.
  Future<void> refetch(int trackId, String? chapterId) {
    throw UnimplementedError();
  }

  /// After a track's chapters changed (edit, recognition, undo): deletes
  /// docs of chapters that are gone and fetches the new ones when the
  /// playlist has lyrics on.
  Future<void> onChaptersChanged(int trackId) {
    throw UnimplementedError();
  }

  void dispose() {
    _changes.close();
  }
}
