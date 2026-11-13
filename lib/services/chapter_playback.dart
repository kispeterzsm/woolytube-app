import 'dart:math';
import 'package:drift/drift.dart' show Value;
import '../database/database.dart';
import 'chapters.dart';

class PlaybackItem {
  final Track track;
  final MediaChapter? chapter;
  const PlaybackItem(this.track, [this.chapter]);
  String get id =>
      chapter == null
          ? 'track:${track.id}:${track.playlistId}'
          : 'chapter:${track.id}:${track.playlistId}:${chapter!.id}';
  int get startMs => chapter?.startMs ?? 0;

  /// Null when unknown. A stored length of 0 (local replacement files) is
  /// unknown too, not an empty file.
  Duration? get duration {
    final chapter = this.chapter;
    if (chapter != null) return chapter.duration;
    final seconds = track.durationSeconds;
    return seconds == null || seconds <= 0 ? null : Duration(seconds: seconds);
  }

  Track get displayTrack =>
      chapter == null
          ? track
          : track.copyWith(
            title: chapter!.title,
            durationSeconds: Value(chapter!.duration.inSeconds),
          );
  Duration relativePosition(Duration source) =>
      chapter == null
          ? source
          : Duration(
            milliseconds: (source.inMilliseconds - startMs).clamp(
              0,
              chapter!.duration.inMilliseconds,
            ),
          );
  Duration sourcePosition(Duration relative) => Duration(
    milliseconds:
        startMs +
        relative.inMilliseconds.clamp(
          0,
          duration?.inMilliseconds ?? max(0, relative.inMilliseconds),
        ),
  );

  /// Whether [next] continues this chapter's audio without a gap: the same
  /// file, and its range starts exactly where this one ends.
  bool continuesInto(PlaybackItem? next) {
    final current = chapter;
    final following = next?.chapter;
    return current != null &&
        following != null &&
        next!.track.id == track.id &&
        next.track.downloadedAt == track.downloadedAt &&
        following.startMs == current.endMs;
  }
}

/// The items [track] plays as: its chapters, or the whole file.
///
/// Chapters marked Always skip are left out, so automatic playback passes
/// over them; a file whose chapters are all skipped gives no items at all,
/// like a file marked Always skip. [selected] (the user tapped this file)
/// keeps such a file: it then plays its chapters anyway. [includeSkipped]
/// lists every chapter, for lists the user picks from (a pick plays even a
/// skipped chapter).
List<PlaybackItem> chapterPlaybackItems(
  Track track,
  Playlist playlist, {
  bool whole = false,
  bool selected = false,
  bool includeSkipped = false,
}) {
  // Decide on the cheap flags first so most tracks never decode JSON.
  if (whole || !(track.chaptersEnabled ?? playlist.playChapters ?? true)) {
    return [PlaybackItem(track)];
  }
  final data = ChapterData.decode(track.chaptersJson);
  final chapters = data.active;
  if (chapters.isEmpty) return [PlaybackItem(track)];
  var kept = includeSkipped ? chapters : data.unskipped;
  if (kept.isEmpty && selected) kept = chapters;
  return kept.map((chapter) => PlaybackItem(track, chapter)).toList();
}

/// One file of a queue built from a list such as search results: the whole
/// file, or only some of its chapters.
class QueueEntry {
  const QueueEntry(this.track, [this.chapterIds]);

  final Track track;

  /// The active chapters to play, in timeline order whatever the set's
  /// order. Null plays the file as usual (its chapters, or the whole file).
  final Set<String>? chapterIds;

  @override
  bool operator ==(Object other) =>
      other is QueueEntry &&
      other.track.id == track.id &&
      _sameIds(other.chapterIds, chapterIds);

  static bool _sameIds(Set<String>? a, Set<String>? b) =>
      a == null || b == null
          ? a == b
          : a.length == b.length && a.containsAll(b);

  @override
  int get hashCode => Object.hash(
    track.id,
    chapterIds == null ? null : Object.hashAllUnordered(chapterIds!),
  );

  @override
  String toString() =>
      'QueueEntry(${track.id}${chapterIds == null ? '' : ', $chapterIds'})';
}

/// The chapters of one file that play one after another. Never build one
/// without items: [trackId] reads the first.
class PlaybackAlbum {
  final List<PlaybackItem> items;

  /// The playlist's "Shuffle chapters" (`Playlist.shuffleChapters`), which
  /// a file without its own choice follows.
  final bool playlistShuffleChapters;

  /// The chapter ids this album was limited to (such as the chapters a
  /// search found), or null when it plays the file's chapters as set. Kept
  /// so a rebuild of the album after a chapter or settings change plays
  /// the same chapters.
  final Set<String>? chapterSubset;
  PlaybackAlbum(
    Iterable<PlaybackItem> items, {
    this.playlistShuffleChapters = false,
    this.chapterSubset,
  }) : items = List.of(items);
  int get trackId => items.first.track.id;

  /// Read once per album; a single-item album (a file played whole) has
  /// nothing to shuffle.
  late final bool shuffleChapters =
      items.length > 1 &&
      (ChapterData.decode(items.first.track.chaptersJson).shuffleChapters ??
          playlistShuffleChapters);
}

/// An opaque copy of an [AlbumPlaybackQueue]'s position, used to undo a step
/// that did not lead to anything playable.
class PlaybackQueueSnapshot {
  final bool _shuffle;
  final bool _shuffleCurrentChapters;
  final List<PlaybackItem> _history;
  final int _historyIndex;
  final List<PlaybackItem> _remaining;
  final List<PlaybackAlbum> _albums;
  final List<PlaybackAlbum> _before;
  final List<PlaybackAlbum> _ordered;
  final Map<int, int> _albumOrder;
  final List<PlaybackAlbum> _taken;
  final Set<int> _consumed;
  final int? _anchor;

  PlaybackQueueSnapshot._(AlbumPlaybackQueue q)
    : _shuffle = q.shuffle,
      _shuffleCurrentChapters = q._shuffleCurrentChapters,
      _history = List.of(q._history),
      _historyIndex = q._historyIndex,
      _remaining = List.of(q._remaining),
      _albums = List.of(q._albums),
      _before = List.of(q._before),
      _ordered = List.of(q._ordered),
      _albumOrder = Map.of(q._albumOrder),
      _taken = List.of(q._taken),
      _consumed = Set.of(q._consumed),
      _anchor = q._anchor;
}

/// The play order of one playback session.
///
/// It keeps the whole playlist in its original order ([_ordered]) plus a
/// cursor, so that:
/// * Previous walks the songs actually played, and in playlist order it
///   continues above the song that was tapped;
/// * turning shuffle on mid-play shuffles every song not played yet,
///   including the ones above the current song;
/// * turning shuffle off continues in playlist order after the current song;
/// * either switch forgets songs ahead of the cursor that Previous went back
///   over, so they come again in the new order and not in the old one;
/// * an album (a file split into chapters) always finishes before another
///   playlist entry starts, and explicitly queued entries ("Up next") come
///   before the rest of the playlist.
class AlbumPlaybackQueue {
  final Random random;
  bool shuffle = false;
  bool _shuffleCurrentChapters = false;

  /// Items played so far (the current one at [_historyIndex]).
  final List<PlaybackItem> _history = [];
  int _historyIndex = -1;

  /// Unplayed items of the album that is playing now.
  final List<PlaybackItem> _remaining = [];

  /// Playlist albums still to come, in play order.
  final List<PlaybackAlbum> _albums = [];

  /// In playlist order: unplayed albums above the anchor, so Previous can
  /// reach them. Empty while shuffling.
  final List<PlaybackAlbum> _before = [];

  /// Explicitly queued albums ("Up next"). They are not part of the playlist.
  final List<PlaybackAlbum> _queued = [];

  /// Albums [next] and [nextFile] took out of [_queued], oldest first, so a
  /// [restore] can put back exactly those and keep every other change the
  /// user made to "Up next" in the meantime.
  final List<PlaybackAlbum> _taken = [];

  /// The playlist in its original order, and each album's position in it.
  final List<PlaybackAlbum> _ordered = [];
  final Map<int, int> _albumOrder = {};

  /// Track ids of playlist albums that were opened, so toggling shuffle never
  /// plays them a second time.
  final Set<int> _consumed = {};

  /// Playlist position of the most recently opened playlist album.
  int? _anchor;

  AlbumPlaybackQueue({Random? random}) : random = random ?? Random();

  PlaybackItem? get current =>
      _historyIndex < 0 ? null : _history[_historyIndex];
  List<PlaybackAlbum> get queued => List.unmodifiable(_queued);

  /// Everything in play order: playlist entries above (in playlist order),
  /// played items, then what is still to come.
  List<PlaybackItem> get items => [
    for (final group in _before) ...group.items,
    ..._history,
    ..._remaining,
    for (final group in _queued) ...group.items,
    for (final group in _albums) ...group.items,
  ];

  /// Position of [current] in [items].
  int get index {
    var before = 0;
    for (final group in _before) {
      before += group.items.length;
    }
    return before + max(0, _historyIndex);
  }

  /// Whether nothing at all is left to play after [current].
  bool get isAtEnd =>
      _historyIndex + 1 >= _history.length &&
      _remaining.isEmpty &&
      _queued.isEmpty &&
      _albums.isEmpty;

  PlaybackQueueSnapshot snapshot() => PlaybackQueueSnapshot._(this);

  void restore(PlaybackQueueSnapshot s) {
    shuffle = s._shuffle;
    _shuffleCurrentChapters = s._shuffleCurrentChapters;
    _history
      ..clear()
      ..addAll(s._history);
    _historyIndex = s._historyIndex;
    _remaining
      ..clear()
      ..addAll(s._remaining);
    _albums
      ..clear()
      ..addAll(s._albums);
    _before
      ..clear()
      ..addAll(s._before);
    _ordered
      ..clear()
      ..addAll(s._ordered);
    _albumOrder
      ..clear()
      ..addAll(s._albumOrder);
    // "Up next" is not rolled back: additions and removals made while a step
    // was in flight stay. Only the albums the step itself took come back.
    final returned = [
      for (final album in _taken)
        if (!s._taken.any((a) => identical(a, album))) album,
    ];
    _queued.insertAll(0, returned);
    _taken.removeWhere((album) => returned.any((a) => identical(a, album)));
    _consumed
      ..clear()
      ..addAll(s._consumed);
    _anchor = s._anchor;
  }

  PlaybackItem? start(
    List<PlaybackAlbum> albums, {
    int? trackId,
    String? chapterId,
    required bool shuffled,
  }) {
    _history.clear();
    _historyIndex = -1;
    _remaining.clear();
    _albums.clear();
    _before.clear();
    _ordered.clear();
    _albumOrder.clear();
    _consumed.clear();
    _taken.clear();
    _anchor = null;
    shuffle = shuffled;
    final valid = albums.where((g) => g.items.isNotEmpty).toList();
    for (var i = 0; i < valid.length; i++) {
      _ordered.add(valid[i]);
      _albumOrder[valid[i].trackId] = i;
    }
    if (valid.isEmpty) return null;
    var selected =
        trackId == null ? -1 : valid.indexWhere((g) => g.trackId == trackId);
    if (selected < 0) selected = shuffle ? random.nextInt(valid.length) : 0;
    final first = valid[selected];
    if (shuffle) {
      _albums.addAll(valid.where((g) => g != first));
      _albums.shuffle(random);
    } else {
      _before.addAll(valid.take(selected));
      _albums.addAll(valid.skip(selected + 1));
    }
    final earlier = _openAlbum(first, chapterId: chapterId, fromPlaylist: true);
    // Chapters above a tapped chapter count as played, so Previous reaches
    // them in order.
    _history.addAll(earlier);
    _historyIndex = earlier.length - 1;
    return next();
  }

  void enqueue(PlaybackAlbum album, {bool first = false}) {
    if (album.items.isEmpty) return;
    if (first) {
      _queued.insert(0, album);
    } else {
      _queued.add(album);
    }
  }

  /// Moves the waiting [album] (as returned by [queued]) to [newIndex].
  void moveQueuedAlbum(PlaybackAlbum album, int newIndex) {
    final index = _queued.indexWhere((a) => identical(a, album));
    if (index < 0) return;
    _queued.removeAt(index);
    _queued.insert(newIndex.clamp(0, _queued.length), album);
  }

  /// Removes [album] (as returned by [queued]) when it is still waiting.
  void removeQueuedAlbum(PlaybackAlbum album) {
    final index = _queued.indexWhere((a) => identical(a, album));
    if (index >= 0) _queued.removeAt(index);
  }

  void clearQueued() {
    _queued.clear();
    // A cleared list stays cleared, also when a step is rolled back.
    _taken.clear();
  }

  void clear() {
    _history.clear();
    _historyIndex = -1;
    _remaining.clear();
    _albums.clear();
    _before.clear();
    _queued.clear();
    _taken.clear();
    _ordered.clear();
    _albumOrder.clear();
    _consumed.clear();
    _anchor = null;
  }

  /// Puts [album]'s items into [_remaining] and returns the chapters that
  /// precede a selected [chapterId] (in playlist order mode only).
  List<PlaybackItem> _openAlbum(
    PlaybackAlbum album, {
    String? chapterId,
    required bool fromPlaylist,
  }) {
    if (fromPlaylist) {
      _consumed.add(album.trackId);
      _anchor = _albumOrder[album.trackId] ?? _anchor;
    }
    _shuffleCurrentChapters = album.shuffleChapters;
    final shuffleEntries = shuffle && _shuffleCurrentChapters;
    final entries = List<PlaybackItem>.of(album.items);
    final selected =
        chapterId == null
            ? -1
            : entries.indexWhere((i) => i.chapter?.id == chapterId);
    PlaybackItem? first;
    var earlier = const <PlaybackItem>[];
    if (selected >= 0) {
      first = entries.removeAt(selected);
      if (!shuffleEntries) {
        earlier = entries.sublist(0, selected);
        entries.removeRange(0, selected);
      }
    }
    if (shuffleEntries) entries.shuffle(random);
    _remaining.addAll([if (first != null) first, ...entries]);
    return earlier;
  }

  /// The item [next] would return, without moving. Null when that would
  /// open another album.
  PlaybackItem? peekNext() {
    if (_historyIndex + 1 < _history.length) {
      return _history[_historyIndex + 1];
    }
    return _remaining.isEmpty ? null : _remaining.first;
  }

  /// The items [next] returns in a row before another album is opened.
  Iterable<PlaybackItem> upcomingInAlbum() sync* {
    for (var i = _historyIndex + 1; i < _history.length; i++) {
      yield _history[i];
    }
    yield* _remaining;
  }

  PlaybackItem? next() {
    if (_historyIndex + 1 < _history.length) return _history[++_historyIndex];
    if (_remaining.isEmpty) {
      if (_queued.isNotEmpty) {
        final album = _queued.removeAt(0);
        _taken.add(album);
        _openAlbum(album, fromPlaylist: false);
      } else if (_albums.isNotEmpty) {
        _openAlbum(_albums.removeAt(0), fromPlaylist: true);
      }
    }
    if (_remaining.isEmpty) return null;
    final item = _remaining.removeAt(0);
    // Forward history was exhausted above, so this always appends.
    _history.add(item);
    _historyIndex = _history.length - 1;
    return item;
  }

  /// Discard the current file's unplayed chapters without adding them to history.
  PlaybackItem? nextFile() {
    final trackId = current?.track.id;
    while (_historyIndex + 1 < _history.length) {
      final item = _history[++_historyIndex];
      if (item.track.id != trackId) return item;
    }
    _remaining.clear();
    while (_queued.isNotEmpty && _queued.first.trackId == trackId) {
      _taken.add(_queued.removeAt(0));
    }
    if (_queued.isEmpty) {
      while (_albums.isNotEmpty && _albums.first.trackId == trackId) {
        _albums.removeAt(0);
      }
    }
    return next();
  }

  /// Drops the chapters of the current file that have not played yet, for a
  /// "next file" that found nothing after it. The cursor stays.
  void discardRestOfCurrentFile() {
    final trackId = current?.track.id;
    if (trackId == null) return;
    var end = _historyIndex + 1;
    while (end < _history.length && _history[end].track.id == trackId) {
      end++;
    }
    _history.removeRange(_historyIndex + 1, end);
    _remaining.removeWhere((i) => i.track.id == trackId);
  }

  /// Steps back through the songs played. At the first played song, in
  /// playlist order, continues with the playlist entry above it (its last
  /// chapter when it is an album).
  PlaybackItem? previous() {
    if (_historyIndex > 0) return _history[--_historyIndex];
    if (_historyIndex < 0 || shuffle || _before.isEmpty) return null;
    final album = _before.removeLast();
    _consumed.add(album.trackId);
    _history.insertAll(0, album.items);
    _historyIndex = album.items.length - 1;
    return _history[_historyIndex];
  }

  /// Makes [item] the current item right away, keeping everything that was
  /// queued: once it ends, playback continues where it was. [thenResume]
  /// (normally a copy of the item that is interrupted) plays right after
  /// [item], so the interrupted song is picked up again.
  PlaybackItem playNow(PlaybackItem item, {PlaybackItem? thenResume}) {
    _history.insert(_historyIndex + 1, item);
    if (thenResume != null) _history.insert(_historyIndex + 2, thenResume);
    _historyIndex++;
    return item;
  }

  /// Swaps the current item for [item] (the same file, whole), dropping the
  /// unplayed chapters that the whole file now covers.
  void replaceCurrent(PlaybackItem item) {
    if (_historyIndex < 0) {
      playNow(item);
      return;
    }
    _history[_historyIndex] = item;
    _remaining.removeWhere((i) => i.track.id == item.track.id);
  }

  /// Makes chapter [chapterId] of the file that is current (track
  /// [trackId]) the current item, keeping the rest of the queue. Chapters
  /// skipped on the way count as played, so Previous reaches them, unless
  /// the file's chapters are shuffled (then they still play later). Null
  /// when the current item is not that file or the chapter is not part of
  /// its unplayed or played chapters.
  PlaybackItem? jumpToChapter(int trackId, String chapterId) {
    final playing = current;
    if (playing == null || playing.track.id != trackId) return null;
    bool matches(PlaybackItem i) =>
        i.track.id == trackId && i.chapter?.id == chapterId;
    // The run of this file's items around the cursor.
    var first = _historyIndex, last = _historyIndex;
    while (first > 0 && _history[first - 1].track.id == trackId) {
      first--;
    }
    while (last + 1 < _history.length &&
        _history[last + 1].track.id == trackId) {
      last++;
    }
    for (var i = first; i <= last; i++) {
      if (matches(_history[i])) {
        _historyIndex = i;
        return _history[i];
      }
    }
    // Unplayed chapters belong to this file only when its run ends the
    // history.
    if (last != _history.length - 1) return null;
    final target = _remaining.indexWhere(matches);
    if (target < 0) return null;
    final item = _remaining.removeAt(target);
    if (!(shuffle && _shuffleCurrentChapters)) {
      final skipped = _remaining.sublist(0, target);
      _remaining.removeRange(0, target);
      _history.addAll(skipped);
    }
    _history.add(item);
    _historyIndex = _history.length - 1;
    return item;
  }

  /// Drops every item whose track matches [test] from the queue: played and
  /// unplayed songs, "Up next" and the playlist still to come. The current
  /// item stays (stop playback first when it matches). Dropped playlist
  /// entries count as played, so a shuffle switch never brings them back.
  void removeTracksWhere(bool Function(Track track) test) {
    final keep = current;
    var removedBefore = 0;
    for (var i = _history.length - 1; i >= 0; i--) {
      final item = _history[i];
      if (identical(item, keep) || !test(item.track)) continue;
      _history.removeAt(i);
      if (i < _historyIndex) removedBefore++;
    }
    _historyIndex -= removedBefore;
    _remaining.removeWhere((i) => test(i.track));
    bool albumMatches(PlaybackAlbum album) =>
        album.items.isNotEmpty && test(album.items.first.track);
    _albums.removeWhere(albumMatches);
    _before.removeWhere(albumMatches);
    _queued.removeWhere(albumMatches);
    _taken.removeWhere(albumMatches);
    for (final album in _ordered) {
      if (albumMatches(album)) _consumed.add(album.trackId);
    }
  }

  /// Rebuilds playlist albums that have not started yet, for example after
  /// the playlist's chapter setting changed. [rebuild] returns the new album
  /// for an album, or null to keep it. Albums that end up empty are dropped.
  void rebuildPendingAlbums(PlaybackAlbum? Function(PlaybackAlbum) rebuild) {
    final replaced = <int, PlaybackAlbum>{};
    for (var i = 0; i < _ordered.length; i++) {
      final album = _ordered[i];
      if (_consumed.contains(album.trackId)) continue;
      final fresh = rebuild(album);
      if (fresh != null) {
        replaced[album.trackId] = fresh;
        _ordered[i] = fresh;
      }
    }
    if (replaced.isEmpty) return;
    void apply(List<PlaybackAlbum> list) {
      for (var i = 0; i < list.length; i++) {
        list[i] = replaced[list[i].trackId] ?? list[i];
      }
      list.removeWhere((a) => a.items.isEmpty);
    }

    apply(_albums);
    apply(_before);
    _ordered.removeWhere((a) => a.items.isEmpty);
  }

  /// Forgets the songs ahead of the cursor that were reached before with
  /// Previous. They were played in the old order; after a shuffle switch
  /// they go back into the pool, so the new order decides when they come.
  /// Chapters of the current file go back in front of its other chapters.
  /// Songs from "Up next" among them were played already and are dropped.
  void _dropForwardHistory() {
    if (_historyIndex < 0 || _historyIndex + 1 >= _history.length) return;
    final dropped = _history.sublist(_historyIndex + 1);
    _history.removeRange(_historyIndex + 1, _history.length);
    final currentId = current!.track.id;
    final kept = {for (final item in _history) item.track.id};
    // The unplayed rest of a dropped album goes back to the pool with it;
    // the rest of a file that is still in the history stays.
    _remaining.removeWhere((i) => !kept.contains(i.track.id));
    _remaining.insertAll(0, dropped.where((i) => i.track.id == currentId));
    for (final item in dropped) {
      if (!kept.contains(item.track.id)) _consumed.remove(item.track.id);
    }
    final order = _albumOrder[currentId];
    if (order != null && _remaining.every((i) => i.track.id == currentId)) {
      _shuffleCurrentChapters = _ordered[order].shuffleChapters;
    }
    for (var i = _history.length - 1; i >= 0; i--) {
      final order = _albumOrder[_history[i].track.id];
      if (order != null) {
        _anchor = order;
        break;
      }
    }
  }

  void setShuffle(bool value) {
    if (shuffle == value) return;
    shuffle = value;
    _dropForwardHistory();
    final pending =
        _ordered.where((a) => !_consumed.contains(a.trackId)).toList();
    if (value) {
      if (_shuffleCurrentChapters) _remaining.shuffle(random);
      // Every playlist entry not played yet, including the ones above.
      _albums
        ..clear()
        ..addAll(pending)
        ..shuffle(random);
      _before.clear();
    } else {
      _remaining.sort((a, b) => a.startMs.compareTo(b.startMs));
      // Continue in playlist order after the song that is playing.
      final anchor = _albumOrder[current?.track.id] ?? _anchor ?? -1;
      _albums
        ..clear()
        ..addAll(pending.where((a) => _albumOrder[a.trackId]! > anchor));
      _before
        ..clear()
        ..addAll(pending.where((a) => _albumOrder[a.trackId]! < anchor));
    }
  }
}
