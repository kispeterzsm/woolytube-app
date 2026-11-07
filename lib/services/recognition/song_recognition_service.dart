import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../chapters.dart';
import '../metadata_service.dart';
import '../ytdlp_service.dart';
import 'audio_window_decoder.dart';
import 'chapter_estimator.dart';
import 'shazam_client.dart';
import 'shazam_signature.dart';
import 'silence_detector.dart';

enum RecognitionPhase { sampling, silence, estimating, done, cancelled, failed }

class RecognitionProgress {
  final int trackId;
  final RecognitionPhase phase;
  final int completed;
  final int total;
  final String? message;

  const RecognitionProgress({
    required this.trackId,
    required this.phase,
    this.completed = 0,
    this.total = 0,
    this.message,
  });

  bool get running =>
      phase == RecognitionPhase.sampling ||
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
  });

  RecognitionRun copyWith({List<ChapterProposal>? proposals}) => RecognitionRun(
    runId: runId,
    trackId: trackId,
    fileKey: fileKey,
    epoch: epoch,
    durationMs: durationMs,
    completedAt: completedAt,
    sampleCount: sampleCount,
    matchedSamples: matchedSamples,
    proposals: proposals ?? this.proposals,
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
  );
}

class RecognitionCancelled implements Exception {
  const RecognitionCancelled();
  @override
  String toString() => 'Recognition cancelled';
}

/// Keeps the process alive and visible while a scan runs.
abstract interface class ScanForegroundNotifier {
  Future<void> start(String label);
  Future<void> update(String label, int current, int total);
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
  Future<void> update(String label, int current, int total) async {
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
  }) : _decoder = decoder,
       _recognizer = recognizer,
       _rootDirectory = rootDirectory,
       _notifier = notifier,
       _silence = silenceDetector;

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

  final _progress = StreamController<RecognitionProgress>.broadcast();
  RecognitionProgress? _current;
  bool _cancelRequested = false;

  Stream<RecognitionProgress> get progressStream => _progress.stream;
  RecognitionProgress? get currentProgress => _current;
  bool get isScanning => _current?.running ?? false;
  int? get scanningTrackId => isScanning ? _current!.trackId : null;

  void cancel() {
    if (isScanning) _cancelRequested = true;
  }

  void dispose() {
    _progress.close();
  }

  /// The last completed run for [track], if its file is unchanged.
  Future<RecognitionRun?> loadRun(Track track) async {
    final path = _filePath(track);
    if (path == null) return null;
    final file = File(p.join(await _runDirectory(track, path), 'run.json'));
    if (!await file.exists()) return null;
    try {
      return RecognitionRun.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveRun(RecognitionRun run, Track track) async {
    final path = _filePath(track);
    if (path == null) return;
    final dir = Directory(await _runDirectory(track, path));
    await dir.create(recursive: true);
    await File(
      p.join(dir.path, 'run.json'),
    ).writeAsString(jsonEncode(run.toJson()));
  }

  Future<void> discardRun(Track track) async {
    final path = _filePath(track);
    if (path == null) return;
    final file = File(p.join(await _runDirectory(track, path), 'run.json'));
    if (await file.exists()) await file.delete();
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
    if (isScanning) {
      throw StateError('Another recognition scan is running.');
    }
    final path = _filePath(track);
    if (path == null) {
      throw StateError('The file for "${track.title}" was not found.');
    }
    _cancelRequested = false;
    final label = 'songs in ${track.title}';
    final durationMs = await _durationMs(track, path);
    final dir = Directory(await _runDirectory(track, path));
    await dir.create(recursive: true);
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
      final sampleDir = Directory(p.join(dir.path, 'samples'));
      await sampleDir.create(recursive: true);
      for (var i = 0; i < starts.length; i++) {
        _checkCancelled();
        final startMs = starts[i];
        final cached = File(p.join(sampleDir.path, '$startMs.json'));
        Map<String, dynamic>? raw;
        if (await cached.exists()) {
          try {
            raw =
                jsonDecode(await cached.readAsString()) as Map<String, dynamic>;
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
            result = await _recognizer.recognize(
              ShazamSignatureGenerator.fromSamples(pcm),
            );
          }
          raw = {
            'sampleStartMs': startMs,
            'sampleDurationMs': windowSeconds * 1000,
            'recordedAt': DateTime.now().toUtc().toIso8601String(),
            'response': result.raw,
          };
          await cached.writeAsString(jsonEncode(raw));
        }
        samples.add(
          RecognitionSample(
            sampleStartMs: startMs,
            sampleDurationMs: windowSeconds * 1000,
            result: ShazamResult.fromJson(
              (raw['response'] as Map?)?.cast<String, dynamic>() ?? const {},
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
      final quiet = await _quietIntervals(path, dir, samples, durationMs);

      _emit(
        RecognitionProgress(
          trackId: track.id,
          phase: RecognitionPhase.estimating,
        ),
      );
      final runId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
      final proposals = ChapterEstimator.estimate(
        runName: 'r$runId',
        durationMs: durationMs,
        samples: samples,
        quietIntervals: quiet,
      );
      final fresh = await _db.getTrack(track.id);
      final epoch = ChapterData.decode(fresh?.chaptersJson).recognitionEpoch;
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
      );
      await File(
        p.join(dir.path, 'run.json'),
      ).writeAsString(jsonEncode(run.toJson()));
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
    int durationMs,
  ) async {
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
          intervals = [
            for (final s in jsonDecode(await cached.readAsString()) as List)
              ((s[0] as num).toDouble(), (s[1] as num).toDouble()),
          ];
        } catch (_) {
          intervals = null;
        }
      }
      if (intervals == null) {
        final pcm = await _decoder.decode(
          path,
          start: Duration(milliseconds: from),
          duration: Duration(milliseconds: to - from),
        );
        intervals = _silence.detect(pcm, offset: Duration(milliseconds: from));
        await cached.writeAsString(
          jsonEncode([
            for (final s in intervals) [s.$1, s.$2],
          ]),
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

  Future<int> _durationMs(Track track, String path) async {
    final probed = await _decoder.probeDuration(path);
    if (probed != null && probed > Duration.zero) return probed.inMilliseconds;
    final stored = ChapterData.decode(track.chaptersJson);
    if (stored.valid && (stored.durationMs ?? 0) > 0) return stored.durationMs!;
    if ((track.durationSeconds ?? 0) > 0) return track.durationSeconds! * 1000;
    throw StateError('Could not determine the duration of "${track.title}".');
  }

  String? _filePath(Track track) =>
      track.filePath == null
          ? null
          : MetadataService.resolveStoredFilePath(track.filePath!);

  Future<String> _runDirectory(Track track, String path) async {
    final root = await _rootDirectory();
    return p.join(
      root.path,
      'recognition',
      '${track.id}-${await fileKey(path)}',
    );
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

/// Helper for tests and tools: builds a window of PCM from a generator.
Int16List pcmFromGenerator(int samples, int Function(int index) generator) {
  final out = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = generator(i);
  }
  return out;
}
