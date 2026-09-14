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
        chaptersJson: Value(ChapterData(downloaded: chapters).encode()),
      );
      albums.add(PlaybackAlbum(chapterPlaybackItems(track, playlist)));
    }
  });
  tearDown(() => db.close());

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
    'Previous traverses real history and toggle does not replay consumed songs',
    () {
      final q = AlbumPlaybackQueue(random: Random(5));
      final first = q.start(albums, shuffled: true)!;
      final second = q.next()!;
      expect(q.previous()!.id, first.id);
      q.setShuffle(false);
      expect(q.next()!.id, second.id);
      final remaining = <String>[];
      for (var next = q.next(); next != null; next = q.next()) {
        remaining.add(next.id);
      }
      expect(remaining, hasLength(5));
      expect(remaining, isNot(contains(first.id)));
      expect(remaining, isNot(contains(second.id)));
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
}
