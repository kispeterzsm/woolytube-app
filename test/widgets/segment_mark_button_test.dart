import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/widgets/segment_mark_button.dart';

class _Playback implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('End segment does not call back once the button is gone', (
    tester,
  ) async {
    final shown = ValueNotifier(true);
    var actions = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackServiceProvider.overrideWithValue(_Playback()),
          pendingSegmentMarkStartProvider.overrideWith(
            (ref) => Stream.value(const Duration(seconds: 3)),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder:
                  (context, value, _) =>
                      value
                          ? SegmentMarkButton(onAction: () => actions++)
                          : const SizedBox(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SegmentMarkButton));
    await tester.pumpAndSettle();
    expect(find.text('Segment category'), findsOneWidget);

    // The video view goes away while the picker is open; then the picker
    // is dismissed.
    shown.value = false;
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Segment category'), findsNothing);
    expect(actions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('End segment calls back after the picker is dismissed', (
    tester,
  ) async {
    var actions = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackServiceProvider.overrideWithValue(_Playback()),
          pendingSegmentMarkStartProvider.overrideWith(
            (ref) => Stream.value(const Duration(seconds: 3)),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: SegmentMarkButton(onAction: () => actions++)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SegmentMarkButton));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(actions, 1);
  });
}
