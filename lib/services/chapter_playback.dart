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
  Duration? get duration =>
      chapter?.duration ??
      (track.durationSeconds == null
          ? null
          : Duration(seconds: track.durationSeconds!));
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

List<PlaybackItem> chapterPlaybackItems(
  Track track,
  Playlist playlist, {
  bool whole = false,
}) {
  // Decide on the cheap flags first so most tracks never decode JSON.
  if (whole || !(track.chaptersEnabled ?? playlist.playChapters ?? true)) {
    return [PlaybackItem(track)];
  }
  final chapters = ChapterData.decode(track.chaptersJson).active;
  if (chapters.isEmpty) return [PlaybackItem(track)];
  return chapters.map((chapter) => PlaybackItem(track, chapter)).toList();
}

class PlaybackAlbum {
  final List<PlaybackItem> items;
  PlaybackAlbum(Iterable<PlaybackItem> items) : items = List.of(items);
  int get trackId => items.first.track.id;

  /// Read once per album; a single-item album has nothing to shuffle.
  late final bool shuffleChapters =
      items.length > 1 &&
      ChapterData.decode(items.first.track.chaptersJson).shuffleChapters;
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
  final List<PlaybackAlbum> _queued;
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
      _queued = List.of(q._queued),
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
    _queued
      ..clear()
      ..addAll(s._queued);
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

  void enqueue(PlaybackAlbum album) {
    if (album.items.isNotEmpty) _queued.add(album);
  }

  void removeQueued(int index) {
    if (index >= 0 && index < _queued.length) _queued.removeAt(index);
  }

  void clearQueued() => _queued.clear();
  void clear() {
    _history.clear();
    _historyIndex = -1;
    _remaining.clear();
    _albums.clear();
    _before.clear();
    _queued.clear();
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
        _openAlbum(_queued.removeAt(0), fromPlaylist: false);
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
      _queued.removeAt(0);
    }
    if (_queued.isEmpty) {
      while (_albums.isNotEmpty && _albums.first.trackId == trackId) {
        _albums.removeAt(0);
      }
    }
    return next();
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
  /// queued: once it ends, playback continues where it was.
  PlaybackItem playNow(PlaybackItem item) {
    _history.insert(_historyIndex + 1, item);
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

  void setShuffle(bool value) {
    if (shuffle == value) return;
    shuffle = value;
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
