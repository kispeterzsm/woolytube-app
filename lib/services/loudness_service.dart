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

/// Whether the phone is on a charger, from the yt-dlp plugin. Plugged in
/// counts even when the battery is not filling (a charge limit such as
/// ASUS's steady charging holds it). True when it cannot be told, so
/// measuring is not held back for good.
Future<bool> platformIsPluggedIn() async {
  try {
    return await const MethodChannel(
          'com.woolytube/ytdlp',
        ).invokeMethod<bool>('isPluggedIn') ??
        true;
  } catch (_) {
    return true;
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

  /// Turns measuring on while a setting needs loudness, off otherwise.
  void setEnabled(bool enabled);

  /// Each file whose new measurement was just stored.
  Stream<LoudnessJob> get measuredFiles;
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

  /// Songs whose file could not be measured this session. They are not
  /// tried again until "Measure now" or the next start.
  final int failed;

  /// Whether songs are being measured right now.
  final bool working;

  /// Songs are left to measure, but the library is only measured while the
  /// phone charges and it does not.
  final bool waitingForCharger;

  /// Measuring waits while the library moves or deletes files.
  final bool waitingForLibrary;

  /// "Measure now": the whole library is measured, charger or not.
  final bool forced;

  const LoudnessProgress({
    this.measured = 0,
    this.total = 0,
    this.failed = 0,
    this.working = false,
    this.waitingForCharger = false,
    this.waitingForLibrary = false,
    this.forced = false,
  });

  static const unknown = LoudnessProgress();

  /// Songs left that could still be measured (or tried again).
  bool get hasWorkLeft => measured < total;

  LoudnessProgress copyWith({
    int? measured,
    int? failed,
    bool? working,
    bool? waitingForCharger,
    bool? waitingForLibrary,
    bool? forced,
  }) => LoudnessProgress(
    measured: measured ?? this.measured,
    total: total,
    failed: failed ?? this.failed,
    working: working ?? this.working,
    waitingForCharger: waitingForCharger ?? this.waitingForCharger,
    waitingForLibrary: waitingForLibrary ?? this.waitingForLibrary,
    forced: forced ?? this.forced,
  );

  @override
  bool operator ==(Object other) =>
      other is LoudnessProgress &&
      other.measured == measured &&
      other.total == total &&
      other.failed == failed &&
      other.working == working &&
      other.waitingForCharger == waitingForCharger &&
      other.waitingForLibrary == waitingForLibrary &&
      other.forced == forced;

  @override
  int get hashCode => Object.hash(
    measured,
    total,
    failed,
    working,
    waitingForCharger,
    waitingForLibrary,
    forced,
  );

  @override
  String toString() =>
      'LoudnessProgress($measured/$total, failed: $failed, '
      'working: $working, waitingForCharger: $waitingForCharger, '
      'waitingForLibrary: $waitingForLibrary, forced: $forced)';
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
/// playing and the next ones are measured right away. The rest of the
/// library is measured one song at a time, by default only while the phone
/// is plugged in: decoding thousands of songs costs real battery, and the
/// player asks for each song before it is needed anyway. [measureNow]
/// measures it all regardless, and [setOnlyWhileCharging] drops the rule.
/// Measuring also waits while the library moves or deletes files.
/// Measurements are stored per track with the file's path, size and
/// modification time; a replaced or moved file is measured again.
///
/// A file that does not answer within [analyzeTimeout] counts as failed,
/// and an error anywhere restarts measuring after [retryAfterError], so
/// measuring never stays stuck for the rest of the session.
class LoudnessService implements TrackLoudnessSource {
  LoudnessService(
    this._db, {
    LoudnessAnalyzer analyzer = const PlatformLoudnessAnalyzer(),
    LogService? log,
    bool Function()? shouldPause,
    Future<bool> Function()? isCharging,
    bool onlyWhileCharging = true,
    Duration pauseBetween = const Duration(milliseconds: 500),
    Duration pausePoll = const Duration(seconds: 5),
    Duration chargerPoll = const Duration(minutes: 5),
    Duration analyzeTimeout = const Duration(minutes: 20),
    Duration retryAfterError = const Duration(minutes: 1),
  }) : _analyzer = analyzer,
       _log = log,
       _shouldPause = shouldPause,
       _isCharging = isCharging ?? platformIsPluggedIn,
       _onlyWhileCharging = onlyWhileCharging,
       _pauseBetween = pauseBetween,
       _pausePoll = pausePoll,
       _chargerPoll = chargerPoll,
       _analyzeTimeout = analyzeTimeout,
       _retryAfterError = retryAfterError;

  final AppDatabase _db;
  final LoudnessAnalyzer _analyzer;
  final LogService? _log;
  final bool Function()? _shouldPause;
  final Future<bool> Function() _isCharging;
  final Duration _pauseBetween;
  final Duration _pausePoll;
  final Duration _chargerPoll;

  /// The plugin gives up on a file after 15 minutes; this is the backstop
  /// should it never answer at all.
  final Duration _analyzeTimeout;
  final Duration _retryAfterError;

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

  final _measured = StreamController<LoudnessJob>.broadcast();

  var _enabled = false;
  var _running = false;

  /// Asked to start while running: the loop may have decided to stop just
  /// before, so it looks again once it ends.
  var _kickPending = false;
  var _disposed = false;
  var _platformMissing = false;
  bool _onlyWhileCharging;

  /// "Measure now": the library is measured whether charging or not, until
  /// it is done or stopped.
  var _forced = false;

  /// Starts measuring again later: to look whether the phone is charging
  /// while the library waits, or after an error.
  Timer? _wake;

  /// Bumped whenever the backlog is thrown away, so a scan that finishes
  /// late does not bring back an outdated list.
  var _scanGeneration = 0;

  /// Progress of measuring the library.
  Stream<LoudnessProgress> get progressStream => _progress.stream.distinct();
  LoudnessProgress get progress => _progress.value;

  bool get enabled => _enabled;

  bool get onlyWhileCharging => _onlyWhileCharging;

  @override
  Stream<LoudnessJob> get measuredFiles => _measured.stream;

  @override
  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) return;
    _enabled = enabled;
    if (enabled) {
      _invalidateBacklog();
      _kick();
    } else {
      _priority.clear();
      _invalidateBacklog();
      _cancelWake();
      _setForced(false);
      _publish(
        working: false,
        waitingForCharger: false,
        waitingForLibrary: false,
      );
    }
  }

  /// Whether the library (beyond the songs the player asks for) is only
  /// measured while the phone is plugged in.
  void setOnlyWhileCharging(bool value) {
    if (_disposed || _onlyWhileCharging == value) return;
    _onlyWhileCharging = value;
    _log?.info('loudness: only while charging: $value');
    if (!value) {
      _cancelWake();
      _publish(waitingForCharger: false);
    }
    _kick();
  }

  /// Measures the whole library now, on battery too, until it is done or
  /// [stopMeasuringNow]. Files that failed this session are tried again.
  void measureNow() {
    if (_disposed || !_enabled) return;
    _log?.info('loudness: measure now');
    _failed.clear();
    _publish(failed: 0, waitingForCharger: false);
    _setForced(true);
    _cancelWake();
    _invalidateBacklog();
    _kick();
  }

  /// Ends [measureNow]: the library goes back to the charging rule.
  void stopMeasuringNow() {
    if (_disposed || !_forced) return;
    _log?.info('loudness: measure now stopped');
    _setForced(false);
  }

  void _setForced(bool value) {
    _forced = value;
    _publish(forced: value);
  }

  void _cancelWake() {
    _wake?.cancel();
    _wake = null;
  }

  void _wakeAfter(Duration delay) {
    _wake?.cancel();
    _wake = Timer(delay, () {
      _wake = null;
      _kick();
    });
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
    if (_disposed || !_enabled || _platformMissing) return;
    if (_running) {
      _kickPending = true;
      return;
    }
    _running = true;
    _kickPending = false;
    unawaited(_run());
  }

  Future<void> _run() async {
    var failed = false;
    try {
      while (_enabled && !_disposed && !_platformMissing) {
        // Files may have been moved or renamed while the library was busy,
        // so a list made before that is thrown away.
        if (await _waitWhilePaused()) _invalidateBacklog();
        if (!_enabled || _disposed) break;
        final job = await _nextJob();
        if (job == null) break;
        if (_isPaused) {
          // The library got busy meanwhile: ask for this file again later.
          _priority.insert(0, job);
          continue;
        }
        _publish(working: true);
        await _measure(job);
        if (_pauseBetween > Duration.zero) {
          await Future<void>.delayed(_pauseBetween);
        }
      }
    } catch (e) {
      // Started again later rather than never: the cause may well pass (a
      // busy database, a scan that failed).
      failed = true;
      _log?.warn('loudness: measuring stopped, retrying later: $e');
      if (!_disposed) _wakeAfter(_retryAfterError);
    } finally {
      _running = false;
      if (!_disposed) _publish(working: false);
    }
    // Work that arrived after the last check. After an error the retry
    // timer starts again instead, so a lasting error does not spin.
    if (!failed && (_kickPending || _priority.isNotEmpty)) _kick();
  }

  bool get _isPaused => _shouldPause?.call() ?? false;

  /// Waits while the library moves or deletes files. Returns whether it
  /// had to wait.
  Future<bool> _waitWhilePaused() async {
    var waited = false;
    while (_enabled && !_disposed && _isPaused) {
      if (!waited) _publish(waitingForLibrary: true);
      waited = true;
      await Future<void>.delayed(_pausePoll);
    }
    if (waited && !_disposed) _publish(waitingForLibrary: false);
    return waited;
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
      final current = _progress.value;
      _progress.add(
        LoudnessProgress(
          measured: scan.measured,
          total: scan.total,
          failed: _failed.length,
          working: current.working,
          waitingForCharger: current.waitingForCharger,
          forced: _forced,
        ),
      );
      _log?.info(
        'loudness: ${scan.measured} of ${scan.total} songs measured, '
        '${_failed.length} failed',
      );
    }
    // Player requests may have arrived while scanning.
    if (_priority.isNotEmpty) return _nextJob();
    if (backlog.isEmpty) return _libraryDone();
    if (_onlyWhileCharging && !_forced && !await _charging()) {
      if (!_progress.value.waitingForCharger) {
        _log?.info('loudness: waiting for the charger');
      }
      _publish(waitingForCharger: true);
      _wakeAfter(_chargerPoll);
      return _priority.isNotEmpty ? _nextJob() : null;
    }
    _publish(waitingForCharger: false);
    while (backlog.isNotEmpty) {
      final job = backlog.removeAt(0);
      // It may have been measured on the player's request meanwhile.
      if (await _needsMeasuring(job)) return job;
      if (!_enabled || _disposed || _priority.isNotEmpty) break;
    }
    if (_priority.isNotEmpty) return _nextJob();
    return backlog.isEmpty ? _libraryDone() : null;
  }

  /// Nothing is left to measure in the library.
  LoudnessJob? _libraryDone() {
    if (_forced) {
      _log?.info('loudness: measure now finished');
      _setForced(false);
    }
    _publish(waitingForCharger: false);
    return null;
  }

  Future<bool> _charging() async {
    try {
      return await _isCharging();
    } catch (_) {
      return true;
    }
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
      loudness = await _analyzer.analyze(job.path).timeout(_analyzeTimeout);
    } on MissingPluginException {
      // Not on Android (or the plugin is missing): nothing can be measured.
      _platformMissing = true;
      _log?.warn('loudness: measuring is not available on this platform');
      return;
    } catch (e) {
      // Also a file the plugin never answered for.
      _failed[job.trackId] = job.path;
      _publish(failed: _failed.length);
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
      _progress.add(current.copyWith(measured: current.measured + 1));
    }
    // An earlier file of the track failed; this one did not.
    if (_failed.remove(job.trackId) != null) {
      _publish(failed: _failed.length);
    }
    if (!_measured.isClosed) _measured.add(job);
  }

  void _publish({
    int? failed,
    bool? working,
    bool? waitingForCharger,
    bool? waitingForLibrary,
    bool? forced,
  }) {
    if (_progress.isClosed) return;
    final current = _progress.value;
    final next = current.copyWith(
      failed: failed,
      working: working,
      waitingForCharger: waitingForCharger,
      waitingForLibrary: waitingForLibrary,
      forced: forced,
    );
    if (next != current) _progress.add(next);
  }

  void dispose() {
    _disposed = true;
    _cancelWake();
    _priority.clear();
    _backlog = null;
    _progress.close();
    _measured.close();
  }
}
