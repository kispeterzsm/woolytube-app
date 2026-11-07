import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/player/player_layout.dart';
import 'package:woolytube/player/video_view.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/services/chapter_playback.dart';
import 'package:woolytube/services/chapters.dart';

import '../helpers/player_shell_harness.dart';

final _background = find.byKey(const ValueKey('player-sheet-background'));
final _miniTitle = find.byKey(const ValueKey('player-mini-title'));
final _miniBar = find.byKey(const ValueKey('mini-player-bar'));
final _dragArea = find.byKey(const ValueKey('player-panel-drag-area'));

double _opacityOf(WidgetTester tester, Finder finder) {
  var opacity = 1.0;
  for (final widget in tester.widgetList<Opacity>(
    find.ancestor(of: finder, matching: find.byType(Opacity)),
  )) {
    opacity *= widget.opacity;
  }
  return opacity;
}

void main() {
  testWidgets('tapping the mini bar morphs it into the panel', (tester) async {
    final harness = await pumpPlayerShell(tester);
    final shell = harness.shellState(tester);
    final geometry = shell.geometry;
    final pageSize = tester.getSize(find.byKey(const ValueKey('test-page')));
    final miniRect = tester.getRect(_background);
    expect(miniRect.height, closeTo(geometry.miniHeight, 0.01));
    expect(audioPlayerOverlayHeightNotifier.value, 0);

    await tester.tap(_miniTitle, warnIfMissed: false);
    await tester.pump();

    var lastHeight = miniRect.height;
    var sawIntermediate = false;
    for (var frame = 0; frame < 30 && shell.expansion.isAnimating; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final t = shell.expansion.value;
      final height = tester.getRect(_background).height;
      // Something is always on screen: the sheet only grows, from the bar.
      expect(height, greaterThanOrEqualTo(lastHeight - 0.01));
      lastHeight = height;
      if (t > 0.05 && t < 0.3) {
        sawIntermediate = true;
        // The bar is still visible while it turns into the panel.
        expect(_miniTitle, findsOneWidget);
        expect(_opacityOf(tester, _miniTitle), greaterThan(0.2));
        expect(height, greaterThan(geometry.miniHeight));
        expect(height, lessThan(geometry.panelHeight));
      }
      // The page underneath keeps its size during the whole transition.
      expect(tester.getSize(find.byKey(const ValueKey('test-page'))), pageSize);
      // The inset is published once, not animated per frame.
      expect(audioPlayerOverlayHeightNotifier.value, geometry.overlayHeight);
    }
    expect(sawIntermediate, isTrue);
    await tester.pumpAndSettle();

    expect(shell.expansion.value, 1);
    expect(
      tester.getRect(_background).height,
      closeTo(geometry.panelHeight, 0.01),
    );
    expect(find.byTooltip('Minimize player'), findsOneWidget);
    expect(find.text('Track 1 of 2'), findsOneWidget);
    expect(find.text('Audio track'), findsOneWidget);
    expect(audioPlayerOverlayHeightNotifier.value, geometry.overlayHeight);
    expect(geometry.overlayHeight, greaterThan(200));
    // No full-screen barrier: the list above the panel still takes taps.
    await tester.tap(find.text('Row 1'));
    expect(shell.expansion.value, 1);

    await tester.tap(find.byTooltip('Minimize player'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(audioPlayerOverlayHeightNotifier.value, geometry.overlayHeight);
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 0);
    expect(audioPlayerOverlayHeightNotifier.value, 0);
    expect(_miniTitle, findsOneWidget);
    expect(_opacityOf(tester, _miniTitle), 1);
  });

  testWidgets('dragging follows the finger and snaps on release', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester);
    final shell = harness.shellState(tester);
    final range = shell.geometry.dragRange(0);

    final gesture = await tester.startGesture(tester.getCenter(_miniBar));
    await gesture.moveBy(
      const Offset(0, -30),
      timeStamp: const Duration(milliseconds: 16),
    );
    await gesture.moveBy(
      const Offset(0, -60),
      timeStamp: const Duration(milliseconds: 32),
    );
    await tester.pump();
    final followed = shell.expansion.value;
    expect(followed, greaterThan(0.1));
    expect(followed, lessThan(90 / range + 0.01));
    expect(_miniTitle, findsOneWidget);
    // Released slowly below half way: snaps back closed.
    await gesture.moveBy(
      const Offset(0, -1),
      timeStamp: const Duration(milliseconds: 600),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 0);

    // A short, fast upward fling opens it.
    await tester.fling(_miniBar, const Offset(0, -60), 1500);
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 1);

    // Dragging the panel's top area down more than half way closes it.
    await tester.drag(_dragArea, Offset(0, range * 0.7));
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 0);

    // Open again and fling it down.
    await tester.tap(_miniTitle, warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.fling(_dragArea, const Offset(0, 50), 1500);
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 0);
  });

  testWidgets('back collapses the player before popping pages', (tester) async {
    final harness = await pumpPlayerShell(tester);
    final shell = harness.shellState(tester);
    harness.pagesKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Second page')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Second page'), findsOneWidget);

    shell.expand();
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 1);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 0);
    expect(find.text('Second page'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Second page'), findsNothing);
    expect(find.text('Row 0'), findsOneWidget);
  });

  testWidgets('pushing a page from above the panel collapses it', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester);
    final shell = harness.shellState(tester);
    shell.expand();
    await tester.pumpAndSettle();
    harness.pagesKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Settings')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(shell.expansion.value, 0);
    expect(_miniTitle, findsOneWidget);
  });

  testWidgets('popups from pages cover the player and pop first', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester);
    final shell = harness.shellState(tester);
    shell.expand();
    await tester.pumpAndSettle();

    final pageContext = tester.element(find.text('Row 0'));
    String? picked;
    showModalBottomSheet<void>(
      context: pageContext,
      builder:
          (_) => ListTile(
            title: const Text('Sheet action'),
            onTap: () => picked = 'action',
          ),
    );
    await tester.pumpAndSettle();
    // The sheet is drawn above the expanded panel: a tap on it reaches it.
    await tester.tap(find.text('Sheet action'));
    expect(picked, 'action');
    // Popping with the page's context closes the sheet, not the page.
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    expect(find.text('Sheet action'), findsNothing);
    expect(find.text('Row 0'), findsOneWidget);
    expect(shell.expansion.value, 1);

    // Back closes a dialog before it collapses the player.
    showDialog<void>(
      context: pageContext,
      builder: (_) => const AlertDialog(title: Text('Question')),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Question'), findsNothing);
    expect(shell.expansion.value, 1);
  });

  testWidgets('snackbars appear above the mini player', (tester) async {
    final harness = await pumpPlayerShell(tester);
    final shell = harness.shellState(tester);
    ScaffoldMessenger.of(
      tester.element(find.text('Row 0')),
    ).showSnackBar(const SnackBar(content: Text('Saved')));
    await tester.pumpAndSettle();
    final snack = tester.getRect(find.byType(SnackBar));
    final screen = tester.getRect(find.byType(MaterialApp));
    expect(snack.bottom, closeTo(screen.bottom - shell.geometry.miniHeight, 1));
  });

  testWidgets('video opens full screen automatically and hides the pages', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester, startPlaying: false);
    final shell = harness.shellState(tester);
    expect(_background, findsNothing);

    harness.play(harness.videoTrack, video: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // Mid-animation the video grows out of the bar; the page is still there.
    expect(find.byKey(const ValueKey('test-video-surface')), findsOneWidget);
    expect(find.text('Row 0'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(shell.expansion.value, 1);
    expect(shell.videoness.value, 1);
    expect(find.byType(VideoView), findsOneWidget);
    expect(find.text('Row 0'), findsNothing, reason: 'pages are offstage');
    expect(videoFullscreenNotifier.value, isTrue);
    expect(audioPlayerOverlayHeightNotifier.value, 0);
    expect(
      tester.getRect(find.byKey(const ValueKey('test-video-surface'))).width,
      tester.getSize(find.byType(MaterialApp)).width,
    );
    expect(
      harness.systemCalls.map((c) => c.arguments.toString()),
      contains(contains('immersiveSticky')),
    );

    harness.systemCalls.clear();
    await tester.binding.handlePopRoute();
    // System UI is restored when the collapse starts, not at its end.
    expect(
      harness.systemCalls.map((c) => c.method),
      contains('SystemChrome.setEnabledSystemUIOverlays'),
    );
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 0);
    expect(find.text('Row 0'), findsOneWidget);
    expect(videoFullscreenNotifier.value, isFalse);
    // The video keeps playing in the mini bar.
    expect(find.byKey(const ValueKey('test-video-surface')), findsOneWidget);
  });

  testWidgets('locked video ignores back; swipe down minimizes', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester, video: true);
    final shell = harness.shellState(tester);
    expect(shell.expansion.value, 1);

    await tester.tap(find.byTooltip('Lock controls'));
    await tester.pumpAndSettle();
    expect(shell.videoLocked.value, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 1, reason: 'back is blocked while locked');

    await tester.tap(find.byTooltip('Unlock controls'));
    await tester.pumpAndSettle();
    expect(shell.videoLocked.value, isFalse);

    // Swipe on an empty part of the picture (not on a button).
    final layer = tester.getRect(
      find.byKey(const ValueKey('video-gesture-layer')),
    );
    await tester.flingFrom(
      Offset(layer.left + 30, layer.center.dy - 60),
      const Offset(0, 200),
      1200,
    );
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 0);
  });

  testWidgets('turning audio-only off opens the video player', (tester) async {
    final harness = await pumpPlayerShell(tester);
    final shell = harness.shellState(tester);
    expect(shell.expansion.value, 0);

    harness.playback.video = true;
    harness.isVideo.add(true);
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 1);
    expect(shell.videoness.value, 1);

    // Back to audio-only while open: the full screen shrinks to the panel.
    harness.playback.video = false;
    harness.isVideo.add(false);
    await tester.pumpAndSettle();
    expect(shell.expansion.value, 1);
    expect(shell.videoness.value, 0);
    expect(find.byTooltip('Minimize player'), findsOneWidget);
    expect(
      audioPlayerOverlayHeightNotifier.value,
      shell.geometry.overlayHeight,
    );
  });

  testWidgets('swiping the mini bar down stops playback', (tester) async {
    final harness = await pumpPlayerShell(tester);
    final shell = harness.shellState(tester);
    await tester.drag(_miniBar, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(harness.playback.stopCalls, 1);
    expect(_background, findsNothing);
    expect(shell.presence.value, 0);

    // A small swipe springs back and keeps playing.
    harness.play(harness.audioTrack);
    await tester.pumpAndSettle();
    await tester.timedDrag(
      _miniBar,
      const Offset(0, 40),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(harness.playback.stopCalls, 1);
    expect(shell.dismissal.value, 0);
  });

  testWidgets('the panel has labelled controls and a deliberate stop', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester);
    harness.shellState(tester).expand();
    await tester.pumpAndSettle();

    for (final label in ['Shuffle', 'Autoplay', 'Sleep', 'Chapters']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Audio only'), findsOneWidget);
    expect(find.text('Next file'), findsNothing);
    expect(find.byTooltip('Next'), findsOneWidget);

    await tester.tap(find.byTooltip('Next'));
    await tester.tap(find.byTooltip('Previous'));
    await tester.tap(find.byTooltip('Pause'));
    expect(harness.playback.nextCalls, 1);
    expect(harness.playback.previousCalls, 1);
    expect(harness.playback.toggleCalls, 1);

    await tester.tap(find.byTooltip('Forward 10 seconds'));
    expect(harness.playback.seeks.last, const Duration(seconds: 10));

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(harness.playback.stopCalls, 1);
    expect(audioPlayerOverlayHeightNotifier.value, 0);
    expect(_background, findsNothing);
  });

  testWidgets('Next file appears only while chapters play as tracks', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester);
    harness.shellState(tester).expand();
    await tester.pumpAndSettle();
    expect(find.text('Next file'), findsNothing);

    const chapter = MediaChapter(
      id: 'c1',
      title: 'Chapter one',
      startMs: 0,
      endMs: 60000,
    );
    harness.item.add(PlaybackItem(harness.audioTrack, chapter));
    await tester.pumpAndSettle();
    expect(find.text('Next file'), findsOneWidget);
    expect(find.byTooltip('Next chapter'), findsOneWidget);
    await tester.tap(find.text('Next file'));
    expect(harness.playback.nextFileCalls, 1);
  });

  testWidgets('seek bar holds the dragged position until the seek lands', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester);
    harness.shellState(tester).expand();
    await tester.pumpAndSettle();

    final slider = find.byType(Slider);
    final rect = tester.getRect(slider);
    await tester.tapAt(Offset(rect.left + rect.width * 0.75, rect.center.dy));
    await tester.pump();
    expect(harness.playback.seeks, isNotEmpty);
    final target = harness.playback.seeks.last;
    expect(target.inSeconds, inInclusiveRange(120, 150));
    // The player has not reported the new position yet: no snap back.
    expect(
      tester.widget<Slider>(slider).value,
      closeTo(target.inMilliseconds.toDouble(), 1),
    );
    harness.position.add(target);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Slider>(slider).value,
      closeTo(target.inMilliseconds.toDouble(), 1),
    );
  });

  testWidgets('mini bar buttons have working tooltips', (tester) async {
    final harness = await pumpPlayerShell(tester);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Next'), findsOneWidget);
    await tester.longPress(find.byTooltip('Next'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Next'));
    expect(harness.playback.nextCalls, 1);
    // No stop button right next to Next any more.
    expect(find.byIcon(Icons.close), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });

  testWidgets('pages see the keyboard and system insets minus the bar', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final harness = await pumpPlayerShell(tester);
    final shell = harness.shellState(tester);
    final dpr = tester.view.devicePixelRatio;
    // The bar sits above the system navigation bar.
    expect(shell.geometry.bottomInset, closeTo(48 / dpr, 0.01));
    expect(
      tester.getRect(_background).height,
      closeTo(PlayerLayout.miniHeight + 48 / dpr, 0.01),
    );
    final page = find.byKey(const ValueKey('test-page'));
    expect(MediaQuery.paddingOf(tester.element(page)).bottom, 0);

    tester.view.viewInsets = FakeViewPadding(bottom: 300 * dpr);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    // The page already ends above the bar: it only needs the rest.
    expect(
      MediaQuery.viewInsetsOf(tester.element(page)).bottom,
      closeTo(300 - shell.geometry.miniHeight, 0.01),
    );
  });

  test('clock format is consistent', () {
    expect(formatClock(const Duration(seconds: 5)), '0:05');
    expect(formatClock(const Duration(minutes: 59, seconds: 59)), '59:59');
    expect(formatClock(const Duration(hours: 2, minutes: 5)), '2:05:00');
    expect(formatClock(const Duration(seconds: -65)), '-1:05');
  });

  test('video rectangles fit and cover', () {
    const box = Rect.fromLTWH(0, 0, 100, 100);
    expect(fitVideoRect(box, 2, cover: false).size, const Size(100, 50));
    expect(fitVideoRect(box, 2, cover: true).size, const Size(200, 100));
  });
}
