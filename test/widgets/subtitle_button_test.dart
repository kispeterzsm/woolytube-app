import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show SubtitleTrack;
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/database/database.dart';
import '../helpers/test_database.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/widgets/subtitle_button.dart';

class _FakePlaybackService implements PlaybackService {
  final selections = <SubtitleTrack>[];

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    selections.add(track);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const english = SubtitleTrack('1', 'English', 'en');
  const hungarian = SubtitleTrack('2', null, 'hu');

  testWidgets('CC menu selects a language, automatic, and off', (tester) async {
    final service = _FakePlaybackService();
    var opened = 0;
    var closed = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackServiceProvider.overrideWithValue(service),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          subtitleTracksProvider.overrideWith(
            (ref) => Stream.value([
              SubtitleTrack.auto(),
              SubtitleTrack.no(),
              english,
              hungarian,
            ]),
          ),
          selectedSubtitleTrackProvider.overrideWith(
            (ref) => Stream.value(english),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SubtitleButton(
              onOpened: () => opened++,
              onClosed: () => closed++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.closed_caption), findsOneWidget);

    for (final label in ['hu', 'Automatic', 'Off']) {
      await tester.tap(find.byTooltip('Subtitles'));
      await tester.pumpAndSettle();
      expect(find.text('English (en)'), findsOneWidget);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(service.selections.map((track) => track.id), ['2', 'auto', 'no']);
    expect(opened, 3);
    expect(closed, 3);
  });

  testWidgets(
    'ignores a menu selection after playback advances to another video',
    (tester) async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final playlist = await insertTestPlaylist(db);
      final first = await insertTestTrack(db, playlistId: playlist.id);
      final second = await insertTestTrack(
        db,
        playlistId: playlist.id,
        index: 2,
        videoId: 'second',
      );
      final current = StreamController<Track?>();
      final subtitles = StreamController<List<SubtitleTrack>>();
      addTearDown(current.close);
      addTearDown(subtitles.close);
      final service = _FakePlaybackService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackServiceProvider.overrideWithValue(service),
            currentTrackProvider.overrideWith((ref) => current.stream),
            subtitleTracksProvider.overrideWith((ref) => subtitles.stream),
            selectedSubtitleTrackProvider.overrideWith(
              (ref) => Stream.value(english),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: SubtitleButton())),
        ),
      );
      current.add(first);
      subtitles.add([english, hungarian]);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Subtitles'));
      await tester.pumpAndSettle();
      current.add(second);
      // Track discovery rebuilds the button while its menu is still open.
      subtitles.add([english]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('hu'));
      await tester.pumpAndSettle();
      expect(service.selections, isEmpty);
    },
  );

  testWidgets('CC menu explains when a video has no subtitles', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          subtitleTracksProvider.overrideWith(
            (ref) => Stream.value([SubtitleTrack.auto(), SubtitleTrack.no()]),
          ),
          selectedSubtitleTrackProvider.overrideWith(
            (ref) => Stream.value(SubtitleTrack.auto()),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SubtitleButton())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.closed_caption_outlined), findsOneWidget);
    await tester.tap(find.byTooltip('Subtitles'));
    await tester.pumpAndSettle();
    expect(find.text('No subtitles available'), findsOneWidget);
    expect(
      tester
          .widget<CheckedPopupMenuItem<SubtitleTrack>>(
            find.widgetWithText(
              CheckedPopupMenuItem<SubtitleTrack>,
              'Automatic',
            ),
          )
          .enabled,
      isFalse,
    );
  });
}
