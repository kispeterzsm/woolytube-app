import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../chapters.dart';
import '../library_layout.dart';
import '../metadata_service.dart';
import '../ytdlp_service.dart';
import 'audio_window_decoder.dart';
import 'chapter_estimator.dart';
import 'decoder_accuracy.dart';
import 'recognition_files.dart';
import 'shazam_client.dart';
import 'shazam_signature.dart';
import 'silence_detector.dart';
import '../track_title.dart';

enum RecognitionPhase {
  sampling,

  /// Sampling is paused before retrying a lookup; see
  /// [RecognitionProgress.resumeAt].
  waiting,
  silence,
  estimating,
  done,
  cancelled,
  failed,
}

/// Why a scan is [RecognitionPhase.waiting].
enum RecognitionWaitReason {
  /// Shazam asked us to slow down.
  rateLimited,

  /// A lookup failed on the network or server side.
  network,
}

class RecognitionProgress {
  final int trackId;
  final RecognitionPhase phase;
  final int completed;
  final int total;
  final String? message;

  /// While [RecognitionPhase.waiting]: when the lookup is retried.
  final DateTime? resumeAt;
  final RecognitionWaitReason? waitReason;

  const RecognitionProgress({
    required this.trackId,
    required this.phase,
    this.completed = 0,
    this.total = 0,
    this.message,
    this.resumeAt,
    this.waitReason,
  });

  bool get running =>
      phase == RecognitionPhase.sampling ||
      phase == RecognitionPhase.waiting ||
      phase == RecognitionPhase.silence ||
      phase == RecognitionPhase.estimating;
}

/// A completed scan: the proposals plus what they were computed against, so
/// they can be applied later only if the chapters have not changed since.
class RecognitionRun {
  final String runId;
  final int trackId;
  final String fileKey;
  final int epoch;
  final int durationMs;
  final DateTime completedAt;
  final int sampleCount;
  final int matchedSamples;
  final List<ChapterProposal> proposals;

  /// The [decoderAccuracyVersion] of the scan. Runs saved before versions
  /// existed read as 1.
  final int decoderVersion;

  /// Set by [SongRecognitionService.loadRun], never stored: the run was
  /// made by a decoder that placed this file's audio wrongly (an MP3 before
  /// version 2), so its timings can be seconds off. Such a run is not
  /// applied; Recognize again makes an exact one.
  final bool decoderOutdated;

  const RecognitionRun({
    required this.runId,
    required this.trackId,
    required this.fileKey,
    required this.epoch,
    required this.durationMs,
    required this.completedAt,
    required this.sampleCount,
    required this.matchedSamples,
    required this.proposals,
    this.decoderVersion = decoderAccuracyVersion,
    this.decoderOutdated = false,
  });

  /// Plain-language reason shown for a [decoderOutdated] run.
  static const decoderOutdatedMessage =
      'These proposals were made with an older, less accurate scan of MP3 '
      'files, so their timings can be off by several seconds. Recognize '
      'again for exact timings.';

  RecognitionRun copyWith({
    List<ChapterProposal>? proposals,
    bool? decoderOutdated,
  }) => RecognitionRun(
    runId: runId,
    trackId: trackId,
    fileKey: fileKey,
    epoch: epoch,
    durationMs: durationMs,
    completedAt: completedAt,
    sampleCount: sampleCount,
    matchedSamples: matchedSamples,
    proposals: proposals ?? this.proposals,
    decoderVersion: decoderVersion,
    decoderOutdated: decoderOutdated ?? this.decoderOutdated,
  );

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'trackId': trackId,
    'fileKey': fileKey,
    'epoch': epoch,
    'durationMs': durationMs,
    'completedAt': completedAt.toIso8601String(),
    'sampleCount': sampleCount,
    'matchedSamples': matchedSamples,
    'proposals': proposals.map((c) => c.toJson()).toList(),
    'decoderVersion': decoderVersion,
  };

  factory RecognitionRun.fromJson(Map<String, dynamic> json) => RecognitionRun(
    runId: json['runId'] as String,
    trackId: json['trackId'] as int,
    fileKey: json['fileKey'] as String,
    epoch: json['epoch'] as int,
    durationMs: json['durationMs'] as int,
    completedAt: DateTime.parse(json['completedAt'] as String),
    sampleCount: json['sampleCount'] as int,
    matchedSamples: json['matchedSamples'] as int,
    proposals:
        (json['proposals'] as List)
            .map((c) => ChapterProposal.fromJson(c as Map<String, dynamic>))
            .toList(),
    decoderVersion: (json['decoderVersion'] as num?)?.toInt() ?? 1,
  );
}

class RecognitionCancelled implements Exception {
  const RecognitionCancelled();
  @override
  String toString() => 'Recognition cancelled';
}

/// Shazam kept rate-limiting lookups for longer than the scan waits. The
/// lookups made so far stay cached, so a later scan resumes from there.
class RecognitionRateLimited implements Exception {
  const RecognitionRateLimited();
  static const message =
      'Shazam is limiting requests right now. Progress is saved; '
      'try again later.';
  @override
  String toString() => message;
}

/// Keeps the process alive and visible while a scan runs.
abstract interface class ScanForegroundNotifier {
  Future<void> start(String label);

  /// [detail], when given, replaces the "n of total" line, for example
  /// while the scan waits before retrying a lookup. The Android side keeps
  /// showing the last detail while [current] stays the same, so an update
  /// without one does not clear it; send a new detail to replace it.
  Future<void> update(String label, int current, int total, {String? detail});
  Future<void> stop();
}

/// Reuses the download foreground service of the yt-dlp plugin.
///
/// A download owns that service whenever [downloadActive] says one is
/// running: the scan then leaves its notification alone and never stops the
/// service, so a download that starts during a scan keeps its foreground
/// protection when the scan ends. Once the download has finished (and
/// stopped the service), the next progress update starts it again for the
/// scan.
class YtDlpScanForegroundNotifier implements ScanForegroundNotifier {
  YtDlpScanForegroundNotifier(this._ytdlp, {bool Function()? downloadActive})
    : _downloadActive = downloadActive ?? _never;
  final YtDlpService _ytdlp;
  final bool Function() _downloadActive;

  /// Whether this scan started the service and still owns it.
  bool _owned = false;

  static bool _never() => false;

  @override
  Future<void> start(String label) async {
    if (_downloadActive()) {
      _owned = false;
      return;
    }
    _owned = true;
    await _ytdlp.startDownloadService(label);
  }

  @override
  Future<void> update(
    String label,
    int current,
    int total, {
    String? detail,
  }) async {
    if (_downloadActive()) {
      _owned = false;
      return;
    }
    if (!_owned) {
      _owned = true;
      await _ytdlp.startDownloadService(label);
    }
    await _ytdlp.updateDownloadServiceProgress(
      playlistName: label,
      currentTrack: current,
      totalTracks: total,
      progress: total == 0 ? 0 : (current * 100 ~/ total),
      trackTitle: detail,
    );
  }

  @override
  Future<void> stop() async {
    final owned = _owned;
    _owned = false;
    if (!owned || _downloadActive()) return;
    await _ytdlp.stopDownloadService();
  }
}

/// Runs the song recognition pipeline for one downloaded file.
///
/// Windows are decoded locally, fingerprinted, and looked up one at a time.
/// Every lookup is cached under the file's content key, so a cancelled or
/// failed scan resumes where it stopped and a finished scan can be re-run
/// without network use. Quiet gaps are only measured where the recognized
/// song changes, which is the only place the estimator uses them.
/// Cached lookups and quiet gaps carry the [decoderAccuracyVersion] that
/// measured them; those an older decoder placed wrongly for this file are
/// measured again rather than reused.
///
/// When Shazam rate-limits a lookup, the scan waits (a growing backoff, or
/// longer when Retry-After asks for it) and retries the same sample, giving
/// up once [rateLimitBudget] has passed since the first rate limit without
/// a single success. Network and server hiccups are retried a few times.
/// Every wait, the recognizer's own pacing included, ends at once on
/// [cancel].
class SongRecognitionService {
  SongRecognitionService(
    this._db, {
    required AudioWindowDecoder decoder,
    required ShazamRecognizer recognizer,
    required Future<Directory> Function() rootDirectory,
    ScanForegroundNotifier? notifier,
    SilenceDetector silenceDetector = const SilenceDetector(),
    this.windowSeconds = 12,
    this.stepSeconds = 60,
    this.firstStartSeconds = 30,
    this.silenceMarginSeconds = 4,
    this.rateLimitBackoff = const [
      Duration(seconds: 30),
      Duration(seconds: 60),
      Duration(seconds: 120),
      Duration(seconds: 240),
      Duration(seconds: 300),
    ],
    this.rateLimitBudget = const Duration(minutes: 20),
    this.transientRetryDelays = const [
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  }) : _decoder = decoder,
       _recognizer = recognizer,
       _rootDirectory = rootDirectory,
       _notifier = notifier,
       _silence = silenceDetector,
       _delay = delay ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final AudioWindowDecoder _decoder;
  final ShazamRecognizer _recognizer;
  final Future<Directory> Function() _rootDirectory;
  final ScanForegroundNotifier? _notifier;
  final SilenceDetector _silence;
  final int windowSeconds;
  final int stepSeconds;
  final int firstStartSeconds;
  final int silenceMarginSeconds;

  /// Waits after consecutive rate-limit responses; the last one repeats.
  /// A longer Retry-After is used instead. Restarts after a successful
  /// lookup.
  final List<Duration> rateLimitBackoff;

  /// The scan gives up once the next retry would come later than this
  /// after the first rate-limit response since the last successful lookup.
  /// Measured on the clock, so pacing and request time count too.
  final Duration rateLimitBudget;

  /// Waits before each retry of a lookup that failed on the network or
  /// server side; when they are used up, the scan fails.
  final List<Duration> transientRetryDelays;

  final Future<void> Function(Duration) _delay;
  final DateTime Function() _clock;

  /// Longest stretch the silence pass decodes in one platform call. Quiet
  /// gaps are measured around song changes, and back-to-back changes merge
  /// into one stretch that can cover most of a long mix; decoding that in
  /// one piece would hold hundreds of MB of PCM at once.
  static const silenceChunkMs = 60000;

  /// Decoded ahead of every later chunk and dropped, so the decoder's
  /// start-up output never lands inside the stretch.
  static const silencePrerollMs = 1000;

  final _progress = StreamController<RecognitionProgress>.broadcast();
  RecognitionProgress? _current;
  bool _cancelRequested = false;

  /// Completed by [cancel], so a wait between retries ends at once.
  Completer<void> _cancelSignal = Completer<void>();

  /// The track of the scan in progress. Set before scan() first awaits, so a
  /// second call can never start alongside it.
  int? _activeTrackId;

  /// The time stamp of the last run id handed out, so a rescan served from
  /// cached lookups within the same millisecond still gets a new id (a run
  /// id that was applied before is never applied again).
  static int _lastRunStamp = 0;

  static String _nextRunId() {
    final stamp = math.max(
      DateTime.now().millisecondsSinceEpoch,
      _lastRunStamp + 1,
    );
    _lastRunStamp = stamp;
    return stamp.toRadixString(36);
  }

  Stream<RecognitionProgress> get progressStream => _progress.stream;
  RecognitionProgress? get currentProgress => _current;
  bool get isScanning => _activeTrackId != null;
  int? get scanningTrackId => _activeTrackId;

  void cancel() {
    if (!isScanning) return;
    _cancelRequested = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }

  void dispose() {
    _progress.close();
  }

  /// The last completed run for [track], if its file is unchanged.
  ///
  /// When this app has none (after a reinstall, or on another phone), the
  /// copy in the playlist folder is taken over if it was made from the same
  /// file content, with its cached lookups.
  Future<RecognitionRun?> loadRun(Track track) async {
    final path = _filePath(track);
    if (path == null) return null;
    final dir = await _runDirectory(track, path);
    final file = File(p.join(dir, 'run.json'));
    if (!await file.exists() &&
        !await _adoptFolderCopy(track, dir, withRun: true)) {
      return null;
    }
    try {
      final run = RecognitionRun.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      // Only a run made from exactly this file content belongs here.
      if (run.fileKey != p.basename(dir)) return null;
      final trusted = decoderVersionTrusted(
        run.decoderVersion,
        mpegAudio: await isMpegAudioFile(path),
      );
      return trusted ? run : run.copyWith(decoderOutdated: true);
    } catch (_) {
      return null;
    }
  }

  /// Stores review edits of [run], here and in the playlist folder. Does
  /// nothing when [track]'s file is no longer the one the run was made
  /// from, so a run never lands in the cache of a replacement file.
  Future<void> saveRun(RecognitionRun run, Track track) async {
    final path = _filePath(track);
    if (path == null) return;
    final dir = Directory(await _runDirectory(track, path));
    if (run.fileKey != p.basename(dir.path)) return;
    await dir.create(recursive: true);
    await File(
      p.join(dir.path, 'run.json'),
    ).writeAsString(jsonEncode(run.toJson()));
    await _mirrorRun(track, dir, run);
  }

  /// Forgets [track]'s run, also the playlist folder's copy of it (a copy
  /// made from other content is left alone).
  Future<void> discardRun(Track track) async {
    final path = _filePath(track);
    if (path == null) return;
    final dir = await _runDirectory(track, path);
    final file = File(p.join(dir, 'run.json'));
    if (await file.exists()) await file.delete();
    try {
      final folder = await _folderOf(track);
      if (folder == null) return;
      final copy = await readRecognitionFile(folder, track.videoId);
      if (copy == null || copy.contentKey != _contentKey(track, dir)) return;
      final folderFile = File(
        LibraryLayout.recognitionJsonPath(folder, track.videoId),
      );
      if (await folderFile.exists()) await folderFile.delete();
    } catch (_) {
      // A copy left behind is only offered for this same file content.
    }
  }

  /// Removes cached lookups and runs for files that no longer exist or
  /// belong to other content.
  Future<int> pruneCache(Iterable<Track> liveTracks) async {
    final root = Directory(
      p.join((await _rootDirectory()).path, 'recognition'),
    );
    if (!await root.exists()) return 0;
    final keep = <String>{};
    for (final track in liveTracks) {
      final path = _filePath(track);
      if (path != null) keep.add(p.basename(await _runDirectory(track, path)));
    }
    var removed = 0;
    await for (final entity in root.list()) {
      if (entity is Directory && !keep.contains(p.basename(entity.path))) {
        await entity.delete(recursive: true);
        removed++;
      }
    }
    return removed;
  }

  Future<RecognitionRun> scan(Track track) async {
    // Checked and claimed synchronously: nothing may await between the two.
    if (isScanning) {
      throw StateError('Another recognition scan is running.');
    }
    final path = _filePath(track);
    if (path == null) {
      throw StateError('The file for "${track.displayTitle}" was not found.');
    }
    _activeTrackId = track.id;
    _cancelRequested = false;
    _cancelSignal = Completer<void>();
    try {
      return await _scan(track, path);
    } finally {
      _activeTrackId = null;
      _cancelRequested = false;
    }
  }

  Future<RecognitionRun> _scan(Track track, String path) async {
    final label = 'songs in ${track.displayTitle}';
    // Read before sampling: an undo, reset or file replacement while the
    // scan runs bumps it, and the run is then not applied.
    final epoch =
        ChapterData.decode(
          (await _db.getTrack(track.id))?.chaptersJson,
        ).recognitionEpoch;
    final durationMs = await _durationMs(track, path);
    // Lookups and quiet gaps an older decoder measured in the wrong place
    // are measured again instead of reused.
    final mpegAudio = await isMpegAudioFile(path);
    final dir = Directory(await _runDirectory(track, path));
    await _pruneStaleCaches(track, dir);
    await dir.create(recursive: true);
    // After a reinstall: the lookups kept in the playlist folder.
    await _adoptFolderCopy(track, dir.path, withRun: false);
    final starts = sampleStartsMs(durationMs);
    _emit(
      RecognitionProgress(
        trackId: track.id,
        phase: RecognitionPhase.sampling,
        total: starts.length,
      ),
    );
    try {
      await _notifier?.start(label);
      final samples = <RecognitionSample>[];
      final retry = _RetryState();
      final sampleDir = Directory(p.join(dir.path, 'samples'));
      await sampleDir.create(recursive: true);
      for (var i = 0; i < starts.length; i++) {
        _checkCancelled();
        samples.add(
          await _sampleAt(
            path,
            sampleDir,
            starts[i],
            mpegAudio: mpegAudio,
            lookUp:
                (signature) => _lookUp(
                  signature,
                  retry,
                  budget: rateLimitBudget,
                  waitBeforeRetry:
                      (wait, reason) => _waitBeforeRetry(
                        wait,
                        reason,
                        trackId: track.id,
                        label: label,
                        completed: i,
                        total: starts.length,
                      ),
                ),
          ),
        );
        _emit(
          RecognitionProgress(
            trackId: track.id,
            phase: RecognitionPhase.sampling,
            completed: i + 1,
            total: starts.length,
          ),
        );
        unawaited(
          _notifier?.update(label, i + 1, starts.length).catchError((_) {}),
        );
      }

      _emit(
        RecognitionProgress(
          trackId: track.id,
          phase: RecognitionPhase.silence,
          completed: 0,
          total: 0,
        ),
      );
      final quiet = await _quietIntervals(
        path,
        dir,
        samples,
        durationMs,
        mpegAudio: mpegAudio,
      );

      _emit(
        RecognitionProgress(
          trackId: track.id,
          phase: RecognitionPhase.estimating,
        ),
      );
      final runId = _nextRunId();
      final proposals = ChapterEstimator.estimate(
        runName: 'r$runId',
        durationMs: durationMs,
        samples: samples,
        quietIntervals: quiet,
      );
      final run = RecognitionRun(
        runId: runId,
        trackId: track.id,
        fileKey: p.basename(dir.path),
        epoch: epoch,
        durationMs: durationMs,
        completedAt: DateTime.now(),
        sampleCount: samples.length,
        matchedSamples: samples.where((s) => s.result.recognized).length,
        proposals: proposals,
        decoderVersion: decoderAccuracyVersion,
      );
      await File(
        p.join(dir.path, 'run.json'),
      ).writeAsString(jsonEncode(run.toJson()));
      await _mirrorRun(track, dir, run);
      _emit(
        RecognitionProgress(
          trackId: track.id,
          phase: RecognitionPhase.done,
          completed: starts.length,
          total: starts.length,
        ),
      );
      return run;
    } on RecognitionCancelled {
      _emit(
        RecognitionProgress(
          trackId: track.id,
          phase: RecognitionPhase.cancelled,
        ),
      );
      rethrow;
    } catch (e) {
      _emit(
        RecognitionProgress(
          trackId: track.id,
          phase: RecognitionPhase.failed,
          message: e.toString(),
        ),
      );
      rethrow;
    } finally {
      await _notifier?.stop().catchError((_) {});
    }
  }

  /// The lookup of the window at [startMs]: from the cache when a decoder
  /// that placed this file's audio correctly made it, otherwise decoded,
  /// fingerprinted, looked up with [lookUp] and cached.
  Future<RecognitionSample> _sampleAt(
    String path,
    Directory sampleDir,
    int startMs, {
    required bool mpegAudio,
    required Future<ShazamResult> Function(ShazamSignature signature) lookUp,
  }) async {
    final cached = File(p.join(sampleDir.path, '$startMs.json'));
    Map<String, dynamic>? raw;
    if (await cached.exists()) {
      try {
        raw = jsonDecode(await cached.readAsString()) as Map<String, dynamic>;
        if (!decoderVersionTrusted(
          (raw['decoderVersion'] as num?)?.toInt(),
          mpegAudio: mpegAudio,
        )) {
          raw = null;
        }
      } catch (_) {
        raw = null;
      }
    }
    if (raw == null) {
      final pcm = await _decoder.decode(
        path,
        start: Duration(milliseconds: startMs),
        duration: Duration(seconds: windowSeconds),
      );
      _checkCancelled();
      final ShazamResult result;
      if (pcm.length < 128) {
        result = ShazamResult.fromJson(const {});
      } else {
        result = await lookUp(ShazamSignatureGenerator.fromSamples(pcm));
      }
      raw = {
        'sampleStartMs': startMs,
        'sampleDurationMs': windowSeconds * 1000,
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
        'decoderVersion': decoderAccuracyVersion,
        'response': result.raw,
      };
      await cached.writeAsString(jsonEncode(raw));
    }
    return RecognitionSample(
      sampleStartMs: startMs,
      sampleDurationMs: windowSeconds * 1000,
      result: ShazamResult.fromJson(
        (raw['response'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }

  /// Looks [signature] up, waiting and retrying the same lookup while Shazam
  /// rate-limits or the network hiccups. [retry] carries the backoff state
  /// across samples; a success resets it. [waitBeforeRetry] shows and
  /// sleeps each wait; [budget] is how long rate limits are waited out.
  Future<ShazamResult> _lookUp(
    ShazamSignature signature,
    _RetryState retry, {
    required Duration budget,
    required Future<void> Function(Duration wait, RecognitionWaitReason reason)
    waitBeforeRetry,
  }) async {
    while (true) {
      _checkCancelled();
      final Duration wait;
      final RecognitionWaitReason reason;
      try {
        final result = await _recognizer.recognize(
          signature,
          cancelled: _cancelSignal.future,
        );
        retry.succeeded();
        return result;
      } catch (error) {
        // A lookup that fails after Cancel was pressed ends as cancelled.
        _checkCancelled();
        switch (classifyShazamFailure(error)) {
          case ShazamFailureKind.rateLimited:
            // Retry-After is the least the endpoint wants us to wait, so a
            // short one never undercuts the backoff: a server that keeps
            // answering "retry now" is backed off like one that says nothing.
            final asked = (error as ShazamHttpException).retryAfter;
            final step =
                rateLimitBackoff[math.min(
                  retry.rateLimits++,
                  rateLimitBackoff.length - 1,
                )];
            wait = asked != null && asked > step ? asked : step;
            final now = _clock();
            final since = retry.rateLimitedSince ??= now;
            if (now.add(wait).difference(since) > budget) {
              throw const RecognitionRateLimited();
            }
            reason = RecognitionWaitReason.rateLimited;
          case ShazamFailureKind.transient:
            if (retry.transientFailures >= transientRetryDelays.length) {
              rethrow;
            }
            wait = transientRetryDelays[retry.transientFailures++];
            reason = RecognitionWaitReason.network;
          case ShazamFailureKind.permanent:
            rethrow;
        }
      }
      await waitBeforeRetry(wait, reason);
    }
  }

  /// Shows the wait, then sleeps for [wait] unless the scan is cancelled
  /// first, in which case it throws [RecognitionCancelled] right away.
  Future<void> _waitBeforeRetry(
    Duration wait,
    RecognitionWaitReason reason, {
    required int trackId,
    required String label,
    required int completed,
    required int total,
  }) async {
    final resumeAt = _clock().add(wait);
    _emit(
      RecognitionProgress(
        trackId: trackId,
        phase: RecognitionPhase.waiting,
        completed: completed,
        total: total,
        resumeAt: resumeAt,
        waitReason: reason,
      ),
    );
    final at = resumeAt.toLocal();
    final time =
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    unawaited(
      _notifier
          ?.update(
            label,
            completed,
            total,
            detail: switch (reason) {
              RecognitionWaitReason.rateLimited =>
                'Shazam asked us to slow down. Retrying at $time',
              RecognitionWaitReason.network =>
                'Connection problem. Retrying at $time',
            },
          )
          .catchError((_) {}),
    );
    await Future.any([_delay(wait), _cancelSignal.future]);
    _checkCancelled();
    _emit(
      RecognitionProgress(
        trackId: trackId,
        phase: RecognitionPhase.sampling,
        completed: completed,
        total: total,
      ),
    );
    // A detail of its own: the notification would otherwise keep showing
    // the retry time, which has now passed, until the sample is done.
    unawaited(
      _notifier
          ?.update(
            label,
            completed,
            total,
            detail: 'Retrying sample ${completed + 1} of $total…',
          )
          .catchError((_) {}),
    );
  }

  /// Recognizes the song(s) in [startMs, endMs) of [track]'s file only,
  /// for naming one chapter.
  ///
  /// Samples the windows [rangeSampleStartsMs] picks, through the same
  /// lookup cache, Shazam pacing and retries as [scan], and shares its lock:
  /// it is refused while a scan runs, and a scan is refused while it runs.
  /// [cancel] stops it ([RecognitionCancelled]). It writes no run, never
  /// touches the chapters or the recognition epoch and reports progress
  /// only through [onProgress], not [progressStream]. When Shazam keeps
  /// rate-limiting for longer than [rateLimitBudget], it stops and returns
  /// what it found so far with [RangeRecognition.limited] set.
  Future<RangeRecognition> recognizeRange(
    Track track, {
    required int startMs,
    required int endMs,
    void Function(RecognitionProgress progress)? onProgress,
    Duration rateLimitBudget = const Duration(minutes: 3),
  }) async {
    // Checked and claimed synchronously: nothing may await between the two.
    if (isScanning) {
      throw StateError('Another recognition scan is running.');
    }
    final path = _filePath(track);
    if (path == null) {
      throw StateError('The file for "${track.displayTitle}" was not found.');
    }
    _activeTrackId = track.id;
    _cancelRequested = false;
    _cancelSignal = Completer<void>();
    try {
      return await _recognizeRange(
        track,
        path,
        startMs,
        endMs,
        onProgress ?? (_) {},
        rateLimitBudget,
      );
    } finally {
      _activeTrackId = null;
      _cancelRequested = false;
    }
  }

  Future<RangeRecognition> _recognizeRange(
    Track track,
    String path,
    int startMs,
    int endMs,
    void Function(RecognitionProgress progress) onProgress,
    Duration budget,
  ) async {
    final durationMs = await _durationMs(track, path);
    final mpegAudio = await isMpegAudioFile(path);
    final dir = Directory(await _runDirectory(track, path));
    final sampleDir = Directory(p.join(dir.path, 'samples'));
    await sampleDir.create(recursive: true);
    await _adoptFolderCopy(track, dir.path, withRun: false);
    final from = startMs.clamp(0, durationMs);
    final to = endMs.clamp(from, durationMs);
    final starts = rangeSampleStartsMs(from, to, durationMs);
    final retry = _RetryState();
    final samples = <RecognitionSample>[];
    var limited = false;
    RecognitionProgress progress(
      RecognitionPhase phase,
      int completed, {
      DateTime? resumeAt,
      RecognitionWaitReason? reason,
    }) => RecognitionProgress(
      trackId: track.id,
      phase: phase,
      completed: completed,
      total: starts.length,
      resumeAt: resumeAt,
      waitReason: reason,
    );
    onProgress(progress(RecognitionPhase.sampling, 0));
    try {
      for (var i = 0; i < starts.length; i++) {
        _checkCancelled();
        samples.add(
          await _sampleAt(
            path,
            sampleDir,
            starts[i],
            mpegAudio: mpegAudio,
            lookUp:
                (signature) => _lookUp(
                  signature,
                  retry,
                  budget: budget,
                  waitBeforeRetry: (wait, reason) async {
                    onProgress(
                      progress(
                        RecognitionPhase.waiting,
                        i,
                        resumeAt: _clock().add(wait),
                        reason: reason,
                      ),
                    );
                    await Future.any([_delay(wait), _cancelSignal.future]);
                    _checkCancelled();
                    onProgress(progress(RecognitionPhase.sampling, i));
                  },
                ),
          ),
        );
        onProgress(progress(RecognitionPhase.sampling, i + 1));
      }
    } on RecognitionRateLimited {
      limited = true;
    }
    onProgress(progress(RecognitionPhase.done, samples.length));
    return RangeRecognition(
      startMs: from,
      endMs: to,
      sampleCount: starts.length,
      checkedSamples: samples.length,
      candidates: groupRangeSamples(samples),
      limited: limited,
    );
  }

  /// Keeps per-chapter lookups this far inside the chapter, away from the
  /// crossfades into the songs around it.
  static const rangeEdgeMs = 3000;

  /// About one new window per this much of a chapter...
  static const rangeSpacingMs = 30000;

  /// ...but never more than this many.
  static const rangeMaxWindows = 8;

  /// Window starts for recognizing [startMs, endMs) of a file
  /// [durationMs] long: the scan grid's windows that lie wholly inside (they
  /// are usually cached, so they cost nothing), plus up to
  /// [rangeMaxWindows] new ones spread over the chapter, at least
  /// [rangeEdgeMs] from its edges and a whole window away from every grid
  /// window and from each other, so they listen to audio the scan did not.
  /// A chapter too short for that gets one window over its middle; one where
  /// no such spot is free gets one as far from the grid as it allows, so
  /// there is always at least one window.
  List<int> rangeSampleStartsMs(int startMs, int endMs, int durationMs) {
    final windowMs = windowSeconds * 1000;
    final lastStart = math.max(0, durationMs - windowMs);
    final grid = sampleStartsMs(durationMs);
    final inside = [
      for (final g in grid)
        if (g >= startMs && g + windowMs <= endMs) g,
    ];
    final from = startMs + rangeEdgeMs;
    final to = math.min(endMs - rangeEdgeMs - windowMs, lastStart);
    final fresh = <int>[];
    if (to < from) {
      if (inside.isEmpty) {
        final middle = startMs + (endMs - startMs - windowMs) ~/ 2;
        fresh.add(middle.clamp(0, lastStart));
      }
    } else {
      final count = ((to - from) / rangeSpacingMs).ceil().clamp(
        1,
        rangeMaxWindows,
      );
      bool clear(int s) =>
          grid.every((g) => (s - g).abs() >= windowMs) &&
          fresh.every((f) => (s - f).abs() >= windowMs);
      for (var i = 0; i < count; i++) {
        final ideal =
            count == 1
                ? from + (to - from) ~/ 2
                : from + (to - from) * i ~/ (count - 1);
        // The nearest free spot, in whole seconds, within half a spacing.
        int? best;
        for (var d = 0; d <= rangeSpacingMs ~/ 2 && best == null; d += 1000) {
          for (final s in [ideal - d, ideal + d]) {
            if (s >= from && s <= to && clear(s)) {
              best = s;
              break;
            }
          }
        }
        if (best != null) fresh.add(best);
      }
      // A short chapter just past a grid window: no spot is a whole window
      // away from the grid, and that window is not wholly inside. Listen
      // anyway, as far from the grid as the chapter allows.
      if (inside.isEmpty && fresh.isEmpty) {
        var best = from;
        var bestGap = -1;
        for (var s = from; s <= to; s += 1000) {
          final gap = grid.fold<int>(
            windowMs,
            (gap, g) => math.min(gap, (s - g).abs()),
          );
          if (gap > bestGap) {
            best = s;
            bestGap = gap;
          }
        }
        fresh.add(best);
      }
    }
    return {...inside, ...fresh}.toList()..sort();
  }

  /// The songs found in [samples], most often matched first (then the one
  /// matched earliest). Samples without a match are left out.
  static List<RangeCandidate> groupRangeSamples(
    List<RecognitionSample> samples,
  ) {
    final byKey = <String, List<RecognitionSample>>{};
    for (final sample in [...samples]
      ..sort((a, b) => a.sampleStartMs.compareTo(b.sampleStartMs))) {
      final key = sample.result.trackKey;
      if (key != null) byKey.putIfAbsent(key, () => []).add(sample);
    }
    final candidates = [
      for (final MapEntry(:key, :value) in byKey.entries)
        RangeCandidate._fromSamples(key, value),
    ];
    candidates.sort((a, b) {
      final byCount = b.matchedAtMs.length.compareTo(a.matchedAtMs.length);
      return byCount != 0
          ? byCount
          : a.matchedAtMs.first.compareTo(b.matchedAtMs.first);
    });
    return candidates;
  }

  /// Sample window starts: every [stepSeconds] from [firstStartSeconds], plus
  /// the final window, matching the PC prototype's grid.
  List<int> sampleStartsMs(int durationMs) {
    final duration = durationMs / 1000;
    final starts = <double>[];
    final limit = (duration - windowSeconds).floor();
    for (var s = firstStartSeconds; s < limit; s += stepSeconds) {
      starts.add(s.toDouble());
    }
    final last = math.max(0.0, duration - windowSeconds);
    starts.add((last * 1000).roundToDouble() / 1000);
    final result = <int>{};
    for (final s in starts) {
      if (s >= 0 && s <= duration - 1) result.add((s * 1000).round());
    }
    return result.toList()..sort();
  }

  Future<List<QuietInterval>> _quietIntervals(
    String path,
    Directory dir,
    List<RecognitionSample> samples,
    int durationMs, {
    required bool mpegAudio,
  }) async {
    // Brackets where the recognized song changes, widened so gaps that
    // straddle the edge still merge like they would in a whole-file pass.
    final ranges = <(int, int)>[];
    for (var i = 0; i + 1 < samples.length; i++) {
      if (samples[i].result.trackKey == samples[i + 1].result.trackKey) {
        continue;
      }
      final from = math.max(
        0,
        samples[i].sampleStartMs - silenceMarginSeconds * 1000,
      );
      final to = math.min(
        durationMs,
        samples[i + 1].sampleStartMs +
            windowSeconds * 1000 +
            silenceMarginSeconds * 1000,
      );
      if (ranges.isNotEmpty && from <= ranges.last.$2) {
        ranges[ranges.length - 1] = (
          ranges.last.$1,
          math.max(ranges.last.$2, to),
        );
      } else {
        ranges.add((from, to));
      }
    }
    final silenceDir = Directory(p.join(dir.path, 'silences'));
    await silenceDir.create(recursive: true);
    final result = <QuietInterval>[];
    for (var i = 0; i < ranges.length; i++) {
      _checkCancelled();
      final (from, to) = ranges[i];
      final cached = File(p.join(silenceDir.path, '$from-$to.json'));
      List<QuietInterval>? intervals;
      if (await cached.exists()) {
        try {
          intervals = _readQuietCache(
            jsonDecode(await cached.readAsString()),
            mpegAudio: mpegAudio,
          );
        } catch (_) {
          intervals = null;
        }
      }
      if (intervals == null) {
        intervals = await _detectSilence(path, from, to);
        await cached.writeAsString(
          jsonEncode({
            'decoderVersion': decoderAccuracyVersion,
            'intervals': [
              for (final s in intervals) [s.$1, s.$2],
            ],
          }),
        );
      }
      result.addAll(intervals);
      _emit(
        RecognitionProgress(
          trackId: samples.isEmpty ? 0 : _current!.trackId,
          phase: RecognitionPhase.silence,
          completed: i + 1,
          total: ranges.length,
        ),
      );
    }
    result.sort((a, b) => a.$1.compareTo(b.$1));
    return result;
  }

  /// The quiet intervals of a cached silence result, or null when the
  /// decoder that measured them placed this file's audio wrongly. Results
  /// stored before decoder versions existed are a bare list of
  /// `[start, end]` pairs and count as version 1.
  static List<QuietInterval>? _readQuietCache(
    Object? json, {
    required bool mpegAudio,
  }) {
    final int? version;
    final List list;
    if (json is Map) {
      version = (json['decoderVersion'] as num?)?.toInt();
      list = json['intervals'] as List;
    } else {
      version = null;
      list = json as List;
    }
    if (!decoderVersionTrusted(version, mpegAudio: mpegAudio)) return null;
    return [
      for (final s in list)
        ((s[0] as num).toDouble(), (s[1] as num).toDouble()),
    ];
  }

  /// Quiet intervals in [fromMs, toMs), decoded in chunks of at most
  /// [silenceChunkMs] (plus the pre-roll) with the detector's open run
  /// carried across chunk edges.
  Future<List<QuietInterval>> _detectSilence(
    String path,
    int fromMs,
    int toMs,
  ) async {
    final scan = SilenceScan(_silence);
    for (var start = fromMs; start < toMs; start += silenceChunkMs) {
      _checkCancelled();
      final end = math.min(toMs, start + silenceChunkMs);
      final preroll = start == fromMs ? 0 : math.min(silencePrerollMs, start);
      var pcm = await _decoder.decode(
        path,
        start: Duration(milliseconds: start - preroll),
        duration: Duration(milliseconds: end - start + preroll),
      );
      if (preroll > 0) {
        final skip = math.min(
          pcm.length,
          preroll * _silence.sampleRate ~/ 1000,
        );
        pcm = Int16List.sublistView(pcm, skip);
      }
      scan.add(pcm, offset: Duration(milliseconds: start));
    }
    return scan.close();
  }

  /// Folders of this service's cache are named `<trackId>-<fileKey>`.
  static final _cacheFolderName = RegExp(r'^(\d+)-\d+-[0-9a-f]{16}$');

  /// Removes cached lookups nobody can use any more: those of tracks that
  /// are no longer in the library, and those of earlier content of
  /// [track]'s file. Only folders directly inside the recognition cache
  /// whose names this service makes are touched. A failure never stops the
  /// scan.
  Future<void> _pruneStaleCaches(Track track, Directory current) async {
    try {
      final root = current.parent;
      if (!await root.exists()) return;
      final liveIds = {for (final t in await _db.getAllTracks()) t.id};
      final keep = p.basename(current.path);
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        final match = _cacheFolderName.firstMatch(name);
        if (match == null || name == keep) continue;
        final id = int.parse(match.group(1)!);
        if (id == track.id || !liveIds.contains(id)) {
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {
      // Stale lookups only take space.
    }
  }

  Future<int> _durationMs(Track track, String path) async {
    final probed = await _decoder.probeDuration(path);
    if (probed != null && probed > Duration.zero) return probed.inMilliseconds;
    final stored = ChapterData.decode(track.chaptersJson);
    if (stored.valid && (stored.durationMs ?? 0) > 0) return stored.durationMs!;
    if ((track.durationSeconds ?? 0) > 0) return track.durationSeconds! * 1000;
    throw StateError(
      'Could not determine the duration of "${track.displayTitle}".',
    );
  }

  /// The playlist folder of [track], or null when the playlist is gone.
  Future<String?> _folderOf(Track track) async =>
      (await _db.getPlaylistOrNull(track.playlistId))?.outputPath;

  /// The content part of a run directory's name (`<trackId>-<content>`).
  static String _contentKey(Track track, String runDirectory) {
    final name = p.basename(runDirectory);
    final prefix = '${track.id}-';
    return name.startsWith(prefix) ? name.substring(prefix.length) : name;
  }

  /// Copies [run] with the lookups and quiet gaps cached in [dir] to the
  /// playlist folder, so it survives a reinstall and moves with the
  /// folder. A failure only costs a new scan after a reinstall.
  Future<void> _mirrorRun(
    Track track,
    Directory dir,
    RecognitionRun run,
  ) async {
    try {
      final folder = await _folderOf(track);
      if (folder == null) return;
      final samples = <Map<String, dynamic>>[];
      final sampleDir = Directory(p.join(dir.path, 'samples'));
      if (await sampleDir.exists()) {
        await for (final entity in sampleDir.list()) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          try {
            final json = jsonDecode(await entity.readAsString());
            if (json is Map<String, dynamic>) samples.add(json);
          } catch (_) {
            // A broken entry is looked up again by the next scan.
          }
        }
      }
      final silences = <({int fromMs, int toMs, Object? content})>[];
      final silenceDir = Directory(p.join(dir.path, 'silences'));
      if (await silenceDir.exists()) {
        await for (final entity in silenceDir.list()) {
          if (entity is! File) continue;
          final match = _silenceFileName.firstMatch(p.basename(entity.path));
          if (match == null) continue;
          try {
            silences.add((
              fromMs: int.parse(match.group(1)!),
              toMs: int.parse(match.group(2)!),
              content: jsonDecode(await entity.readAsString()),
            ));
          } catch (_) {
            // Measured again by the next scan.
          }
        }
      }
      await writeRecognitionFile(
        folder,
        track.videoId,
        recognitionFileJson(
          videoId: track.videoId,
          contentKey: _contentKey(track, dir.path),
          run: run.toJson(),
          samples: samples,
          silences: silences,
        ),
      );
    } catch (_) {
      // Kept in the app either way.
    }
  }

  static final _silenceFileName = RegExp(r'^(\d+)-(\d+)\.json$');

  /// Takes over what the playlist folder's copy of a run made from the same
  /// content as [track]'s file holds: its cached lookups and quiet gaps
  /// that this app does not have, and, with [withRun], the run itself under
  /// this track. Returns whether a run was taken over. Never replaces
  /// anything this app already has.
  Future<bool> _adoptFolderCopy(
    Track track,
    String runDirectory, {
    required bool withRun,
  }) async {
    try {
      final folder = await _folderOf(track);
      if (folder == null) return false;
      final copy = await readRecognitionFile(folder, track.videoId);
      if (copy == null || copy.contentKey != _contentKey(track, runDirectory)) {
        return false;
      }
      final RecognitionRun? run;
      if (withRun) {
        run = RecognitionRun.fromJson({
          ...copy.run,
          'trackId': track.id,
          'fileKey': p.basename(runDirectory),
        });
      } else {
        run = null;
      }
      Future<void> writeNew(File file, Object? json) async {
        if (await file.exists()) return;
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(json));
      }

      for (final sample in copy.samples) {
        await writeNew(
          File(
            p.join(runDirectory, 'samples', '${sample['sampleStartMs']}.json'),
          ),
          sample,
        );
      }
      for (final silence in copy.silences) {
        await writeNew(
          File(
            p.join(
              runDirectory,
              'silences',
              '${silence.fromMs}-${silence.toMs}.json',
            ),
          ),
          silence.content,
        );
      }
      if (run == null) return false;
      final runFile = File(p.join(runDirectory, 'run.json'));
      if (await runFile.exists()) return true;
      await writeNew(runFile, run.toJson());
      return true;
    } catch (_) {
      return false;
    }
  }

  String? _filePath(Track track) =>
      track.filePath == null
          ? null
          : MetadataService.resolveStoredFilePath(track.filePath!);

  Future<String> _runDirectory(Track track, String path) async {
    final root = await _rootDirectory();
    return p.join(root.path, 'recognition', await _runKey(track.id, path));
  }

  /// The [RecognitionRun.fileKey] a run made from [path] gets.
  static Future<String> _runKey(int trackId, String path) async =>
      '$trackId-${await fileKey(path)}';

  /// The [RecognitionRun.fileKey] a scan of [track]'s file as it is now
  /// would get, or null when the file is missing or unreadable. A run whose
  /// key differs was made from other content and must not be applied.
  static Future<String?> currentFileKey(Track track) async {
    final stored = track.filePath;
    if (stored == null) return null;
    try {
      final path = MetadataService.resolveStoredFilePath(stored);
      if (path == null || !await File(path).exists()) return null;
      return await _runKey(track.id, path);
    } on FileSystemException {
      return null;
    }
  }

  /// Cheap content key: size plus a hash of the first and last 256 KiB, so a
  /// replaced file never reuses another file's lookups.
  static Future<String> fileKey(String path) async {
    final file = File(path);
    final length = await file.length();
    const chunk = 256 * 1024;
    final head = await file
        .openRead(0, math.min(chunk, length))
        .fold<List<int>>([], (acc, bytes) => acc..addAll(bytes));
    final tail =
        length > chunk
            ? await file
                .openRead(math.max(chunk, length - chunk), length)
                .fold<List<int>>([], (acc, bytes) => acc..addAll(bytes))
            : const <int>[];
    final digest = sha256.convert([...head, ...tail]).toString();
    return '$length-${digest.substring(0, 16)}';
  }

  void _checkCancelled() {
    if (_cancelRequested) throw const RecognitionCancelled();
  }

  void _emit(RecognitionProgress progress) {
    _current = progress;
    if (!_progress.isClosed) _progress.add(progress);
  }
}

/// What [SongRecognitionService.recognizeRange] found in one stretch.
class RangeRecognition {
  final int startMs;
  final int endMs;

  /// Windows planned for the stretch.
  final int sampleCount;

  /// Windows looked up (fewer than [sampleCount] when [limited]).
  final int checkedSamples;
  final List<RangeCandidate> candidates;

  /// Shazam kept rate-limiting, so not every window was checked.
  final bool limited;

  const RangeRecognition({
    required this.startMs,
    required this.endMs,
    required this.sampleCount,
    required this.checkedSamples,
    required this.candidates,
    this.limited = false,
  });

  /// More than one song was heard in the stretch.
  bool get mixed => candidates.length > 1;
}

/// One song recognized in a stretch, with where it matched.
class RangeCandidate {
  final String trackKey;
  final String? artist;
  final String? songTitle;

  /// Starts of the sample windows that matched it, in order.
  final List<int> matchedAtMs;

  /// Where the song itself seems to start in the file, from the catalog's
  /// offsets (median over the reference that explains most samples).
  final int? songStartMs;

  /// At least two samples agree on [songStartMs] within 2 s.
  final bool consistent;

  const RangeCandidate({
    required this.trackKey,
    required this.artist,
    required this.songTitle,
    required this.matchedAtMs,
    this.songStartMs,
    this.consistent = false,
  });

  factory RangeCandidate._fromSamples(
    String key,
    List<RecognitionSample> samples,
  ) {
    final first = samples.first.result;
    final estimatesById = <String, List<double>>{};
    for (final sample in samples) {
      for (final offset in sample.result.offsets) {
        estimatesById
            .putIfAbsent(offset.referenceId, () => [])
            .add(sample.sampleStartMs - offset.offsetSeconds * 1000);
      }
    }
    List<double> estimates = const [];
    for (final list in estimatesById.values) {
      if (list.length > estimates.length) estimates = list;
    }
    int? songStart;
    var consistent = false;
    if (estimates.isNotEmpty) {
      final sorted = [...estimates]..sort();
      final mid = sorted.length ~/ 2;
      songStart =
          (sorted.length.isOdd
                  ? sorted[mid]
                  : (sorted[mid - 1] + sorted[mid]) / 2)
              .round();
      consistent = sorted.length >= 2 && sorted.last - sorted.first <= 2000;
    }
    return RangeCandidate(
      trackKey: key,
      artist: first.artist,
      songTitle: first.title,
      matchedAtMs: [for (final s in samples) s.sampleStartMs],
      songStartMs: songStart,
      consistent: consistent,
    );
  }

  /// The chapter title for this song, written like the scan writes it.
  String get title {
    final song = songTitle?.trim() ?? '';
    final by = artist?.trim() ?? '';
    if (song.isEmpty) return by.isEmpty ? 'Unknown song' : by;
    return by.isEmpty ? song : '$by — $song';
  }
}

/// Retry bookkeeping of one scan's lookups.
class _RetryState {
  /// Rate-limit responses since the last success.
  int rateLimits = 0;

  /// Transient failures since the last success.
  int transientFailures = 0;

  /// When the first rate-limit response since the last success came.
  DateTime? rateLimitedSince;

  void succeeded() {
    rateLimits = 0;
    transientFailures = 0;
    rateLimitedSince = null;
  }
}

/// Helper for tests and tools: builds a window of PCM from a generator.
Int16List pcmFromGenerator(int samples, int Function(int index) generator) {
  final out = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = generator(i);
  }
  return out;
}
