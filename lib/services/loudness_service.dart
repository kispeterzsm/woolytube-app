import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

import '../database/database.dart';
import 'audio_processing.dart';
import 'log_service.dart';
import 'metadata_service.dart';

/// Measures how loud a media file is.
abstract interface class LoudnessAnalyzer {
  /// Decodes the whole file at [path] and measures it. Throws when the file
  /// cannot be decoded.
  Future<MeasuredLoudness> analyze(String path);
}

/// Measures on the device with the yt-dlp plugin's decoder and EBU R128
/// meter. A 4-minute song takes a few seconds on a phone.
class PlatformLoudnessAnalyzer implements LoudnessAnalyzer {
  const PlatformLoudnessAnalyzer();

  static const _channel = MethodChannel('com.woolytube/ytdlp');

  @override
  Future<MeasuredLoudness> analyze(String path) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'analyzeLoudness',
      {'path': path},
    );
    if (result == null) throw StateError('No loudness result for $path');
    return measuredLoudnessFromMap(result);
  }
}

/// Reads the plugin's reply. Missing or non-finite numbers read as unknown.
MeasuredLoudness measuredLoudnessFromMap(Map<String, Object?> map) {
  double? number(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;
  return MeasuredLoudness(
    integratedLufs: number(map['integratedLufs']),
    cabinLufs: number(map['cabinLufs']),
    peakDb: number(map['peakDb']),
  );
}

/// Where the player gets measured loudness from.
abstract interface class TrackLoudnessSource {
  /// The stored measurement of the file at [path] for [trackId], or null
  /// when it was not measured or the file changed since.
  Future<MeasuredLoudness?> loudnessFor(int trackId, String path);

  /// Measures these files first, in order (the song that is playing, then
  /// the next ones). Ignored while measuring is off.
  void prioritize(List<LoudnessJob> files);
}

/// A file to measure for a track.
class LoudnessJob {
  final int trackId;
  final String path;

  const LoudnessJob(this.trackId, this.path);

  @override
  bool operator ==(Object other) =>
      other is LoudnessJob && other.trackId == trackId && other.path == path;

  @override
  int get hashCode => Object.hash(trackId, path);

  @override
  String toString() => 'LoudnessJob($trackId, $path)';
}

/// How far measuring the library has come, for the settings page.
class LoudnessProgress {
  /// Downloaded songs whose current file has a measurement.
  final int measured;

  /// Downloaded songs with a file on disk.
  final int total;

  /// Whether songs are being measured right now.
  final bool working;

  const LoudnessProgress({
    this.measured = 0,
    this.total = 0,
    this.working = false,
  });

  static const unknown = LoudnessProgress();

  @override
  bool operator ==(Object other) =>
      other is LoudnessProgress &&
      other.measured == measured &&
      other.total == total &&
      other.working == working;

  @override
  int get hashCode => Object.hash(measured, total, working);

  @override
  String toString() => 'LoudnessProgress($measured/$total, working: $working)';
}

/// Size and modification time of a file, to tell whether a measurement
/// still belongs to it.
class _FileSignature {
  final int size;
  final int modifiedMs;

  const _FileSignature(this.size, this.modifiedMs);

  bool matches(LoudnessMeasurement row, String path) =>
      row.filePath == path &&
      row.fileSize == size &&
      row.fileModifiedMs == modifiedMs;
}

Future<_FileSignature?> _signatureOf(String path) async {
  try {
    final stat = await File(path).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return _FileSignature(stat.size, stat.modified.millisecondsSinceEpoch);
  } catch (_) {
    return null;
  }
}

/// A downloaded track as the library scan sees it.
typedef _StoredFile = ({int trackId, String storedPath});

/// The stored measurement of a track, as the library scan sees it.
typedef _StoredMeasurement = ({String path, int size, int modifiedMs});

/// Result of the library scan: files that need measuring (in library
/// order), and how many downloaded songs there are and are measured.
typedef _ScanResult = ({List<LoudnessJob> todo, int total, int measured});

/// Runs in a separate isolate: resolving thousands of stored paths and
/// reading their file sizes must not stall the UI.
_ScanResult _scanLibrary(
  List<_StoredFile> files,
  Map<int, _StoredMeasurement> measurements,
) {
  final todo = <LoudnessJob>[];
  var total = 0;
  var measured = 0;
  for (final file in files) {
    final path = MetadataService.resolveStoredFilePath(file.storedPath);
    if (path == null) continue;
    final FileStat stat;
    try {
      stat = File(path).statSync();
    } catch (_) {
      continue;
    }
    if (stat.type != FileSystemEntityType.file) continue;
    total++;
    final stored = measurements[file.trackId];
    if (stored != null &&
        stored.path == path &&
        stored.size == stat.size &&
        stored.modifiedMs == stat.modified.millisecondsSinceEpoch) {
      measured++;
    } else {
      todo.add(LoudnessJob(file.trackId, path));
    }
  }
  return (todo: todo, total: total, measured: measured);
}

/// Measures songs' loudness in the background for plane mode and "Even out
/// volume", and hands the stored measurements to the player.
///
/// Nothing is measured while both are off. When one is on, the song that is
/// playing and the next ones come first, then every other downloaded song,
/// one at a time with a short pause in between, so a phone on battery is
/// not kept busy. Measurements are stored per track with the file's size
/// and modification time; a replaced file is measured again.
class LoudnessService implements TrackLoudnessSource {
  LoudnessService(
    this._db, {
    LoudnessAnalyzer analyzer = const PlatformLoudnessAnalyzer(),
    LogService? log,
    bool Function()? shouldPause,
    Duration pauseBetween = const Duration(milliseconds: 500),
    Duration pausePoll = const Duration(seconds: 5),
  }) : _analyzer = analyzer,
       _log = log,
       _shouldPause = shouldPause,
       _pauseBetween = pauseBetween,
       _pausePoll = pausePoll;

  final AppDatabase _db;
  final LoudnessAnalyzer _analyzer;
  final LogService? _log;
  final bool Function()? _shouldPause;
  final Duration _pauseBetween;
  final Duration _pausePoll;

  final _progress = BehaviorSubject<LoudnessProgress>.seeded(
    LoudnessProgress.unknown,
  );

  /// Files asked for by the player, most urgent first.
  final _priority = <LoudnessJob>[];

  /// The rest of the library still to measure; null until scanned.
  List<LoudnessJob>? _backlog;

  /// Files that failed this session (by track), with the path that failed,
  /// so a broken file is not decoded over and over.
  final _failed = <int, String>{};

  var _enabled = false;
  var _running = false;
  var _disposed = false;
  var _platformMissing = false;

  /// Bumped whenever the backlog is thrown away, so a scan that finishes
  /// late does not bring back an outdated list.
  var _scanGeneration = 0;

  /// Progress of measuring the library.
  Stream<LoudnessProgress> get progressStream => _progress.stream.distinct();
  LoudnessProgress get progress => _progress.value;

  bool get enabled => _enabled;

  /// Turns background measuring on or off.
  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) return;
    _enabled = enabled;
    if (enabled) {
      _invalidateBacklog();
      _kick();
    } else {
      _priority.clear();
      _invalidateBacklog();
      _publish(working: false);
    }
  }

  /// Looks for unmeasured songs again, for example after downloads finished.
  void rescan() {
    if (_disposed || !_enabled) return;
    _invalidateBacklog();
    _kick();
  }

  @override
  void prioritize(List<LoudnessJob> files) {
    if (_disposed || !_enabled || files.isEmpty) return;
    final wanted = [
      for (final job in files)
        if (_failed[job.trackId] != job.path) job,
    ];
    _priority.removeWhere(wanted.contains);
    _priority.insertAll(0, wanted);
    _kick();
  }

  @override
  Future<MeasuredLoudness?> loudnessFor(int trackId, String path) async {
    if (_disposed) return null;
    final signature = await _signatureOf(path);
    if (signature == null) return null;
    final LoudnessMeasurement? row;
    try {
      row = await _db.getLoudnessMeasurement(trackId);
    } catch (_) {
      return null;
    }
    if (row == null || !signature.matches(row, path)) return null;
    return MeasuredLoudness(
      integratedLufs: row.integratedLufs,
      cabinLufs: row.cabinLufs,
      peakDb: row.peakDb,
    );
  }

  void _invalidateBacklog() {
    _backlog = null;
    _scanGeneration++;
  }

  void _kick() {
    if (_running || _disposed || !_enabled || _platformMissing) return;
    _running = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      while (_enabled && !_disposed && !_platformMissing) {
        final job = await _nextJob();
        if (job == null) break;
        await _waitWhilePaused();
        if (!_enabled || _disposed) break;
        _publish(working: true);
        await _measure(job);
        if (_pauseBetween > Duration.zero) {
          await Future<void>.delayed(_pauseBetween);
        }
      }
    } catch (e) {
      _log?.warn('loudness: measuring stopped: $e');
    } finally {
      _running = false;
      if (!_disposed) _publish(working: false);
    }
    // Work that arrived after the last check.
    if (_enabled && !_disposed && !_platformMissing && _priority.isNotEmpty) {
      _kick();
    }
  }

  Future<void> _waitWhilePaused() async {
    while (_enabled && !_disposed && (_shouldPause?.call() ?? false)) {
      await Future<void>.delayed(_pausePoll);
    }
  }

  Future<LoudnessJob?> _nextJob() async {
    while (_priority.isNotEmpty) {
      final job = _priority.removeAt(0);
      if (await _needsMeasuring(job)) return job;
    }
    var backlog = _backlog;
    if (backlog == null) {
      final generation = _scanGeneration;
      final scan = await _scan();
      if (_disposed || !_enabled) return null;
      // Thrown away while scanning: scan again.
      if (generation != _scanGeneration) return _nextJob();
      backlog = _backlog = scan.todo;
      _progress.add(
        LoudnessProgress(
          measured: scan.measured,
          total: scan.total,
          working: scan.todo.isNotEmpty,
        ),
      );
    }
    // Player requests may have arrived while scanning.
    if (_priority.isNotEmpty) return _nextJob();
    while (backlog.isNotEmpty) {
      final job = backlog.removeAt(0);
      // It may have been measured on the player's request meanwhile.
      if (await _needsMeasuring(job)) return job;
      if (!_enabled || _disposed || _priority.isNotEmpty) break;
    }
    return _priority.isNotEmpty ? _nextJob() : null;
  }

  /// Whether [job]'s file exists and has no measurement of its current
  /// contents (a silent file's empty measurement counts as one).
  Future<bool> _needsMeasuring(LoudnessJob job) async {
    if (_failed[job.trackId] == job.path) return false;
    final signature = await _signatureOf(job.path);
    if (signature == null) return false;
    final LoudnessMeasurement? row;
    try {
      row = await _db.getLoudnessMeasurement(job.trackId);
    } catch (_) {
      return false;
    }
    return row == null || !signature.matches(row, job.path);
  }

  Future<_ScanResult> _scan() async {
    final tracks = await _db.getAllTracks();
    final files = <_StoredFile>[
      for (final track in tracks)
        if (track.status == 'complete' && track.filePath != null)
          (trackId: track.id, storedPath: track.filePath!),
    ];
    final measurements = <int, _StoredMeasurement>{
      for (final row in (await _db.getLoudnessMeasurements()).values)
        row.trackId: (
          path: row.filePath,
          size: row.fileSize,
          modifiedMs: row.fileModifiedMs,
        ),
    };
    return Isolate.run(() => _scanLibrary(files, measurements));
  }

  Future<void> _measure(LoudnessJob job) async {
    final before = await _signatureOf(job.path);
    if (before == null) return;
    final MeasuredLoudness loudness;
    try {
      loudness = await _analyzer.analyze(job.path);
    } on MissingPluginException {
      // Not on Android (or the plugin is missing): nothing can be measured.
      _platformMissing = true;
      return;
    } catch (e) {
      _failed[job.trackId] = job.path;
      _log?.warn('loudness: could not measure ${job.path}: $e');
      return;
    }
    // The file may have been replaced while it was read.
    final after = await _signatureOf(job.path);
    if (after == null ||
        after.size != before.size ||
        after.modifiedMs != before.modifiedMs) {
      return;
    }
    try {
      await _db.saveLoudnessMeasurement(
        LoudnessMeasurementsCompanion.insert(
          trackId: Value(job.trackId),
          filePath: job.path,
          fileSize: after.size,
          fileModifiedMs: after.modifiedMs,
          integratedLufs: Value(loudness.integratedLufs),
          cabinLufs: Value(loudness.cabinLufs),
          peakDb: Value(loudness.peakDb),
          measuredAt: DateTime.now(),
        ),
      );
    } catch (e) {
      // The track was deleted meanwhile.
      _log?.warn('loudness: could not store ${job.path}: $e');
      return;
    }
    final current = _progress.value;
    if (current.total > 0 && current.measured < current.total) {
      _progress.add(
        LoudnessProgress(
          measured: current.measured + 1,
          total: current.total,
          working: true,
        ),
      );
    }
  }

  void _publish({required bool working}) {
    if (_progress.isClosed) return;
    final current = _progress.value;
    if (current.working != working) {
      _progress.add(
        LoudnessProgress(
          measured: current.measured,
          total: current.total,
          working: working,
        ),
      );
    }
  }

  void dispose() {
    _disposed = true;
    _priority.clear();
    _backlog = null;
    _progress.close();
  }
}
