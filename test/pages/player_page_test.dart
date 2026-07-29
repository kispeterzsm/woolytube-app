import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/player_page.dart';
import 'package:woolytube/providers/playback_providers.dart';

void main() {
  setUp(() {
    videoFullscreenNotifier.value = false;
  });

  tearDown(() {
    videoFullscreenNotifier.value = false;
  });

  testWidgets('expanded player route owns mini-player visibility', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(null),
          ),
          isVideoContentProvider.overrideWith(
            (ref) => Stream<bool>.value(false),
          ),
        ],
        child: const MaterialApp(home: PlayerPage()),
      ),
    );

    expect(videoFullscreenNotifier.value, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    expect(videoFullscreenNotifier.value, isFalse);
  });
}
