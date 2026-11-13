import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/chapter_draft.dart';
import 'package:woolytube/services/chapters.dart';

DraftChapter ch(
  String id,
  int start,
  int end, {
  String? title,
  ChapterOrigin origin = ChapterOrigin.original,
}) => DraftChapter(
  id: id,
  title: title ?? id.toUpperCase(),
  startMs: start,
  endMs: end,
  origin: origin,
);

List<(String, int, int)> ranges(ChapterDraft d) => [
  for (final c in d.chapters) (c.id, c.startMs, c.endMs),
];

void main() {
  const min = ChapterDraft.minChapterMs;

  // a [0,10s) b [10s,20s) gap c [30s,40s), file 50 s.
  ChapterDraft sample() => ChapterDraft([
    ch('c', 30000, 40000),
    ch('a', 0, 10000),
    ch('b', 10000, 20000),
  ], durationMs: 50000);

  group('construction', () {
    test('sorts chapters and keeps the duration at least the last end', () {
      final d = ChapterDraft([
        ch('b', 5000, 9000),
        ch('a', 0, 5000),
      ], durationMs: 3000);
      expect(d.chapters.map((c) => c.id), ['a', 'b']);
      expect(d.durationMs, 9000);
      expect(d.dirty, isFalse);
      expect(d.canUndo, isFalse);
      expect(d.canRedo, isFalse);
    });

    test('fromChapters keeps notes and round-trips MediaChapter fields', () {
      const yt = MediaChapter(
        id: 'youtube-0-0',
        title: 'Intro',
        startMs: 0,
        endMs: 5000,
        origin: ChapterOrigin.original,
        alternativeTitles: ['Opening'],
      );
      const auto = MediaChapter(
        id: 'auto-1',
        title: 'Song',
        startMs: 5000,
        endMs: 9000,
        origin: ChapterOrigin.auto,
        reviewReasons: ['Name: unsure'],
      );
      final d = ChapterDraft.fromChapters(
        [yt, auto],
        durationMs: 10000,
        notesById: {
          'auto-1': ['Name: unsure'],
        },
      );
      expect(d.chapters[1].notes, ['Name: unsure']);
      expect(d.chapters[0].notes, isEmpty);
      expect(d.chapters[1].origin, ChapterOrigin.auto);

      final moved = d.moveEdge(d.edges[1], 6000);
      final out = moved.toChapters();
      expect(out[0].alternativeTitles, ['Opening']);
      expect(out[0].endMs, 6000);
      expect(out[0].manuallyEdited, isTrue);
      expect(out[0].origin, ChapterOrigin.original);
      expect(out[1].reviewReasons, ['Name: unsure']);
      expect(out[1].startMs, 6000);
      expect(out[1].origin, ChapterOrigin.auto);
      expect(() => validateChapters(out, durationMs: 10000), returnsNormally);
    });

    test('new chapters become user chapters', () {
      final d = ChapterDraft(const [], durationMs: 10000).splitAt(2000);
      final out = d.toChapters().single;
      expect(out.origin, ChapterOrigin.user);
      expect(out.startMs, 2000);
      expect(out.endMs, 10000);
      expect(out.id, startsWith('local-'));
    });
  });

  group('edges', () {
    test('lists shared edges, lone starts and lone ends in order', () {
      final edges = sample().edges;
      expect(edges, const [
        DraftEdge(ms: 0, rightId: 'a'),
        DraftEdge(ms: 10000, leftId: 'a', rightId: 'b'),
        DraftEdge(ms: 20000, leftId: 'b'),
        DraftEdge(ms: 30000, rightId: 'c'),
        DraftEdge(ms: 40000, leftId: 'c'),
      ]);
      expect(edges[1].shared, isTrue);
      expect(edges[0].shared, isFalse);
      expect(edges[2].shared, isFalse);
    });

    test('no chapters means no edges', () {
      final d = ChapterDraft(const [], durationMs: 10000);
      expect(d.edges, isEmpty);
      expect(d.nearestEdge(500), isNull);
    });

    test('a chapter not at file start gets a lone start edge', () {
      final d = ChapterDraft([ch('a', 2000, 8000)], durationMs: 10000);
      expect(d.edges, const [
        DraftEdge(ms: 2000, rightId: 'a'),
        DraftEdge(ms: 8000, leftId: 'a'),
      ]);
    });

    test('keys stay the same after a move and find the edge again', () {
      final d = sample();
      final e = d.edges[1];
      final moved = d.moveEdge(e, 12000);
      final again = moved.edgeByKey(e.key);
      expect(again, const DraftEdge(ms: 12000, leftId: 'a', rightId: 'b'));
      expect(moved.edgeByKey('nope|nada'), isNull);
    });

    test('nearestEdge picks the closest edge', () {
      final d = sample();
      expect(d.nearestEdge(26000)!.ms, 30000);
      expect(d.nearestEdge(24000)!.ms, 20000);
      expect(d.nearestEdge(-500)!.ms, 0);
    });

    test('chapterIndexAt includes the start and excludes the end', () {
      final d = sample();
      expect(d.chapterIndexAt(0), 0);
      expect(d.chapterIndexAt(9999), 0);
      expect(d.chapterIndexAt(10000), 1);
      expect(d.chapterIndexAt(25000), isNull);
      expect(d.chapterIndexAt(40000), isNull);
      expect(d.chapterIndexAt(50000), isNull);
    });
  });

  group('clampEdge', () {
    test('shared edge keeps both chapters at least the minimum length', () {
      final d = sample();
      final e = d.edges[1];
      expect(d.clampEdge(e, 0), min);
      expect(d.clampEdge(e, 19900), 20000 - min);
      expect(d.clampEdge(e, 15000), 15000);
    });

    test('file-start edge cannot go before 0', () {
      final d = sample();
      expect(d.clampEdge(d.edges[0], -5000), 0);
      expect(d.clampEdge(d.edges[0], 9500), 10000 - min);
    });

    test('lone end can grow into the gap but not over the next chapter', () {
      final d = sample();
      final end = d.edges[2];
      expect(d.clampEdge(end, 25000), 25000);
      expect(d.clampEdge(end, 35000), 30000);
      expect(d.clampEdge(end, 10200), 10000 + min);
    });

    test('lone start can move back into the gap but not over the chapter '
        'before it', () {
      final d = sample();
      final start = d.edges[3];
      expect(d.clampEdge(start, 25000), 25000);
      expect(d.clampEdge(start, 15000), 20000);
      expect(d.clampEdge(start, 39900), 40000 - min);
    });

    test('last end is limited by the file end', () {
      final d = sample();
      expect(d.clampEdge(d.edges.last, 60000), 50000);
    });

    test('an edge with no valid place stays where it is', () {
      final d = ChapterDraft([
        ch('a', 0, 500),
        ch('b', 500, 1200),
      ], durationMs: 5000);
      final shared = d.edges[1];
      expect(d.clampEdge(shared, 800), 500);
      expect(d.moveEdge(shared, 800), same(d));
    });

    test('a too-short chapter can still be made longer', () {
      final d = ChapterDraft([
        ch('a', 0, 500),
        ch('b', 500, 5000),
      ], durationMs: 5000);
      expect(d.clampEdge(d.edges[1], 3000), 3000);
      expect(d.clampEdge(d.edges[1], 700), min);
    });

    test('unknown chapters leave the edge unchanged', () {
      final d = sample();
      expect(d.clampEdge(const DraftEdge(ms: 7, leftId: 'zz'), 900), 7);
    });
  });

  group('moveEdge', () {
    test('moves both sides of a shared edge and marks them edited', () {
      final d = sample();
      final moved = d.moveEdge(d.edges[1], 12345);
      expect(ranges(moved), [
        ('a', 0, 12345),
        ('b', 12345, 20000),
        ('c', 30000, 40000),
      ]);
      expect(moved.chapters[0].edited, isTrue);
      expect(moved.chapters[1].edited, isTrue);
      expect(moved.chapters[2].edited, isFalse);
      expect(moved.dirty, isTrue);
      expect(d.dirty, isFalse, reason: 'the old draft is unchanged');
    });

    test('moving a lone start only changes that chapter', () {
      final d = sample();
      final moved = d.moveEdge(d.edges[3], 28000);
      expect(ranges(moved).last, ('c', 28000, 40000));
      expect(moved.chapters[1].edited, isFalse);
    });

    test('moving a lone start onto the previous end makes a shared edge', () {
      final d = sample();
      final moved = d.moveEdge(d.edges[3], 0);
      expect(ranges(moved).last, ('c', 20000, 40000));
      expect(
        moved.edges,
        contains(const DraftEdge(ms: 20000, leftId: 'b', rightId: 'c')),
      );
    });

    test('moving a lone end clamps to the file end', () {
      final d = sample();
      final moved = d.moveEdge(d.edges.last, 99999);
      expect(ranges(moved).last, ('c', 30000, 50000));
    });

    test('a move to the same place is not a change', () {
      final d = sample();
      expect(d.moveEdge(d.edges[1], 10000), same(d));
      expect(d.moveEdge(d.edges[1], 10000).canUndo, isFalse);
    });

    test('moving back to the start position is no longer dirty', () {
      final d = sample();
      final there = d.moveEdge(d.edges[1], 15000);
      final back = there.moveEdge(there.edges[1], 10000);
      expect(back.dirty, isFalse);
      expect(back.canUndo, isTrue);
    });

    test('markSaved makes the saved list the clean one and keeps undo', () {
      final d = sample();
      final moved = d.moveEdge(d.edges[1], 15000);
      final saved = moved.markSaved();
      expect(saved.dirty, isFalse);
      expect(ranges(saved), ranges(moved));
      expect(saved.canUndo, isTrue);

      final again = saved.moveEdge(saved.edges[1], 16000);
      expect(again.dirty, isTrue);
      // Undo back to what was saved is clean; one more step is not.
      final undone = again.undo();
      expect(undone.dirty, isFalse);
      expect(undone.undo().dirty, isTrue);
      expect(ranges(undone.undo()), ranges(d));
    });

    test('markSaved with the saved list keeps later changes dirty', () {
      final d = sample();
      final moved = d.moveEdge(d.edges[1], 15000);
      final saving = moved.chapters;
      // A change made while the save was running.
      final during = moved.moveEdge(moved.edges[1], 16000);
      final saved = during.markSaved(saving);
      expect(saved.dirty, isTrue);
      expect(ranges(saved), ranges(during));
      expect(saved.undo().dirty, isFalse);
    });
  });

  group('splitAt', () {
    test('splits inside a chapter; the right part is a new chapter', () {
      final d = sample();
      final split = d.splitAt(4000);
      expect(split.chapters, hasLength(4));
      expect(split.chapters[0].id, 'a');
      expect(split.chapters[0].endMs, 4000);
      expect(split.chapters[0].edited, isTrue);
      final added = split.chapters[1];
      expect(added.id, startsWith('local-'));
      expect(added.startMs, 4000);
      expect(added.endMs, 10000);
      expect(added.title, 'Chapter 2');
      expect(added.origin, ChapterOrigin.user);
      expect(split.dirty, isTrue);
    });

    test('uses the given title', () {
      final split = sample().splitAt(4000, newTitle: '  New song ');
      expect(split.chapters[1].title, 'New song');
    });

    test('default title skips names already in use', () {
      final d = ChapterDraft([
        ch('a', 0, 10000, title: 'Chapter 2'),
      ], durationMs: 10000);
      expect(d.splitAt(5000).chapters[1].title, 'Chapter 3');
    });

    test('refuses a piece shorter than the minimum', () {
      final d = sample();
      expect(d.splitAt(10000 - min + 1), same(d));
      expect(d.splitAt(min - 1), same(d));
      expect(d.splitAt(10000), same(d), reason: 'exactly at a boundary');
      expect(d.splitAt(min).chapters, hasLength(4));
    });

    test('in a gap makes a chapter up to the next chapter start', () {
      final split = sample().splitAt(22000);
      expect(ranges(split)[2], (split.chapters[2].id, 22000, 30000));
      expect(split.chapters[2].title, 'Chapter 3');
      expect(split.chapters[1].edited, isFalse);
    });

    test('after the last chapter makes a chapter to the file end', () {
      final split = sample().splitAt(45000);
      expect(split.chapters.last.startMs, 45000);
      expect(split.chapters.last.endMs, 50000);
    });

    test('in a gap too short for a chapter does nothing', () {
      final d = sample();
      expect(d.splitAt(29500), same(d));
      expect(d.splitAt(49500), same(d));
    });

    test('with no chapters makes one chapter to the file end', () {
      final d = ChapterDraft(const [], durationMs: 60000);
      final split = d.splitAt(12000);
      expect(split.chapters.single.startMs, 12000);
      expect(split.chapters.single.endMs, 60000);
      expect(split.chapters.single.title, 'Chapter 1');
      final again = split.splitAt(30000);
      expect(again.chapters.map((c) => (c.startMs, c.endMs)), [
        (12000, 30000),
        (30000, 60000),
      ]);
      expect(again.chapters[1].title, 'Chapter 2');
    });

    test('outside the file does nothing', () {
      final d = sample();
      expect(d.splitAt(-1), same(d));
      expect(d.splitAt(50000), same(d));
    });

    test('new ids are unique', () {
      var d = ChapterDraft(const [], durationMs: 100000);
      for (var ms = 5000; ms < 100000; ms += 5000) {
        d = d.splitAt(ms);
      }
      final ids = d.chapters.map((c) => c.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(
        () => validateChapters(d.toChapters(), durationMs: 100000),
        returnsNormally,
      );
    });
  });

  group('removeEdge and merge', () {
    test('removing a shared edge merges and keeps the left title', () {
      final d = sample();
      final merged = d.removeEdge(d.edges[1], keepLeftTitle: true);
      expect(ranges(merged), [('a', 0, 20000), ('c', 30000, 40000)]);
      expect(merged.chapters[0].title, 'A');
      expect(merged.chapters[0].edited, isTrue);
    });

    test('keeping the right title keeps the right chapter', () {
      final d = ChapterDraft([
        ch('a', 0, 10000),
        const DraftChapter(
          id: 'b',
          title: 'B',
          startMs: 10000,
          endMs: 20000,
          notes: ['Timing: rough'],
        ),
      ], durationMs: 20000);
      final merged = d.removeEdge(d.edges[1], keepLeftTitle: false);
      expect(ranges(merged), [('b', 0, 20000)]);
      expect(merged.chapters.single.title, 'B');
      expect(merged.chapters.single.notes, ['Timing: rough']);
    });

    test('lone edges cannot be removed', () {
      final d = sample();
      expect(d.removeEdge(d.edges[0], keepLeftTitle: true), same(d));
      expect(d.removeEdge(d.edges[2], keepLeftTitle: true), same(d));
    });

    test('a stale shared edge whose chapters no longer touch is ignored', () {
      final d = sample();
      const stale = DraftEdge(ms: 20000, leftId: 'b', rightId: 'c');
      expect(d.removeEdge(stale, keepLeftTitle: true), same(d));
    });

    test('mergeWithNext covers the gap', () {
      final merged = sample().mergeWithNext('b');
      expect(ranges(merged), [('a', 0, 10000), ('b', 10000, 40000)]);
      expect(sample().mergeWithNext('c'), isNot(same(merged)));
      final d = sample();
      expect(d.mergeWithNext('c'), same(d), reason: 'no next chapter');
      expect(d.mergeWithNext('zz'), same(d));
    });
  });

  group('rename, delete, create', () {
    test('rename trims and marks edited; empty or same is ignored', () {
      final d = sample();
      final renamed = d.rename('b', '  Better ');
      expect(renamed.chapters[1].title, 'Better');
      expect(renamed.chapters[1].edited, isTrue);
      expect(d.rename('b', '   '), same(d));
      expect(d.rename('b', 'B'), same(d));
      expect(d.rename('nope', 'X'), same(d));
    });

    test('delete leaves a gap', () {
      final d = sample().delete('b');
      expect(ranges(d), [('a', 0, 10000), ('c', 30000, 40000)]);
      expect(d.edges[1], const DraftEdge(ms: 10000, leftId: 'a'));
      expect(sample().delete('zz').canUndo, isFalse);
    });

    test('createFromScratch covers the file only when empty', () {
      final empty = ChapterDraft(const [], durationMs: 30000);
      final created = empty.createFromScratch('Whole mix');
      expect(created.chapters.single.title, 'Whole mix');
      expect(created.chapters.single.startMs, 0);
      expect(created.chapters.single.endMs, 30000);
      expect(created.dirty, isTrue);
      expect(empty.createFromScratch('  ').chapters.single.title, 'Chapter 1');
      final d = sample();
      expect(d.createFromScratch('x'), same(d));
      final tiny = ChapterDraft(const [], durationMs: 500);
      expect(tiny.createFromScratch('x'), same(tiny));
    });
  });

  group('undo and redo', () {
    test('steps back and forward through changes', () {
      final d0 = sample();
      final d1 = d0.moveEdge(d0.edges[1], 12000);
      final d2 = d1.rename('c', 'Closing');
      final d3 = d2.delete('a');

      final u1 = d3.undo();
      expect(ranges(u1), ranges(d2));
      expect(u1.canRedo, isTrue);
      final u2 = u1.undo();
      expect(ranges(u2), ranges(d1));
      expect(u2.chapters[2].title, 'C');
      final u3 = u2.undo();
      expect(ranges(u3), ranges(d0));
      expect(u3.canUndo, isFalse);
      expect(u3.dirty, isFalse);
      expect(u3.undo(), same(u3));

      final r1 = u3.redo();
      expect(ranges(r1), ranges(d1));
      expect(r1.dirty, isTrue);
      final r3 = r1.redo().redo();
      expect(ranges(r3), ranges(d3));
      expect(r3.canRedo, isFalse);
      expect(r3.redo(), same(r3));
    });

    test('a new change clears redo', () {
      final d0 = sample();
      final d1 = d0.moveEdge(d0.edges[1], 12000).undo();
      expect(d1.canRedo, isTrue);
      final d2 = d1.rename('a', 'Alpha');
      expect(d2.canRedo, isFalse);
      expect(d2.canUndo, isTrue);
    });

    test('a refused change is not an undo step', () {
      final d0 = sample();
      expect(d0.splitAt(29500).canUndo, isFalse);
    });

    test('withDuration keeps history and is not undoable', () {
      final d0 = ChapterDraft(const [], durationMs: 0);
      expect(d0.createFromScratch('x'), same(d0));
      final known = d0.withDuration(40000);
      expect(known.durationMs, 40000);
      expect(known.canUndo, isFalse);
      final created = known.createFromScratch('x');
      expect(created.chapters.single.endMs, 40000);
      expect(created.undo().withDuration(40000).chapters, isEmpty);
    });
  });
}
