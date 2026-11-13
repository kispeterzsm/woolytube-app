import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What the scheduled update remembers about one playlist between runs.
class AutoUpdateAttempt {
  const AutoUpdateAttempt({
    this.at,
    this.unreachable = 0,
    this.failureKeys = const {},
  });

  /// When a scheduled run last picked the playlist up.
  final DateTime? at;

  /// Scheduled runs in a row, the last one at [at], whose update did not
  /// count because YouTube could not be reached (no network, or the
  /// playlist could not be listed). Spaces out the next tries, see
  /// [autoUpdateRetryDelay].
  final int unreachable;

  /// The failed downloads of the playlist's last scheduled run, as
  /// `DownloadFailure.key`s. A failure that is among them was already told
  /// about and is not notified again.
  final Set<String> failureKeys;

  AutoUpdateAttempt copyWith({
    DateTime? at,
    int? unreachable,
    Set<String>? failureKeys,
  }) => AutoUpdateAttempt(
    at: at ?? this.at,
    unreachable: unreachable ?? this.unreachable,
    failureKeys: failureKeys ?? this.failureKeys,
  );

  Map<String, Object?> toJson() => {
    if (at != null) 'at': at!.toIso8601String(),
    if (unreachable > 0) 'unreachable': unreachable,
    if (failureKeys.isNotEmpty) 'failed': failureKeys.toList(),
  };

  /// Reads an entry; a bare time string is the file's first format.
  static AutoUpdateAttempt? fromJson(Object? value) {
    if (value is String) {
      final at = DateTime.tryParse(value);
      return at == null ? null : AutoUpdateAttempt(at: at);
    }
    if (value is! Map) return null;
    final at = value['at'];
    final unreachable = value['unreachable'];
    final failed = value['failed'];
    return AutoUpdateAttempt(
      at: at is String ? DateTime.tryParse(at) : null,
      unreachable: unreachable is int && unreachable > 0 ? unreachable : 0,
      failureKeys: {
        if (failed is List)
          for (final key in failed)
            if (key is String) key,
      },
    );
  }
}

/// How long the scheduled update waits before trying a playlist again
/// after [unreachable] runs in a row could not reach YouTube for it: 1 hour,
/// then 2, 4, 8 ... but never longer than the playlist's own [interval].
Duration autoUpdateRetryDelay(int unreachable, Duration interval) {
  if (unreachable <= 0) return Duration.zero;
  final delay = Duration(hours: 1 << math.min(unreachable - 1, 16));
  return delay < interval ? delay : interval;
}

/// What the scheduled update remembers per playlist (see
/// [AutoUpdateAttempt]). Kept in a small file because the app engine and
/// the headless engine both read it, and SharedPreferences caches values
/// per engine.
class AutoUpdateAttemptLog {
  AutoUpdateAttemptLog({Future<String> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const fileName = 'auto_update_attempts.json';

  final Future<String> Function() _directoryProvider;

  static Future<String> _defaultDirectory() async =>
      (await getApplicationDocumentsDirectory()).path;

  Future<File> _file() async =>
      File(p.join(await _directoryProvider(), fileName));

  Future<Map<int, AutoUpdateAttempt>> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      final result = <int, AutoUpdateAttempt>{};
      decoded.forEach((key, value) {
        final id = int.tryParse('$key');
        final attempt = AutoUpdateAttempt.fromJson(value);
        if (id != null && attempt != null) result[id] = attempt;
      });
      return result;
    } catch (_) {
      // A damaged file only loses the rotation order, the back-off and
      // which failures were already told about.
      return {};
    }
  }

  /// Replaces the whole log.
  Future<void> save(Map<int, AutoUpdateAttempt> attempts) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          for (final entry in attempts.entries)
            '${entry.key}': entry.value.toJson(),
        }),
        flush: true,
      );
    } catch (_) {
      // Not worth failing an update over.
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
    final attempts = await read();
    attempts[playlistId] = (attempts[playlistId] ?? const AutoUpdateAttempt())
        .copyWith(at: at);
    if (knownIds != null) {
      final keep = {...knownIds, playlistId};
      attempts.removeWhere((id, _) => !keep.contains(id));
    }
    await save(attempts);
  }

  /// Records how the scheduled update of [playlistId] went: [updated] when
  /// it counted (YouTube was reached), otherwise one more unreachable run.
  Future<void> recordOutcome(int playlistId, {required bool updated}) async {
    final attempts = await read();
    final attempt = attempts[playlistId] ?? const AutoUpdateAttempt();
    final unreachable = updated ? 0 : attempt.unreachable + 1;
    if (unreachable == attempt.unreachable &&
        attempts.containsKey(playlistId)) {
      return;
    }
    attempts[playlistId] = attempt.copyWith(unreachable: unreachable);
    await save(attempts);
  }

  /// Remembers [keys] as the failures of [playlistId]'s scheduled run that
  /// just ended, and returns those that the previous scheduled run did not
  /// have: the ones worth telling about.
  Future<Set<String>> takeNewFailures(
    int playlistId,
    Iterable<String> keys,
  ) async {
    final current = keys.toSet();
    final attempts = await read();
    final attempt = attempts[playlistId] ?? const AutoUpdateAttempt();
    final previous = attempt.failureKeys;
    if (previous.length != current.length || !previous.containsAll(current)) {
      attempts[playlistId] = attempt.copyWith(failureKeys: current);
      await save(attempts);
    }
    return current.difference(previous);
  }
}
