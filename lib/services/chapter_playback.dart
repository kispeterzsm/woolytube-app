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
}

List<PlaybackItem> chapterPlaybackItems(
  Track track,
  Playlist playlist, {
  bool whole = false,
}) {
  final data = ChapterData.decode(track.chaptersJson);
  final chapters = data.active;
  if (whole ||
      !(track.chaptersEnabled ?? playlist.playChapters ?? false) ||
      chapters.isEmpty) {
    return [PlaybackItem(track)];
  }
  return chapters.map((chapter) => PlaybackItem(track, chapter)).toList();
}

class PlaybackAlbum {
  final List<PlaybackItem> items;
  PlaybackAlbum(Iterable<PlaybackItem> items) : items = List.of(items);
  int get trackId => items.first.track.id;
}

/// Two finite shuffle pools, with history separate from unconsumed items.
/// The current album is exhausted before queued or random albums are selected.
class AlbumPlaybackQueue {
  final Random random;
  bool shuffle = false;
  final List<PlaybackItem> _history = [];
  int _historyIndex = -1;
  final List<PlaybackItem> _remaining = [];
  final List<PlaybackAlbum> _albums = [];
  final List<PlaybackAlbum> _queued = [];
  final Map<int, int> _albumOrder = {};
  AlbumPlaybackQueue({Random? random}) : random = random ?? Random();
  PlaybackItem? get current =>
      _historyIndex < 0 ? null : _history[_historyIndex];
  List<PlaybackAlbum> get queued => List.unmodifiable(_queued);
  List<PlaybackItem> get items => [
    ..._history,
    ..._remaining,
    for (final group in _queued) ...group.items,
    for (final group in _albums) ...group.items,
  ];
  int get index => max(0, _historyIndex);

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
    _albumOrder.clear();
    shuffle = shuffled;
    final valid = albums.where((g) => g.items.isNotEmpty).toList();
    for (var i = 0; i < valid.length; i++) {
      _albumOrder[valid[i].trackId] = i;
    }
    if (valid.isEmpty) return null;
    var selected =
        trackId == null ? -1 : valid.indexWhere((g) => g.trackId == trackId);
    if (selected < 0) selected = shuffle ? random.nextInt(valid.length) : 0;
    final first = valid[selected];
    _albums.addAll(
      shuffle ? valid.where((g) => g != first) : valid.skip(selected + 1),
    );
    if (shuffle) _albums.shuffle(random);
    _openAlbum(first, chapterId: chapterId);
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
    _queued.clear();
  }

  void _openAlbum(PlaybackAlbum album, {String? chapterId}) {
    final entries = List<PlaybackItem>.of(album.items);
    final selected =
        chapterId == null
            ? -1
            : entries.indexWhere((i) => i.chapter?.id == chapterId);
    PlaybackItem? first;
    if (selected >= 0) {
      first = entries.removeAt(selected);
      if (!shuffle) entries.removeRange(0, selected);
    }
    if (shuffle) entries.shuffle(random);
    _remaining.addAll([if (first != null) first, ...entries]);
  }

  PlaybackItem? next() {
    if (_historyIndex + 1 < _history.length) return _history[++_historyIndex];
    if (_remaining.isEmpty) {
      if (_queued.isNotEmpty) {
        _openAlbum(_queued.removeAt(0));
      } else if (_albums.isNotEmpty) {
        _openAlbum(_albums.removeAt(0));
      }
    }
    if (_remaining.isEmpty) return null;
    final item = _remaining.removeAt(0);
    _history.add(item);
    _historyIndex++;
    return item;
  }

  PlaybackItem? previous() =>
      _historyIndex > 0 ? _history[--_historyIndex] : null;

  void setShuffle(bool value) {
    if (shuffle == value) return;
    shuffle = value;
    if (value) {
      _remaining.shuffle(random);
      _albums.shuffle(random);
    } else {
      _remaining.sort((a, b) => a.startMs.compareTo(b.startMs));
      _albums.sort(
        (a, b) => (_albumOrder[a.trackId] ?? 0).compareTo(
          _albumOrder[b.trackId] ?? 0,
        ),
      );
    }
  }
}
