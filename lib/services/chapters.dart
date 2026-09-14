import 'dart:convert';

/// A named range on the unchanged source file's timeline.
class MediaChapter {
  final String id;
  final String title;
  final int startMs;
  final int endMs;

  const MediaChapter({
    required this.id,
    required this.title,
    required this.startMs,
    required this.endMs,
  });

  Duration get duration => Duration(milliseconds: endMs - startMs);
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'startMs': startMs,
    'endMs': endMs,
  };

  static List<MediaChapter> parse(Object? value) {
    if (value is! List) return [];
    try {
      final result =
          value.map((entry) {
              final m = entry as Map;
              return MediaChapter(
                id: m['id'] as String,
                title: m['title'] as String,
                startMs: m['startMs'] as int,
                endMs: m['endMs'] as int,
              );
            }).toList()
            ..sort((a, b) => a.startMs.compareTo(b.startMs));
      validateChapters(result);
      return result;
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

  const ChapterData({
    this.downloaded = const [],
    this.custom,
    this.checkedAt,
    this.durationMs,
    this.valid = true,
    this.shuffleChapters = false,
  });

  List<MediaChapter> get active => valid ? (custom ?? downloaded) : const [];
  ChapterData withCustom(List<MediaChapter>? chapters) => ChapterData(
    downloaded: downloaded,
    custom: chapters,
    checkedAt: checkedAt,
    durationMs: durationMs,
    valid: valid,
    shuffleChapters: shuffleChapters,
  );
  ChapterData withShuffleChapters(bool enabled) => ChapterData(
    downloaded: downloaded,
    custom: custom,
    checkedAt: checkedAt,
    durationMs: durationMs,
    valid: valid,
    shuffleChapters: enabled,
  );
  ChapterData invalidate() => ChapterData(
    downloaded: downloaded,
    custom: custom,
    checkedAt: checkedAt,
    durationMs: durationMs,
    valid: false,
    shuffleChapters: shuffleChapters,
  );
  Map<String, dynamic> toJson() => {
    'downloaded': downloaded.map((c) => c.toJson()).toList(),
    'custom': custom?.map((c) => c.toJson()).toList(),
    'checkedAt': checkedAt?.toUtc().toIso8601String(),
    'durationMs': durationMs,
    'valid': valid,
    'shuffleChapters': shuffleChapters,
  };
  String encode() => jsonEncode(toJson());
  static ChapterData decode(String? value) {
    if (value == null) return const ChapterData();
    try {
      return fromJson(jsonDecode(value));
    } catch (_) {
      return const ChapterData();
    }
  }

  static ChapterData fromJson(Object? value) {
    if (value is! Map) return const ChapterData();
    return ChapterData(
      downloaded: MediaChapter.parse(value['downloaded']),
      custom:
          value['custom'] == null ? null : MediaChapter.parse(value['custom']),
      checkedAt: DateTime.tryParse(value['checkedAt']?.toString() ?? ''),
      durationMs:
          value['durationMs'] is int ? value['durationMs'] as int : null,
      valid: value['valid'] != false,
      shuffleChapters: value['shuffleChapters'] == true,
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
