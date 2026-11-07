import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/database.dart';
import '../providers/providers.dart';
import 'download_service.dart';
import 'library_gate.dart';
import 'log_service.dart';
import 'playlist_service.dart';
import 'ytdlp_service.dart';

/// Scheduled playlist updates (the hourly WorkManager job).
///
/// The job runs in one of two places:
///
/// * In the app's own Flutter engine, when the app process is alive (the app
///   is open, or music plays in the background). AutoUpdateWorker asks this
///   engine over [autoUpdateChannelName] to run the update, so the app keeps
///   one database connection, its live lists see every change, and no second
///   engine competes with the app's frames on the Android main thread.
/// * In a headless engine started by the worker (`backgroundMain`), only when
///   no app engine exists.
///
/// Both use [AutoUpdateRunner], which keeps every run inside WorkManager's
/// ten-minute budget: after [AutoUpdateRunner.softBudget] no new track or
/// playlist starts, and at [AutoUpdateRunner.hardBudget] the track still
/// downloading is stopped and returns to the queue. Tracks that were not
/// reached stay pending for the next run.

/// Kotlin (AutoUpdateWorker) → app engine: run, stop, refresh.
const autoUpdateChannelName = 'com.woolytube/auto_update';

/// Native yt-dlp plugin → every engine: the user tapped Cancel on the
/// download notification, or swiped the app away.
const ytdlpControlChannelName = 'com.woolytube/ytdlp_control';

/// The worker runs about once an hour, and a run stamps `lastUpdated` when
/// it finishes, so the next run usually comes a few minutes short of a full
/// interval. Without this slack a 1-hour playlist was updated only every
/// second hour, and a 24-hour one after 25 hours.
const autoUpdateDueTolerance = Duration(minutes: 10);

/// Whether [playlist] should be updated by a scheduled run at [now].
bool isDueForAutoUpdate(
  Playlist playlist,
  DateTime now, {
  Duration tolerance = autoUpdateDueTolerance,
}) {
  if (!playlist.autoUpdate) return false;
  final lastUpdated = playlist.lastUpdated;
  if (lastUpdated == null) return true;
  final interval = Duration(hours: playlist.updateFrequencyHours);
  return now.difference(lastUpdated) >= interval - tolerance;
}

/// The due playlists of [all], least recently attempted first.
///
/// A run that runs out of time never stamps `lastUpdated`, so ordering by
/// that would start every run with the same large playlist and never reach
/// the others. The attempt time rotates them instead.
List<Playlist> duePlaylistsInOrder(
  Iterable<Playlist> all,
  Map<int, DateTime> lastAttempts,
  DateTime now,
) {
  final due = [
    for (final playlist in all)
      if (isDueForAutoUpdate(playlist, now)) playlist,
  ];
  due.sort((a, b) {
    final attemptA = lastAttempts[a.id];
    final attemptB = lastAttempts[b.id];
    if (attemptA == null && attemptB != null) return -1;
    if (attemptA != null && attemptB == null) return 1;
    if (attemptA != null && attemptB != null) {
      final byAttempt = attemptA.compareTo(attemptB);
      if (byAttempt != 0) return byAttempt;
    }
    return a.id.compareTo(b.id);
  });
  return due;
}

/// When each playlist was last picked up by a scheduled run. Kept in a small
/// file because the app engine and the headless engine both read it, and
/// SharedPreferences caches values per engine.
class AutoUpdateAttemptLog {
  AutoUpdateAttemptLog({Future<String> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const fileName = 'auto_update_attempts.json';

  final Future<String> Function() _directoryProvider;

  static Future<String> _defaultDirectory() async =>
      (await getApplicationDocumentsDirectory()).path;

  Future<File> _file() async =>
      File(p.join(await _directoryProvider(), fileName));

  Future<Map<int, DateTime>> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      final result = <int, DateTime>{};
      decoded.forEach((key, value) {
        final id = int.tryParse('$key');
        final at = value is String ? DateTime.tryParse(value) : null;
        if (id != null && at != null) result[id] = at;
      });
      return result;
    } catch (_) {
      // A damaged file only loses the rotation order.
      return {};
    }
  }

  /// Records that [playlistId] was picked up at [at]. Entries of playlists
  /// that are not in [knownIds] are dropped, so deleted playlists do not
  /// pile up.
  Future<void> record(
    int playlistId,
    DateTime at, {
    Iterable<int>? knownIds,
  }) async {
    try {
      final attempts = await read();
      attempts[playlistId] = at;
      if (knownIds != null) {
        final keep = {...knownIds, playlistId};
        attempts.removeWhere((id, _) => !keep.contains(id));
      }
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          for (final entry in attempts.entries)
            '${entry.key}': entry.value.toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {
      // Not worth failing an update over.
    }
  }
}

enum AutoUpdateStatus {
  /// No playlist was due.
  nothingDue,

  /// Something else is changing the library (a download the user started,
  /// or the other engine); the run did nothing or stopped early.
  busy,

  /// Every due playlist was handled.
  finished,

  /// Stopped on request (notification Cancel, app swiped away, or the
  /// worker being stopped by Android).
  stopped,

  /// Ran out of its time budget; the rest is left for the next run.
  outOfTime,

  /// Could not run at all.
  failed,
}

class AutoUpdateReport {
  const AutoUpdateReport(
    this.status, {
    this.due = 0,
    this.handled = 0,
    this.error,
  });

  final AutoUpdateStatus status;

  /// Playlists that were due when the run started.
  final int due;

  /// Playlists the run got to.
  final int handled;

  final String? error;

  Map<String, Object?> toMap() => {
    'status': status.name,
    'due': due,
    'handled': handled,
    if (error != null) 'error': error,
  };

  @override
  String toString() =>
      'AutoUpdateReport(${status.name}, $handled of $due'
      '${error == null ? '' : ', $error'})';
}

/// Runs one scheduled update over a list of due playlists within a time
/// budget. It only orchestrates; syncing and downloading are passed in so
/// the same logic serves the app engine and the headless worker engine.
class AutoUpdateRunner {
  AutoUpdateRunner({
    required this.syncPlaylist,
    required this.reloadPlaylist,
    required this.downloadPlaylist,
    required this.cancelDownload,
    required this.activeTrackId,
    required this.blockedReason,
    required this.attempts,
    required this.log,
    this.softBudget = defaultSoftBudget,
    this.hardBudget = defaultHardBudget,
    this.pollInterval = const Duration(seconds: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// After this no new track or playlist starts.
  static const defaultSoftBudget = Duration(minutes: 7);

  /// At this point the track still downloading is stopped. WorkManager stops
  /// a worker after ten minutes; the native side needs the rest for engine
  /// start-up and a clean shutdown.
  static const defaultHardBudget = Duration(minutes: 8, seconds: 30);

  final Future<void> Function(Playlist playlist) syncPlaylist;
  final Future<Playlist> Function(int playlistId) reloadPlaylist;
  final Future<void> Function(Playlist playlist, {required bool sourceChecked})
  downloadPlaylist;

  /// Stops the running download; its track returns to the queue.
  final Future<void> Function() cancelDownload;

  /// The track being downloaded right now, if any.
  final int? Function() activeTrackId;

  /// Why the run must not continue (the other engine holds the library),
  /// or null.
  final Future<String?> Function() blockedReason;

  final AutoUpdateAttemptLog attempts;
  final LogService log;
  final Duration softBudget;
  final Duration hardBudget;
  final Duration pollInterval;
  final DateTime Function() _clock;

  bool _running = false;
  bool _stopRequested = false;
  bool _outOfTime = false;
  bool _softStopped = false;
  Timer? _softTimer;
  Timer? _hardTimer;
  Timer? _trackWatch;

  bool get isRunning => _running;
  bool get stopRequested => _stopRequested;

  /// Stops the run: the current download is cancelled (its track goes back
  /// to the queue) and nothing new starts.
  ///
  /// The flag is set before the first await, so a caller that does not wait
  /// for the clean-up still stops the loop.
  Future<void> requestStop() async {
    if (_stopRequested) return;
    _stopRequested = true;
    log.info('Scheduled update: stop requested');
    await _cancelQuietly();
  }

  /// Someone else stopped the download this run started (the app's Stop
  /// button, or the app closing). That means "stop", not "skip this
  /// playlist": nothing new starts.
  void stopAfterOutsideCancel() {
    // The runner's own cancels (stop, time budget) are already accounted for.
    if (_stopRequested || _outOfTime) return;
    _stopRequested = true;
    log.info('Scheduled update: the download was stopped in the app');
  }

  Future<AutoUpdateReport> run(List<Playlist> due) async {
    if (due.isEmpty) return const AutoUpdateReport(AutoUpdateStatus.nothingDue);
    if (_running) {
      return AutoUpdateReport(AutoUpdateStatus.busy, due: due.length);
    }
    if (_stopRequested) {
      return AutoUpdateReport(AutoUpdateStatus.stopped, due: due.length);
    }
    _running = true;
    final knownIds = [for (final playlist in due) playlist.id];
    var handled = 0;
    var status = AutoUpdateStatus.finished;
    log.info('Scheduled update: ${due.length} playlist(s) due');

    _softTimer = Timer(softBudget, _beginSoftStop);
    _hardTimer = Timer(hardBudget, () {
      _outOfTime = true;
      _stopRequested = true;
      log.info('Scheduled update: out of time, stopping the current track');
      unawaited(_cancelQuietly());
    });

    try {
      for (final playlist in due) {
        if (_halted) break;
        final blocked = await blockedReason();
        if (blocked != null) {
          log.info('Scheduled update paused: $blocked');
          status = AutoUpdateStatus.busy;
          break;
        }
        handled++;
        await attempts.record(playlist.id, _clock(), knownIds: knownIds);

        var synced = true;
        try {
          await syncPlaylist(playlist);
        } on LibraryBusyException catch (e) {
          // The app (or the other engine) started changing the library.
          // Every further playlist would be refused the same way, after a
          // network fetch each, so stop here.
          log.info('Scheduled update paused: $e');
          status = AutoUpdateStatus.busy;
          break;
        } catch (e) {
          synced = false;
          // The playlist may have become private or been deleted on
          // YouTube. Tracks already known can often still be downloaded
          // one by one, so carry on with them.
          log.warn('Sync of "${playlist.name}" failed: $e');
        }
        if (_halted) break;

        try {
          final fresh = await reloadPlaylist(playlist.id);
          await downloadPlaylist(fresh, sourceChecked: synced);
        } catch (e) {
          log.warn('Scheduled download of "${playlist.name}" failed: $e');
        }
      }
    } finally {
      _softTimer?.cancel();
      _hardTimer?.cancel();
      _trackWatch?.cancel();
      _running = false;
    }

    if (_outOfTime) {
      status = AutoUpdateStatus.outOfTime;
    } else if (status == AutoUpdateStatus.busy) {
      // Keep: the library was taken by someone else.
    } else if (_stopRequested) {
      status = AutoUpdateStatus.stopped;
    } else if (_softStopped && handled < due.length) {
      status = AutoUpdateStatus.outOfTime;
    }
    final report = AutoUpdateReport(status, due: due.length, handled: handled);
    log.info('Scheduled update ended: $report');
    return report;
  }

  bool get _halted => _stopRequested || _softStopped;

  /// From now on nothing new starts. The track being downloaded may finish,
  /// but a track that starts after this point (the playlist loop moved on)
  /// is stopped at once.
  void _beginSoftStop() {
    _softStopped = true;
    final trackAtDeadline = activeTrackId();
    log.info('Scheduled update: time is nearly up, finishing current track');
    _trackWatch = Timer.periodic(pollInterval, (timer) {
      final current = activeTrackId();
      if (current != null && current != trackAtDeadline) {
        timer.cancel();
        _outOfTime = true;
        unawaited(_cancelQuietly());
      }
    });
  }

  Future<void> _cancelQuietly() async {
    try {
      await cancelDownload();
    } catch (e) {
      log.warn('Scheduled update: could not stop the download: $e');
    }
  }
}

/// Lets AutoUpdateWorker run the scheduled update inside the app's engine,
/// and lets the download notification's Cancel button reach this engine.
///
/// Attach it once from the app's root widget (see [attach]).
class ForegroundAutoUpdateBridge {
  ForegroundAutoUpdateBridge({
    required AppDatabase db,
    required YtDlpService ytdlp,
    required PlaylistService playlists,
    required DownloadService downloads,
    required LogService log,
    DownloadLock? lock,
    AutoUpdateAttemptLog? attempts,
    MethodChannel? channel,
    MethodChannel? controlChannel,
    DateTime Function()? clock,
  }) : _db = db,
       _ytdlp = ytdlp,
       _playlists = playlists,
       _downloads = downloads,
       _log = log,
       _lock = lock ?? DownloadLock(),
       _attempts = attempts ?? AutoUpdateAttemptLog(),
       _channel = channel ?? const MethodChannel(autoUpdateChannelName),
       _controlChannel =
           controlChannel ?? const MethodChannel(ytdlpControlChannelName),
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final YtDlpService _ytdlp;
  final PlaylistService _playlists;
  final DownloadService _downloads;
  final LogService _log;
  final DownloadLock _lock;
  final AutoUpdateAttemptLog _attempts;
  final MethodChannel _channel;
  final MethodChannel _controlChannel;
  final DateTime Function() _clock;

  AutoUpdateRunner? _runner;
  bool _attached = false;

  /// The run in progress, if any.
  AutoUpdateRunner? get activeRun => _runner;

  void attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler(handleWorkerCall);
    _controlChannel.setMethodCallHandler(handleControlCall);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    _channel.setMethodCallHandler(null);
    _controlChannel.setMethodCallHandler(null);
  }

  /// Calls from AutoUpdateWorker.
  Future<Object?> handleWorkerCall(MethodCall call) async {
    switch (call.method) {
      case 'ping':
        return true;
      case 'runAutoUpdate':
        final args = call.arguments;
        final budgetMs = args is Map ? args['budgetMs'] : null;
        final report = await runScheduledUpdate(
          budget:
              budgetMs is int && budgetMs > 0
                  ? Duration(milliseconds: budgetMs)
                  : null,
        );
        return report.toMap();
      case 'stopAutoUpdate':
        await _runner?.requestStop();
        return null;
      case 'libraryChangedExternally':
        // The headless worker engine wrote through its own connection;
        // drift only refreshes streams for writes on this one.
        _db.markTablesUpdated([
          _db.playlists,
          _db.tracks,
          _db.sponsorBlockSegments,
        ]);
        return null;
      default:
        throw MissingPluginException('No handler for ${call.method}');
    }
  }

  /// Calls from the native download notification.
  ///
  /// The reply only says that this engine took the request; native shows
  /// "Stopping download…" until the run ends. Waiting for the clean-up (it
  /// rewrites the playlist's metadata) could outlast native's fallback, which
  /// then tore the notification down while Dart was still working.
  Future<Object?> handleControlCall(MethodCall call) async {
    switch (call.method) {
      case 'ping':
        // Native shows the notification's Cancel button only for engines
        // that answer this.
        return true;
      case 'cancelRequestedByUser':
        final runner = _runner;
        if (runner != null) {
          unawaited(runner.requestStop());
        } else {
          unawaited(_downloads.cancelActiveDownloads());
        }
        return true;
      default:
        throw MissingPluginException('No handler for ${call.method}');
    }
  }

  /// Runs the due playlists in this engine. [budget] is how long the worker
  /// will wait; the run ends comfortably before that.
  Future<AutoUpdateReport> runScheduledUpdate({Duration? budget}) async {
    if (_runner != null) return const AutoUpdateReport(AutoUpdateStatus.busy);
    // A download or another library change the user started is running.
    // The worker comes back in an hour.
    if (_downloads.isDownloading || _downloads.gate.isBusy) {
      _log.info('Scheduled update skipped: the app is busy');
      return const AutoUpdateReport(AutoUpdateStatus.busy);
    }
    final hard = _hardBudgetFor(budget);
    late final AutoUpdateRunner runner;
    runner = AutoUpdateRunner(
      syncPlaylist: _playlists.syncPlaylist,
      reloadPlaylist: _db.getPlaylist,
      downloadPlaylist:
          (playlist, {required sourceChecked}) =>
              _downloadPlaylist(runner, playlist, sourceChecked: sourceChecked),
      cancelDownload: _downloads.cancelActiveDownloads,
      activeTrackId: () => _downloads.activeTrackId,
      blockedReason: () async {
        if (await _lock.isHeldByOther(DownloadLock.foregroundOwner)) {
          return 'a scheduled update is running in the background';
        }
        return null;
      },
      attempts: _attempts,
      log: _log,
      hardBudget: hard,
      softBudget: _softBudgetFor(hard),
      clock: _clock,
    );
    _runner = runner;
    try {
      final due = duePlaylistsInOrder(
        await _db.getAllPlaylists(),
        await _attempts.read(),
        _clock(),
      );
      if (due.isEmpty) {
        return const AutoUpdateReport(AutoUpdateStatus.nothingDue);
      }
      await _ytdlp.initialize();
      return await runner.run(due);
    } catch (e) {
      _log.warn('Scheduled update failed: $e');
      return AutoUpdateReport(AutoUpdateStatus.failed, error: '$e');
    } finally {
      _runner = null;
    }
  }

  /// Downloads [playlist] with the app's own service. The app's Stop button
  /// (and the app closing) cancel that service directly, which only ends
  /// this one playlist; the run must end too, or the next due playlist
  /// starts right after the user pressed Stop.
  Future<void> _downloadPlaylist(
    AutoUpdateRunner runner,
    Playlist playlist, {
    required bool sourceChecked,
  }) async {
    // DownloadService emits `idle` from downloadPlaylist only when the run
    // was cancelled. Events are delivered in microtasks queued before the
    // service's own clean-up awaits, so they arrive before it returns.
    var cancelled = false;
    final subscription = _downloads.progressStream.listen((progress) {
      if (progress.status == DownloadProgress.idle.status) cancelled = true;
    });
    try {
      await _downloads.downloadPlaylist(playlist, sourceChecked: sourceChecked);
    } finally {
      await subscription.cancel();
    }
    if (cancelled) runner.stopAfterOutsideCancel();
  }

  static Duration _hardBudgetFor(Duration? budget) {
    if (budget == null) return AutoUpdateRunner.defaultHardBudget;
    // Leave the worker time to collect the reply after a stop.
    final hard = budget - const Duration(seconds: 40);
    if (hard < const Duration(seconds: 30)) return const Duration(seconds: 30);
    return hard < AutoUpdateRunner.defaultHardBudget
        ? hard
        : AutoUpdateRunner.defaultHardBudget;
  }

  static Duration _softBudgetFor(Duration hard) {
    final soft = hard - const Duration(seconds: 90);
    return soft.isNegative ? Duration.zero : soft;
  }
}

/// The app engine's bridge. The root widget attaches it once:
/// `ref.read(foregroundAutoUpdateBridgeProvider).attach();`
final foregroundAutoUpdateBridgeProvider = Provider<ForegroundAutoUpdateBridge>(
  (ref) {
    final bridge = ForegroundAutoUpdateBridge(
      db: ref.watch(databaseProvider),
      ytdlp: ref.watch(ytdlpServiceProvider),
      playlists: ref.watch(playlistServiceProvider),
      downloads: ref.watch(downloadServiceProvider),
      log: ref.watch(logServiceProvider),
    );
    ref.onDispose(bridge.detach);
    return bridge;
  },
);
