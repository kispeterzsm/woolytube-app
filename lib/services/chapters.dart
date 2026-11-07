import 'dart:convert';

enum ChapterOrigin { original, auto, user }

/// A named range on the unchanged source file's timeline.
class MediaChapter {
  final String id;
  final String title;
  final int startMs;
  final int endMs;
  final ChapterOrigin origin;
  final bool manuallyEdited;
  final List<String> alternativeTitles;
  final List<String> reviewReasons;

  const MediaChapter({
    required this.id,
    required this.title,
    required this.startMs,
    required this.endMs,
    this.origin = ChapterOrigin.user,
    this.manuallyEdited = false,
    this.alternativeTitles = const [],
    this.reviewReasons = const [],
  });

  bool get protectedFromRecognition =>
      origin != ChapterOrigin.auto || manuallyEdited;
  String get originLabel => switch (origin) {
    ChapterOrigin.original => 'Original',
    ChapterOrigin.auto => 'Auto',
    ChapterOrigin.user => 'User-created',
  };
  MediaChapter copyWith({
    String? id,
    String? title,
    int? startMs,
    int? endMs,
    ChapterOrigin? origin,
    bool? manuallyEdited,
    List<String>? alternativeTitles,
    List<String>? reviewReasons,
  }) => MediaChapter(
    id: id ?? this.id,
    title: title ?? this.title,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    origin: origin ?? this.origin,
    manuallyEdited: manuallyEdited ?? this.manuallyEdited,
    alternativeTitles: alternativeTitles ?? this.alternativeTitles,
    reviewReasons: reviewReasons ?? this.reviewReasons,
  );

  Duration get duration => Duration(milliseconds: endMs - startMs);

  /// Fields still at the value [parse] would read back are left out, so a
  /// chapter nobody recognized or edited is stored exactly as before song
  /// recognition existed (smaller sidecars, nothing for older versions or
  /// the PC tool to trip over). [impliedOrigin] is the origin [parse] infers
  /// for this chapter's list when the key is missing.
  Map<String, dynamic> toJson({ChapterOrigin? impliedOrigin}) => {
    'id': id,
    'title': title,
    'startMs': startMs,
    'endMs': endMs,
    if (origin != impliedOrigin) 'origin': origin.name,
    if (manuallyEdited) 'manuallyEdited': true,
    if (alternativeTitles.isNotEmpty) 'alternativeTitles': alternativeTitles,
    if (reviewReasons.isNotEmpty) 'reviewReasons': reviewReasons,
  };

  static List<MediaChapter> parse(
    Object? value, {
    ChapterOrigin fallbackOrigin = ChapterOrigin.user,
    List<MediaChapter> originals = const [],
  }) {
    if (value is! List) return [];
    try {
      final result =
          value.map((entry) {
              final m = entry as Map;
              final original =
                  originals.where((c) => c.id == m['id']).firstOrNull;
              final origin =
                  ChapterOrigin.values
                      .where((o) => o.name == m['origin'])
                      .firstOrNull ??
                  (original == null ? fallbackOrigin : ChapterOrigin.original);
              final editedLegacy =
                  original != null &&
                  (original.title != m['title'] ||
                      original.startMs != m['startMs'] ||
                      original.endMs != m['endMs']);
              return MediaChapter(
                id: m['id'] as String,
                title: m['title'] as String,
                startMs: m['startMs'] as int,
                endMs: m['endMs'] as int,
                origin: origin,
                manuallyEdited: m['manuallyEdited'] == true || editedLegacy,
                alternativeTitles:
                    (m['alternativeTitles'] as List?)
                        ?.whereType<String>()
                        .toList() ??
                    const [],
                reviewReasons:
                    (m['reviewReasons'] as List?)
                        ?.whereType<String>()
                        .toList() ??
                    const [],
              );
            }).toList()
            ..sort((a, b) => a.startMs.compareTo(b.startMs));
      validateChapters(result);
      // Decoded chapter data is cached and shared, so it must not change.
      return List.unmodifiable(result);
    } catch (_) {
      return [];
    }
  }
}

void validateChapters(List<MediaChapter> chapters, {int? durationMs}) {
  var previousEnd = 0;
  final ids = <String>{};
  for (final chapter in chapters) {
    if (chapter.id.isEmpty ||
        !ids.add(chapter.id) ||
        chapter.title.trim().isEmpty) {
      throw const FormatException(
        'Each chapter needs a title and a unique ID.',
      );
    }
    if (chapter.startMs < 0 || chapter.endMs <= chapter.startMs) {
      throw const FormatException('The end must be after the start.');
    }
    if (chapter.startMs < previousEnd) {
      throw const FormatException(
        'Chapters cannot overlap. Edit the existing chapter first.',
      );
    }
    if (durationMs != null && durationMs > 0 && chapter.endMs > durationMs) {
      throw const FormatException(
        'Chapters must stay within the media duration.',
      );
    }
    previousEnd = chapter.endMs;
  }
}

/// null custom means downloaded chapters; an empty custom list is intentional.
class ChapterData {
  final List<MediaChapter> downloaded;
  final List<MediaChapter>? custom;
  final DateTime? checkedAt;
  final int? durationMs;
  final bool valid;
  final bool shuffleChapters;
  final List<MediaChapter>? undoChapters;
  final int recognitionEpoch;
  final String? lastRecognitionRunId;

  const ChapterData({
    this.downloaded = const [],
    this.custom,
    this.checkedAt,
    this.durationMs,
    this.valid = true,
    this.shuffleChapters = false,
    this.undoChapters,
    this.recognitionEpoch = 0,
    this.lastRecognitionRunId,
  });

  List<MediaChapter> get active => valid ? (custom ?? downloaded) : const [];
  ChapterData withCustom(List<MediaChapter>? chapters) =>
      copyWith(custom: chapters);
  ChapterData withShuffleChapters(bool enabled) =>
      copyWith(shuffleChapters: enabled);
  static const _unset = Object();
  ChapterData copyWith({
    List<MediaChapter>? downloaded,
    Object? custom = _unset,
    DateTime? checkedAt,
    int? durationMs,
    bool? valid,
    bool? shuffleChapters,
    Object? undoChapters = _unset,
    int? recognitionEpoch,
    String? lastRecognitionRunId,
  }) => ChapterData(
    downloaded: downloaded ?? this.downloaded,
    custom:
        identical(custom, _unset) ? this.custom : custom as List<MediaChapter>?,
    checkedAt: checkedAt ?? this.checkedAt,
    durationMs: durationMs ?? this.durationMs,
    valid: valid ?? this.valid,
    shuffleChapters: shuffleChapters ?? this.shuffleChapters,
    undoChapters:
        identical(undoChapters, _unset)
            ? this.undoChapters
            : undoChapters as List<MediaChapter>?,
    recognitionEpoch: recognitionEpoch ?? this.recognitionEpoch,
    lastRecognitionRunId: lastRecognitionRunId ?? this.lastRecognitionRunId,
  );
  ChapterData invalidate() => ChapterData(
    downloaded: downloaded,
    custom: custom,
    checkedAt: checkedAt,
    durationMs: durationMs,
    valid: false,
    shuffleChapters: shuffleChapters,
    recognitionEpoch: recognitionEpoch + 1,
    lastRecognitionRunId: lastRecognitionRunId,
  );

  /// Main's fields are always written; the recognition fields only when
  /// they differ from what [fromJson] assumes when they are missing.
  Map<String, dynamic> toJson() {
    final originalIds = {for (final c in downloaded) c.id};
    List<Map<String, dynamic>> edited(List<MediaChapter> chapters) => [
      for (final c in chapters)
        c.toJson(
          impliedOrigin:
              originalIds.contains(c.id)
                  ? ChapterOrigin.original
                  : ChapterOrigin.user,
        ),
    ];
    return {
      'downloaded': [
        for (final c in downloaded)
          c.toJson(impliedOrigin: ChapterOrigin.original),
      ],
      'custom': custom == null ? null : edited(custom!),
      'checkedAt': checkedAt?.toUtc().toIso8601String(),
      'durationMs': durationMs,
      'valid': valid,
      'shuffleChapters': shuffleChapters,
      if (undoChapters != null) 'undoChapters': edited(undoChapters!),
      if (recognitionEpoch != 0) 'recognitionEpoch': recognitionEpoch,
      if (lastRecognitionRunId != null)
        'lastRecognitionRunId': lastRecognitionRunId,
    };
  }

  String encode() => jsonEncode(toJson());

  /// Recently decoded values. Playback, the notification and every list row
  /// decode the same few chapter blobs again and again; jsonDecode is the
  /// expensive part, so identical strings share one immutable result.
  static final Map<String, ChapterData> _decodeCache = {};
  static const _decodeCacheSize = 256;

  static ChapterData decode(String? value) {
    if (value == null || value.isEmpty) return const ChapterData();
    final cached = _decodeCache.remove(value);
    if (cached != null) {
      // Re-insert to keep the most recently used entries last.
      _decodeCache[value] = cached;
      return cached;
    }
    ChapterData result;
    try {
      result = fromJson(jsonDecode(value));
    } catch (_) {
      result = const ChapterData();
    }
    if (_decodeCache.length >= _decodeCacheSize) {
      _decodeCache.remove(_decodeCache.keys.first);
    }
    _decodeCache[value] = result;
    return result;
  }

  static ChapterData fromJson(Object? value) {
    if (value is! Map) return const ChapterData();
    final originals = MediaChapter.parse(
      value['downloaded'],
      fallbackOrigin: ChapterOrigin.original,
    );
    return ChapterData(
      downloaded: originals,
      custom:
          value['custom'] == null
              ? null
              : MediaChapter.parse(value['custom'], originals: originals),
      checkedAt: DateTime.tryParse(value['checkedAt']?.toString() ?? ''),
      durationMs:
          value['durationMs'] is int ? value['durationMs'] as int : null,
      valid: value['valid'] != false,
      shuffleChapters: value['shuffleChapters'] == true,
      undoChapters:
          value['undoChapters'] == null
              ? null
              : MediaChapter.parse(value['undoChapters'], originals: originals),
      recognitionEpoch:
          value['recognitionEpoch'] is int
              ? value['recognitionEpoch'] as int
              : 0,
      lastRecognitionRunId: value['lastRecognitionRunId'] as String?,
    );
  }

  static ChapterData fromVideoInfo(Map<String, dynamic> info) {
    int? milliseconds(Object? value) =>
        value is num && value.isFinite ? (value * 1000).round() : null;
    final duration = milliseconds(info['duration']);
    final raw = info['chapters'];
    final result = <MediaChapter>[];
    if (raw is List) {
      for (var i = 0; i < raw.length; i++) {
        if (raw[i] is! Map) continue;
        final m = raw[i] as Map;
        final start = milliseconds(m['start_time']);
        final next =
            i + 1 < raw.length && raw[i + 1] is Map
                ? milliseconds((raw[i + 1] as Map)['start_time'])
                : duration;
        final end = milliseconds(m['end_time']) ?? next;
        if (start == null || end == null) {
          return ChapterData(checkedAt: DateTime.now(), durationMs: duration);
        }
        result.add(
          MediaChapter(
            id: 'youtube-$i-$start',
            origin: ChapterOrigin.original,
            title:
                (m['title'] as String?)?.trim().isNotEmpty == true
                    ? (m['title'] as String).trim()
                    : 'Chapter ${i + 1}',
            startMs: start,
            endMs: end,
          ),
        );
      }
    }
    try {
      validateChapters(result, durationMs: duration);
    } catch (_) {
      result.clear();
    }
    return ChapterData(
      downloaded: result,
      checkedAt: DateTime.now(),
      durationMs: duration,
    );
  }
}

String chapterTimestamp(int ms) {
  final d = Duration(milliseconds: ms);
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  final fraction =
      (ms % 1000) == 0 ? '' : '.${(ms % 1000).toString().padLeft(3, '0')}';
  return '${d.inMinutes}:$seconds$fraction';
}

int? parseChapterTimestamp(String text) {
  final parts = text.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  double seconds = 0;
  for (var i = 0; i < parts.length; i++) {
    final n = double.tryParse(parts[i]);
    if (n == null ||
        !n.isFinite ||
        n < 0 ||
        (i < parts.length - 1 && n != n.truncateToDouble()) ||
        (i > 0 && n >= 60)) {
      return null;
    }
    seconds = seconds * 60 + n;
  }
  return (seconds * 1000).round();
}
