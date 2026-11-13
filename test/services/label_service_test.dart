import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/label_service.dart';
import 'package:woolytube/services/labels.dart';

import '../helpers/test_database.dart';

const newUid = '11111111-2222-4333-8444-555555555555';

void main() {
  late AppDatabase db;
  late LabelService labels;
  late DateTime now;

  setUp(() {
    db = openTestDatabase();
    now = DateTime.utc(2026, 11, 13, 12);
    labels = LabelService(db, clock: () => now);
  });

  tearDown(() => db.close());

  Future<Track> track(
    Playlist playlist,
    int index, {
    String? videoId,
    List<MediaChapter> chapters = const [],
  }) => insertTestTrack(
    db,
    playlistId: playlist.id,
    index: index,
    videoId: videoId ?? 'video-$index',
    title: 'Song $index',
    chaptersJson:
        chapters.isEmpty
            ? null
            : ChapterData(custom: chapters, durationMs: 600000).encode(),
  );

  Future<Track> fresh(Track track) async => (await db.getTrack(track.id))!;

  group('making and changing labels', () {
    test('a label gets a UUID and goes to the end of the order', () async {
      final rock = await labels.create('  Rock ', 0xffe53935);
      final jazz = await labels.create('Jazz', 0xff1e88e5);
      expect(rock.name, 'Rock');
      expect(isLabelUid(rock.uid), isTrue);
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
          r'[0-9a-f]{12}$',
        ).hasMatch(rock.uid),
        isTrue,
      );
      expect(rock.uid, isNot(jazz.uid));
      expect((await labels.labels()).map((l) => l.name), ['Rock', 'Jazz']);

      await labels.reorder([jazz.uid]);
      expect((await labels.labels()).map((l) => l.name), ['Jazz', 'Rock']);
    });

    test('names must be there, short and not taken (case ignored)', () async {
      final rock = await labels.create('Rock', 0xffe53935);
      final folk = await labels.create('Folk', 0xff43a047);
      for (final name in ['', '   ', 'x' * 41]) {
        await expectLater(
          labels.create(name, 0),
          throwsA(isA<LabelException>()),
        );
      }
      await expectLater(
        labels.create('rock', 0),
        throwsA(isA<LabelException>()),
      );
      await expectLater(
        labels.rename(folk.uid, 'ROCK'),
        throwsA(isA<LabelException>()),
      );
      // Its own name in other letters is fine.
      await labels.rename(rock.uid, 'ROCK');
      expect((await db.getLabel(rock.uid))!.name, 'ROCK');
      // Accents count too.
      await labels.create('Ősz', 0);
      await expectLater(
        labels.create('ősz', 0),
        throwsA(isA<LabelException>()),
      );
    });

    test('renaming and recoloring stamp the change time', () async {
      final rock = await labels.create('Rock', 0xffe53935);
      now = now.add(const Duration(hours: 1));
      await labels.rename(rock.uid, 'Hard rock');
      await labels.recolor(rock.uid, 0xff000000);
      final stored = (await db.getLabel(rock.uid))!;
      expect(stored.name, 'Hard rock');
      expect(stored.color, 0xff000000);
      expect(stored.updatedAt.isAtSameMomentAs(now), isTrue);
      expect(
        stored.createdAt.isAtSameMomentAs(DateTime.utc(2026, 11, 13, 12)),
        isTrue,
      );
    });
  });

  group('assigning', () {
    test('files and chapters carry labels separately, also two copies of '
        'one video', () async {
      final audio = await insertTestPlaylist(db, name: 'Audio');
      final video = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=video',
        name: 'Video',
      );
      final rock = await labels.create('Rock', 0xffe53935);
      final live = await labels.create('Live', 0xff1e88e5);
      final song = await track(audio, 1, videoId: 'same');
      final copy = await track(video, 1, videoId: 'same');

      expect(await labels.setTrackLabel(song.id, rock.uid, true), isTrue);
      expect(await labels.setTrackLabel(song.id, rock.uid, true), isFalse);
      await labels.setTrackLabel(song.id, live.uid, true);
      expect(decodeLabelUids((await fresh(song)).labelUids), [
        rock.uid,
        live.uid,
      ]);
      expect((await fresh(copy)).labelUids, isNull);
      expect(
        (await labels.labelsOfTrack(await fresh(song))).map((l) => l.name),
        ['Rock', 'Live'],
      );

      await labels.setTrackLabels(song.id, [live.uid]);
      expect(decodeLabelUids((await fresh(song)).labelUids), [live.uid]);
      await labels.setTrackLabel(song.id, live.uid, false);
      expect((await fresh(song)).labelUids, isNull);
    });

    test('a label change raises the revision of the playlists using it, and '
        'only theirs', () async {
      final used = await insertTestPlaylist(db, name: 'Used');
      final other = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=other',
        name: 'Other',
      );
      final byChapter = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=mix',
        name: 'Mix',
      );
      final rock = await labels.create('Rock', 0xffe53935);
      final song = await track(used, 1);
      await track(other, 1);
      final mix = await track(
        byChapter,
        1,
        chapters: const [
          MediaChapter(id: 'a', title: 'A', startMs: 0, endMs: 1000),
        ],
      );
      await labels.setTrackLabel(song.id, rock.uid, true);
      await labels.setChapterLabel(mix.id, 'a', rock.uid, true);
      final before = await db.playlistRevisions();

      await labels.rename(rock.uid, 'Hard rock');
      var after = await db.playlistRevisions();
      expect(after[used.id], before[used.id]! + 1);
      expect(after[byChapter.id], before[byChapter.id]! + 1);
      expect(after[other.id], before[other.id]);

      // The order of labels is not in the metadata files.
      await labels.create('Jazz', 0);
      final ordered = await db.playlistRevisions();
      await labels.reorder([(await labels.labels()).last.uid]);
      expect(await db.playlistRevisions(), ordered);

      await labels.delete(rock.uid);
      after = await db.playlistRevisions();
      expect(after[used.id], ordered[used.id]! + 1);
      expect(after[other.id], ordered[other.id]);
    });
  });

  group('deleting', () {
    test('a deleted label stops showing and matching; restoring brings it '
        'back everywhere', () async {
      final playlist = await insertTestPlaylist(db);
      final rock = await labels.create('Rock', 0xffe53935);
      final song = await track(playlist, 1);
      final mix = await track(
        playlist,
        2,
        chapters: const [
          MediaChapter(id: 'a', title: 'A', startMs: 0, endMs: 1000),
        ],
      );
      await labels.setTrackLabel(song.id, rock.uid, true);
      await labels.setChapterLabel(mix.id, 'a', rock.uid, true);
      expect(await labels.find({rock.uid}), hasLength(2));

      await labels.delete(rock.uid);
      expect(await labels.labels(), isEmpty);
      expect(await labels.find({rock.uid}), isEmpty);
      expect(await labels.labelsOfTrack(await fresh(song)), isEmpty);
      expect(await labels.labelsOfChapter(await fresh(mix), 'a'), isEmpty);
      // The uid stays on the file until its labels change.
      expect(decodeLabelUids((await fresh(song)).labelUids), [rock.uid]);
      await expectLater(
        labels.rename(rock.uid, 'Other'),
        throwsA(isA<LabelException>()),
      );
      // Its name is free again meanwhile.
      final other = await labels.create('rock', 0);
      await expectLater(
        labels.restore(rock.uid),
        throwsA(isA<LabelException>()),
      );
      await labels.delete(other.uid);

      await labels.restore(rock.uid);
      expect((await labels.labels()).single.uid, rock.uid);
      expect(await labels.find({rock.uid}), [
        LabelledItem(await fresh(song)),
        LabelledItem(
          await fresh(mix),
          ChapterData.decode((await fresh(mix)).chaptersJson).active.single,
        ),
      ]);
    });

    test('uids of deleted labels are dropped the next time a file or '
        'chapter is labelled', () async {
      final playlist = await insertTestPlaylist(db);
      final rock = await labels.create('Rock', 0xffe53935);
      final jazz = await labels.create('Jazz', 0xff1e88e5);
      final mix = await track(
        playlist,
        1,
        chapters: const [
          MediaChapter(id: 'a', title: 'A', startMs: 0, endMs: 1000),
        ],
      );
      await labels.setTrackLabel(mix.id, rock.uid, true);
      await labels.setChapterLabel(mix.id, 'a', rock.uid, true);
      await labels.delete(rock.uid);

      await labels.setTrackLabel(mix.id, jazz.uid, true);
      await labels.setChapterLabel(mix.id, 'a', jazz.uid, true);
      final stored = await fresh(mix);
      expect(decodeLabelUids(stored.labelUids), [jazz.uid]);
      expect(ChapterData.decode(stored.chaptersJson).labelsOf('a'), [jazz.uid]);
      // Only labels in use can be given.
      await labels.setTrackLabel(mix.id, rock.uid, true);
      expect(decodeLabelUids((await fresh(mix)).labelUids), [jazz.uid]);
    });
  });

  group('finding', () {
    test('two labels find what has both, or with "any" what has either; '
        'files and chapters count on their own', () async {
      final playlist = await insertTestPlaylist(db);
      final rock = await labels.create('Rock', 0xffe53935);
      final live = await labels.create('Live', 0xff1e88e5);
      final both = await track(playlist, 1);
      final onlyRock = await track(playlist, 2);
      await track(playlist, 3);
      final mix = await track(
        playlist,
        4,
        chapters: const [
          MediaChapter(id: 'a', title: 'A', startMs: 0, endMs: 1000),
          MediaChapter(id: 'b', title: 'B', startMs: 1000, endMs: 2000),
        ],
      );
      await labels.setTrackLabels(both.id, [rock.uid, live.uid]);
      await labels.setTrackLabels(onlyRock.id, [rock.uid]);
      // The file is Live, its first chapter Rock: neither has both.
      await labels.setTrackLabels(mix.id, [live.uid]);
      await labels.setChapterLabels(mix.id, 'a', [rock.uid]);
      await labels.setChapterLabels(mix.id, 'b', [rock.uid, live.uid]);

      String describe(LabelledItem item) =>
          '${item.track.index}${item.chapter == null ? '' : item.chapter!.id}';

      expect((await labels.find({rock.uid, live.uid})).map(describe), [
        '1',
        '4b',
      ]);
      expect(
        (await labels.find({
          rock.uid,
          live.uid,
        }, match: LabelMatch.any)).map(describe),
        ['1', '2', '4', '4a', '4b'],
      );
      expect((await labels.find({rock.uid})).map(describe), [
        '1',
        '2',
        '4a',
        '4b',
      ]);
      expect(await labels.find({}), isEmpty);

      final usage = await labels.usage();
      expect(usage[rock.uid]!.files, 2);
      expect(usage[rock.uid]!.chapters, 2);
      expect(usage[live.uid]!.files, 2);
      expect(usage[live.uid]!.chapters, 1);
    });

    test('a chapter the file no longer shows is not found', () async {
      final playlist = await insertTestPlaylist(db);
      final rock = await labels.create('Rock', 0xffe53935);
      final mix = await track(
        playlist,
        1,
        chapters: const [
          MediaChapter(id: 'a', title: 'A', startMs: 0, endMs: 1000),
        ],
      );
      await labels.setChapterLabels(mix.id, 'a', [rock.uid]);
      await db.invalidateTrackChapters(mix.id);
      expect(await labels.find({rock.uid}), isEmpty);
    });
  });

  group('importing', () {
    PortableLabel portable(
      String uid,
      String name, {
      int color = 0xff000000,
      DateTime? updatedAt,
    }) =>
        PortableLabel(uid: uid, name: name, color: color, updatedAt: updatedAt);

    const otherUid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

    test('new labels are added at the end in the incoming order; the same '
        'uid takes the newer name and color', () async {
      final rock = await labels.create('Rock', 0xffe53935);
      final result = await importLabels(db, [
        portable(newUid, 'Folk', updatedAt: DateTime.utc(2020)),
        portable(
          rock.uid,
          'Hard rock',
          color: 0xff00ff00,
          updatedAt: now.add(const Duration(minutes: 1)),
        ),
      ]);
      expect(result.added, 1);
      expect(result.updated, 1);
      expect(result.remap, {newUid: newUid, rock.uid: rock.uid});
      final all = await labels.labels();
      expect(all.map((l) => l.name), ['Hard rock', 'Folk']);
      expect(all.first.color, 0xff00ff00);
      // The incoming change time is kept for the next merge.
      expect(all.last.updatedAt.isAtSameMomentAs(DateTime.utc(2020)), isTrue);

      // An older copy changes nothing.
      final older = await importLabels(db, [
        portable(rock.uid, 'Rock', updatedAt: DateTime.utc(2021)),
      ]);
      expect(older.updated, 0);
      expect((await db.getLabel(rock.uid))!.name, 'Hard rock');
    });

    test(
      'a label of the same name made on another phone is the same label',
      () async {
        final rock = await labels.create('Rock', 0xffe53935);
        final result = await importLabels(db, [
          portable(otherUid, 'ROCK', updatedAt: DateTime.utc(2030)),
        ]);
        expect(result.added, 0);
        expect(result.remap[otherUid], rock.uid);
        expect(result.apply([otherUid, rock.uid]), [rock.uid]);
        final chapters =
            const ChapterData(
              custom: [MediaChapter(id: 'a', title: 'A', startMs: 0, endMs: 9)],
            ).withChapterLabels('a', [otherUid]).encode();
        expect(
          ChapterData.decode(result.applyToChapters(chapters)).labelsOf('a'),
          [rock.uid],
        );
        expect((await labels.labels()).single.name, 'Rock');
      },
    );

    test('a label deleted here stays deleted unless the incoming copy '
        'changed later', () async {
      final rock = await labels.create('Rock', 0xffe53935);
      now = now.add(const Duration(hours: 1));
      await labels.delete(rock.uid);

      var result = await importLabels(db, [
        portable(rock.uid, 'Rock', updatedAt: DateTime.utc(2026, 11, 13, 12)),
      ]);
      expect(result.remap[rock.uid], rock.uid);
      expect(await labels.labels(), isEmpty);

      result = await importLabels(db, [
        portable(
          rock.uid,
          'Rock!',
          updatedAt: now.add(const Duration(days: 1)),
        ),
      ]);
      expect(result.updated, 1);
      expect((await labels.labels()).single.name, 'Rock!');
    });

    test('a newer name that another label has is not taken', () async {
      final rock = await labels.create('Rock', 0xffe53935);
      await labels.create('Jazz', 0xff1e88e5);
      await importLabels(db, [
        portable(
          rock.uid,
          'jazz',
          color: 0xff123456,
          updatedAt: now.add(const Duration(hours: 1)),
        ),
      ]);
      final stored = (await db.getLabel(rock.uid))!;
      expect(stored.name, 'Rock');
      expect(stored.color, 0xff123456);
    });
  });

  group('the folder file form', () {
    test('colors are written as hex and read in either form', () {
      expect(labelColorHex(0xffe53935), '#e53935');
      expect(labelColorHex(0x80e53935), '#80e53935');
      expect(parseLabelColor('#E53935'), 0xffe53935);
      expect(parseLabelColor('80e53935'), 0x80e53935);
      expect(parseLabelColor(0xffe53935), 0xffe53935);
      expect(parseLabelColor('red'), isNull);
    });

    test('unreadable entries are skipped, a missing color is grey', () {
      final list = PortableLabel.listFromJson([
        {'uid': 'short', 'name': 'Bad uid'},
        {'uid': newUid, 'name': '  '},
        {'uid': newUid, 'name': 'Folk', 'color': 'nope'},
        {'uid': newUid, 'name': 'Twice'},
        'junk',
      ]);
      expect(list, hasLength(1));
      expect(list.single.name, 'Folk');
      expect(list.single.color, defaultLabelColor);
      expect(decodeLabelUids('[1, "$newUid", "$newUid", "x"]'), [newUid]);
      expect(decodeLabelUids('not json'), isEmpty);
      expect(encodeLabelUids(const []), isNull);
    });
  });
}
