import 'dart:math';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/chapters.dart';
import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Playlist playlist;
  late List<PlaybackAlbum> albums;
  setUp(() async {
    db = openTestDatabase();
    playlist = (await insertTestPlaylist(
      db,
    )).copyWith(playChapters: const Value(true));
    albums = [];
    for (var a = 0; a < 3; a++) {
      var track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: a + 1,
        videoId: 'album-$a',
        status: 'complete',
        filePath: '/tmp/album-$a.m4a',
        durationSeconds: 60,
      );
      final chapters =
          a == 1
              ? <MediaChapter>[]
              : List.generate(
                3,
                (i) => MediaChapter(
                  id: '$a-$i',
                  title: 'Song $i',
                  startMs: i * 20000,
                  endMs: (i + 1) * 20000,
                ),
              );
      track = track.copyWith(
        chaptersJson: Value(
          ChapterData(downloaded: chapters, shuffleChapters: true).encode(),
        ),
      );
      albums.add(PlaybackAlbum(chapterPlaybackItems(track, playlist)));
    }
  });
  tearDown(() => db.close());

  group('jumping to a chapter of the current file', () {
    test('in order: the chapters skipped count as played', () {
      final q = AlbumPlaybackQueue(random: Random(1));
      expect(q.start(albums, shuffled: false)!.chapter!.id, '0-0');
      final trackId = albums[0].trackId;

      expect(q.jumpToChapter(trackId, '0-2')!.chapter!.id, '0-2');
      expect(q.previous()!.chapter!.id, '0-1');
      // Back in the played chapters, a jump moves the cursor there.
      expect(q.jumpToChapter(trackId, '0-0')!.chapter!.id, '0-0');
      expect(q.next()!.chapter!.id, '0-1');
      expect(q.next()!.chapter!.id, '0-2');
      expect(q.next()!.track.id, albums[1].trackId);
      // Another file: nothing happens.
      expect(q.jumpToChapter(trackId, '0-1'), isNull);
      expect(q.current!.track.id, albums[1].trackId);
    });

    test('with shuffled chapters the others still play afterwards', () {
      for (var seed = 0; seed < 20; seed++) {
        final q = AlbumPlaybackQueue(random: Random(seed));
        final first = q.start(
          albums,
          trackId: albums[0].trackId,
          shuffled: true,
        );
        final trackId = albums[0].trackId;
        final others = {'0-0', '0-1', '0-2'}..remove(first!.chapter!.id);
        final target = others.first;
        expect(q.jumpToChapter(trackId, target)!.chapter!.id, target);
        final rest = <String>[];
        var item = q.next();
        while (item != null && item.track.id == trackId) {
          rest.add(item.chapter!.id);
          item = q.next();
        }
        expect(rest, [others.last], reason: 'seed $seed');
      }
    });
  });

  test('removing tracks keeps the current item and never brings them back', () {
    final q = AlbumPlaybackQueue(random: Random(3));
    q.start(albums, trackId: albums[1].trackId, shuffled: false);
    q.enqueue(albums[2]);
    final removed = albums[2].trackId;
    q.removeTracksWhere((t) => t.id == removed);
    expect(q.current!.track.id, albums[1].trackId);
    expect(q.queued, isEmpty);
    expect(q.items.where((i) => i.track.id == removed), isEmpty);
    q.setShuffle(true);
    q.setShuffle(false);
    expect(q.items.where((i) => i.track.id == removed), isEmpty);
    // The entry above is still reachable with Previous.
    expect(q.previous()!.track.id, albums[0].trackId);
  });

  test('shuffle completes each album once before another playlist entry', () {
    for (var seed = 0; seed < 50; seed++) {
      final q = AlbumPlaybackQueue(random: Random(seed));
      final played = <PlaybackItem>[];
      var item = q.start(albums, shuffled: true);
      while (item != null) {
        played.add(item);
        item = q.next();
      }
      expect(played.length, 7);
      expect(played.map((i) => i.id).toSet().length, 7);
      final groups = <int>[];
      for (final item in played) {
        if (groups.isEmpty || groups.last != item.track.id) {
          groups.add(item.track.id);
        }
      }
      expect(
        groups.length,
        3,
        reason: 'An album must never be interleaved with another',
      );
      expect(groups.toSet().length, 3);
    }
  });

  test('one album shuffles chapters; direct selection plays first', () {
    final q = AlbumPlaybackQueue(random: Random(4));
    final album = albums.first;
    final selected =
        q.start(
          [album],
          shuffled: true,
          trackId: album.trackId,
          chapterId: album.items[1].chapter!.id,
        )!;
    expect(selected.id, album.items[1].id);
    final ids = [selected.id, q.next()!.id, q.next()!.id];
    expect(ids.toSet(), album.items.map((i) => i.id).toSet());
    expect(q.next(), isNull);
  });

  test('queued requests wait until the current album finishes', () {
    final q = AlbumPlaybackQueue(random: Random(2));
    q.start(albums, shuffled: false);
    q.enqueue(PlaybackAlbum([albums.last.items.last]));
    expect(q.next()!.id, albums.first.items[1].id);
    expect(q.next()!.id, albums.first.items[2].id);
    expect(q.next()!.id, albums.last.items.last.id);
    expect(q.next()!.id, albums[1].items.first.id);
  });

  test(
    'Previous traverses real history and a toggle restarts from the cursor',
    () {
      for (var seed = 0; seed < 20; seed++) {
        final q = AlbumPlaybackQueue(random: Random(seed));
        final first = q.start(albums, shuffled: true)!;
        q.next();
        expect(q.previous()!.id, first.id);
        q.setShuffle(false);
        final remaining = <PlaybackItem>[];
        for (var next = q.next(); next != null; next = q.next()) {
          remaining.add(next);
        }
        final ids = remaining.map((i) => i.id).toList();
        expect(ids, isNot(contains(first.id)));
        expect(ids.toSet(), hasLength(ids.length), reason: 'no repeats');
        // In playlist order: the rest of the current file in its own order,
        // then everything after it; what lies above stays reachable
        // through Previous.
        final order = albums.map((a) => a.trackId).toList();
        final anchor = order.indexOf(first.track.id);
        final sameFile =
            remaining.takeWhile((i) => i.track.id == first.track.id).toList();
        expect(
          sameFile.map((i) => i.startMs).toList(),
          [...sameFile.map((i) => i.startMs)]..sort(),
        );
        for (final item in remaining.skip(sameFile.length)) {
          expect(order.indexOf(item.track.id), greaterThan(anchor));
        }
        final above = <String>[];
        for (var prev = q.previous(); prev != null; prev = q.previous()) {
          above.add(prev.id);
        }
        expect({
          first.id,
          ...ids,
          ...above,
        }, albums.expand((a) => a.items).map((i) => i.id).toSet());
      }
    },
  );

  test(
    'overrides and empty custom sets fall back without duplicate whole albums',
    () {
      final track = albums.first.items.first.track;
      expect(
        chapterPlaybackItems(
          track.copyWith(chaptersEnabled: const Value(false)),
          playlist,
        ),
        hasLength(1),
      );
      expect(
        chapterPlaybackItems(track, playlist, whole: true).single.chapter,
        isNull,
      );
      final customEmpty = track.copyWith(
        chaptersJson: Value(
          ChapterData.decode(track.chaptersJson).withCustom([]).encode(),
        ),
      );
      expect(
        chapterPlaybackItems(customEmpty, playlist).single.chapter,
        isNull,
      );
      final disabledPlaylist = playlist.copyWith(
        playChapters: const Value(false),
      );
      expect(
        chapterPlaybackItems(
          track.copyWith(chaptersEnabled: const Value(true)),
          disabledPlaylist,
        ),
        hasLength(3),
      );
    },
  );

  test('chapters default to tracks while explicit whole-file settings win', () {
    final track = albums.first.items.first.track;
    final defaults = playlist.copyWith(playChapters: const Value(null));
    expect(chapterPlaybackItems(track, defaults), hasLength(3));
    expect(
      chapterPlaybackItems(
        track,
        defaults.copyWith(playChapters: const Value(false)),
      ).single.chapter,
      isNull,
    );
  });

  test('chapter shuffle is opt-in and only applies with playlist shuffle', () {
    // Don't shuffle stays in order even when the playlist would shuffle.
    final source = albums.first.items.first.track;
    final ordered = PlaybackAlbum(
      chapterPlaybackItems(
        source.copyWith(
          chaptersJson: Value(
            ChapterData.decode(
              source.chaptersJson,
            ).withShuffleChapters(false).encode(),
          ),
        ),
        playlist,
      ),
      playlistShuffleChapters: true,
    );
    final shuffledOrders = <String>{};
    for (var seed = 0; seed < 30; seed++) {
      for (final shuffle in [false, true]) {
        final q = AlbumPlaybackQueue(random: Random(seed));
        final first = q.start([ordered], shuffled: shuffle)!;
        q.setShuffle(!shuffle);
        final ids = [first.id, q.next()!.id, q.next()!.id];
        expect(ids, ordered.items.map((i) => i.id).toList());
      }
      final q = AlbumPlaybackQueue(random: Random(seed));
      final first = q.start([albums.first], shuffled: true)!;
      shuffledOrders.add([first.id, q.next()!.id, q.next()!.id].join(','));
      final linear = AlbumPlaybackQueue(random: Random(seed));
      expect(
        linear.start([albums.first], shuffled: false)!.id,
        albums.first.items.first.id,
      );
      expect(linear.next()!.id, albums.first.items[1].id);
    }
    expect(shuffledOrders.length, greaterThan(1));
  });

  test('a file without its own choice follows the playlist', () {
    final source = albums.first.items.first.track;
    Track withChoice(bool? value) => source.copyWith(
      chaptersJson: Value(
        ChapterData.decode(
          source.chaptersJson,
        ).withShuffleChapters(value).encode(),
      ),
    );
    bool shuffles(Track track, Playlist playlist) =>
        PlaybackAlbum(
          chapterPlaybackItems(track, playlist),
          playlistShuffleChapters: playlist.shuffleChapters,
        ).shuffleChapters;
    for (final playlistDefault in [false, true]) {
      final p = playlist.copyWith(shuffleChapters: playlistDefault);
      expect(shuffles(withChoice(null), p), playlistDefault);
      expect(shuffles(withChoice(true), p), isTrue);
      expect(shuffles(withChoice(false), p), isFalse);
    }
    // Without the playlist's choice an album does not shuffle on its own.
    expect(
      PlaybackAlbum(
        chapterPlaybackItems(withChoice(null), playlist),
      ).shuffleChapters,
      isFalse,
    );

    // A file played whole has nothing to shuffle, whatever is chosen.
    final both = playlist.copyWith(shuffleChapters: true);
    for (final whole in [
      withChoice(true).copyWith(chaptersEnabled: const Value(false)),
      withChoice(null).copyWith(chaptersEnabled: const Value(false)),
    ]) {
      expect(shuffles(whole, both), isFalse);
    }
    expect(
      shuffles(
        withChoice(true),
        both.copyWith(playChapters: const Value(false)),
      ),
      isFalse,
    );
    expect(
      PlaybackAlbum(
        chapterPlaybackItems(withChoice(true), both, whole: true),
        playlistShuffleChapters: true,
      ).shuffleChapters,
      isFalse,
    );

    // The playlist default really mixes a file's chapters in the queue.
    final orders = <String>{};
    for (var seed = 0; seed < 30; seed++) {
      final q = AlbumPlaybackQueue(random: Random(seed));
      final album = PlaybackAlbum(
        chapterPlaybackItems(withChoice(null), both),
        playlistShuffleChapters: true,
      );
      final first = q.start([album], shuffled: true)!;
      orders.add([first.id, q.next()!.id, q.next()!.id].join(','));
    }
    expect(orders.length, greaterThan(1));
  });

  test(
    'next file drops unplayed chapters and previous uses played history',
    () {
      final q = AlbumPlaybackQueue();
      final first = q.start(albums, shuffled: false)!;
      final second = q.nextFile()!;
      expect(second.track.id, albums[1].trackId);
      expect(q.previous()!.id, first.id);
      expect(q.nextFile()!.id, second.id);
      expect(q.next()!.id, albums.last.items.first.id);
      expect(q.nextFile(), isNull);
      expect(q.next(), isNull);
    },
  );

  test('next file selects queued requests before remaining playlist files', () {
    final q = AlbumPlaybackQueue(random: Random(4));
    q.start(albums, shuffled: true, trackId: albums.first.trackId);
    q.enqueue(PlaybackAlbum([albums.last.items.last]));
    expect(q.nextFile()!.id, albums.last.items.last.id);
  });

  test('next file preserves a later explicitly queued replay of this file', () {
    final q = AlbumPlaybackQueue();
    q.start([albums.first], shuffled: false);
    q.enqueue(albums[1]);
    q.enqueue(albums.first);
    expect(q.nextFile()!.track.id, albums[1].trackId);
    expect(q.nextFile()!.track.id, albums.first.trackId);
  });

  group('playlist order', () {
    late List<PlaybackAlbum> list;
    setUp(() async => list = await _singleTrackPlaylist(db, 10));
    List<int> ids(Iterable<PlaybackAlbum> albums) =>
        albums.map((a) => a.trackId).toList();

    test('the queue shows the whole playlist at the tapped position', () {
      final q = AlbumPlaybackQueue(random: Random(1));
      final first = q.start(list, trackId: list[7].trackId, shuffled: false)!;
      expect(first.track.id, list[7].trackId);
      expect(q.items.map((i) => i.track.id), ids(list));
      expect(q.index, 7);
      expect(_drain(q), ids(list.skip(8)));
    });

    test('Previous at the tapped song plays the song above it', () {
      final q = AlbumPlaybackQueue(random: Random(1));
      q.start(list, trackId: list[5].trackId, shuffled: false);
      expect(q.previous()!.track.id, list[4].trackId);
      expect(q.previous()!.track.id, list[3].trackId);
      expect(q.index, 3);
      // Forward again walks the same songs, then continues after the tap.
      expect(q.next()!.track.id, list[4].trackId);
      expect(q.next()!.track.id, list[5].trackId);
      expect(q.next()!.track.id, list[6].trackId);
    });

    test('shuffle on mid-play covers the songs above the current one', () {
      for (var seed = 0; seed < 20; seed++) {
        final q = AlbumPlaybackQueue(random: Random(seed));
        final current = q.start(
          list,
          trackId: list[8].trackId,
          shuffled: false,
        );
        q.setShuffle(true);
        expect(q.current!.id, current!.id, reason: 'the song keeps playing');
        final rest = _drain(q);
        expect(
          rest.toSet(),
          ids(list).toSet()..remove(list[8].trackId),
          reason: 'all other songs, including those above, still play',
        );
        expect(rest, hasLength(9));
      }
    });

    test('shuffle off continues in playlist order after the current song', () {
      for (var seed = 0; seed < 20; seed++) {
        final q = AlbumPlaybackQueue(random: Random(seed));
        q.start(list, shuffled: true);
        final played = {q.current!.track.id};
        for (var i = 0; i < 3; i++) {
          played.add(q.next()!.track.id);
        }
        final current = q.current!.track.id;
        q.setShuffle(false);
        final position = ids(list).indexOf(current);
        expect(
          _drain(q),
          ids(list.skip(position + 1)).where((id) => !played.contains(id)),
        );
      }
    });

    test('toggling shuffle never replays a song already played', () {
      final q = AlbumPlaybackQueue(random: Random(3));
      q.start(list, trackId: list[2].trackId, shuffled: false);
      final played = {q.current!.track.id, q.next()!.track.id};
      q.setShuffle(true);
      played.add(q.next()!.track.id);
      q.setShuffle(false);
      q.setShuffle(true);
      final rest = _drain(q);
      expect(rest.toSet().intersection(played), isEmpty);
      expect(rest.length + played.length, list.length);
    });

    test('Previous then shuffle off continues after the current song', () {
      for (var seed = 0; seed < 20; seed++) {
        final q = AlbumPlaybackQueue(random: Random(seed));
        q.start(list, trackId: list[4].trackId, shuffled: true);
        q.next();
        q.next();
        q.previous();
        expect(q.previous()!.track.id, list[4].trackId);
        q.setShuffle(false);
        expect(
          _drain(q),
          ids(list.skip(5)),
          reason: 'the old shuffle history does not come first',
        );
      }
    });

    test('Previous then shuffle on does not replay songs in order', () {
      final firstAfterToggle = <int>{};
      for (var seed = 0; seed < 20; seed++) {
        final q = AlbumPlaybackQueue(random: Random(seed));
        q.start(list, trackId: list[2].trackId, shuffled: false);
        q.next();
        q.next();
        q.previous();
        expect(q.previous()!.track.id, list[2].trackId);
        q.setShuffle(true);
        final rest = _drain(q);
        expect(rest.toSet(), ids(list).toSet()..remove(list[2].trackId));
        expect(rest, hasLength(list.length - 1));
        firstAfterToggle.add(rest.first);
      }
      expect(
        firstAfterToggle.length,
        greaterThan(1),
        reason: 'the songs reached before are shuffled like the rest',
      );
    });

    test('a rolled-back step keeps Up next changes made meanwhile', () {
      final q = AlbumPlaybackQueue(random: Random(1));
      q.start(list, shuffled: false);
      q.enqueue(list[7]);
      q.enqueue(list[8]);
      final snapshot = q.snapshot();
      expect(q.next()!.track.id, list[7].trackId);
      q.enqueue(list[9]);
      q.removeQueuedAlbum(q.queued.firstWhere((a) => a == list[8]));
      q.restore(snapshot);
      expect(q.current!.track.id, list[0].trackId);
      expect(q.queued, [list[7], list[9]]);
    });

    test(
      'a rolled-back step returns a song queued after Up next was cleared',
      () {
        final q = AlbumPlaybackQueue(random: Random(1));
        q.start(list, shuffled: false);
        q.enqueue(list[7]);
        final snapshot = q.snapshot();
        expect(q.next()!.track.id, list[7].trackId);
        q.clearQueued();
        q.enqueue(list[9]);
        expect(q.next()!.track.id, list[9].trackId);
        q.restore(snapshot);
        expect(q.current!.track.id, list[0].trackId);
        expect(q.queued, [list[9]], reason: 'the cleared song stays gone');
      },
    );

    test('a queued song comes before the rest of the playlist', () {
      final q = AlbumPlaybackQueue(random: Random(1));
      q.start(list, shuffled: false);
      q.enqueue(list[9]);
      expect(q.next()!.track.id, list[9].trackId);
      expect(q.next()!.track.id, list[1].trackId);
    });

    test('snapshot and restore undo a step', () {
      final q = AlbumPlaybackQueue(random: Random(1));
      q.start(list, trackId: list[4].trackId, shuffled: false);
      final snapshot = q.snapshot();
      q.previous();
      q.previous();
      q.restore(snapshot);
      expect(q.current!.track.id, list[4].trackId);
      expect(q.index, 4);
      expect(q.next()!.track.id, list[5].trackId);
    });

    test('playNow plays a song and then continues the queue', () {
      final q = AlbumPlaybackQueue(random: Random(1));
      q.start(list, shuffled: false);
      final extra = list[7].items.single;
      expect(q.playNow(extra).id, extra.id);
      expect(q.current!.id, extra.id);
      expect(q.next()!.track.id, list[1].trackId);
      expect(q.previous()!.id, extra.id);
      expect(q.previous()!.track.id, list[0].trackId);
    });

    test('rebuilt pending albums play with their new items', () {
      final q = AlbumPlaybackQueue(random: Random(1));
      q.start(list, shuffled: false);
      q.rebuildPendingAlbums(
        (album) =>
            album.trackId == list[1].trackId
                ? PlaybackAlbum(const [])
                : album.trackId == list[2].trackId
                ? PlaybackAlbum(list[9].items)
                : null,
      );
      expect(q.next()!.track.id, list[9].trackId);
      expect(q.next()!.track.id, list[3].trackId);
    });
  });

  test('peek and the album run show what plays next without moving', () {
    final q = AlbumPlaybackQueue();
    final first = q.start([albums.first], shuffled: false)!;
    expect(q.peekNext()!.id, albums.first.items[1].id);
    expect(q.upcomingInAlbum().map((i) => i.id), [
      albums.first.items[1].id,
      albums.first.items[2].id,
    ]);
    expect(first.continuesInto(q.peekNext()), isTrue);
    expect(q.current!.id, first.id);
    q.replaceCurrent(PlaybackItem(first.track));
    expect(q.current!.chapter, isNull);
    expect(q.peekNext(), isNull, reason: 'the whole file covers its chapters');
  });

  test('chapter timeline and identity differ for ranges of the same file', () {
    final item = albums.first.items[1];
    expect(item.duration, const Duration(seconds: 20));
    expect(
      item.relativePosition(const Duration(seconds: 25)),
      const Duration(seconds: 5),
    );
    expect(item.relativePosition(Duration.zero), Duration.zero);
    expect(
      item.sourcePosition(const Duration(seconds: -10)),
      const Duration(seconds: 20),
    );
    expect(
      item.sourcePosition(const Duration(hours: 1)),
      const Duration(seconds: 40),
    );
    expect(item.id, isNot(albums.first.items.first.id));
  });

  group('a whole file whose stored length is 0', () {
    test('has no known length, so a seek is not clamped to 0', () async {
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 10,
        videoId: 'local-mix',
        status: 'complete',
        filePath: '/tmp/local-mix.mp3',
        durationSeconds: 0,
      );
      final item = PlaybackItem(track);
      expect(item.duration, isNull);
      expect(
        item.sourcePosition(const Duration(minutes: 30)),
        const Duration(minutes: 30),
      );
      expect(item.sourcePosition(const Duration(seconds: -5)), Duration.zero);
      // A known length still clamps.
      final known = PlaybackItem(
        track.copyWith(durationSeconds: const Value(60)),
      );
      expect(
        known.sourcePosition(const Duration(minutes: 30)),
        const Duration(seconds: 60),
      );
    });
  });

  group('chapters marked Always skip', () {
    Future<Track> trackWith(Set<String> skipped) async {
      final track = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 20,
        videoId: 'skips',
        status: 'complete',
        filePath: '/tmp/skips.m4a',
        durationSeconds: 60,
      );
      return track.copyWith(
        chaptersJson: Value(
          ChapterData(
            downloaded: List.generate(
              3,
              (i) => MediaChapter(
                id: 'c$i',
                title: 'Song $i',
                startMs: i * 20000,
                endMs: (i + 1) * 20000,
              ),
            ),
            skippedChapterIds: skipped,
          ).encode(),
        ),
      );
    }

    test('are left out of automatic playback', () async {
      final track = await trackWith({'c1'});
      expect(chapterPlaybackItems(track, playlist).map((i) => i.chapter!.id), [
        'c0',
        'c2',
      ]);
      // Played whole, the file is one item (the player jumps over the
      // skipped ranges).
      expect(
        chapterPlaybackItems(track, playlist, whole: true).single.chapter,
        isNull,
      );
    });

    test(
      'a file with every chapter skipped is passed over unless tapped',
      () async {
        final track = await trackWith({'c0', 'c1', 'c2'});
        expect(chapterPlaybackItems(track, playlist), isEmpty);
        expect(
          chapterPlaybackItems(
            track,
            playlist,
            selected: true,
          ).map((i) => i.chapter!.id),
          ['c0', 'c1', 'c2'],
        );
      },
    );

    test(
      'rebuilding pending albums drops a file that became all skipped',
      () async {
        final q = AlbumPlaybackQueue(random: Random(1));
        q.start(albums, shuffled: false);
        final skipped = await trackWith({'c0', 'c1', 'c2'});
        final target = albums[2].trackId;
        q.rebuildPendingAlbums(
          (album) =>
              album.trackId == target
                  ? PlaybackAlbum(
                    chapterPlaybackItems(
                      skipped.copyWith(id: target),
                      playlist,
                    ),
                  )
                  : null,
        );
        expect(q.items.where((i) => i.track.id == target), isEmpty);
        expect(_drain(q), isNot(contains(target)));
      },
    );
  });
}

/// A playlist of [count] single-file tracks, in order.
Future<List<PlaybackAlbum>> _singleTrackPlaylist(
  AppDatabase db,
  int count,
) async {
  final playlist = await insertTestPlaylist(db, name: 'Long');
  return [
    for (var i = 0; i < count; i++)
      PlaybackAlbum([
        PlaybackItem(
          await insertTestTrack(
            db,
            playlistId: playlist.id,
            index: i + 1,
            videoId: 'long-$i',
            status: 'complete',
            filePath: '/tmp/long-$i.m4a',
          ),
        ),
      ]),
  ];
}

List<int> _drain(AlbumPlaybackQueue q) => [
  for (var next = q.next(); next != null; next = q.next()) next.track.id,
];
