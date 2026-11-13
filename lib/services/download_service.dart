import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../database/database.dart';
import 'download_errors.dart';
import 'ytdlp_service.dart';
import 'app_settings_service.dart';
import 'library_gate.dart';
import 'log_service.dart';
import 'lyrics/lyrics_models.dart';
import 'lyrics/lyrics_service.dart';
import 'media_thumbnail_service.dart';
import 'metadata_service.dart';
import 'notification_service.dart';
import 'sponsorblock_service.dart';
import 'video_quality.dart';

/// What a running download is doing right now.
enum DownloadPhase {
  /// Nothing is running (status 'idle', 'complete' or 'error').
  none,

  /// Repairing leftovers and working out what to download.
  preparing,

  /// Downloading tracks.
  downloading,

  /// Fetching skip segments, writing the playlist files, cleaning up.
  finishing,
}

/// One progress report of [DownloadService].
///
/// While a run is busy, [status] is 'downloading' in every [phase]. The
/// position fields count the tracks of this run, not of the playlist:
/// [currentTrackIndex] is the 1-based number of the track being downloaded
/// and [totalTracks] how many tracks this run downloads ("2 of 3").
///
/// Values compare by content, so `select` on the provider only rebuilds
/// when something shown actually changed. [trackProgress] moves in whole
/// percent steps and at most a few times a second.
class DownloadProgress {
  final int playlistId;
  final int currentTrackIndex;
  final int totalTracks;

  /// Percent (0-100) of the current track.
  final double trackProgress;
  final String status; // idle | downloading | complete | error
  final String? error;

  final DownloadPhase phase;

  /// Title of the track being downloaded.
  final String? currentTitle;

  /// Database id of the track being downloaded.
  final int? activeTrackId;

  /// Tracks of this run that downloaded (or were found on disk) so far.
  final int downloadedCount;

  /// Tracks of this run whose download failed so far; the next update
  /// tries them again.
  final int failedCount;

  /// Tracks of this run that YouTube removed for good. They are marked
  /// "Removed from YouTube"; updates try them again quietly, and a track
  /// that is still removed then is not counted again.
  final int removedCount;

  const DownloadProgress({
    required this.playlistId,
    required this.currentTrackIndex,
    required this.totalTracks,
    required this.trackProgress,
    required this.status,
    this.error,
    this.phase = DownloadPhase.none,
    this.currentTitle,
    this.activeTrackId,
    this.downloadedCount = 0,
    this.failedCount = 0,
    this.removedCount = 0,
  });

  static const idle = DownloadProgress(
    playlistId: 0,
    currentTrackIndex: 0,
    totalTracks: 0,
    trackProgress: 0,
    status: 'idle',
  );

  bool get isBusy => status == 'downloading';

  /// Progress through the whole run, 0 to 1. Before and after the track
  /// downloads it is 0 and 1.
  double get overallFraction {
    if (status == 'complete') return 1;
    if (phase == DownloadPhase.finishing) return 1;
    if (totalTracks <= 0 || phase != DownloadPhase.downloading) return 0;
    final done = (currentTrackIndex - 1).clamp(0, totalTracks);
    final fraction = (done + trackProgress.clamp(0, 100) / 100) / totalTracks;
    return fraction.clamp(0.0, 1.0).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadProgress &&
      other.playlistId == playlistId &&
      other.currentTrackIndex == currentTrackIndex &&
      other.totalTracks == totalTracks &&
      other.trackProgress == trackProgress &&
      other.status == status &&
      other.error == error &&
      other.phase == phase &&
      other.currentTitle == currentTitle &&
      other.activeTrackId == activeTrackId &&
      other.downloadedCount == downloadedCount &&
      other.failedCount == failedCount &&
      other.removedCount == removedCount;

  @override
  int get hashCode => Object.hash(
    playlistId,
    currentTrackIndex,
    totalTracks,
    trackProgress,
    status,
    error,
    phase,
    currentTitle,
    activeTrackId,
    downloadedCount,
    failedCount,
    removedCount,
  );

  @override
  String toString() =>
      'DownloadProgress($status/${phase.name}, playlist $playlistId, '
      '$currentTrackIndex/$totalTracks, ${trackProgress.round()}%'
      '${error == null ? '' : ', error: $error'})';
}

/// What [DownloadService.downloadPlaylist] did with a request.
enum DownloadStart {
  /// The download ran (the returned future completes when it is done).
  started,

  /// Another download is running; this playlist starts after it.
  queued,

  /// This playlist is already downloading or queued.
  alreadyQueued,
}

typedef LockDirectoryProvider = Future<String> Function();

/// Mutual exclusion between the foreground app and the hourly background
/// worker. Both run in the same process but in separate Flutter engines, so a
/// file in the app's documents directory is the shared state.
///
/// The file records its owner. A holder of the same kind may take the lock
/// over, because only one foreground service and one scheduled worker can
/// exist at a time; a lock left behind by a killed engine must not block the
/// other side forever.
class DownloadLock {
  DownloadLock({LockDirectoryProvider? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const foregroundOwner = 'foreground';
  static const backgroundOwner = 'background';
  static const fileName = 'download.lock';

  /// The foreground refreshes its lock before every track, so a much older
  /// lock belongs to a process that no longer exists.
  static const foregroundStaleAfter = Duration(hours: 1);

  /// WorkManager destroys the background engine after ten minutes, so a
  /// background lock cannot be live for longer than that.
  static const backgroundStaleAfter = Duration(minutes: 10);

  /// A lock without a readable holder is left by an engine that died between
  /// creating the file and stamping it. Only a moment passes between the two,
  /// so such a lock is abandoned once it is this old.
  static const unknownHolderStaleAfter = Duration(seconds: 10);

  static Future<String> _defaultDirectory() async =>
      (await getApplicationDocumentsDirectory()).path;

  final LockDirectoryProvider _directoryProvider;

  Future<File> _file() async =>
      File(p.join(await _directoryProvider(), fileName));

  static String _stamp(String owner) =>
      '$owner ${DateTime.now().toIso8601String()}';

  /// Takes the lock for [owner]. Returns false while a live holder of another
  /// kind has it.
  ///
  /// A free lock is taken by creating the file exclusively, so when both
  /// engines start at the same moment only one of them gets it.
  Future<bool> acquire(String owner) async {
    final file = await _file();
    var created = false;
    try {
      await file.create(exclusive: true);
      created = true;
    } on FileSystemException {
      // It exists: see who holds it.
    }
    if (created) {
      try {
        await file.writeAsString(_stamp(owner), flush: true);
        return true;
      } on FileSystemException {
        // Do not leave an unstamped lock behind.
        try {
          await file.delete();
        } on FileSystemException {
          // It goes stale on its own.
        }
        rethrow;
      }
    }
    if (await isHeldByOther(owner, file: file)) return false;
    // Ours already, or abandoned: take it over.
    await file.writeAsString(_stamp(owner), flush: true);
    return true;
  }

  /// Whether a live lock of a kind other than [owner] exists.
  Future<bool> isHeldByOther(String owner, {File? file}) async {
    final lockFile = file ?? await _file();
    final String holder;
    final DateTime modified;
    try {
      if (!await lockFile.exists()) return false;
      holder = (await lockFile.readAsString()).split(' ').first.trim();
      modified = await lockFile.lastModified();
    } on FileSystemException {
      // The other engine released it between the checks.
      return false;
    }
    if (holder == owner) return false;
    final staleAfter = switch (holder) {
      backgroundOwner => backgroundStaleAfter,
      foregroundOwner => foregroundStaleAfter,
      _ => unknownHolderStaleAfter,
    };
    return DateTime.now().difference(modified) < staleAfter;
  }

  /// Re-stamps the lock so a long foreground download is not mistaken for an
  /// abandoned one.
  Future<void> refresh(String owner) async {
    final file = await _file();
    try {
      await file.writeAsString(_stamp(owner), flush: true);
    } on FileSystemException {
      // Losing a refresh only shortens the stale window.
    }
  }

  /// Removes the lock. With [owner], only a lock that still names [owner] is
  /// removed, so one side can never drop the other side's live lock.
  Future<void> release([String? owner]) async {
    final file = await _file();
    try {
      if (!await file.exists()) return;
      if (owner != null) {
        final holder = (await file.readAsString()).split(' ').first.trim();
        if (holder != owner) return;
      }
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}

enum _TrackDownloadResult { downloaded, reused, failed, removed, cancelled }

/// Words in a yt-dlp error that mean the video cannot be fetched by this
/// app, as opposed to a network hiccup, a bot check or a yt-dlp bug.
///
/// A bare "Video unavailable" is not among them: YouTube also answers bot
/// checks and throttled requests with it.
const _permanentErrorPatterns = [
  'private video',
  'video is private',
  'members-only',
  'members only',
  'premium',
  'confirm your age',
  'age-restricted',
];

/// Whether [message] says YouTube will not give this app the video, now or
/// later: removed for good (see [isRemovedFromYouTubeError]), private,
/// members-only, Premium-only or age-restricted.
bool isPermanentDownloadError(String message) {
  if (isBotCheckDownloadError(message)) return false;
  if (isRemovedFromYouTubeError(message)) return true;
  final lower = message.toLowerCase();
  return _permanentErrorPatterns.any(lower.contains);
}

class DownloadService {
  static const lockHeldMessage =
      'A scheduled update is running in the background. '
      'Try again in a few minutes.';

  /// Longest title part of a downloaded file name, in bytes. File names are
  /// limited to 255 bytes and non-Latin titles take 2-4 bytes per letter.
  static const titleByteLimit = 150;

  /// Shortest gap between two progress reports of one track.
  static const progressInterval = Duration(milliseconds: 250);

  /// Shortest gap between two updates of the download notification.
  static const notificationInterval = Duration(seconds: 1);

  final AppDatabase _db;
  final YtDlpService _ytdlp;
  final LogService _log;
  final MetadataService _metadata;
  final DownloadNotificationService? _notifications;
  final SponsorBlockService? _sponsorBlock;
  final LyricsService? _lyrics;
  final AppSettingsService _settings;
  final LibraryGate _gate;
  final MediaThumbnailService _thumbnails;

  final _progressController = StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  final _queueController = StreamController<List<int>>.broadcast();
  final _queue = <({int playlistId, bool sourceChecked})>[];

  /// Playlists asked to download while they were already downloading. The
  /// running pass chose its work when it started, so each gets one more
  /// pass right after it, which picks up what was added meanwhile.
  final _rerunRequested = <int>{};

  /// While above zero, queued playlists wait, and new requests queue
  /// instead of starting (see [runWithDownloadStopped]).
  int _queueHolds = 0;

  StreamSubscription? _ytdlpProgressSub;
  bool _isDownloading = false;
  bool _finishing = false;
  bool _cancelRequested = false;
  Completer<void> _cancelSignal = Completer<void>();
  Completer<void>? _runCompleter;
  bool _reportingStarted = false;
  int? _activeTrackId;
  bool _activeTrackIsReplacement = false;
  Playlist? _activePlaylist;
  String? _lastFailure;

  // What the progress reports describe.
  int _position = 0;
  int _workTotal = 0;
  String? _currentTitle;
  int? _currentTrackId;
  int _downloadedSoFar = 0;
  int _failedSoFar = 0;
  int _removedSoFar = 0;
  DownloadProgress? _lastEmitted;
  final _sinceTrackEmit = Stopwatch();
  final _sinceNotification = Stopwatch();
  int _lastNotifiedPercent = -1;
  int? _lastNotifiedPosition;

  bool get isDownloading => _isDownloading;

  /// The track whose file is being downloaded right now, if any.
  int? get activeTrackId => _activeTrackId;

  /// The playlist being downloaded right now, if any.
  int? get activePlaylistId => _activePlaylist?.id;

  /// Completes when the running download has fully ended (at once when none
  /// is running). Use after [cancelActiveDownloads] to wait until the
  /// library is free again.
  Future<void> get runFinished => _runCompleter?.future ?? Future.value();

  /// Playlists waiting for the running download to finish, in order.
  List<int> get queuedPlaylistIds => [for (final e in _queue) e.playlistId];

  /// [queuedPlaylistIds] after every change.
  Stream<List<int>> get queueStream => _queueController.stream;

  /// The last progress report, or [DownloadProgress.idle].
  DownloadProgress get currentProgress => _lastEmitted ?? DownloadProgress.idle;

  /// Mutual exclusion shared with every other operation that changes files.
  LibraryGate get gate => _gate;

  DownloadService(
    this._db,
    this._ytdlp,
    this._log,
    this._metadata, [
    this._notifications,
    this._sponsorBlock,
    AppSettingsService? settings,
    DownloadLock? lock,
    String lockOwner = DownloadLock.foregroundOwner,
    LibraryGate? gate,
    MediaThumbnailService? thumbnails,
    LyricsService? lyrics,
  ]) : _lyrics = lyrics,
       _settings = settings ?? AppSettingsService(),
       _gate =
           gate ?? LibraryGate(lock: lock ?? DownloadLock(), owner: lockOwner),
       _thumbnails = thumbnails ?? const MediaThumbnailService();

  /// yt-dlp reads `%` in `-o` as the start of a format field, so a literal
  /// path component such as `100% Hits` must be doubled.
  static String escapeOutputTemplateLiteral(String literal) =>
      literal.replaceAll('%', '%%');

  void _emit(DownloadProgress progress) {
    if (_progressController.isClosed) return;
    // Repeated identical reports carry nothing new. Errors always go out:
    // the same refusal twice in a row is still worth telling.
    if (progress.status != 'error' && progress == _lastEmitted) return;
    _lastEmitted = progress;
    _progressController.add(progress);
  }

  /// A report of the running playlist in [phase].
  void _emitRun(
    Playlist playlist,
    DownloadPhase phase, {
    double trackProgress = 0,
  }) {
    _emit(
      DownloadProgress(
        playlistId: playlist.id,
        currentTrackIndex: _position,
        totalTracks: _workTotal,
        trackProgress: trackProgress,
        status: 'downloading',
        phase: phase,
        currentTitle: phase == DownloadPhase.downloading ? _currentTitle : null,
        activeTrackId:
            phase == DownloadPhase.downloading ? _currentTrackId : null,
        downloadedCount: _downloadedSoFar,
        failedCount: _failedSoFar,
        removedCount: _removedSoFar,
      ),
    );
  }

  void _setQueue() {
    if (!_queueController.isClosed) _queueController.add(queuedPlaylistIds);
  }

  void _resetRunState() {
    _position = 0;
    _workTotal = 0;
    _currentTitle = null;
    _currentTrackId = null;
    _downloadedSoFar = 0;
    _failedSoFar = 0;
    _removedSoFar = 0;
    _lastNotifiedPercent = -1;
    _lastNotifiedPosition = null;
  }

  void _beginRun(Playlist playlist) {
    _isDownloading = true;
    _cancelRequested = false;
    _cancelSignal = Completer<void>();
    _runCompleter = Completer<void>();
    _activePlaylist = playlist;
    _lastFailure = null;
    _resetRunState();
  }

  /// Downloads every pending or failed track of [playlist], and replaces the
  /// files of tracks whose replacement was requested (a mode switch, or the
  /// original of a local replacement). An existing file is only replaced
  /// after its successor is completely on disk.
  ///
  /// Pass [sourceChecked] false when the playlist could not be read from
  /// YouTube first: the run then does not count as an update, so the next
  /// scheduled check still happens on time.
  ///
  /// An update ([sourceChecked]) also tries again the tracks marked
  /// "Removed from YouTube", after all other work. Such a retry is quiet:
  /// one that fails again is neither counted as failed nor notified.
  ///
  /// When another download is running, the playlist is queued and starts
  /// right after it ([DownloadStart.queued]); the returned future then
  /// completes at once.
  ///
  /// [shouldStop] is asked before each track (the scheduled worker passes
  /// its time budget): once it says true, no further track starts, what is
  /// done so far is saved and the playlist stays due, like after a cancel.
  Future<DownloadStart> downloadPlaylist(
    Playlist playlist, {
    bool sourceChecked = true,
    bool Function()? shouldStop,
  }) async {
    if (_isDownloading || _queueHolds > 0) {
      final inQueue = _queue.indexWhere((e) => e.playlistId == playlist.id);
      if (_activePlaylist?.id == playlist.id || inQueue >= 0) {
        if (inQueue >= 0 && sourceChecked && !_queue[inQueue].sourceChecked) {
          _queue[inQueue] = (playlistId: playlist.id, sourceChecked: true);
        }
        if (inQueue < 0) _rerunRequested.add(playlist.id);
        return DownloadStart.alreadyQueued;
      }
      _queue.add((playlistId: playlist.id, sourceChecked: sourceChecked));
      _log.info('"${playlist.name}" queued after the running download');
      _setQueue();
      return DownloadStart.queued;
    }
    _beginRun(playlist);
    var entered = false;
    var downloadedCount = 0;
    var reusedCount = 0;
    var failedCount = 0;
    var removedCount = 0;
    final failureReasons = <String>[];

    try {
      final busy = await _gate.tryEnter('download', wait: LibraryGate.userWait);
      if (busy != null) {
        _log.warn('Playlist download skipped: $busy');
        _emit(
          DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: 0,
            totalTracks: 0,
            trackProgress: 0,
            status: 'error',
            error: busy,
          ),
        );
        return DownloadStart.started;
      }
      entered = true;
      _emitRun(playlist, DownloadPhase.preparing);

      // Settings such as the folder may have changed since the caller read
      // the row (for example a mode switch), or the playlist may be gone.
      final current = await _db.getPlaylistOrNull(playlist.id);
      if (current == null) {
        _log.info('"${playlist.name}" was deleted; nothing to download');
        _emit(DownloadProgress.idle);
        return DownloadStart.started;
      }
      playlist = current;
      _activePlaylist = playlist;

      // A manual or scheduled update is an explicit download trigger. Repair
      // anything a previous process left behind before selecting work.
      await _metadata.discardStaging(playlist.outputPath);
      var recovered = await _metadata.recoverInterruptedPlaylist(playlist);
      recovered += await _metadata.adoptStrayFiles(playlist);
      if (recovered > 0) {
        _log.info('Recovered $recovered interrupted download files/states');
        await _writeMetadataForPlaylist(playlist.id);
      }

      final pendingTracks = await _db.getPendingTracks(playlist.id);
      final replaceTracks = await _db.getReplacementRequests(playlist.id);
      // YouTube sometimes brings a removed video back (a claim withdrawn, an
      // account restored), so every update asks for those again. They go
      // last: they never hold up new videos or eat a time budget first.
      final retryTracks =
          sourceChecked
              ? await _db.getRemovedFromYouTubeTracks(playlist.id)
              : const <Track>[];
      final work = [
        for (final track in pendingTracks)
          (track: track, replace: false, retry: false),
        for (final track in replaceTracks)
          (track: track, replace: true, retry: false),
      ]..sort((a, b) => a.track.index.compareTo(b.track.index));
      work.addAll([
        for (final track in retryTracks)
          (track: track, replace: false, retry: true),
      ]);
      final playlistTrackCount = await _db.getTotalTrackCount(playlist.id);
      _workTotal = work.length;

      _log.info(
        'Updating "${playlist.name}": ${pendingTracks.length} of '
        '$playlistTrackCount tracks to download'
        '${replaceTracks.isEmpty ? '' : ', ${replaceTracks.length} to replace'}'
        '${retryTracks.isEmpty ? '' : ', ${retryTracks.length} removed to try again'}',
      );

      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return DownloadStart.started;
      }

      if (work.isEmpty) {
        // A successful check with no pending work still starts the next
        // auto-update interval. Without this, an unchanged playlist remains
        // overdue and gets checked on every background-worker run.
        if (sourceChecked) await _markPlaylistUpdated(playlist);
        _emitRun(playlist, DownloadPhase.finishing);
        await _backfillMissingSponsorBlockSegments(playlist);
        await _backfillMissingLyrics(playlist);
        await _writeMetadataForPlaylist(playlist.id);
        if (_cancelRequested) {
          _emit(DownloadProgress.idle);
          return DownloadStart.started;
        }
        _emit(
          DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: 0,
            totalTracks: 0,
            trackProgress: 100,
            status: 'complete',
          ),
        );
        return DownloadStart.started;
      }

      await _startDownloadReporting(playlist);

      var playlistDeleted = false;
      var outOfTime = false;
      var retriedBack = 0;
      var retriedStillRemoved = 0;
      for (var i = 0; i < work.length; i++) {
        if (_cancelRequested) break;
        if (shouldStop?.call() ?? false) {
          outOfTime = true;
          break;
        }
        // Deleting a playlist (keeping its files) does not wait for its
        // download; stop instead of downloading files nobody keeps.
        final latest = await _db.getPlaylistOrNull(playlist.id);
        if (latest == null) {
          _log.info('"${playlist.name}" was deleted; stopping its download');
          playlistDeleted = true;
          break;
        }
        final item = work[i];
        _position = i + 1;
        await _gate.refresh();
        // The run chose its work when it started; read the track again so
        // a quality set on it meanwhile is used.
        final track = await _db.getTrack(item.track.id) ?? item.track;

        final result = await _downloadTrackFile(
          playlist: playlist,
          track: item.track,
          totalTracks: playlistTrackCount,
          trackLabel: '[${i + 1}/${work.length}] ${item.track.title}',
          reuseExistingFile: !item.replace,
          replaceExisting: item.replace,
          // A quality chosen while the run goes applies to the next track.
          maxHeight: effectiveMaxHeight(latest, track),
        );
        if (item.retry) {
          // Quiet: a video still gone is not news, and its failure must not
          // count towards a failure notification.
          if (result == _TrackDownloadResult.downloaded ||
              result == _TrackDownloadResult.reused) {
            downloadedCount++;
            _downloadedSoFar++;
            retriedBack++;
          } else if (result == _TrackDownloadResult.removed) {
            retriedStillRemoved++;
          } else if (result == _TrackDownloadResult.failed &&
              !isPermanentDownloadError(_lastFailure ?? '')) {
            // A bot check or the network: the other removed videos would
            // fail the same way. They wait for the next update.
            _log.info(
              'Stopped trying removed videos again for now: $_lastFailure',
            );
            break;
          }
          continue;
        }
        switch (result) {
          case _TrackDownloadResult.downloaded:
            downloadedCount++;
            _downloadedSoFar++;
          case _TrackDownloadResult.reused:
            reusedCount++;
            _downloadedSoFar++;
          case _TrackDownloadResult.failed:
            failedCount++;
            _failedSoFar++;
            failureReasons.add(_lastFailure ?? 'Download failed');
          case _TrackDownloadResult.removed:
            removedCount++;
            _removedSoFar++;
          case _TrackDownloadResult.cancelled:
            break;
        }
      }

      if (playlistDeleted) {
        _emit(DownloadProgress.idle);
        return DownloadStart.started;
      }

      if (_cancelRequested || outOfTime) {
        _log.info(
          outOfTime
              ? 'Out of time; the rest of "${playlist.name}" waits for the '
                  'next update'
              : 'Playlist download stopped',
        );
        await _writeMetadataForPlaylist(playlist.id);
        _emit(DownloadProgress.idle);
        return DownloadStart.started;
      }

      if (removedCount > 0) {
        _log.warn(
          '$removedCount ${removedCount == 1 ? 'video was' : 'videos were'} '
          'removed from YouTube; they are marked and only tried again '
          'quietly by updates',
        );
      }
      if (retriedBack + retriedStillRemoved > 0) {
        _log.info(
          'Tried removed videos again: $retriedBack back, '
          '$retriedStillRemoved still removed',
        );
      }

      // A run in which every attempt failed for a reason that may pass (a
      // bot check, the network, an outdated yt-dlp) has not updated
      // anything: leave the playlist overdue so the next worker run retries
      // it. Videos YouTube removed, and ones that will not download for
      // good (private, members-only, age-restricted), do not hold the
      // update back.
      final failedEntirely =
          downloadedCount + reusedCount == 0 &&
          failedCount > 0 &&
          failureReasons.any((reason) => !isPermanentDownloadError(reason));
      if (failedEntirely) {
        _log.warn(
          'All $failedCount downloads failed; '
          'not stamping "${playlist.name}" as updated',
        );
      } else if (sourceChecked) {
        await _markPlaylistUpdated(playlist);
      }

      _position = _workTotal;
      _emitRun(playlist, DownloadPhase.finishing, trackProgress: 100);
      await _backfillMissingSponsorBlockSegments(playlist);
      await _backfillMissingLyrics(playlist);
      await _writeMetadataForPlaylist(playlist.id);
      await _cleanupFolder(playlist);

      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return DownloadStart.started;
      }

      // Only now is the playlist really finished; emitting earlier left the
      // UI claiming completion while the backfill still ran for minutes.
      if (failedEntirely) {
        _emit(
          DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: _workTotal,
            totalTracks: _workTotal,
            trackProgress: 0,
            status: 'error',
            error: _mostCommon(failureReasons),
            failedCount: failedCount,
            removedCount: removedCount,
          ),
        );
        if (_gate.owner == DownloadLock.backgroundOwner) {
          await _notifyFailures(playlist, failedCount, failureReasons);
        }
      } else {
        _emit(
          DownloadProgress(
            playlistId: playlist.id,
            currentTrackIndex: _workTotal,
            totalTracks: _workTotal,
            trackProgress: 100,
            status: 'complete',
            downloadedCount: downloadedCount + reusedCount,
            failedCount: failedCount,
            removedCount: removedCount,
          ),
        );
      }

      if (downloadedCount > 0) {
        await _notifications?.showDownloadComplete(
          playlist.name,
          downloadedCount: downloadedCount,
          notificationId: playlist.id,
          audioOnly: playlist.audioOnly,
          failedCount: failedCount,
        );
      }
    } catch (e) {
      if (_cancelRequested) {
        _log.info('Playlist download stopped');
        await _writeMetadataForPlaylist(playlist.id);
        _emit(DownloadProgress.idle);
        return DownloadStart.started;
      }
      _log.error('Playlist download failed: $e');
      await _writeMetadataForPlaylist(playlist.id);
      _emit(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: 0,
          totalTracks: _workTotal,
          trackProgress: 0,
          status: 'error',
          error: e.toString(),
        ),
      );
    } finally {
      await _finishRun(entered: entered);
    }
    return DownloadStart.started;
  }

  static String _mostCommon(List<String> reasons) {
    final counts = <String, int>{};
    for (final reason in reasons) {
      counts.update(reason, (n) => n + 1, ifAbsent: () => 1);
    }
    var best = reasons.first;
    for (final entry in counts.entries) {
      if (entry.value > counts[best]!) best = entry.key;
    }
    return best;
  }

  Future<void> _notifyFailures(
    Playlist playlist,
    int failedCount,
    List<String> reasons,
  ) async {
    try {
      await _notifications?.showDownloadsFailed(
        playlist.name,
        failedCount: failedCount,
        reason: friendlyDownloadError(_mostCommon(reasons)),
        notificationId: playlist.id,
      );
    } catch (e) {
      _log.warn('Could not show the failure notification: $e');
    }
  }

  /// Downloads one track now: a retry of a failed track, a track marked
  /// "Removed from YouTube", or a fresh copy of a downloaded one. A
  /// downloaded file is replaced only once the new copy is complete; if the
  /// download fails the old file stays as it was.
  ///
  /// Returns true when a new file was saved, false when the owner stopped
  /// it (nothing changed then). Throws with the reason when it failed.
  Future<bool> downloadTrack(Playlist playlist, Track track) async {
    // A run that is only tidying up ends within moments; wait for it rather
    // than refuse.
    while (_isDownloading && _finishing) {
      await runFinished;
    }
    // A caller must never report success for a download that never ran.
    if (_isDownloading) {
      throw StateError('A download is already in progress.');
    }
    _beginRun(playlist);
    var entered = false;

    try {
      final busy = await _gate.tryEnter('download', wait: LibraryGate.userWait);
      if (busy != null) {
        _log.warn('Track download skipped: $busy');
        throw StateError(busy);
      }
      entered = true;

      final currentPlaylist = await _db.getPlaylistOrNull(playlist.id);
      if (currentPlaylist == null) {
        throw StateError('The playlist no longer exists.');
      }
      playlist = currentPlaylist;
      _activePlaylist = playlist;
      final fresh = await _db.getTrack(track.id);
      if (fresh == null) throw StateError('The track no longer exists.');
      final totalTracks = await _db.getTotalTrackCount(playlist.id);
      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return false;
      }

      _workTotal = 1;
      _position = 1;
      await _startDownloadReporting(playlist);
      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return false;
      }

      final replace =
          fresh.status == 'complete' &&
          fresh.filePath != null &&
          await File(fresh.filePath!).exists();
      _log.info(
        '${replace ? 'Redownloading' : 'Downloading'} "${fresh.title}" '
        'from "${playlist.name}"',
      );

      final result = await _downloadTrackFile(
        playlist: playlist,
        track: fresh,
        totalTracks: totalTracks,
        trackLabel: '[${fresh.index}/$totalTracks] ${fresh.title}',
        reuseExistingFile: false,
        replaceExisting: replace,
        maxHeight: effectiveMaxHeight(playlist, fresh),
      );

      if (result != _TrackDownloadResult.downloaded) {
        if (_cancelRequested) {
          await _writeMetadataForPlaylist(playlist.id);
          _emit(DownloadProgress.idle);
          return false;
        }
        // The caller shows this failure, so carry the recorded reason.
        final failed = await _db.getTrack(track.id);
        throw StateError(
          _lastFailure ?? failed?.lastError ?? 'Download failed',
        );
      }

      // A single track is not a check of the playlist against YouTube, so
      // it does not move the next scheduled update.
      _emitRun(playlist, DownloadPhase.finishing, trackProgress: 100);
      await _writeMetadataForPlaylist(playlist.id);
      await _cleanupFolder(playlist);

      _emit(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: 1,
          totalTracks: 1,
          trackProgress: 100,
          status: 'complete',
          downloadedCount: 1,
        ),
      );

      await _notifications?.showDownloadComplete(
        playlist.name,
        notificationId: playlist.id,
        trackTitle: fresh.title,
        audioOnly: playlist.audioOnly,
      );
      return true;
    } catch (e) {
      if (_cancelRequested) {
        await _writeMetadataForPlaylist(playlist.id);
        _emit(DownloadProgress.idle);
        return false;
      }
      // A single-track download is always user-initiated and its caller
      // reports the failure, so do not also raise the global error event.
      _emit(DownloadProgress.idle);
      rethrow;
    } finally {
      await _finishRun(entered: entered);
    }
  }

  /// Downloads [url], a reupload of [track]'s video, and hands the finished
  /// file to [adopt] while the library gate is still held, so nothing can
  /// touch the playlist folder in between. The track's row and status are
  /// left alone until [adopt] changes them: a failed or stopped download
  /// changes nothing.
  ///
  /// Returns true when [adopt] ran, false when the owner stopped it.
  /// Throws with the reason when it failed.
  Future<bool> downloadReupload(
    Playlist playlist,
    Track track,
    String url, {
    required Future<void> Function(File media) adopt,
  }) async {
    while (_isDownloading && _finishing) {
      await runFinished;
    }
    if (_isDownloading) {
      throw StateError('A download is already in progress.');
    }
    _beginRun(playlist);
    var entered = false;
    Directory? staging;

    try {
      final busy = await _gate.tryEnter('download', wait: LibraryGate.userWait);
      if (busy != null) throw StateError(busy);
      entered = true;

      final currentPlaylist = await _db.getPlaylistOrNull(playlist.id);
      if (currentPlaylist == null) {
        throw StateError('The playlist no longer exists.');
      }
      playlist = currentPlaylist;
      _activePlaylist = playlist;
      final fresh = await _db.getTrack(track.id);
      if (fresh == null) throw StateError('The track no longer exists.');

      _workTotal = 1;
      _position = 1;
      _currentTitle = fresh.title;
      _currentTrackId = fresh.id;
      await _startDownloadReporting(playlist);
      if (_cancelRequested) {
        _emit(DownloadProgress.idle);
        return false;
      }
      _emitRun(playlist, DownloadPhase.downloading);
      // Marked as a replacement so a Stop leaves the track as it is.
      _activeTrackId = fresh.id;
      _activeTrackIsReplacement = true;

      final trackLabel = '[reupload] ${fresh.title}';
      _log.info('$trackLabel Downloading $url');
      staging = await _metadata.prepareStagingDir(
        playlist.outputPath,
        fresh.id,
      );
      String? failure;
      try {
        await _downloadWithRetry(
          url: url,
          outputPath: staging.path,
          audioOnly: playlist.audioOnly,
          embedThumbnail: playlist.includeThumbnails,
          metadataAlbum: playlist.name,
          outputTemplate:
              '${escapeOutputTemplateLiteral(staging.path)}/'
              'reupload_%(title).${titleByteLimit}B.%(ext)s',
          trackLabel: trackLabel,
          maxHeight: effectiveMaxHeight(playlist, fresh),
        );
      } catch (e) {
        failure = _cleanErrorMessage(e);
      }
      if (_cancelRequested) {
        _log.info('$trackLabel Stopped; nothing was changed');
        _emit(DownloadProgress.idle);
        return false;
      }
      final staged = MetadataService.findStagedMedia(staging);
      if (failure != null &&
          !(staged != null && _isPostProcessingError(failure))) {
        _log.error('$trackLabel Failed: $failure');
        throw StateError(failure);
      }
      if (staged == null) throw StateError('Downloaded file not found');

      _emitRun(playlist, DownloadPhase.finishing, trackProgress: 100);
      await adopt(staged);
      _log.info('$trackLabel Replaced with the reupload');
      await _metadata.discardStagingDir(staging);
      await _cleanupFolder(playlist);

      _emit(
        DownloadProgress(
          playlistId: playlist.id,
          currentTrackIndex: 1,
          totalTracks: 1,
          trackProgress: 100,
          status: 'complete',
          downloadedCount: 1,
        ),
      );
      await _notifications?.showDownloadComplete(
        playlist.name,
        notificationId: playlist.id,
        trackTitle: fresh.title,
        audioOnly: playlist.audioOnly,
      );
      return true;
    } catch (e) {
      _emit(DownloadProgress.idle);
      if (_cancelRequested) return false;
      rethrow;
    } finally {
      if (staging != null) await _metadata.discardStagingDir(staging);
      await _finishRun(entered: entered);
    }
  }

  /// Ends a run. The service counts as busy until the teardown (stopping
  /// the progress feed and the foreground service, releasing the gate) is
  /// done, so a request arriving meanwhile is queued instead of colliding
  /// with the gate, and [runFinished] resolves only for this run.
  Future<void> _finishRun({required bool entered}) async {
    final completer = _runCompleter;
    final finishedPlaylistId = _activePlaylist?.id;
    _finishing = true;
    _activeTrackId = null;
    _activeTrackIsReplacement = false;
    try {
      await _ytdlpProgressSub?.cancel();
      _ytdlpProgressSub = null;
      if (_reportingStarted) {
        _reportingStarted = false;
        try {
          await _ytdlp.stopDownloadService();
        } catch (e) {
          _log.warn('Failed to stop download foreground service: $e');
        }
      }
      if (entered) {
        try {
          await _gate.exit();
        } catch (e) {
          _log.warn('Failed to release download lock: $e');
        }
      }
    } finally {
      _isDownloading = false;
      _finishing = false;
      _activePlaylist = null;
      _resetRunState();
      if (identical(_runCompleter, completer)) _runCompleter = null;
      if (completer != null && !completer.isCompleted) completer.complete();
      if (finishedPlaylistId != null &&
          _rerunRequested.remove(finishedPlaylistId) &&
          !_cancelRequested &&
          !_queue.any((e) => e.playlistId == finishedPlaylistId)) {
        // Ahead of the queue: the user just asked for it.
        _queue.insert(0, (
          playlistId: finishedPlaylistId,
          sourceChecked: false,
        ));
        _setQueue();
      }
      _startNextQueued();
    }
  }

  void _startNextQueued() {
    if (_queue.isEmpty ||
        _isDownloading ||
        _queueHolds > 0 ||
        _progressController.isClosed) {
      return;
    }
    final next = _queue.removeAt(0);
    _setQueue();
    unawaited(() async {
      try {
        final playlist = await _db.getPlaylistOrNull(next.playlistId);
        if (playlist == null) {
          _startNextQueued();
          return;
        }
        await downloadPlaylist(playlist, sourceChecked: next.sourceChecked);
      } catch (e) {
        _log.warn('Queued download failed to start: $e');
      }
    }());
  }

  Future<void> _startDownloadReporting(Playlist playlist) async {
    _reportingStarted = true;
    try {
      await _ytdlp.startDownloadService(playlist.name);
    } catch (e) {
      _log.warn('Failed to start download foreground service: $e');
    }

    _sinceTrackEmit
      ..reset()
      ..start();
    _sinceNotification
      ..reset()
      ..start();
    await _ytdlpProgressSub?.cancel();
    _ytdlpProgressSub = _ytdlp.progressStream.listen((event) {
      final status = event['status'] as String? ?? 'downloading';
      if (status != 'downloading' && status != 'starting') return;
      final raw = (event['progress'] as num?)?.toDouble() ?? 0;
      _reportTrackProgress(playlist, raw);
    });
  }

  /// Forwards yt-dlp's per-line progress at a rate the UI and the
  /// notification can afford: whole percent steps, at most every
  /// [progressInterval] (the notification every [notificationInterval]).
  void _reportTrackProgress(Playlist playlist, double raw) {
    final percent = raw.isNaN ? 0 : raw.clamp(0, 100).floor();
    final previous = _lastEmitted;
    final sameTrack =
        previous != null &&
        previous.phase == DownloadPhase.downloading &&
        previous.activeTrackId == _currentTrackId &&
        previous.currentTrackIndex == _position;
    if (sameTrack) {
      final last = previous.trackProgress.round();
      if (percent == last) return;
      if (percent < 100 &&
          _sinceTrackEmit.elapsed < progressInterval &&
          percent - last < 10) {
        return;
      }
    }
    _sinceTrackEmit.reset();
    _emitRun(playlist, DownloadPhase.downloading, trackProgress: percent * 1.0);

    final positionChanged = _lastNotifiedPosition != _position;
    if (positionChanged ||
        (percent != _lastNotifiedPercent &&
            (percent == 100 ||
                _sinceNotification.elapsed >= notificationInterval))) {
      _lastNotifiedPercent = percent;
      _lastNotifiedPosition = _position;
      _sinceNotification.reset();
      unawaited(
        _ytdlp
            .updateDownloadServiceProgress(
              playlistName: playlist.name,
              currentTrack: _position,
              totalTracks: _workTotal,
              progress: percent,
            )
            .catchError((Object e) {
              _log.warn('Download notification update failed: $e');
            }),
      );
    }
  }

  Future<_TrackDownloadResult> _downloadTrackFile({
    required Playlist playlist,
    required Track track,
    required int totalTracks,
    required String trackLabel,
    required bool reuseExistingFile,
    required bool replaceExisting,
    required int? maxHeight,
  }) async {
    final indexStr = MetadataService.paddedIndex(track.index, totalTracks);
    _currentTitle = track.title;
    _currentTrackId = track.id;

    if (reuseExistingFile) {
      final existingFile = await _metadata.findAdoptableMediaFile(
        playlist,
        track,
      );
      if (existingFile != null) {
        // A local file that was briefly missing stays a local file: its
        // timeline is not the YouTube video's.
        await _db.updateTrackStatus(
          track.id,
          'complete',
          filePath: existingFile,
        );
        await _metadata.captureChapterMetadata(track, playlist.outputPath);
        if (!track.isLocalReplacement) {
          await _sponsorBlock?.refreshTrackSegments(
            track.copyWith(filePath: Value(existingFile), status: 'complete'),
          );
        }
        _log.info(
          '$trackLabel Found existing file: ${p.basename(existingFile)}',
        );
        _emitRun(playlist, DownloadPhase.downloading, trackProgress: 100);
        return _TrackDownloadResult.reused;
      }
    }

    if (track.videoId.startsWith(forcedInsertVideoIdPrefix)) {
      // A local-only entry has nothing on YouTube to download.
      const errorMsg = 'This entry is a local file and has no YouTube source';
      if (replaceExisting) {
        await _db.setTrackReplaceRequested(track.id, false);
      } else {
        await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
      }
      _lastFailure = errorMsg;
      return _TrackDownloadResult.failed;
    }

    _emitRun(playlist, DownloadPhase.downloading);

    _activeTrackId = track.id;
    _activeTrackIsReplacement = replaceExisting;
    if (!replaceExisting) {
      await _db.updateTrackStatus(track.id, 'downloading');
    }

    final Directory staging;
    try {
      staging = await _metadata.prepareStagingDir(
        playlist.outputPath,
        track.id,
      );
    } catch (e) {
      _activeTrackId = null;
      _activeTrackIsReplacement = false;
      return _recordFailure(
        track: track,
        playlist: playlist,
        replaceExisting: replaceExisting,
        trackLabel: trackLabel,
        errorMsg:
            'Could not prepare the download folder: ${_cleanErrorMessage(e)}',
      );
    }
    final outputTemplate =
        '${escapeOutputTemplateLiteral(staging.path)}/'
        '${indexStr}_%(title).${titleByteLimit}B.%(ext)s';
    final videoUrl = 'https://www.youtube.com/watch?v=${track.videoId}';

    try {
      String? failure;
      try {
        await _downloadWithRetry(
          url: videoUrl,
          outputPath: staging.path,
          audioOnly: playlist.audioOnly,
          embedThumbnail: playlist.includeThumbnails,
          metadataAlbum: playlist.name,
          outputTemplate: outputTemplate,
          trackLabel: trackLabel,
          maxHeight: maxHeight,
        );
      } catch (e) {
        failure = _cleanErrorMessage(e);
      }

      if (_cancelRequested) {
        if (!replaceExisting) {
          await _db.resetInterruptedTrack(track.id, onlyIfDownloading: true);
        }
        _log.info('$trackLabel Interrupted; nothing was changed');
        return _TrackDownloadResult.cancelled;
      }

      final staged = MetadataService.findStagedMedia(staging);
      if (failure != null) {
        // yt-dlp reports a failed post-processing step (thumbnail or
        // metadata embedding) as an error although the media is complete.
        // Keep such a file rather than throw away a good copy.
        if (staged != null && _isPostProcessingError(failure)) {
          _log.warn('$trackLabel Saved, but post-processing failed: $failure');
        } else {
          return await _recordFailure(
            track: track,
            playlist: playlist,
            replaceExisting: replaceExisting,
            trackLabel: trackLabel,
            errorMsg: failure,
          );
        }
      }

      if (staged == null) {
        // yt-dlp reported success but left no playable file (for example a
        // failed merge). Recording a made-up path would present a track that
        // cannot be played and would never be retried.
        return await _recordFailure(
          track: track,
          playlist: playlist,
          replaceExisting: replaceExisting,
          trackLabel: trackLabel,
          errorMsg: 'Downloaded file not found',
        );
      }

      final updatedTrack = await _metadata.publishDownload(
        playlist: playlist,
        trackId: track.id,
        stagingDir: staging,
        stagedMedia: staged,
        thumbnails: _thumbnails,
        embeddedThumbnailExpected: playlist.includeThumbnails,
        downloadedMaxHeight: playlist.audioOnly ? null : (maxHeight ?? 0),
      );
      if (updatedTrack == null) {
        _lastFailure = 'The track was removed during the download';
        return _TrackDownloadResult.failed;
      }
      // A track once found removed from YouTube that downloads again is
      // simply available again.
      if (updatedTrack.unavailableReason == removedFromYouTubeReason) {
        await _db.clearRemovedFromYouTube(track.id);
      }
      await _sponsorBlock?.refreshTrackSegments(updatedTrack);
      _log.info('$trackLabel Downloaded: ${track.title}');

      _emitRun(playlist, DownloadPhase.downloading, trackProgress: 100);
      return _TrackDownloadResult.downloaded;
    } catch (e) {
      // Unexpected failure while publishing; the previous file, if any, was
      // not touched before the new one was in place.
      final errorMsg = _cleanErrorMessage(e);
      _log.error('$trackLabel Could not save "${track.title}": $errorMsg');
      _lastFailure = errorMsg;
      if (!replaceExisting) {
        if (track.unavailableReason == removedFromYouTubeReason) {
          await _db.restoreRemovedFromYouTube(track.id);
        } else {
          await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
        }
      }
      return _TrackDownloadResult.failed;
    } finally {
      await _metadata.discardStagingDir(staging);
      if (_activeTrackId == track.id) {
        _activeTrackId = null;
        _activeTrackIsReplacement = false;
      }
    }
  }

  Future<_TrackDownloadResult> _recordFailure({
    required Track track,
    required Playlist playlist,
    required bool replaceExisting,
    required String trackLabel,
    required String errorMsg,
  }) async {
    _lastFailure = errorMsg;
    final removed = isRemovedFromYouTubeError(errorMsg);
    if (!replaceExisting) {
      if (removed) {
        // YouTube took the video down for good. Retrying it on every
        // update would fail forever and keep the playlist from counting as
        // updated; it stays listed as "Removed from YouTube" instead.
        await _db.markTrackRemovedFromYouTube(track.id, errorMsg);
        _log.warn('$trackLabel Removed from YouTube: "${track.title}"');
        return _TrackDownloadResult.removed;
      }
      if (track.unavailableReason == removedFromYouTubeReason) {
        // A manual retry of a removed video failed for another reason (a
        // bot check, the network): it keeps its mark and stays out of the
        // updates; the caller shows this error.
        await _db.restoreRemovedFromYouTube(track.id);
        _log.error(
          '$trackLabel Retry of removed "${track.title}" failed: $errorMsg',
        );
        return _TrackDownloadResult.failed;
      }
      await _db.updateTrackStatus(track.id, 'error', error: errorMsg);
      _log.error('$trackLabel Failed "${track.title}": $errorMsg');
      return _TrackDownloadResult.failed;
    }
    // The existing copy is still in place and keeps playing.
    _log.error(
      '$trackLabel Could not download a new copy of "${track.title}"; '
      'kept the existing file: $errorMsg',
    );
    // Give up the replacement only when YouTube will really never provide
    // the video: a clear removal message, a refusal that does not pass
    // (private, members-only, ...), or the last sync already flagged it.
    // A bot check or throttling ("Video unavailable") must not cost a
    // video playlist its video files for good.
    final permanent =
        isPermanentDownloadError(errorMsg) ||
        (track.unavailableReason != null && !isBotCheckDownloadError(errorMsg));
    if (track.replaceRequested && permanent) {
      // YouTube no longer serves it: keep what we have for good.
      await _metadata.adoptKeptFile(playlist, track.id);
      await _db.setTrackReplaceRequested(track.id, false);
      if (removed) {
        await _db.markTrackRemovedFromYouTube(track.id, errorMsg);
        return _TrackDownloadResult.removed;
      }
    }
    return _TrackDownloadResult.failed;
  }

  /// Only a failed embedding step leaves a complete, playable file. A failed
  /// audio conversion can leave a truncated one, so it is not accepted.
  static bool _isPostProcessingError(String message) {
    final lower = message.toLowerCase();
    return lower.contains('postprocessing') &&
        (lower.contains('thumbnail') ||
            lower.contains('embed') ||
            lower.contains('metadata'));
  }

  /// Stops this service's native yt-dlp process. A track that had no file
  /// returns to the queue; a track that was being replaced keeps its file.
  /// Playlists waiting in the queue are dropped too: Stop means stop.
  Future<void> cancelActiveDownloads() async {
    _rerunRequested.clear();
    if (_queue.isNotEmpty) {
      _queue.clear();
      _setQueue();
    }
    await _cancelRun();
  }

  /// Stops the running download, if any, and leaves the queue alone.
  Future<void> _cancelRun() async {
    if (!_isDownloading) return;
    _cancelRequested = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();

    try {
      await _ytdlp.cancelDownloads();
    } catch (e) {
      _log.warn('Failed to cancel native download: $e');
    }

    final trackId = _activeTrackId;
    if (trackId != null && !_activeTrackIsReplacement) {
      await _db.resetInterruptedTrack(trackId, onlyIfDownloading: true);
    }

    final playlist = _activePlaylist;
    if (playlist != null) {
      try {
        await _writeMetadataForPlaylist(playlist.id);
      } catch (e) {
        _log.warn('Interrupted download cleanup failed: $e');
      }
    }
  }

  /// Runs [action], which changes the files of [playlistId], while that
  /// playlist does not download.
  ///
  /// When another playlist is downloading, nothing is touched and a
  /// [LibraryBusyException] is thrown: its download holds the library until
  /// it ends, so [action] could not run anyway. Otherwise [playlistId]
  /// leaves the queue, and its running download is stopped and waited for
  /// up to [timeout] (a [LibraryBusyException] when it does not stop in
  /// time). Other queued playlists keep their places but start only after
  /// [action], so they cannot take the library first. A download of
  /// [playlistId] that was stopped starts again afterwards, ahead of them,
  /// when [resume] is true or [action] failed.
  Future<T> runWithDownloadStopped<T>(
    int playlistId,
    Future<T> Function() action, {
    bool resume = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_isDownloading && _activePlaylist?.id != playlistId) {
      throw const LibraryBusyException(
        'Wait until the current download finishes.',
      );
    }
    final wasQueued = removeFromQueue(playlistId);
    final wasRunning = _isDownloading;
    var succeeded = false;
    _queueHolds++;
    try {
      if (wasRunning) {
        await _cancelRun();
        try {
          await runFinished.timeout(timeout);
        } on TimeoutException {
          if (_isDownloading && _activePlaylist?.id == playlistId) {
            throw const LibraryBusyException(
              'Could not stop the download. Try again.',
            );
          }
        }
      }
      final result = await action();
      succeeded = true;
      return result;
    } finally {
      _queueHolds--;
      if ((wasRunning || wasQueued) &&
          (resume || !succeeded) &&
          !_queue.any((e) => e.playlistId == playlistId)) {
        _queue.insert(0, (playlistId: playlistId, sourceChecked: false));
        _setQueue();
      }
      _startNextQueued();
    }
  }

  /// Takes [playlistId] out of the queue. Returns whether it was queued.
  bool removeFromQueue(int playlistId) {
    _rerunRequested.remove(playlistId);
    final before = _queue.length;
    _queue.removeWhere((e) => e.playlistId == playlistId);
    if (_queue.length == before) return false;
    _setQueue();
    return true;
  }

  /// Stamps only `lastUpdated`. A full row replace from the [Playlist]
  /// snapshot handed to this run would silently undo settings the user
  /// changed while the download was in progress.
  Future<void> _markPlaylistUpdated(Playlist playlist) =>
      _db.markPlaylistUpdated(playlist.id, DateTime.now());

  Future<void> _cleanupFolder(Playlist playlist) async {
    try {
      final cleaned = await _metadata.cleanupPlaylist(playlist);
      if (cleaned > 0) _log.info('Cleaned up $cleaned leftover files');
    } catch (e) {
      _log.warn('Cleanup failed: $e');
    }
  }

  static const _transientErrorPatterns = [
    'no address associated with hostname',
    'unable to download webpage',
    'http error 5',
    'http error 429',
    'too many requests',
    'connection reset',
    'connection refused',
    'connection closed',
    'timed out',
    'timeout',
    'rate limited',
    'temporary failure in name resolution',
    'network is unreachable',
  ];

  static bool _isTransientError(String message) {
    final lower = message.toLowerCase();
    return _transientErrorPatterns.any(lower.contains);
  }

  static bool _isExtrasError(String message) {
    final lower = message.toLowerCase();
    return (lower.contains('postprocessing:') ||
            lower.contains('preprocessing:')) &&
        !lower.contains('audio conversion');
  }

  static bool _isSubtitleError(String message) =>
      message.toLowerCase().contains('subtitles');

  Future<void> _downloadWithRetry({
    required String url,
    required String outputPath,
    required bool audioOnly,
    required bool embedThumbnail,
    required String metadataAlbum,
    required String outputTemplate,
    required String trackLabel,
    int? maxHeight,
  }) async {
    var downloadSubtitles =
        !audioOnly && await _settings.getDownloadSubtitles();
    final subtitleLanguages =
        downloadSubtitles ? await _settings.getSubtitleLanguages() : 'en';
    const backoffs = [Duration(seconds: 5), Duration(seconds: 15)];
    var attempt = 0;
    var withExtras = true;
    while (true) {
      if (_cancelRequested) return;
      try {
        // No track-number tag: it would go stale when videos are inserted
        // above; the file name and the .m3u8 carry the order.
        await _ytdlp.download(
          url: url,
          outputPath: outputPath,
          audioOnly: audioOnly,
          embedThumbnail: embedThumbnail && withExtras,
          writeThumbnail: withExtras,
          embedMetadata: withExtras,
          metadataAlbum: metadataAlbum,
          downloadSubtitles: downloadSubtitles,
          subtitleLanguages: subtitleLanguages,
          outputTemplate: outputTemplate,
          maxHeight: maxHeight,
        );
        return;
      } catch (e) {
        final cleaned = _cleanErrorMessage(e);
        if (downloadSubtitles && _isSubtitleError(cleaned)) {
          // Subtitles are an extra. Never let them cost the media itself.
          _log.warn(
            '$trackLabel: subtitles failed, retrying without: $cleaned',
          );
          downloadSubtitles = false;
          continue;
        }
        if (withExtras && _isExtrasError(cleaned)) {
          // Cover art, tags and the kept thumbnail are extras too. yt-dlp
          // reports their failure with the same bare "Conversion failed!"
          // as a failed merge, so try once more without them: the media
          // already in staging is reused, and a real merge failure fails
          // again.
          _log.warn(
            '$trackLabel: post-processing failed, retrying without '
            'cover/tags: $cleaned',
          );
          withExtras = false;
          continue;
        }
        if (attempt >= backoffs.length || !_isTransientError(cleaned)) {
          rethrow;
        }
        final delay = backoffs[attempt];
        attempt++;
        _log.warn(
          '$trackLabel: transient error (attempt $attempt), retrying in ${delay.inSeconds}s: $cleaned',
        );
        // A cancel ends the wait at once instead of after up to 15 s.
        await Future.any([Future<void>.delayed(delay), _cancelSignal.future]);
        if (_cancelRequested) return;
      }
    }
  }

  static const _sponsorBlockMissingRetryInterval = Duration(days: 7);
  static const _sponsorBlockBackfillConcurrency = 4;
  static const _sponsorBlockWriteChunk = 50;

  /// Fetches segments for completed YouTube downloads that have none stored.
  /// Local replacements are skipped: their timeline is not the YouTube
  /// video's, and remote segments would cut the wrong parts of the audio.
  ///
  /// Results are written in chunks (one transaction each), so a playlist of
  /// hundreds of songs does not cause hundreds of separate database updates.
  Future<void> _backfillMissingSponsorBlockSegments(Playlist playlist) async {
    final sponsorBlock = _sponsorBlock;
    if (sponsorBlock == null || !playlist.sponsorBlockEnabled) return;

    final now = DateTime.now();
    final candidates =
        (await _db.getTracksForPlaylist(playlist.id))
            .where(
              (track) =>
                  track.status == 'complete' &&
                  track.filePath != null &&
                  track.unavailableReason == null &&
                  !track.isLocalReplacement &&
                  shouldRecheckSponsorBlock(track, now),
            )
            .toList();
    if (candidates.isEmpty) return;

    var refreshed = 0;
    var next = 0;
    final pending = <int, List<SponsorBlockSegmentsCompanion>>{};
    Future<void> flush() async {
      if (pending.isEmpty) return;
      final batch = Map.of(pending);
      pending.clear();
      await _db.storeSponsorBlockResults(batch, now);
      refreshed += batch.length;
    }

    Future<void> worker() async {
      while (next < candidates.length && !_cancelRequested) {
        final track = candidates[next++];
        try {
          final existingSegments = await _db.getSegmentsForTrack(track.id);
          final hasRemoteState = existingSegments.any(
            (segment) =>
                segment.source == 'sponsorblock' ||
                segment.source == 'override' ||
                segment.source == 'hidden',
          );
          if (hasRemoteState) continue;

          pending[track.id] = await sponsorBlock.fetchSegments(
            track.videoId,
            track.id,
          );
          if (pending.length >= _sponsorBlockWriteChunk) await flush();
        } catch (e) {
          _log.warn('SponsorBlock backfill failed for ${track.videoId}: $e');
        }
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < _sponsorBlockBackfillConcurrency; i++) worker(),
      ]);
    } finally {
      try {
        await flush();
      } catch (e) {
        _log.warn('SponsorBlock backfill could not be saved: $e');
      }
    }

    if (refreshed > 0) {
      _log.info('SponsorBlock: backfilled $refreshed tracks');
    }
  }

  /// Longest a playlist run spends fetching lyrics, so a scheduled update
  /// stays inside its time limit; the rest waits for the next run.
  static const lyricsBackfillBudget = Duration(seconds: 90);

  /// Fetches lyrics or transcripts that are due, when the playlist has them
  /// on. Stops on cancel and after [lyricsBackfillBudget].
  Future<void> _backfillMissingLyrics(Playlist playlist) async {
    final lyrics = _lyrics;
    if (lyrics == null || !lyricsModeIsOn(playlist.lyricsMode)) return;
    if (_cancelRequested) return;
    try {
      await lyrics.backfillPlaylist(
        playlist.id,
        cancellation: _DownloadLyricsCancellation(() => _cancelRequested),
        budget: lyricsBackfillBudget,
      );
    } catch (e) {
      _log.warn('Lyrics backfill failed for "${playlist.name}": $e');
    }
  }

  /// Whether a downloaded track without segments is due for another
  /// SponsorBlock check. The interval is spread over two extra days by
  /// track, so a playlist checked in one go does not come due all at once
  /// again a week later.
  static bool shouldRecheckSponsorBlock(Track track, DateTime now) {
    final checkedAt = track.sponsorBlockCheckedAt;
    if (checkedAt == null) return true;
    final spread = Duration(hours: track.id % 48);
    return now.difference(checkedAt) >=
        _sponsorBlockMissingRetryInterval + spread;
  }

  Future<void> _writeMetadataForPlaylist(int playlistId) async {
    try {
      await _metadata.writeMetadataFor(playlistId);
    } catch (e) {
      _log.warn('Failed to write metadata: $e');
    }
  }

  void dispose() {
    _ytdlpProgressSub?.cancel();
    _progressController.close();
    _queueController.close();
  }

  static final _ansiPattern = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final _ytPrefixPattern = RegExp(
    r'^\s*(?:ERROR:\s*)?(?:\[[^\]]+\]\s*[^:]*:\s*)?',
  );

  static String _cleanErrorMessage(Object e) {
    String raw;
    if (e is PlatformException) {
      raw = e.message ?? e.details?.toString() ?? e.toString();
    } else {
      raw = e.toString();
    }
    var cleaned = raw.replaceAll(_ansiPattern, '').trim();
    // yt-dlp prints warnings before the error; keep the error lines.
    final errorLines = [
      for (final line in cleaned.split('\n'))
        if (line.trimLeft().startsWith('ERROR:')) line.trim(),
    ];
    if (errorLines.isNotEmpty) cleaned = errorLines.join('\n');
    // Strip a leading "ERROR: [youtube] xxxx: " prefix once.
    cleaned = cleaned.replaceFirst(_ytPrefixPattern, '').trim();
    if (cleaned.isEmpty) cleaned = raw.trim();
    if (cleaned.length > 500) {
      cleaned = '${cleaned.substring(0, 500)}...';
    }
    return cleaned;
  }
}

/// Stops a lyrics backfill when the download run is cancelled.
class _DownloadLyricsCancellation extends LyricsCancellation {
  _DownloadLyricsCancellation(this._cancelRequested);

  final bool Function() _cancelRequested;

  @override
  bool get isCancelled => super.isCancelled || _cancelRequested();
}
