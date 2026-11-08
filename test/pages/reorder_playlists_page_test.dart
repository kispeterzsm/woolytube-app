import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/reorder_playlists_page.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late List<Playlist> playlists;
  late StreamController<List<Playlist>> published;
  late _Playlists service;

  setUp(() async {
    db = openTestDatabase();
    playlists = [
      for (var i = 1; i <= 3; i++)
        await insertTestPlaylist(db, url: 'list-$i', name: 'Playlist $i'),
    ];
    published = StreamController<List<Playlist>>.broadcast();
    service = _Playlists(db);
  });

  tearDown(() async {
    await published.close();
    await db.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistServiceProvider.overrideWithValue(service),
          playlistsProvider.overrideWith((ref) => published.stream),
        ],
        child: const MaterialApp(home: ReorderPlaylistsPage()),
      ),
    );
    published.add(playlists);
    await tester.pumpAndSettle();
  }

  List<String> shownNames(WidgetTester tester) =>
      tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('reorder-playlists-list')),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .whereType<String>()
          .where((t) => t.startsWith('Playlist '))
          .toList();

  Future<void> dragFirstDown(WidgetTester tester, double distance) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.drag_handle).first),
    );
    await tester.pump(const Duration(milliseconds: 50));
    for (var moved = 0.0; moved < distance; moved += 10) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('dragging a playlist saves the move and shows the new order '
      'at once', (tester) async {
    await pumpPage(tester);
    expect(find.text('Reorder playlists'), findsOneWidget);
    expect(shownNames(tester), ['Playlist 1', 'Playlist 2', 'Playlist 3']);
    final rowHeight =
        tester
            .getSize(
              find.byKey(ValueKey('reorder-playlist-${playlists[0].id}')),
            )
            .height;

    // Past the second row, so it lands between the second and the third.
    await dragFirstDown(tester, rowHeight * 1.1);

    expect(service.moves, [(playlists[0].id, playlists[2].id)]);
    // The database has not answered yet; the dropped order shows anyway.
    expect(shownNames(tester), ['Playlist 2', 'Playlist 1', 'Playlist 3']);

    published.add([playlists[1], playlists[0], playlists[2]]);
    await tester.pumpAndSettle();
    expect(shownNames(tester), ['Playlist 2', 'Playlist 1', 'Playlist 3']);
  });

  testWidgets('dropping a playlist last moves it to the end', (tester) async {
    await pumpPage(tester);
    final rowHeight =
        tester
            .getSize(
              find.byKey(ValueKey('reorder-playlist-${playlists[0].id}')),
            )
            .height;

    await dragFirstDown(tester, rowHeight * 3);

    expect(service.moves, [(playlists[0].id, null)]);
    expect(shownNames(tester), ['Playlist 2', 'Playlist 3', 'Playlist 1']);
  });

  testWidgets('a failed save puts the saved order back', (tester) async {
    service.fail = true;
    await pumpPage(tester);
    final rowHeight =
        tester
            .getSize(
              find.byKey(ValueKey('reorder-playlist-${playlists[0].id}')),
            )
            .height;

    await dragFirstDown(tester, rowHeight * 3);

    expect(find.textContaining('Could not save the order'), findsOneWidget);
    expect(shownNames(tester), ['Playlist 1', 'Playlist 2', 'Playlist 3']);
  });
}

class _Playlists extends PlaylistService {
  _Playlists(AppDatabase db)
    : super(db, FakeYtDlpService(), MetadataService(db));

  final moves = <(int, int?)>[];
  bool fail = false;

  @override
  Future<void> movePlaylist(int id, {int? beforeId}) async {
    moves.add((id, beforeId));
    if (fail) throw StateError('disk full');
  }
}
