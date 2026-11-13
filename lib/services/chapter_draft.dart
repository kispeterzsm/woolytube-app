import 'dart:math';

import 'chapters.dart';

/// One chapter while it is being edited. Values are never changed in place;
/// every edit makes a new copy.
class DraftChapter {
  final String id;
  final String title;
  final int startMs;
  final int endMs;
  final ChapterOrigin origin;

  /// The user changed this chapter (in this session or before it).
  final bool edited;

  /// Review notes shown under the chapter. They are not saved.
  final List<String> notes;

  /// Whatever the caller wants to carry along, e.g. the [MediaChapter] the
  /// draft was made from.
  final Object? tag;

  const DraftChapter({
    required this.id,
    required this.title,
    required this.startMs,
    required this.endMs,
    this.origin = ChapterOrigin.user,
    this.edited = false,
    this.notes = const [],
    this.tag,
  });

  /// A draft of [chapter]. The chapter is kept in [tag] so [toMediaChapter]
  /// can keep its other fields.
  factory DraftChapter.fromMediaChapter(
    MediaChapter chapter, {
    List<String> notes = const [],
  }) => DraftChapter(
    id: chapter.id,
    title: chapter.title,
    startMs: chapter.startMs,
    endMs: chapter.endMs,
    origin: chapter.origin,
    edited: chapter.manuallyEdited,
    notes: notes,
    tag: chapter,
  );

  int get lengthMs => endMs - startMs;

  DraftChapter copyWith({
    String? title,
    int? startMs,
    int? endMs,
    bool? edited,
    List<String>? notes,
  }) => DraftChapter(
    id: id,
    title: title ?? this.title,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    origin: origin,
    edited: edited ?? this.edited,
    notes: notes ?? this.notes,
    tag: tag,
  );

  /// The chapter to save. A chapter made from a [MediaChapter] keeps that
  /// chapter's origin, alternative titles and review reasons.
  MediaChapter toMediaChapter() {
    final source = tag;
    if (source is MediaChapter) {
      return source.copyWith(
        title: title,
        startMs: startMs,
        endMs: endMs,
        manuallyEdited: source.manuallyEdited || edited,
      );
    }
    return MediaChapter(
      id: id,
      title: title,
      startMs: startMs,
      endMs: endMs,
      origin: origin,
      manuallyEdited: edited,
    );
  }

  bool _sameAs(DraftChapter other) =>
      id == other.id &&
      title == other.title &&
      startMs == other.startMs &&
      endMs == other.endMs;

  @override
  String toString() => 'DraftChapter($id, "$title", $startMs-$endMs)';
}

/// A boundary the user can move: a shared boundary between two touching
/// chapters, a lone start (a gap or the file start before it) or a lone
/// end (a gap or the file end after it).
class DraftEdge {
  final int ms;

  /// The chapter that ends here, if any.
  final String? leftId;

  /// The chapter that starts here, if any.
  final String? rightId;

  const DraftEdge({required this.ms, this.leftId, this.rightId})
    : assert(leftId != null || rightId != null);

  /// One chapter ends where the next one starts.
  bool get shared => leftId != null && rightId != null;

  /// Stays the same while the edge is moved, so a selection can follow it.
  String get key => '${leftId ?? ''}|${rightId ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is DraftEdge &&
      other.ms == ms &&
      other.leftId == leftId &&
      other.rightId == rightId;

  @override
  int get hashCode => Object.hash(ms, leftId, rightId);

  @override
  String toString() => 'DraftEdge($ms, $leftId|$rightId)';
}

/// The chapter list of one file while the editor is open, with undo and
/// redo. Every change returns a new draft; a change that is not allowed
/// returns the same draft.
class ChapterDraft {
  /// No chapter can be made shorter than this.
  static const minChapterMs = 1000;

  static const _maxHistory = 200;
  static int _idCounter = 0;

  final List<DraftChapter> chapters;

  /// The file length. Never shorter than the end of the last chapter.
  final int durationMs;

  final List<List<DraftChapter>> _past;
  final List<List<DraftChapter>> _future;
  final List<DraftChapter> _initial;

  ChapterDraft(List<DraftChapter> chapters, {required int durationMs})
    : this._(
        _sorted(chapters),
        durationMs: durationMs,
        past: const [],
        future: const [],
        initial: null,
      );

  /// A draft of [chapters]; [notesById] adds review notes to them.
  factory ChapterDraft.fromChapters(
    List<MediaChapter> chapters, {
    required int durationMs,
    Map<String, List<String>> notesById = const {},
  }) => ChapterDraft([
    for (final c in chapters)
      DraftChapter.fromMediaChapter(c, notes: notesById[c.id] ?? const []),
  ], durationMs: durationMs);

  ChapterDraft._(
    List<DraftChapter> chapters, {
    required int durationMs,
    required List<List<DraftChapter>> past,
    required List<List<DraftChapter>> future,
    required List<DraftChapter>? initial,
  }) : chapters = List.unmodifiable(chapters),
       durationMs = max(
         max(durationMs, 0),
         chapters.isEmpty ? 0 : chapters.map((c) => c.endMs).reduce(max),
       ),
       _past = past,
       _future = future,
       _initial = initial ?? List.unmodifiable(chapters);

  static List<DraftChapter> _sorted(List<DraftChapter> chapters) =>
      [...chapters]..sort((a, b) => a.startMs.compareTo(b.startMs));

  /// The chapters to save.
  List<MediaChapter> toChapters() => [
    for (final c in chapters) c.toMediaChapter(),
  ];

  /// The list differs from the one the editor started with.
  bool get dirty {
    if (chapters.length != _initial.length) return true;
    for (var i = 0; i < chapters.length; i++) {
      if (!chapters[i]._sameAs(_initial[i])) return true;
    }
    return false;
  }

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  ChapterDraft undo() {
    if (!canUndo) return this;
    return ChapterDraft._(
      _past.last,
      durationMs: durationMs,
      past: _past.sublist(0, _past.length - 1),
      future: [chapters, ..._future],
      initial: _initial,
    );
  }

  ChapterDraft redo() {
    if (!canRedo) return this;
    return ChapterDraft._(
      _future.first,
      durationMs: durationMs,
      past: [..._past, chapters],
      future: _future.sublist(1),
      initial: _initial,
    );
  }

  /// The same draft after [saved] (by default its chapters as they are)
  /// was saved: not [dirty] while its chapters are that list. Undo and redo
  /// keep their steps, and a step away from the saved list makes it dirty
  /// again. Pass the list that was saved when changes may have been made
  /// while saving: those stay unsaved.
  ChapterDraft markSaved([List<DraftChapter>? saved]) => ChapterDraft._(
    chapters,
    durationMs: durationMs,
    past: _past,
    future: _future,
    initial: saved == null ? chapters : List.unmodifiable(saved),
  );

  /// The same draft with a corrected file length (e.g. the real length from
  /// the player). It is not an undoable change.
  ChapterDraft withDuration(int durationMs) => ChapterDraft._(
    chapters,
    durationMs: durationMs,
    past: _past,
    future: _future,
    initial: _initial,
  );

  ChapterDraft _change(List<DraftChapter> next) {
    final past = [..._past, chapters];
    if (past.length > _maxHistory) past.removeAt(0);
    return ChapterDraft._(
      _sorted(next),
      durationMs: durationMs,
      past: past,
      future: const [],
      initial: _initial,
    );
  }

  /// Every boundary, in time order.
  List<DraftEdge> get edges {
    final result = <DraftEdge>[];
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      final previous = i > 0 ? chapters[i - 1] : null;
      final next = i + 1 < chapters.length ? chapters[i + 1] : null;
      if (previous == null || previous.endMs != c.startMs) {
        result.add(DraftEdge(ms: c.startMs, rightId: c.id));
      }
      result.add(
        next != null && next.startMs == c.endMs
            ? DraftEdge(ms: c.endMs, leftId: c.id, rightId: next.id)
            : DraftEdge(ms: c.endMs, leftId: c.id),
      );
    }
    return result;
  }

  /// The edge with this [DraftEdge.key] as the draft stands now.
  DraftEdge? edgeByKey(String key) {
    for (final e in edges) {
      if (e.key == key) return e;
    }
    return null;
  }

  /// The edge closest to [ms], or null when there are no chapters.
  DraftEdge? nearestEdge(int ms) {
    DraftEdge? best;
    for (final e in edges) {
      if (best == null || (e.ms - ms).abs() < (best.ms - ms).abs()) best = e;
    }
    return best;
  }

  int _indexOf(String? id) =>
      id == null ? -1 : chapters.indexWhere((c) => c.id == id);

  DraftChapter? chapterById(String id) {
    final i = _indexOf(id);
    return i < 0 ? null : chapters[i];
  }

  /// The chapter playing at [ms] (start included, end excluded).
  int? chapterIndexAt(int ms) {
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      if (ms >= c.startMs && ms < c.endMs) return i;
    }
    return null;
  }

  /// The closest position to [ms] that [edge] can move to: inside the file,
  /// not over a neighbouring chapter and leaving every chapter at least
  /// [minChapterMs] long. An edge that cannot move stays where it is.
  int clampEdge(DraftEdge edge, int ms) {
    final left = _indexOf(edge.leftId);
    final right = _indexOf(edge.rightId);
    if (left < 0 && right < 0) return edge.ms;
    int lo;
    int hi;
    int current;
    if (left >= 0 && right >= 0) {
      lo = chapters[left].startMs + minChapterMs;
      hi = chapters[right].endMs - minChapterMs;
      current = chapters[right].startMs;
    } else if (right >= 0) {
      lo = right > 0 ? chapters[right - 1].endMs : 0;
      hi = chapters[right].endMs - minChapterMs;
      current = chapters[right].startMs;
    } else {
      lo = chapters[left].startMs + minChapterMs;
      hi = left + 1 < chapters.length ? chapters[left + 1].startMs : durationMs;
      current = chapters[left].endMs;
    }
    lo = max(lo, 0);
    hi = min(hi, durationMs);
    if (lo > hi) return current;
    return ms.clamp(lo, hi);
  }

  /// Moves [edge] to [ms] (clamped). Both chapters of a shared edge move.
  ChapterDraft moveEdge(DraftEdge edge, int ms) {
    final left = _indexOf(edge.leftId);
    final right = _indexOf(edge.rightId);
    if (left < 0 && right < 0) return this;
    if (edge.shared && (left < 0 || right < 0)) return this;
    final target = clampEdge(edge, ms);
    final current = right >= 0 ? chapters[right].startMs : chapters[left].endMs;
    if (target == current) return this;
    final next = [...chapters];
    if (left >= 0) {
      next[left] = next[left].copyWith(endMs: target, edited: true);
    }
    if (right >= 0) {
      next[right] = next[right].copyWith(startMs: target, edited: true);
    }
    return _change(next);
  }

  /// Adds a boundary at [ms]. Inside a chapter it splits it in two (the
  /// right part is a new chapter); in a gap, or with no chapters, it makes a
  /// new chapter from [ms] to the next chapter or the file end. Nothing
  /// happens if a piece would be shorter than [minChapterMs].
  ChapterDraft splitAt(int ms, {String? newTitle}) {
    if (ms < 0 || ms >= durationMs) return this;
    final index = chapterIndexAt(ms);
    final next = [...chapters];
    final DraftChapter added;
    if (index != null) {
      final c = chapters[index];
      if (ms - c.startMs < minChapterMs || c.endMs - ms < minChapterMs) {
        return this;
      }
      next[index] = c.copyWith(endMs: ms, edited: true);
      added = DraftChapter(
        id: newChapterId(),
        title: '',
        startMs: ms,
        endMs: c.endMs,
      );
    } else {
      var end = durationMs;
      for (final c in chapters) {
        if (c.startMs > ms) {
          end = c.startMs;
          break;
        }
      }
      if (end - ms < minChapterMs) return this;
      added = DraftChapter(
        id: newChapterId(),
        title: '',
        startMs: ms,
        endMs: end,
      );
    }
    next.add(added);
    final sorted = _sorted(next);
    final position = sorted.indexOf(added);
    final title = newTitle?.trim();
    sorted[position] = added.copyWith(
      title:
          title == null || title.isEmpty
              ? _defaultTitle(position + 1, sorted)
              : title,
    );
    return _change(sorted);
  }

  /// "Chapter N" for the chapter at 1-based [number], made unique.
  static String _defaultTitle(int number, List<DraftChapter> list) {
    final taken = {for (final c in list) c.title};
    var n = number;
    while (taken.contains('Chapter $n')) {
      n++;
    }
    return 'Chapter $n';
  }

  /// Removes a shared [edge] by merging its two chapters. The merged
  /// chapter keeps the id, title and notes of the left chapter when
  /// [keepLeftTitle] is true, otherwise those of the right one. Lone edges
  /// cannot be removed.
  ChapterDraft removeEdge(DraftEdge edge, {required bool keepLeftTitle}) {
    if (!edge.shared) return this;
    final left = _indexOf(edge.leftId);
    final right = _indexOf(edge.rightId);
    if (left < 0 || right != left + 1) return this;
    if (chapters[left].endMs != chapters[right].startMs) return this;
    return _merge(left, keepLeftTitle: keepLeftTitle);
  }

  /// Merges chapter [id] with the chapter after it, covering any gap
  /// between them.
  ChapterDraft mergeWithNext(String id, {bool keepLeftTitle = true}) {
    final i = _indexOf(id);
    if (i < 0 || i + 1 >= chapters.length) return this;
    return _merge(i, keepLeftTitle: keepLeftTitle);
  }

  ChapterDraft _merge(int left, {required bool keepLeftTitle}) {
    final a = chapters[left];
    final b = chapters[left + 1];
    final survivor = keepLeftTitle ? a : b;
    final merged = survivor.copyWith(
      startMs: a.startMs,
      endMs: b.endMs,
      edited: true,
    );
    final next =
        [...chapters]
          ..removeRange(left, left + 2)
          ..insert(left, merged);
    return _change(next);
  }

  ChapterDraft rename(String id, String title) {
    final i = _indexOf(id);
    final trimmed = title.trim();
    if (i < 0 || trimmed.isEmpty || chapters[i].title == trimmed) return this;
    final next = [...chapters];
    next[i] = next[i].copyWith(title: trimmed, edited: true);
    return _change(next);
  }

  /// Removes chapter [id], leaving a gap where it was.
  ChapterDraft delete(String id) {
    final i = _indexOf(id);
    if (i < 0) return this;
    return _change([...chapters]..removeAt(i));
  }

  /// One chapter covering the whole file, when there are no chapters yet.
  ChapterDraft createFromScratch(String title) {
    final trimmed = title.trim();
    if (chapters.isNotEmpty || durationMs < minChapterMs) return this;
    return _change([
      DraftChapter(
        id: newChapterId(),
        title: trimmed.isEmpty ? 'Chapter 1' : trimmed,
        startMs: 0,
        endMs: durationMs,
      ),
    ]);
  }

  /// A new, unique chapter id.
  static String newChapterId() =>
      'local-${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';
}
