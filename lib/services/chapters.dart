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

  /// Shuffle this file's chapters when shuffle is on: null follows the
  /// playlist's "Shuffle chapters" (`Playlists.shuffleChapters`).
  final bool? shuffleChapters;
  final List<MediaChapter>? undoChapters;

  /// True when the state [undoChapters] was taken from followed the
  /// downloaded (YouTube) chapters (custom was null). Undo then follows them
  /// again instead of freezing a copy, so later YouTube fetches still show.
  final bool undoFollowsDownloaded;
  final int recognitionEpoch;
  final String? lastRecognitionRunId;

  /// Chapters that automatic playback passes over ("Always skip"), by id.
  /// Kept apart from the chapter lists so followed YouTube chapters can be
  /// skipped without copying them into [custom], and so it is not a chapter
  /// edit (undo leaves it alone). Ids no longer in [active] are ignored.
  final Set<String> skippedChapterIds;

  const ChapterData({
    this.downloaded = const [],
    this.custom,
    this.checkedAt,
    this.durationMs,
    this.valid = true,
    this.shuffleChapters,
    this.undoChapters,
    this.undoFollowsDownloaded = false,
    this.recognitionEpoch = 0,
    this.lastRecognitionRunId,
    this.skippedChapterIds = const {},
  });

  List<MediaChapter> get active => valid ? (custom ?? downloaded) : const [];

  bool isSkipped(String chapterId) => skippedChapterIds.contains(chapterId);

  /// [active] without the chapters marked Always skip.
  List<MediaChapter> get unskipped =>
      skippedChapterIds.isEmpty
          ? active
          : active.where((c) => !isSkipped(c.id)).toList();

  ChapterData withChapterSkip(String chapterId, bool skip) {
    if (isSkipped(chapterId) == skip) return this;
    return copyWith(
      skippedChapterIds:
          skip
              ? {...skippedChapterIds, chapterId}
              : skippedChapterIds.where((id) => id != chapterId).toSet(),
    );
  }

  ChapterData withCustom(List<MediaChapter>? chapters) =>
      copyWith(custom: chapters);

  /// null goes back to the playlist's choice.
  ChapterData withShuffleChapters(bool? enabled) =>
      copyWith(shuffleChapters: enabled);
  static const _unset = Object();
  ChapterData copyWith({
    List<MediaChapter>? downloaded,
    Object? custom = _unset,
    DateTime? checkedAt,
    int? durationMs,
    bool? valid,
    Object? shuffleChapters = _unset,
    Object? undoChapters = _unset,
    bool? undoFollowsDownloaded,
    int? recognitionEpoch,
    String? lastRecognitionRunId,
    Set<String>? skippedChapterIds,
  }) => ChapterData(
    downloaded: downloaded ?? this.downloaded,
    custom:
        identical(custom, _unset) ? this.custom : custom as List<MediaChapter>?,
    checkedAt: checkedAt ?? this.checkedAt,
    durationMs: durationMs ?? this.durationMs,
    valid: valid ?? this.valid,
    shuffleChapters:
        identical(shuffleChapters, _unset)
            ? this.shuffleChapters
            : shuffleChapters as bool?,
    undoChapters:
        identical(undoChapters, _unset)
            ? this.undoChapters
            : undoChapters as List<MediaChapter>?,
    undoFollowsDownloaded: undoFollowsDownloaded ?? this.undoFollowsDownloaded,
    recognitionEpoch: recognitionEpoch ?? this.recognitionEpoch,
    lastRecognitionRunId: lastRecognitionRunId ?? this.lastRecognitionRunId,
    skippedChapterIds:
        skippedChapterIds == null
            ? this.skippedChapterIds
            : Set.unmodifiable(skippedChapterIds),
  );

  /// The file was replaced: its chapters no longer apply, and neither do
  /// the skip marks made for them.
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
      // What versions without a playlist default read: only "Shuffle"
      // shuffles there.
      'shuffleChapters': shuffleChapters == true,
      if (shuffleChapters != null)
        'shuffleChaptersMode': shuffleChapters! ? 'shuffle' : 'noShuffle',
      if (undoChapters != null) 'undoChapters': edited(undoChapters!),
      if (undoChapters != null && undoFollowsDownloaded)
        'undoFollowsDownloaded': true,
      if (recognitionEpoch != 0) 'recognitionEpoch': recognitionEpoch,
      if (lastRecognitionRunId != null)
        'lastRecognitionRunId': lastRecognitionRunId,
      if (skippedChapterIds.isNotEmpty)
        'skippedChapterIds': [...skippedChapterIds]..sort(),
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
      shuffleChapters: switch (value['shuffleChaptersMode']) {
        'shuffle' => true,
        'noShuffle' => false,
        // Older versions always wrote the bool, so false cannot tell "off
        // on purpose" from "never touched"; it follows the playlist.
        _ => value['shuffleChapters'] == true ? true : null,
      },
      undoChapters:
          value['undoChapters'] == null
              ? null
              : MediaChapter.parse(value['undoChapters'], originals: originals),
      undoFollowsDownloaded:
          value['undoChapters'] != null &&
          value['undoFollowsDownloaded'] == true,
      recognitionEpoch:
          value['recognitionEpoch'] is int
              ? value['recognitionEpoch'] as int
              : 0,
      lastRecognitionRunId: value['lastRecognitionRunId'] as String?,
      skippedChapterIds: Set.unmodifiable(
        value['skippedChapterIds'] is List
            ? (value['skippedChapterIds'] as List).whereType<String>()
            : const <String>[],
      ),
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

/// The title song recognition gives a section it could not identify.
const unrecognizedChapterTitle = 'Unrecognized section';

final _numberedChapterTitle = RegExp(r'^chapter\s*\d+$', caseSensitive: false);

/// Whether [title] is a stand-in rather than a real name: the title song
/// recognition gives an unidentified section, or a default "Chapter N"
/// (YouTube chapters without a title, a split in the chapter editor).
/// Lists show these in the error color, so unknown parts are easy to find.
bool isPlaceholderChapterTitle(String title) {
  final trimmed = title.trim();
  return trimmed.toLowerCase() == unrecognizedChapterTitle.toLowerCase() ||
      _numberedChapterTitle.hasMatch(trimmed);
}

/// The one clock format for times in a file's chapters: `m:ss`, or
/// `h:mm:ss` when the file ([fileMs], its length) or [ms] itself reaches an
/// hour, so every time of a long file reads alike and minutes never pass 59.
/// [decimals] (0, 1 or 3) digits of the second follow, cut rather than
/// rounded so a time never shows later than it is. Negative times get "−".
String chapterClock(int ms, {int? fileMs, int decimals = 0}) {
  assert(decimals == 0 || decimals == 1 || decimals == 3);
  final abs = ms.abs();
  final hours = abs ~/ 3600000;
  final minutes = abs ~/ 60000 % 60;
  final seconds = (abs ~/ 1000 % 60).toString().padLeft(2, '0');
  final withHours = hours > 0 || (fileMs ?? 0) >= 3600000;
  var text =
      withHours
          ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
          : '$minutes:$seconds';
  if (decimals == 3) {
    text += '.${(abs % 1000).toString().padLeft(3, '0')}';
  } else if (decimals == 1) {
    text += '.${abs % 1000 ~/ 100}';
  }
  return ms < 0 ? '−$text' : text;
}

/// [chapterClock] with milliseconds only when [ms] is not a whole second.
/// Edit fields use it too: [parseChapterTimestamp] reads it back exactly.
String chapterTimestamp(int ms, {int? fileMs}) =>
    chapterClock(ms, fileMs: fileMs, decimals: ms % 1000 == 0 ? 0 : 3);

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
