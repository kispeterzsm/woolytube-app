import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/widgets/mini_player.dart';

import '../helpers/player_shell_harness.dart';

final _title = find.byKey(const ValueKey('player-mini-title'));

void main() {
  testWidgets('mini bar shows the track with Material, tooltips, semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final harness = await pumpPlayerShell(tester);
    harness.position.add(const Duration(seconds: 30));
    await tester.pumpAndSettle();

    expect(find.byType(MiniPlayerBar), findsOneWidget);
    expect(_title, findsOneWidget);
    expect(tester.widget<Text>(_title).data, 'Audio track');
    expect(find.text('0:30 / 3:00'), findsOneWidget);
    // Text inside the bar has a Material ancestor (no yellow underline).
    expect(
      find.ancestor(of: _title, matching: find.byType(Material)),
      findsWidgets,
    );
    expect(find.bySemanticsLabel('Open player'), findsOneWidget);
    // Tooltips work: the bar has an Overlay above it.
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Next'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Pause'));
    expect(harness.playback.toggleCalls, 1);
    await tester.tap(find.byTooltip('Next'));
    expect(harness.playback.nextCalls, 1);

    await tester.tap(find.text('0:30 / 3:00'));
    await tester.pumpAndSettle();
    expect(harness.shellState(tester).expansion.value, 1);
    handle.dispose();
  });

  testWidgets('bar slides in when playback starts and out when it stops', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester, startPlaying: false);
    final shell = harness.shellState(tester);
    final page = find.byKey(const ValueKey('test-page'));
    final fullHeight = tester.getSize(page).height;
    expect(find.byType(MiniPlayerBar), findsNothing);

    harness.play(harness.audioTrack);
    // One frame to deliver the track, one for the animation's first tick.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-way: the bar is partly in and the page is shrinking smoothly.
    expect(shell.presence.value, inExclusiveRange(0.0, 1.0));
    expect(find.byType(MiniPlayerBar), findsOneWidget);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(page).height,
      closeTo(fullHeight - shell.geometry.miniHeight, 0.01),
    );

    harness.track.add(null);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(shell.presence.value, inExclusiveRange(0.0, 1.0));
    await tester.pumpAndSettle();
    expect(find.byType(MiniPlayerBar), findsNothing);
    expect(tester.getSize(page).height, fullHeight);
  });

  testWidgets('a video plays in the bar after the full screen is closed', (
    tester,
  ) async {
    final harness = await pumpPlayerShell(tester, video: true);
    final shell = harness.shellState(tester);
    expect(shell.expansion.value, 1);
    shell.collapse();
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('test-video-surface'));
    expect(surface, findsOneWidget);
    // The 16:9 picture covers the square thumbnail slot.
    final rect = tester.getRect(surface);
    expect(rect.height, closeTo(48, 0.01));
    expect(rect.width, closeTo(48 * 16 / 9, 0.01));
  });
}
