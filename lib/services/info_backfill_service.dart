/// Saving YouTube's description of older downloads (`.info.json`), slowly
/// and in the background.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show PlatformException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/database.dart';
import 'download_errors.dart';
import 'info_files.dart';
import 'library_layout.dart';
import 'log_service.dart';
import 'media_thumbnail_service.dart' show forcedInsertVideoIdPrefix;
import 'metadata_service.dart' show encodeVideoInfo;

/// What a failed fetch of a video's description means for the backfill.
enum InfoFetchProblem {
  /// YouTube asked to slow down (its bot check, or a rate limit): every
  /// fetch pauses for a while.
  slowDown,

  /// YouTube could not be reached. Nothing was learned about the video.
  offline,

  /// The video is gone for good (removed, private, members-only, ...).
  gone,

  /// Anything else. The video is tried again a few times, days apart.
  failed,
}

/// Sorts what yt-dlp said when it could not describe a video.
InfoFetchProblem classifyInfoFetchError(String raw) {
  final lower = raw.toLowerCase();
  if (isBotCheckDownloadError(raw) ||
      lower.contains('http error 429') ||
      lower.contains('too many requests') ||
      lower.contains('rate-limit') ||
      lower.contains('rate limit')) {
    return InfoFetchProblem.slowDown;
  }
  if (isNetworkDownloadError(raw)) return InfoFetchProblem.offline;
  if (isRemovedFromYouTubeError(raw) ||
      lower.contains('private video') ||
      lower.contains('members-only') ||
      lower.contains('members only') ||
      isAgeGateDownloadError(raw)) {
    return InfoFetchProblem.gone;
  }
  return InfoFetchProblem.failed;
}

/// How fast the backfill goes and how it backs off.
class InfoBackfillPacing {
  const InfoBackfillPacing({
    this.minGap = const Duration(seconds: 20),
    this.maxGap = const Duration(seconds: 60),
    this.firstPause = const Duration(minutes: 30),
    this.maxPause = const Duration(hours: 12),
    this.retryAfter = const Duration(days: 1),
    this.maxTries = 3,
    this.failuresBeforePause = 5,
  });

  /// Between two fetches: a random time from [minGap] to [maxGap].
  final Duration minGap;
  final Duration maxGap;

  /// After YouTube asked to slow down: [firstPause], doubling each time it
  /// asks again before a fetch worked, up to [maxPause].
  final Duration firstPause;
  final Duration maxPause;

  /// A video whose fetch failed is tried again after [retryAfter], at most
  /// [maxTries] times in all.
  final Duration retryAfter;
  final int maxTries;

  /// This many failed fetches in a row pause the backfill like a slow-down
  /// request: something is wrong for every video (an outdated yt-dlp).
  final int failuresBeforePause;

  /// The wait before the next fetch.
  Duration gap(math.Random random) {
    final spread = maxGap - minGap;
    if (spread <= Duration.zero) return minGap;
    return minGap +
        Duration(
          milliseconds: (spread.inMilliseconds * random.nextDouble()).round(),
        );
  }

  /// The pause after the [slowDowns]th slow-down request in a row, with up
  /// to a fifth more at random so retries do not line up.
  Duration pause(int slowDowns, math.Random random) {
    final doublings = math.min(math.max(slowDowns - 1, 0), 16);
    var pause = firstPause * (1 << doublings);
    if (pause > maxPause) pause = maxPause;
    return pause +
        Duration(
          milliseconds:
              (pause.inMilliseconds * 0.2 * random.nextDouble()).round(),
        );
  }
}

/// What the backfill remembers about one video it could not describe.
class InfoBackfillMiss {
  const InfoBackfillMiss({
    required this.at,
    this.tries = 0,
    this.gone = false,
    this.reason,
  });

  /// When it was last tried.
  final DateTime at;

  /// Failed fetches. A fetch cut short by a slow-down request does not
  /// count, but still moves the video back a day.
  final int tries;

  /// YouTube no longer has it.
  final bool gone;

  /// What yt-dlp said, shortened.
  final String? reason;

  bool givenUp(InfoBackfillPacing pacing) => gone || tries >= pacing.maxTries;

  bool dueAt(DateTime now, InfoBackfillPacing pacing) =>
      !givenUp(pacing) && now.difference(at) >= pacing.retryAfter;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    if (tries > 0) 'tries': tries,
    if (gone) 'gone': true,
    if (reason != null) 'reason': reason,
  };

  static InfoBackfillMiss? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final time = at is String ? DateTime.tryParse(at) : null;
    if (time == null) return null;
    final tries = json['tries'];
    final reason = json['reason'];
    return InfoBackfillMiss(
      at: time,
      tries: tries is int && tries > 0 ? tries : 0,
      gone: json['gone'] == true,
      reason: reason is String ? reason : null,
    );
  }
}

/// What the backfill remembers between runs, in both engines.
class InfoBackfillState {
  InfoBackfillState({
    this.lastFetchAt,
    this.pausedUntil,
    this.slowDowns = 0,
    Map<String, InfoBackfillMiss>? misses,
  }) : misses = misses ?? {};

  /// When the last fetch started, so a new run (in the other engine, or
  /// after a restart) still keeps the gap.
  DateTime? lastFetchAt;

  /// No fetch before this: YouTube asked to slow down.
  DateTime? pausedUntil;

  /// Slow-down requests since the last fetch that worked.
  int slowDowns;

  /// By video id.
  final Map<String, InfoBackfillMiss> misses;

  Map<String, Object?> toJson() => {
    'version': 1,
    if (lastFetchAt != null) 'lastFetchAt': lastFetchAt!.toIso8601String(),
    if (pausedUntil != null) 'pausedUntil': pausedUntil!.toIso8601String(),
    if (slowDowns > 0) 'slowDowns': slowDowns,
    'videos': {
      for (final entry in misses.entries) entry.key: entry.value.toJson(),
    },
  };

  static InfoBackfillState fromJson(Object? json) {
    if (json is! Map) return InfoBackfillState();
    DateTime? time(Object? value) =>
        value is String ? DateTime.tryParse(value) : null;
    final slowDowns = json['slowDowns'];
    final videos = json['videos'];
    return InfoBackfillState(
      lastFetchAt: time(json['lastFetchAt']),
      pausedUntil: time(json['pausedUntil']),
      slowDowns: slowDowns is int && slowDowns > 0 ? slowDowns : 0,
      misses: {
        if (videos is Map)
          for (final entry in videos.entries)
            if (entry.key is String)
              if (InfoBackfillMiss.fromJson(entry.value) case final miss?)
                entry.key as String: miss,
      },
    );
  }
}

/// Keeps [InfoBackfillState] in a small file in the app's private storage:
/// the app engine and the headless worker engine both use it, and
/// SharedPreferences caches values per engine.
class InfoBackfillStore {
  InfoBackfillStore({Future<String> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const fileName = 'info_backfill.json';

  final Future<String> Function() _directoryProvider;

  static Future<String> _defaultDirectory() async =>
      (await getApplicationDocumentsDirectory()).path;

  Future<File> _file() async =>
      File(p.join(await _directoryProvider(), fileName));

  Future<InfoBackfillState> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return InfoBackfillState();
      return InfoBackfillState.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      // A damaged file only forgets which videos failed and the pause.
      return InfoBackfillState();
    }
  }

  Future<void> save(InfoBackfillState state) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await tmp.rename(file.path);
  }
}

/// Why a backfill run ended.
enum InfoBackfillEnd {
  /// Every video that can be fetched now has its description.
  done,

  /// Asked to stop.
  stopped,

  /// Its time budget ran out.
  outOfTime,

  /// A download or another library change runs; try again later.
  busy,

  /// Not on Wi-Fi, or YouTube could not be reached; try again later.
  noWifi,

  /// YouTube asked to slow down; nothing before [InfoBackfillRun.pausedUntil].
  slowedDown,

  /// yt-dlp is not ready.
  notReady,
}

class InfoBackfillRun {
  const InfoBackfillRun(
    this.end, {
    this.saved = 0,
    this.copied = 0,
    this.pausedUntil,
  });

  final InfoBackfillEnd end;

  /// Videos whose description was fetched and saved.
  final int saved;

  /// Folders that got a copy of the description another folder had.
  final int copied;

  final DateTime? pausedUntil;

  @override
  String toString() =>
      'InfoBackfillRun(${end.name}, saved $saved, copied $copied'
      '${pausedUntil == null ? '' : ', paused until $pausedUntil'})';
}

/// One video of the library without its description in some folder.
class _Video {
  _Video(this.videoId);

  final String videoId;

  /// The info files to write.
  final missing = <String>{};

  /// An info file another folder already has.
  String? existing;

  /// YouTube no longer offers the video (the track is marked so).
  bool unavailable = false;
}

/// Saves the YouTube description (`.woolytube_info/<id>.info.json`) of
/// downloaded tracks that have none: downloads before the app kept that
/// file. Only ever writes info files: media files, titles and chapters are
/// never touched.
///
/// Slow on purpose: only on Wi-Fi, one video every 20 to 60 seconds
/// ([InfoBackfillPacing]), a long pause when YouTube asks to slow down, and
/// no fetch while a download or another library change runs. Videos that
/// are gone (removed, private) and tracks whose file the owner replaced are
/// skipped. What failed and the pause are kept in [InfoBackfillStore], and
/// the info files themselves are the progress, so a run that stops is simply
/// continued by the next.
class InfoBackfillService {
  InfoBackfillService(
    this._db, {
    required Future<Map<String, dynamic>> Function(String url) fetchInfo,
    required Future<bool> Function() isOnWifi,
    InfoBackfillStore? store,
    bool Function()? isBusy,
    Future<bool> Function()? prepare,
    LogService? log,
    this.pacing = const InfoBackfillPacing(),
    DateTime Function()? clock,
    math.Random? random,
    Future<void> Function(Duration)? sleep,
  }) : _fetchInfo = fetchInfo,
       _isOnWifi = isOnWifi,
       store = store ?? InfoBackfillStore(),
       _isBusy = isBusy ?? _never,
       _prepare = prepare,
       _log = log,
       _clock = clock ?? DateTime.now,
       _random = random ?? math.Random(),
       _sleep = sleep ?? Future<void>.delayed;

  final AppDatabase _db;
  final Future<Map<String, dynamic>> Function(String url) _fetchInfo;
  final Future<bool> Function() _isOnWifi;
  final InfoBackfillStore store;
  final bool Function() _isBusy;
  final Future<bool> Function()? _prepare;
  final LogService? _log;
  final InfoBackfillPacing pacing;
  final DateTime Function() _clock;
  final math.Random _random;
  final Future<void> Function(Duration) _sleep;

  /// How often waits check whether to stop.
  static const _tick = Duration(seconds: 1);

  static bool _never() => false;

  bool _running = false;
  bool get isRunning => _running;

  /// Saves descriptions until every video that can be fetched has one, or
  /// until [shouldStop] says so, [budget] runs out, the phone leaves Wi-Fi,
  /// the library gets busy or YouTube asks to slow down.
  Future<InfoBackfillRun> run({
    bool Function()? shouldStop,
    Duration? budget,
  }) async {
    if (_running) return const InfoBackfillRun(InfoBackfillEnd.busy);
    _running = true;
    try {
      final result = await _run(shouldStop ?? _never, budget);
      if (result.saved > 0 || result.copied > 0) {
        _log?.info(
          'YouTube info: saved ${result.saved}, copied ${result.copied}; '
          '${result.end.name}',
        );
      }
      return result;
    } finally {
      _running = false;
    }
  }

  Future<InfoBackfillRun> _run(bool Function() stop, Duration? budget) async {
    final deadline = budget == null ? null : _clock().add(budget);
    final state = await store.read();
    var saved = 0;
    var copied = 0;
    InfoBackfillRun end(InfoBackfillEnd why) => InfoBackfillRun(
      why,
      saved: saved,
      copied: copied,
      pausedUntil: why == InfoBackfillEnd.slowedDown ? state.pausedUntil : null,
    );

    if (stop()) return end(InfoBackfillEnd.stopped);
    final paused = state.pausedUntil;
    if (paused != null && _clock().isBefore(paused)) {
      // Unless the phone's clock was set back by more than a pause.
      if (paused.difference(_clock()) <= pacing.maxPause * 1.2) {
        return end(InfoBackfillEnd.slowedDown);
      }
      state.pausedUntil = null;
    }
    if (_isBusy()) return end(InfoBackfillEnd.busy);
    if (!await _onWifi()) return end(InfoBackfillEnd.noWifi);

    final videos = await _videosWithoutInfo();

    // A description another folder already has is copied, without network.
    for (final video in videos) {
      if (video.existing == null) continue;
      if (stop()) return end(InfoBackfillEnd.stopped);
      if (_isBusy()) return end(InfoBackfillEnd.busy);
      copied += await _copy(video);
    }

    final now = _clock();
    final toFetch = [
      for (final video in videos)
        if (video.existing == null &&
            !video.unavailable &&
            (state.misses[video.videoId]?.dueAt(now, pacing) ?? true))
          video,
    ];
    // Videos never tried before the ones that failed before.
    final neverTried = [
      for (final video in toFetch)
        if (!state.misses.containsKey(video.videoId)) video,
    ];
    final retries = [
      for (final video in toFetch)
        if (state.misses.containsKey(video.videoId)) video,
    ];

    var prepared = false;
    var failuresInRow = 0;
    for (final video in [...neverTried, ...retries]) {
      final last = state.lastFetchAt;
      final gap = pacing.gap(_random);
      var next = last == null ? _clock() : last.add(gap);
      // A time in the future means the phone's clock was set back.
      if (next.isAfter(_clock().add(pacing.maxGap))) next = _clock().add(gap);
      final waited = await _waitUntil(next, stop, deadline);
      if (waited != null) return end(waited);
      if (_isBusy()) return end(InfoBackfillEnd.busy);
      if (!await _onWifi()) return end(InfoBackfillEnd.noWifi);
      // The list may be hours old: a download may have saved the file
      // meanwhile, or an update removed the track or moved it.
      final current = await _current(video.videoId);
      if (current.missing.isEmpty || current.unavailable) continue;
      if (current.existing != null) {
        copied += await _copy(current);
        continue;
      }
      if (!prepared) {
        try {
          prepared = await (_prepare?.call() ?? Future.value(true));
        } catch (e) {
          _log?.warn('YouTube info: yt-dlp is not ready: $e');
          prepared = false;
        }
        if (!prepared) return end(InfoBackfillEnd.notReady);
      }

      state.lastFetchAt = _clock();
      await _save(state);
      final fetch = await _fetch(video.videoId, stop);
      if (fetch == null) return end(InfoBackfillEnd.stopped);
      final info = fetch.info;
      if (info != null) {
        if (_isBusy()) {
          // A playlist folder may be moving: fetched again later.
          return end(InfoBackfillEnd.busy);
        }
        final written = await _write(video.videoId, encodeVideoInfo(info));
        if (written > 0) saved++;
        state.misses.remove(video.videoId);
        state.slowDowns = 0;
        state.pausedUntil = null;
        failuresInRow = 0;
        await _save(state);
        continue;
      }

      final error = fetch.error!;
      final previous = state.misses[video.videoId];
      final reason = _shortReason(error);
      switch (classifyInfoFetchError(error)) {
        case InfoFetchProblem.offline:
          return end(InfoBackfillEnd.noWifi);
        case InfoFetchProblem.slowDown:
          // Not the video's fault, but it waits a day so one video that
          // always gets this answer cannot hold up the rest.
          state.misses[video.videoId] = InfoBackfillMiss(
            at: _clock(),
            tries: previous?.tries ?? 0,
            reason: reason,
          );
          _pause(state, 'YouTube asked to slow down');
          await _save(state);
          return end(InfoBackfillEnd.slowedDown);
        case InfoFetchProblem.gone:
          state.misses[video.videoId] = InfoBackfillMiss(
            at: _clock(),
            tries: (previous?.tries ?? 0) + 1,
            gone: true,
            reason: reason,
          );
          failuresInRow = 0;
          _log?.info('YouTube info of ${video.videoId} skipped: $reason');
        case InfoFetchProblem.failed:
          state.misses[video.videoId] = InfoBackfillMiss(
            at: _clock(),
            tries: (previous?.tries ?? 0) + 1,
            reason: reason,
          );
          failuresInRow++;
          _log?.warn('YouTube info of ${video.videoId} failed: $reason');
          if (failuresInRow >= pacing.failuresBeforePause) {
            _pause(state, '$failuresInRow fetches failed in a row');
            await _save(state);
            return end(InfoBackfillEnd.slowedDown);
          }
      }
      await _save(state);
    }
    return end(InfoBackfillEnd.done);
  }

  void _pause(InfoBackfillState state, String why) {
    state.slowDowns++;
    final until = _clock().add(pacing.pause(state.slowDowns, _random));
    state.pausedUntil = until;
    _log?.info('YouTube info: paused until $until ($why)');
  }

  Future<bool> _onWifi() async {
    try {
      return await _isOnWifi();
    } catch (_) {
      return false;
    }
  }

  Future<void> _save(InfoBackfillState state) async {
    try {
      await store.save(state);
    } catch (e) {
      // Kept in memory for this run; the next one starts afresh.
      _log?.warn('YouTube info: could not save the progress: $e');
    }
  }

  /// Waits until [when]. Null when it is time, else why the run must end.
  Future<InfoBackfillEnd?> _waitUntil(
    DateTime when,
    bool Function() stop,
    DateTime? deadline,
  ) async {
    while (true) {
      if (stop()) return InfoBackfillEnd.stopped;
      // A fetch that would start after the deadline is not started.
      if (deadline != null && !when.isBefore(deadline)) {
        return InfoBackfillEnd.outOfTime;
      }
      final left = when.difference(_clock());
      if (left <= Duration.zero) return null;
      await _sleep(left < _tick ? left : _tick);
    }
  }

  /// Fetches [videoId]'s description. Null when [stop] said so while
  /// waiting (the answer is then dropped).
  Future<({Map<String, dynamic>? info, String? error})?> _fetch(
    String videoId,
    bool Function() stop,
  ) async {
    Map<String, dynamic>? info;
    String? error;
    var finished = false;
    final watched = _fetchInfo('https://www.youtube.com/watch?v=$videoId')
        .then(
          (value) {
            if (value['id'] == videoId) {
              info = value;
            } else {
              error = 'yt-dlp described another video (${value['id']})';
            }
          },
          onError: (Object e) {
            error = e is PlatformException ? (e.message ?? e.code) : '$e';
          },
        )
        .whenComplete(() => finished = true);
    while (!finished) {
      if (stop()) return null;
      await Future.any([watched, _sleep(_tick)]);
    }
    return (info: info, error: error);
  }

  /// Copies the info file another folder of [video] has to the folders
  /// that miss it. Returns how many it wrote.
  Future<int> _copy(_Video video) async {
    String content;
    try {
      content = await File(video.existing!).readAsString();
      jsonDecode(content);
    } catch (_) {
      return 0;
    }
    return _write(video.videoId, content);
  }

  /// Writes [content] to every folder that misses [videoId]'s info file
  /// now: never over a file saved meanwhile (by a download, which describes
  /// the format it got), and never for a track that is gone, moved or
  /// replaced meanwhile. Returns how many it wrote. A folder that is gone is
  /// skipped.
  Future<int> _write(String videoId, String content) async {
    var written = 0;
    for (final path in (await _current(videoId)).missing) {
      try {
        if (await File(path).exists()) continue;
        await writeInfoFile(path, content);
        written++;
      } catch (e) {
        _log?.warn('YouTube info: could not save $path: $e');
      }
    }
    return written;
  }

  static String _shortReason(String error) {
    final line = error
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => error);
    return line.length > 200 ? '${line.substring(0, 200)}...' : line;
  }

  /// The downloaded YouTube tracks of the library that have no info file
  /// in their folder, by video, in the home order.
  Future<List<_Video>> _videosWithoutInfo() async {
    final byId = <String, _Video>{};
    for (final playlist in await _db.getAllPlaylists()) {
      final folder = playlist.outputPath;
      if (!await Directory(folder).exists()) continue;
      for (final track in await _db.getTracksForPlaylist(playlist.id)) {
        if (!keepsYouTubeInfo(track)) continue;
        await _addTrack(
          byId.putIfAbsent(track.videoId, () => _Video(track.videoId)),
          folder,
          track,
        );
      }
    }
    return [
      for (final video in byId.values)
        if (video.missing.isNotEmpty) video,
    ];
  }

  /// [videoId] as the library has it now, from the database and the disk.
  Future<_Video> _current(String videoId) async {
    final video = _Video(videoId);
    final folders = <int, String?>{};
    for (final track in await _db.getTracksForVideo(videoId)) {
      if (!keepsYouTubeInfo(track)) continue;
      final id = track.playlistId;
      final folder =
          folders.containsKey(id)
              ? folders[id]
              : folders[id] = await _folder(id);
      if (folder == null) continue;
      await _addTrack(video, folder, track);
    }
    return video;
  }

  /// The playlist's folder, or null when the playlist or its folder is gone.
  Future<String?> _folder(int playlistId) async {
    final playlist = await _db.getPlaylistOrNull(playlistId);
    if (playlist == null) return null;
    final folder = playlist.outputPath;
    return await Directory(folder).exists() ? folder : null;
  }

  static Future<void> _addTrack(
    _Video video,
    String folder,
    Track track,
  ) async {
    final path = LibraryLayout.infoJsonPath(folder, track.videoId);
    if (await File(path).exists()) {
      video.existing ??= path;
    } else {
      video.missing.add(path);
    }
    if (track.unavailableReason != null) video.unavailable = true;
  }
}

/// Whether [track] should have its YouTube description in its folder: a
/// downloaded YouTube video. A file the owner put in its place is not that
/// video, and inserted local files have no YouTube video.
bool keepsYouTubeInfo(Track track) =>
    track.status == 'complete' &&
    track.filePath != null &&
    track.videoId.isNotEmpty &&
    !track.videoId.startsWith(forcedInsertVideoIdPrefix) &&
    !track.isLocalReplacement;

/// Runs [InfoBackfillService] in the app whenever it is idle: a while after
/// the start, again a few minutes after it had to wait (no Wi-Fi, a
/// download running), after a pause YouTube asked for, and when the app
/// comes back to the foreground.
class InfoBackfillScheduler {
  InfoBackfillScheduler(
    this._service, {
    this.firstDelay = const Duration(minutes: 3),
    this.retryDelay = const Duration(minutes: 5),
    this.rescanAfter = const Duration(minutes: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final InfoBackfillService _service;
  final Duration firstDelay;
  final Duration retryDelay;

  /// After a run found nothing left, coming back to the app looks again
  /// only after this long.
  final Duration rescanAfter;
  final DateTime Function() _clock;

  Timer? _timer;
  bool _started = false;
  bool _stopped = false;
  Future<void>? _running;
  DateTime? _doneAt;

  /// The last run's end.
  InfoBackfillRun? lastRun;

  /// Starts the first run after [firstDelay]. Once only.
  void start() {
    if (_started || _stopped) return;
    _started = true;
    _schedule(firstDelay);
  }

  /// The app came back to the foreground.
  void wake() {
    if (!_started || _stopped || _running != null) return;
    final doneAt = _doneAt;
    if (doneAt != null && _clock().difference(doneAt) < rescanAfter) return;
    if (lastRun?.end == InfoBackfillEnd.slowedDown) return;
    _schedule(const Duration(seconds: 30));
  }

  /// Stops the run and everything scheduled. For good.
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Runs now (for tests and the timer).
  Future<void> runNow() {
    if (_stopped) return Future.value();
    return _running ??= _run().whenComplete(() => _running = null);
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(runNow());
    });
  }

  Future<void> _run() async {
    InfoBackfillRun result;
    try {
      result = await _service.run(shouldStop: () => _stopped);
    } catch (_) {
      result = const InfoBackfillRun(InfoBackfillEnd.notReady);
    }
    lastRun = result;
    if (_stopped) return;
    switch (result.end) {
      case InfoBackfillEnd.done:
        _doneAt = _clock();
      case InfoBackfillEnd.stopped:
        break;
      case InfoBackfillEnd.slowedDown:
        final until = result.pausedUntil;
        final wait = until == null ? retryDelay : until.difference(_clock());
        _schedule(
          wait < retryDelay ? retryDelay : wait + const Duration(minutes: 1),
        );
      case InfoBackfillEnd.outOfTime:
      case InfoBackfillEnd.busy:
      case InfoBackfillEnd.noWifi:
      case InfoBackfillEnd.notReady:
        _schedule(retryDelay);
    }
  }
}

/// How far the backfill has come, for "Check backup".
class InfoBackfillStatus {
  const InfoBackfillStatus({this.pausedUntil, this.givenUp = const {}});

  /// YouTube asked to slow down; nothing is fetched before this.
  final DateTime? pausedUntil;

  /// Videos that are gone or failed too often.
  final Set<String> givenUp;

  static Future<InfoBackfillStatus> read(
    InfoBackfillStore store, {
    InfoBackfillPacing pacing = const InfoBackfillPacing(),
    DateTime? now,
  }) async {
    final state = await store.read();
    final paused = state.pausedUntil;
    return InfoBackfillStatus(
      pausedUntil:
          paused != null && paused.isAfter(now ?? DateTime.now())
              ? paused
              : null,
      givenUp: {
        for (final entry in state.misses.entries)
          if (entry.value.givenUp(pacing)) entry.key,
      },
    );
  }
}
