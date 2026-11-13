import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/chapter_editor_page.dart';
import 'package:woolytube/providers/chapter_editor_providers.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/recognition/audio_window_decoder.dart';
import 'package:woolytube/services/waveform_service.dart';

import '../helpers/test_database.dart';
import 'chapter_editor_fakes.dart';

const _youTube = [
  MediaChapter(
    id: 'a',
    title: 'Intro',
    startMs: 0,
    endMs: 60000,
    origin: ChapterOrigin.original,
  ),
  MediaChapter(
    id: 'b',
    title: 'Song',
    startMs: 60000,
    endMs: 120000,
    origin: ChapterOrigin.original,
  ),
  MediaChapter(
    id: 'c',
    title: 'Outro',
    startMs: 120000,
    endMs: 180000,
    origin: ChapterOrigin.original,
  ),
];

void main() {
  late Directory dir;
  late Track track;
  late FakePreviewFactory previews;
  late WaveformService waveforms;
  List<(List<MediaChapter>, int)> saves = [];
  bool? popped;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('woolytube-editor-');
    final media = File('${dir.path}/mix.mp3')..writeAsBytesSync([1, 2, 3]);
    final db = openTestDatabase();
    final playlist = await insertTestPlaylist(db);
    track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Long mix',
      status: 'complete',
      filePath: media.path,
      durationSeconds: 180,
    );
    await db.close();
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() {
    ChapterEditorPage.resetSessionChoices();
    previews = FakePreviewFactory();
    waveforms = fakeWaveforms();
    saves = [];
    popped = null;
  });

  Future<void> pumpEditor(
    WidgetTester tester, {
    List<MediaChapter> initial = _youTube,
    int? durationMs = 180000,
    String? focus,
    Size size = const Size(400, 1800),
    Map<String, List<String>> notes = const {},
    Future<bool> Function(List<MediaChapter>, int)? onSave,
    bool closeOnSave = false,
    int? playingAtMs,
    Stream<int?>? playerPositionMs,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chapterPreviewPlayerFactoryProvider.overrideWithValue(previews.call),
          waveformServiceProvider.overrideWithValue(waveforms),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed: () async {
                    popped = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder:
                            (_) => ChapterEditorPage(
                              track: track,
                              initial: initial,
                              durationMs: durationMs,
                              focusChapterId: focus,
                              saveLabel: 'Save',
                              notesById: notes,
                              closeOnSave: closeOnSave,
                              playingAtMs: playingAtMs,
                              playerPositionMs: playerPositionMs,
                              onSave:
                                  onSave ??
                                  (list, duration) async {
                                    saves.add((list, duration));
                                    return true;
                                  },
                            ),
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  String timeShown(WidgetTester tester) =>
      tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('editor-time')),
                  matching: find.byType(Text),
                )
                .first,
          )
          .data!;

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
  }

  /// Lets a started preview finish, so frames stop and the tree settles.
  Future<void> finishPreview(WidgetTester tester) async {
    previews.last.finish();
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the first shared boundary with both chapter names', (
    tester,
  ) async {
    await pumpEditor(tester);
    expect(find.text('Boundary 2 of 4'), findsOneWidget);
    expect(timeShown(tester), '1:00.000');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-focus')),
        matching: find.text('Intro'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-focus')),
        matching: find.text('Song'),
      ),
      findsOneWidget,
    );
    // The file is opened right away for its real length, but the app's
    // music is left alone until something is played.
    expect(previews.last.opens, greaterThan(0));
    expect(previews.last.ranges, isEmpty);
    await tapKey(tester, 'editor-next-edge');
    expect(find.text('Boundary 3 of 4'), findsOneWidget);
    expect(timeShown(tester), '2:00.000');
    await tapKey(tester, 'editor-prev-edge');
    await tapKey(tester, 'editor-prev-edge');
    expect(find.text('Boundary 1 of 4'), findsOneWidget);
    expect(find.text('Start of the file'), findsOneWidget);
  });

  testWidgets('focuses the start of the chapter it was opened for', (
    tester,
  ) async {
    await pumpEditor(tester, focus: 'c');
    expect(find.text('Boundary 3 of 4'), findsOneWidget);
    expect(timeShown(tester), '2:00.000');
  });

  testWidgets('stand-in chapter names are red in the chapter list', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      initial: [
        _youTube[0].copyWith(title: 'chapter 1'),
        _youTube[1].copyWith(title: unrecognizedChapterTitle),
        _youTube[2],
      ],
    );
    Color? colorOf(String id) {
      final key = ValueKey('editor-chapter-title-$id');
      return tester.widget<Text>(find.byKey(key)).style?.color;
    }

    final error =
        Theme.of(
          tester.element(find.byKey(const ValueKey('editor-chapter-title-c'))),
        ).colorScheme.error;
    expect(colorOf('a'), error);
    expect(colorOf('b'), error);
    expect(colorOf('c'), isNot(error));
  });

  testWidgets('the listen buttons play around the boundary and stop there', (
    tester,
  ) async {
    await pumpEditor(tester);
    final preview = previews.last;

    await tapKey(tester, 'editor-hear-end');
    expect(preview.ranges.last, (startMs: 56000, endMs: 60000, loop: false));
    expect(preview.rests.last, 60000, reason: 'rests on the boundary');
    await finishPreview(tester);
    expect(preview.positionMs, 60000);

    await tapKey(tester, 'editor-play-across');
    expect(preview.ranges.last, (startMs: 56000, endMs: 64000, loop: false));
    await finishPreview(tester);

    await tapKey(tester, 'editor-lead-2000');
    await tapKey(tester, 'editor-loop');
    await tapKey(tester, 'editor-hear-start');
    expect(preview.ranges.last, (startMs: 60000, endMs: 62000, loop: true));
    // Tapping the playing button again stops it.
    await tapKey(tester, 'editor-hear-start');
    expect(preview.isPlaying, isFalse);
    expect(preview.ranges, hasLength(3));
    await tester.pumpAndSettle();
  });

  testWidgets('nudges move a shared boundary, replay it, and undo and redo '
      'step through the changes', (tester) async {
    await pumpEditor(tester);
    final preview = previews.last;

    await tapKey(tester, 'editor-nudge-100');
    expect(timeShown(tester), '1:00.100');
    expect(find.text('+0.100 s from where it was'), findsOneWidget);
    // "Replay after change" plays the default listen mode again.
    await tester.pump(const Duration(milliseconds: 200));
    expect(preview.ranges.last, (startMs: 60100, endMs: 64100, loop: false));
    await finishPreview(tester);

    await tapKey(tester, 'editor-nudge--10');
    await tapKey(tester, 'editor-nudge--1000');
    expect(timeShown(tester), '0:59.090');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
    expect(find.text('0:00 – 0:59.090 · 0:59.090'), findsOneWidget);
    expect(find.text('0:59.090 – 2:00 · 1:00.910'), findsOneWidget);

    await tapKey(tester, 'editor-undo');
    expect(timeShown(tester), '1:00.090');
    await tapKey(tester, 'editor-undo');
    await tapKey(tester, 'editor-undo');
    expect(timeShown(tester), '1:00.000');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('editor-save')))
          .onPressed,
      isNull,
      reason: 'back where it started: nothing to save',
    );
    await tapKey(tester, 'editor-redo');
    expect(timeShown(tester), '1:00.100');
    await tester.pumpAndSettle();
  });

  testWidgets('a boundary never passes its neighbours', (tester) async {
    await pumpEditor(tester, focus: 'b');
    await tapKey(tester, 'editor-time');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('editor-time-field')),
      '5:00',
    );
    await tester.tap(find.text('Move'));
    await tester.pump(const Duration(milliseconds: 500));
    await finishPreview(tester);
    // Stops 1 s before the end of "Song".
    expect(timeShown(tester), '1:59.000');
    expect(find.textContaining('as close as it can go'), findsOneWidget);
  });

  testWidgets('typing an exact time moves the boundary there', (tester) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-time');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('editor-time-field')),
      '1:05.250',
    );
    await tester.tap(find.text('Move'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(timeShown(tester), '1:05.250');
    // And plays its start, where the next song should begin.
    expect(previews.last.ranges.last, (
      startMs: 65250,
      endMs: 69250,
      loop: false,
    ));
    await finishPreview(tester);
  });

  testWidgets('dragging the waveform moves the boundary like tape', (
    tester,
  ) async {
    await pumpEditor(tester);
    expect(find.text('Drag the waveform to move the boundary'), findsOneWidget);
    final lens = find.byKey(const ValueKey('editor-waveform'));
    final width = tester.getSize(lens).width;

    // Dragging left brings later audio under the line: the boundary moves
    // later. 8 seconds span the whole width.
    await tester.drag(lens, const Offset(-100, 0));
    await tester.pump();
    final expected = 60000 + (100 * 8000 / width).round();
    final shown = parseChapterTimestamp(timeShown(tester))!;
    expect((shown - expected).abs(), lessThanOrEqualTo(2));
    expect(find.text('Drag the waveform to move the boundary'), findsNothing);

    // Finer zoom: the same drag is a much smaller move.
    await tapKey(tester, 'editor-undo');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('editor-zoom')),
        matching: find.text('2 s'),
      ),
    );
    await tester.pump();
    await tester.drag(lens, const Offset(50, 0));
    await tester.pump();
    final fine = parseChapterTimestamp(timeShown(tester))!;
    expect((fine - (60000 - (50 * 2000 / width).round())).abs(), lessThan(3));
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
  });

  testWidgets('a pinch on the waveform zooms without scrolling the page', (
    tester,
  ) async {
    await pumpEditor(tester, size: const Size(360, 740));
    final lens = find.byKey(const ValueKey('editor-waveform'));
    final list = tester.state<ScrollableState>(find.byType(Scrollable).last);
    expect(list.position.maxScrollExtent, greaterThan(0));
    final before = list.position.pixels;
    final center = tester.getCenter(lens);
    final a = await tester.startGesture(center - const Offset(20, 5));
    await tester.pump();
    final b = await tester.startGesture(
      center + const Offset(20, 5),
      pointer: 7,
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(-10, -15));
      await b.moveBy(const Offset(10, -15));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(list.position.pixels, before);
  });

  testWidgets('Set here moves the boundary to the playhead', (tester) async {
    await pumpEditor(tester);
    final preview = previews.last;
    final setHere = find.byKey(const ValueKey('editor-set-here'));
    expect(tester.widget<OutlinedButton>(setHere).onPressed, isNull);

    await tapKey(tester, 'editor-play-pause');
    expect(preview.plays, 1);
    preview.position = 63456;
    await tester.pump();
    await tapKey(tester, 'editor-set-here');
    expect(timeShown(tester), '1:03.456');
    // Playback goes on; nothing is replayed over it.
    await tester.pump(const Duration(milliseconds: 300));
    expect(preview.ranges, isEmpty);
    await tapKey(tester, 'editor-play-pause');
    await tester.pumpAndSettle();
    expect(preview.isPlaying, isFalse);
  });

  group('Set here acts only on a playhead the user chose', () {
    OutlinedButton setHere(WidgetTester tester) => tester
        .widget<OutlinedButton>(find.byKey(const ValueKey('editor-set-here')));
    String hint(WidgetTester tester) =>
        tester
            .widget<Text>(find.byKey(const ValueKey('editor-set-here-hint')))
            .data!;
    String position(WidgetTester tester) =>
        tester
            .widget<Text>(find.byKey(const ValueKey('editor-position')))
            .data!;

    testWidgets('A: after a preview ends the playhead rests on the boundary, '
        'and repeated taps never move it', (tester) async {
      await pumpEditor(tester);
      final preview = previews.last;
      expect(hint(tester), 'Play, then tap when you hear the change');

      for (final mode in [
        'editor-hear-start',
        'editor-play-across',
        'editor-hear-end',
      ]) {
        await tapKey(tester, mode);
        expect(preview.rests.last, 60000, reason: mode);
        await finishPreview(tester);
        expect(preview.positionMs, 60000, reason: mode);
        expect(position(tester), '1:00.000', reason: mode);
        // Lit a moment longer, only to say a late tap was too late.
        await tester.pump(const Duration(milliseconds: 700));
        expect(setHere(tester).onPressed, isNull, reason: mode);
        expect(hint(tester), 'Play, then tap when you hear the change');
      }

      final ranges = preview.ranges.length;
      for (var i = 0; i < 3; i++) {
        await tapKey(tester, 'editor-set-here');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      }
      expect(timeShown(tester), '1:00.000');
      expect(preview.ranges, hasLength(ranges), reason: 'nothing replayed');
    });

    testWidgets('a paused playhead the user chose: Set here moves there '
        'once, without replaying, and does not creep', (tester) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-play-pause');
      expect(hint(tester), 'Tap when you hear the change');
      preview.position = 63456;
      await tester.pump();
      await tapKey(tester, 'editor-play-pause');
      await tester.pumpAndSettle();
      expect(setHere(tester).onPressed, isNotNull);
      expect(hint(tester), 'Moves it to the playhead');

      for (var i = 0; i < 4; i++) {
        await tapKey(tester, 'editor-set-here');
        await tester.pump(const Duration(milliseconds: 300));
        expect(timeShown(tester), '1:03.456', reason: 'press ${i + 1}');
        expect(preview.positionMs, 63456);
      }
      expect(find.text('The boundary is already here.'), findsOneWidget);
      expect(preview.ranges, isEmpty);
      await tester.pumpAndSettle();
    });

    testWidgets('B: Set here while "Hear start" plays keeps playing and then '
        'rests on the new spot', (tester) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-hear-start');
      preview.position = 61500;
      await tester.pump();
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:01.500');
      await tester.pump(const Duration(milliseconds: 300));
      expect(preview.ranges, hasLength(1), reason: 'no replay over it');
      expect(preview.isPlaying, isTrue);
      expect(preview.restMs, 61500);

      await finishPreview(tester);
      expect(preview.positionMs, 61500);
      await tester.pump(const Duration(milliseconds: 700));
      expect(setHere(tester).onPressed, isNull);
      await tapKey(tester, 'editor-set-here');
      await tester.pumpAndSettle();
      expect(timeShown(tester), '1:01.500', reason: 'the good tap stays');
    });

    testWidgets('C: two taps while playing keep the later one', (tester) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-play-pause');
      preview.position = 61500;
      await tester.pump();
      await tapKey(tester, 'editor-set-here');
      preview.position = 61780;
      await tester.pump();
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:01.780');
      await tapKey(tester, 'editor-undo');
      expect(timeShown(tester), '1:01.500');
      await tapKey(tester, 'editor-play-pause');
      await tester.pumpAndSettle();
    });

    testWidgets('D: a nudge moves the paused playhead along, so Set here '
        'cannot undo it', (tester) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-hear-start');
      await finishPreview(tester);

      await tapKey(tester, 'editor-nudge-100');
      expect(timeShown(tester), '1:00.100');
      expect(preview.positionMs, 60100);
      expect(preview.parkedSeeks, [60100]);
      // Within the replay delay.
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:00.100');
      await tester.pump(const Duration(milliseconds: 200));
      expect(preview.ranges.last, (startMs: 60100, endMs: 64100, loop: false));
      expect(preview.rests.last, 60100);
      await finishPreview(tester);
      expect(preview.positionMs, 60100);

      // And with "Replay after change" off.
      await tapKey(tester, 'editor-auto-replay');
      await tapKey(tester, 'editor-nudge-100');
      await tester.pump(const Duration(milliseconds: 500));
      expect(preview.positionMs, 60200);
      await tapKey(tester, 'editor-set-here');
      await tester.pumpAndSettle();
      expect(timeShown(tester), '1:00.200');
      expect(preview.ranges, hasLength(2));
    });

    testWidgets('a nudge while a preview plays moves where it comes to rest', (
      tester,
    ) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-auto-replay');
      await tapKey(tester, 'editor-hear-end');
      await tapKey(tester, 'editor-nudge--1000');
      expect(preview.isPlaying, isTrue);
      expect(preview.restMs, 59000);
      await finishPreview(tester);
      expect(preview.positionMs, 59000);
    });

    testWidgets('a tap right after "Hear start" began is not taken for the '
        'change', (tester) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-hear-start');
      preview.position = 60300;
      await tester.pump();
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:00.000');
      expect(find.textContaining('use Play across'), findsOneWidget);

      preview.position = 60800;
      await tester.pump();
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:00.800');
      await finishPreview(tester);
    });

    testWidgets('a tap right after Play started on the boundary is not taken '
        'for the change', (tester) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-hear-start');
      await finishPreview(tester);
      await tester.pump(const Duration(milliseconds: 700));
      expect(preview.positionMs, 60000);

      // Play from where the preview rests: it starts on the boundary.
      await tapKey(tester, 'editor-play-pause');
      expect(preview.isPlaying, isTrue);
      preview.position = 60300;
      await tester.pump();
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:00.000');
      expect(find.textContaining('use Play across'), findsOneWidget);
      preview.position = 61200;
      await tester.pump();
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:01.200');
      await tapKey(tester, 'editor-play-pause');

      // "Play its start" on the selected boundary's chapter is the same.
      await tapKey(tester, 'editor-row-play-b');
      preview.position = 61500;
      await tester.pump();
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:01.200');
      await finishPreview(tester);

      // Playing from a spot the user picked away from the boundary is not
      // guarded: a quick tap there counts.
      await tester.pump(const Duration(milliseconds: 700));
      await tapKey(tester, 'editor-forward-5');
      await tapKey(tester, 'editor-play-pause');
      preview.position = preview.positionMs + 300;
      await tester.pump();
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:06.500');
      await tapKey(tester, 'editor-play-pause');
      await tester.pumpAndSettle();
    });

    testWidgets('a finger that went down while a preview played counts even '
        'if the preview stops before it lifts', (tester) async {
      await pumpEditor(tester);
      final preview = previews.last;
      final button = find.byKey(const ValueKey('editor-set-here'));
      await tapKey(tester, 'editor-hear-end');
      preview.position = 59800;
      await tester.pump();
      await tester.ensureVisible(button);
      final gesture = await tester.startGesture(tester.getCenter(button));
      preview.finish();
      await tester.pump();
      expect(preview.isPlaying, isFalse);
      expect(setHere(tester).onPressed, isNotNull, reason: 'finger is down');
      await tester.pump(const Duration(milliseconds: 80));
      await gesture.up();
      await tester.pump();
      expect(timeShown(tester), '0:59.800');
      await tester.pump(const Duration(milliseconds: 700));
      expect(setHere(tester).onPressed, isNull);

      // Split here too.
      await tapKey(tester, 'editor-play-across');
      preview.position = 62000;
      await tester.pump();
      final split = find.byKey(const ValueKey('editor-split'));
      await tester.ensureVisible(split);
      final down = await tester.startGesture(tester.getCenter(split));
      preview.finish();
      await tester.pump(const Duration(milliseconds: 80));
      await down.up();
      await tester.pump();
      expect(find.textContaining('at 1:02.000'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('a tap just after a preview stopped is told it was too late', (
      tester,
    ) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-hear-end');
      preview.finish();
      await tester.pump();
      expect(setHere(tester).onPressed, isNotNull);
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '1:00.000');
      expect(find.textContaining('Too late'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 700));
      expect(setHere(tester).onPressed, isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('the position is taken when the finger touches, not when it '
        'lifts', (tester) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-play-pause');
      preview.position = 70000;
      await tester.pump();
      final button = find.byKey(const ValueKey('editor-set-here'));
      await tester.ensureVisible(button);
      final gesture = await tester.startGesture(tester.getCenter(button));
      preview.position = 70110;
      await tester.pump(const Duration(milliseconds: 90));
      await gesture.up();
      await tester.pump();
      expect(timeShown(tester), '1:10.000');

      // Split here too.
      preview.position = 90000;
      await tester.pump();
      final split = find.byKey(const ValueKey('editor-split'));
      final down = await tester.startGesture(tester.getCenter(split));
      preview.position = 90090;
      await tester.pump(const Duration(milliseconds: 90));
      await down.up();
      await tester.pump();
      expect(find.textContaining('at 1:30.000'), findsOneWidget);
      await tapKey(tester, 'editor-play-pause');
      await tester.pumpAndSettle();
    });

    testWidgets('Split here after a preview ended says what to do', (
      tester,
    ) async {
      await pumpEditor(tester);
      final preview = previews.last;
      await tapKey(tester, 'editor-hear-start');
      preview.finish();
      await tester.pump();
      await tapKey(tester, 'editor-split');
      expect(find.text('Chapters (3)'), findsOneWidget);
      expect(find.textContaining('Too late'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 700));
      await tapKey(tester, 'editor-split');
      // Shown once the first message has slid away.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Chapters (3)'), findsOneWidget);
      expect(
        find.text('Play, then tap Split here where a new chapter starts.'),
        findsOneWidget,
      );
      // Moving the playhead on purpose makes it count again.
      await tapKey(tester, 'editor-forward-5');
      expect(preview.parked, isFalse);
      expect(setHere(tester).onPressed, isNotNull);
      await tapKey(tester, 'editor-split');
      expect(find.text('Chapters (4)'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });

  testWidgets('Snap to quiet offers the quiet spot near the boundary', (
    tester,
  ) async {
    waveforms = fakeWaveforms(quietFromMs: 60600, quietToMs: 60800);
    await pumpEditor(tester);
    await tester.pumpAndSettle();
    expect(find.text('+0.70 s'), findsOneWidget);
    await tapKey(tester, 'editor-snap-quiet');
    final at = parseChapterTimestamp(timeShown(tester))!;
    expect(at, inInclusiveRange(60650, 60750));
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
    expect(find.text('Already there'), findsOneWidget);
  });

  testWidgets('Snap to quiet says so when the search finds nothing', (
    tester,
  ) async {
    waveforms = WaveformService(_FailingDecoder());
    await pumpEditor(tester);
    await tester.pumpAndSettle();
    expect(find.text('Looking…'), findsNothing);
    expect(find.text('Nothing nearby'), findsOneWidget);
  });

  testWidgets('a boundary made by Split here is new, with nothing to reset '
      'to', (tester) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-play-pause');
    previews.last.position = 30000;
    await tester.pump();
    await tapKey(tester, 'editor-split');
    await tapKey(tester, 'editor-play-pause');
    await tester.pumpAndSettle();
    expect(timeShown(tester), '0:30.000');
    expect(find.text('New boundary'), findsOneWidget);
    expect(find.textContaining('from where it was'), findsNothing);

    await tapKey(tester, 'editor-edge-menu');
    await tester.pumpAndSettle();
    final reset = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('Reset to original position'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(reset.enabled, isFalse);
  });

  testWidgets('removing a boundary merges the chapters with the chosen '
      'title', (tester) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-edge-menu');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove this boundary'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-keep-right')));
    await tester.pumpAndSettle();
    expect(find.text('Chapters (2)'), findsOneWidget);
    expect(find.text('0:00 – 2:00 · 2:00'), findsOneWidget);

    await tapKey(tester, 'editor-save');
    await tester.pumpAndSettle();
    final saved = saves.single.$1;
    expect(saved.map((c) => (c.id, c.title)), [('b', 'Song'), ('c', 'Outro')]);
    expect(saved.first.startMs, 0);
    expect(find.byType(ChapterEditorPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(popped, isTrue);
  });

  testWidgets('chapter rows select their start, play it, rename, delete and '
      'merge', (tester) async {
    await pumpEditor(
      tester,
      notes: {
        'c': ['Timing: Check the start'],
      },
    );
    expect(find.text('Timing: Check the start'), findsOneWidget);
    expect(find.text('YouTube'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('editor-chapter-c')));
    await tester.pumpAndSettle();
    expect(find.text('Boundary 3 of 4'), findsOneWidget);

    await tapKey(tester, 'editor-row-play-c');
    expect(previews.last.ranges.last.startMs, 120000);
    await finishPreview(tester);

    await tester.tap(find.byKey(const ValueKey('editor-row-menu-c')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('editor-rename-field')),
      'Finale',
    );
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(find.text('Finale'), findsWidgets);
    expect(find.text('edited'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('editor-row-menu-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge with next'));
    await tester.pumpAndSettle();
    expect(find.text('Chapters (2)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('editor-row-menu-c')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete (leaves a gap)'));
    await tester.pumpAndSettle();
    expect(find.text('Chapters (1)'), findsOneWidget);
    expect(find.text('No chapter for 1:00'), findsOneWidget);

    await tapKey(tester, 'editor-save');
    await tester.pumpAndSettle();
    final saved = saves.single.$1;
    expect(saved.single.id, 'a');
    expect(saved.single.endMs, 120000);
    expect(saved.single.manuallyEdited, isTrue);
  });

  testWidgets('a file with no chapters starts empty; Split here and "Start '
      'with one chapter" create them', (tester) async {
    await pumpEditor(tester, initial: const [], durationMs: null);
    expect(find.text('No chapters yet'), findsOneWidget);
    // The real length came from the preview player.
    expect(find.text('of 3:00'), findsOneWidget);

    await tapKey(tester, 'editor-play-pause');
    previews.last.position = 42000;
    await tester.pump();
    await tapKey(tester, 'editor-split');
    expect(
      find.textContaining('Added "Chapter 1" at 0:42.000'),
      findsOneWidget,
    );
    expect(find.text('0:42 – 3:00 · 2:18'), findsOneWidget);
    expect(find.text('No chapter for 0:42'), findsOneWidget);

    previews.last.position = 100000;
    await tester.pump();
    await tapKey(tester, 'editor-split');
    expect(find.text('Chapters (2)'), findsOneWidget);
    expect(timeShown(tester), '1:40.000');
    await tapKey(tester, 'editor-play-pause');
    await tester.pumpAndSettle();

    await tapKey(tester, 'editor-save');
    await tester.pumpAndSettle();
    final (saved, duration) = saves.single;
    expect(duration, 180000);
    expect(saved.map((c) => (c.title, c.startMs, c.endMs)), [
      ('Chapter 1', 42000, 100000),
      ('Chapter 2', 100000, 180000),
    ]);
    expect(saved.every((c) => c.origin == ChapterOrigin.user), isTrue);
  });

  testWidgets('"Start with one chapter" covers the whole file', (tester) async {
    await pumpEditor(tester, initial: const []);
    await tapKey(tester, 'editor-start-scratch');
    await tester.pumpAndSettle();
    expect(find.text('0:00 – 3:00 · 3:00'), findsOneWidget);
    expect(find.text('Boundary 1 of 2'), findsOneWidget);
  });

  testWidgets('leaving with changes asks first', (tester) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-nudge-1000');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditorPage), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-discard')));
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditorPage), findsNothing);
    expect(popped, isFalse);
    expect(saves, isEmpty);
    expect(previews.last.disposed, isTrue);
  });

  testWidgets('a failed save keeps the editor open with the reason', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      onSave:
          (list, duration) async =>
              throw const FormatException('Chapters overlap.'),
    );
    await tapKey(tester, 'editor-nudge-1000');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
    await tapKey(tester, 'editor-save');
    await tester.pumpAndSettle();
    expect(find.text('Chapters overlap.'), findsOneWidget);
    expect(find.byType(ChapterEditorPage), findsOneWidget);
  });

  testWidgets('back is ignored while saving', (tester) async {
    final saving = Completer<bool>();
    await pumpEditor(tester, onSave: (list, duration) => saving.future);
    await tapKey(tester, 'editor-nudge-1000');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
    await tapKey(tester, 'editor-save');
    await tester.pump();

    // The progress bar animates while saving: pump, do not settle.
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ChapterEditorPage), findsOneWidget);
    expect(find.text('Discard changes?'), findsNothing);

    saving.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditorPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditorPage), findsNothing);
    expect(popped, isTrue);
  });

  bool saveEnabled(WidgetTester tester) =>
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('editor-save')))
          .onPressed !=
      null;

  testWidgets('Save keeps the editor open; back then leaves without asking '
      'until the next change', (tester) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-nudge-1000');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
    expect(saveEnabled(tester), isTrue);

    await tapKey(tester, 'editor-save');
    await tester.pumpAndSettle();
    expect(saves.single.$1[1].startMs, 61000);
    expect(find.byType(ChapterEditorPage), findsOneWidget);
    expect(find.text('Chapters saved.'), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
    // The saved spot is now where the boundary "was".
    expect(timeShown(tester), '1:01.000');
    expect(find.text('Where it was'), findsOneWidget);

    // A change after the save asks again on back, and is saved on its own.
    await tapKey(tester, 'editor-nudge-100');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
    expect(saveEnabled(tester), isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-save');
    await tester.pumpAndSettle();
    expect(saves, hasLength(2));
    expect(saves.last.$1[1].startMs, 61100);

    // Undo steps back past the save: that is a change again.
    await tapKey(tester, 'editor-undo');
    expect(saveEnabled(tester), isTrue);
    await tapKey(tester, 'editor-redo');
    expect(saveEnabled(tester), isFalse);
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    expect(find.byType(ChapterEditorPage), findsNothing);
    expect(popped, isTrue);
  });

  testWidgets('a change made while saving is not taken as saved', (
    tester,
  ) async {
    final saving = Completer<bool>();
    final stored = <List<MediaChapter>>[];
    await pumpEditor(
      tester,
      onSave: (list, duration) {
        stored.add(list);
        return saving.future;
      },
    );
    await tapKey(tester, 'editor-nudge-1000');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
    await tapKey(tester, 'editor-save');
    await tester.pump();

    // Nudged before the save finished: not in what is being saved.
    await tapKey(tester, 'editor-nudge-100');
    await tester.pump(const Duration(milliseconds: 200));
    previews.last.finish();
    saving.complete(true);
    await tester.pumpAndSettle();
    expect(stored.single[1].startMs, 61000);
    expect(timeShown(tester), '1:01.100');
    expect(saveEnabled(tester), isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    // Undo back to what was saved is clean.
    await tapKey(tester, 'editor-undo');
    expect(saveEnabled(tester), isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('discarding after a save still reports the save', (tester) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-nudge-1000');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
    await tapKey(tester, 'editor-save');
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-nudge-1000');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-discard')));
    await tester.pumpAndSettle();
    expect(find.byType(ChapterEditorPage), findsNothing);
    expect(popped, isTrue);
    expect(saves, hasLength(1));
  });

  testWidgets('with closeOnSave, Save leaves with the result', (tester) async {
    await pumpEditor(tester, closeOnSave: true);
    await tapKey(tester, 'editor-nudge-1000');
    await tester.pump(const Duration(milliseconds: 200));
    await finishPreview(tester);
    await tapKey(tester, 'editor-save');
    await tester.pumpAndSettle();
    expect(saves, hasLength(1));
    expect(find.byType(ChapterEditorPage), findsNothing);
    expect(popped, isTrue);
  });

  group('opened while the app plays this file', () {
    String topBar(WidgetTester tester) =>
        tester
            .widget<Text>(find.byKey(const ValueKey('editor-player-position')))
            .textSpan!
            .toPlainText();

    testWidgets('selects the start of the playing chapter and puts the '
        'playhead where the player is', (tester) async {
      await pumpEditor(tester, playingAtMs: 135420);
      expect(find.text('Boundary 3 of 4'), findsOneWidget);
      expect(timeShown(tester), '2:00.000');
      expect(previews.last.seeks, [135420]);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('editor-position'))).data,
        '2:15.420',
      );
      expect(topBar(tester), endsWith('2:15.420 · Long mix'));
      // The playhead is a spot the user listened to: Set here moves the
      // boundary there.
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '2:15.420');
      await tester.pumpAndSettle();
    });

    testWidgets('Set here and Play use where the player is while the file '
        'is still opening', (tester) async {
      final opening = previews.openGate = Completer<void>();
      await pumpEditor(tester, playingAtMs: 135420);
      expect(previews.last.positionMs, 0);
      expect(previews.last.seeks, isEmpty);
      await tapKey(tester, 'editor-set-here');
      expect(timeShown(tester), '2:15.420');

      await tapKey(tester, 'editor-play-pause');
      opening.complete();
      await tester.pump();
      await tester.pump();
      expect(previews.last.seeks.last, 135420);
      expect(previews.last.plays, 1);
      await finishPreview(tester);
    });

    testWidgets('Retry after a failed open moves the preview to where the '
        'player is', (tester) async {
      previews.failOpen = true;
      await pumpEditor(tester, playingAtMs: 135420);
      expect(previews.last.seeks, isEmpty);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('editor-position'))).data,
        '2:15.420',
      );
      previews.last.failOpen = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(previews.last.seeks, [135420]);
      expect(previews.last.positionMs, 135420);
    });

    testWidgets('in a gap it selects the chapter before it', (tester) async {
      await pumpEditor(
        tester,
        initial: [_youTube[0], _youTube[2]],
        playingAtMs: 90000,
      );
      expect(find.text('Boundary 1 of 4'), findsOneWidget);
    });

    testWidgets('the chapter it was opened for comes first', (tester) async {
      await pumpEditor(tester, focus: 'b', playingAtMs: 135420);
      expect(find.text('Boundary 2 of 4'), findsOneWidget);
    });

    testWidgets('the top bar follows the player to the millisecond', (
      tester,
    ) async {
      final positions = StreamController<int?>();
      addTearDown(positions.close);
      await pumpEditor(
        tester,
        playingAtMs: 1000,
        playerPositionMs: positions.stream,
      );
      expect(topBar(tester), endsWith('0:01.000 · Long mix'));
      positions.add(61234);
      await tester.pumpAndSettle();
      expect(topBar(tester), endsWith('1:01.234 · Long mix'));
      // The player moved on to another file.
      positions.add(null);
      await tester.pumpAndSettle();
      expect(topBar(tester), 'Long mix');
    });

    testWidgets('without the player on this file the top bar shows the '
        'title alone', (tester) async {
      await pumpEditor(tester);
      expect(topBar(tester), 'Long mix');
      expect(previews.last.seeks, isEmpty);
    });
  });

  testWidgets('a length the file never reported is not saved', (tester) async {
    previews.failOpen = true;
    await pumpEditor(tester, durationMs: null);
    await tester.tap(find.byKey(const ValueKey('editor-row-menu-c')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('editor-rename-field')),
      'Finale',
    );
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-save');
    await tester.pumpAndSettle();
    expect(saves.single.$2, 0);
  });

  testWidgets('an empty file that cannot be opened says why it cannot start', (
    tester,
  ) async {
    previews.failOpen = true;
    await pumpEditor(tester, initial: const [], durationMs: null);
    expect(find.text('Opening the file…'), findsNothing);
    expect(
      find.text('The file could not be opened, so its length is unknown.'),
      findsOneWidget,
    );
  });

  testWidgets('a file that cannot be opened still allows editing', (
    tester,
  ) async {
    previews.failOpen = true;
    await pumpEditor(tester);
    expect(find.textContaining('Could not open the file'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('editor-split')))
          .onPressed,
      isNotNull,
    );
    await tapKey(tester, 'editor-nudge-1000');
    expect(timeShown(tester), '1:01.000');
    await tester.pumpAndSettle();
    expect(previews.last.ranges, isEmpty);
  });

  for (final size in const [Size(320, 640), Size(360, 740)]) {
    testWidgets('fits a ${size.width.toInt()} dp wide phone', (tester) async {
      await pumpEditor(
        tester,
        size: size,
        initial: [
          for (final c in _youTube)
            c.copyWith(
              title:
                  '${c.title} with a very long name from a long YouTube '
                  'description that never ends',
            ),
        ],
        notes: {
          'b': ['Name: Only one sampled detection; verify the identity.'],
        },
      );
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
      await tester.pumpAndSettle();
    });
  }
}

/// A decoder that cannot read the file.
class _FailingDecoder implements AudioWindowDecoder {
  @override
  Future<Int16List> decode(
    String path, {
    required Duration start,
    required Duration duration,
  }) async => throw StateError('cannot decode');

  @override
  Future<Duration?> probeDuration(String path) async => null;
}
