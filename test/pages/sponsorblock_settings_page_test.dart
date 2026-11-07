import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/sponsorblock_settings_page.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/sponsorblock_categories.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late _Playlists playlists;

  setUp(() {
    db = openTestDatabase();
    playlists = _Playlists(db);
  });
  tearDown(() => db.close());

  Future<void> pumpPage(WidgetTester tester, int playlistId) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playlistServiceProvider.overrideWithValue(playlists),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: SponsorBlockSettingsPage(playlistId: playlistId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<Map<String, SponsorBlockCategoryAction>> stored(int id) async =>
      decodeSponsorBlockCategoryActions(
        (await db.getPlaylist(id)).sponsorBlockCategoryActions,
      );

  Finder choice(String category, String label) => find.descendant(
    of: find.byKey(ValueKey('sponsorblock-category-$category')),
    matching: find.text(label),
  );

  testWidgets('explains every category and offers only useful choices', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db);
    await pumpPage(tester, playlist.id);

    for (final definition in sponsorBlockCategoryDefinitions) {
      expect(find.text(definition.label), findsOneWidget);
      expect(find.text(definition.description), findsOneWidget);
    }
    expect(find.text('Save'), findsNothing);
    // A highlight is a point to jump to; it cannot be skipped.
    expect(choice('poi_highlight', 'Skip'), findsNothing);
    expect(choice('poi_highlight', 'Show'), findsOneWidget);
    expect(choice('sponsor', 'Skip'), findsOneWidget);
  });

  testWidgets('music playlists list the non-music category first', (
    tester,
  ) async {
    final playlist = await insertTestPlaylist(db, audioOnly: true);
    await pumpPage(tester, playlist.id);
    final nonMusic = tester.getTopLeft(
      find.byKey(const ValueKey('sponsorblock-category-music_offtopic')),
    );
    final sponsor = tester.getTopLeft(
      find.byKey(const ValueKey('sponsorblock-category-sponsor')),
    );
    expect(nonMusic.dy, lessThan(sponsor.dy));
  });

  testWidgets('a choice is saved at once; reset can be undone', (tester) async {
    final playlist = await insertTestPlaylist(db);
    await pumpPage(tester, playlist.id);

    await tester.tap(choice('sponsor', 'Ignore'));
    await tester.pumpAndSettle();
    expect(
      (await stored(playlist.id))['sponsor'],
      SponsorBlockCategoryAction.disabled,
    );

    await tester.tap(find.byKey(const ValueKey('sponsorblock-reset')));
    await tester.pumpAndSettle();
    expect(
      (await stored(playlist.id))['sponsor'],
      SponsorBlockCategoryAction.autoSkip,
    );

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(
      (await stored(playlist.id))['sponsor'],
      SponsorBlockCategoryAction.disabled,
    );
  });

  testWidgets('after a failed save the screen shows what is stored, '
      'including a choice saved after it', (tester) async {
    final playlist = await insertTestPlaylist(db);
    await pumpPage(tester, playlist.id);
    final firstWrite = Completer<void>();
    var writes = 0;
    playlists.beforeWrite = () async {
      if (++writes == 1) {
        await firstWrite.future;
        throw StateError('disk full');
      }
    };

    await tester.tap(choice('sponsor', 'Ignore'));
    await tester.pump();
    await tester.tap(choice('selfpromo', 'Ignore'));
    await tester.pump();
    firstWrite.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not save'), findsOneWidget);
    final saved = await stored(playlist.id);
    SponsorBlockCategoryAction shown(String category) =>
        tester
            .widget<SegmentedButton<SponsorBlockCategoryAction>>(
              find.descendant(
                of: find.byKey(ValueKey('sponsorblock-category-$category')),
                matching: find.byType(
                  SegmentedButton<SponsorBlockCategoryAction>,
                ),
              ),
            )
            .selected
            .single;
    expect(saved['selfpromo'], SponsorBlockCategoryAction.disabled);
    expect(shown('selfpromo'), saved['selfpromo']);
    expect(shown('sponsor'), saved['sponsor']);
  });

  test('summary counts skipped and shown categories', () {
    expect(
      sponsorBlockSummary(defaultSponsorBlockCategoryActions()),
      '7 skipped',
    );
    expect(
      sponsorBlockSummary({
        for (final d in sponsorBlockCategoryDefinitions)
          d.id: SponsorBlockCategoryAction.disabled,
        'poi_highlight': SponsorBlockCategoryAction.showInSeekbar,
      }),
      '1 shown',
    );
    expect(
      sponsorBlockSummary({
        for (final d in sponsorBlockCategoryDefinitions)
          d.id: SponsorBlockCategoryAction.disabled,
      }),
      'Nothing is skipped or shown',
    );
  });
}

class _Playlists implements PlaylistService {
  _Playlists(this.db);

  final AppDatabase db;
  Future<void> Function()? beforeWrite;

  @override
  Future<void> updatePlaylistSettings({
    required int id,
    String? name,
    bool? audioOnly,
    bool? autoUpdate,
    bool? playChapters,
    int? updateFrequencyHours,
    bool? includeThumbnails,
    bool? sponsorBlockEnabled,
    List<String>? sponsorBlockCategories,
    Map<String, SponsorBlockCategoryAction>? sponsorBlockCategoryActions,
  }) async {
    await beforeWrite?.call();
    final current = await db.getPlaylist(id);
    await db.updatePlaylist(
      current
          .copyWith(
            sponsorBlockCategoryActions: encodeSponsorBlockCategoryActions(
              sponsorBlockCategoryActions!,
            ),
          )
          .toCompanion(true),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
