import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/playlist_detail_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playlist_service.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late Playlist playlist;
  late _Downloads downloads;

  setUp(() async {
    db = openTestDatabase();
    playlist = await insertTestPlaylist(db, name: 'Loaded name');
    downloads = _Downloads();
  });

  tearDown(() => db.close());

  Future<void> pumpPage(
    WidgetTester tester, {
    required List<Track> tracks,
    DownloadProgress progress = DownloadProgress.idle,
    String? initialName,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          metadataServiceProvider.overrideWithValue(_Metadata()),
          playlistServiceProvider.overrideWithValue(_Playlists()),
          downloadServiceProvider.overrideWithValue(downloads),
          tracksProvider(
            playlist.id,
          ).overrideWith((ref) => Stream.value(tracks)),
          upNextQueueProvider.overrideWith((ref) => Stream.value(<Track>[])),
          downloadProgressProvider.overrideWith(
            (ref) => Stream.value(progress),
          ),
          playbackServiceProvider.overrideWithValue(_Playback()),
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(null),
          ),
          isPlayingProvider.overrideWith((ref) => Stream.value(false)),
          shuffleEnabledProvider.overrideWith((ref) => Stream.value(false)),
          autoplayEnabledProvider.overrideWith((ref) => Stream.value(true)),
          audioOnlyModeProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: MaterialApp(
          home: PlaylistDetailPage(
            playlistId: playlist.id,
            initialName: initialName,
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('shows the passed name until the playlist row loads', (
    tester,
  ) async {
    await pumpPage(
      tester,
      tracks: const [],
      initialName: 'Initial name',
      settle: false,
    );
    expect(find.text('Initial name'), findsOneWidget);
    expect(find.text('Playlist'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Loaded name'), findsOneWidget);
    expect(find.text('Initial name'), findsNothing);
  });

  testWidgets('empty playlist keeps search available and explains itself', (
    tester,
  ) async {
    await pumpPage(tester, tracks: const []);
    expect(
      find.text('No tracks yet. Tap Update to fetch them.'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Search tracks'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('Close search'), findsOneWidget);
  });

  testWidgets('search with no hits shows an empty state', (tester) async {
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Only song',
      status: 'complete',
      filePath: '/tmp/only.m4a',
    );
    await pumpPage(tester, tracks: [track]);
    await tester.tap(find.byTooltip('Search tracks'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'nothing like this');
    await tester.pumpAndSettle();
    expect(find.text('No matching tracks'), findsOneWidget);
    expect(find.text('Only song'), findsNothing);
  });

  testWidgets('more button and non-playable rows open the actions sheet', (
    tester,
  ) async {
    final pending = await insertTestTrack(
      db,
      playlistId: playlist.id,
      title: 'Pending song',
      status: 'pending',
    );
    await pumpPage(tester, tracks: [pending]);

    await tester.tap(find.byKey(ValueKey('track-more-${pending.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Add to queue'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Add to queue'), findsNothing);

    await tester.tap(find.text('Pending song'));
    await tester.pumpAndSettle();
    expect(find.text('Add to queue'), findsOneWidget);
  });

  testWidgets('Redownload is hidden for local replacements', (tester) async {
    final replaced = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 1,
      videoId: 'replaced',
      title: 'Replaced song',
      status: 'complete',
      filePath: '/tmp/replaced.m4a',
      isLocalReplacement: true,
      unavailableReason: 'private',
    );
    final normal = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: 2,
      videoId: 'normal',
      title: 'Normal song',
      status: 'complete',
      filePath: '/tmp/normal.m4a',
    );
    await pumpPage(tester, tracks: [replaced, normal]);

    Future<void> openStorage(Track track) async {
      await tester.tap(find.byKey(ValueKey('track-more-${track.id}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('track-actions-group-storage')),
      );
      await tester.pumpAndSettle();
    }

    await openStorage(replaced);
    expect(
      find.byKey(const ValueKey('track-actions-redownload')),
      findsNothing,
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await openStorage(normal);
    expect(
      find.byKey(const ValueKey('track-actions-redownload')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('track-actions-redownload')));
    await tester.pumpAndSettle();
    expect(find.text('Redownload track?'), findsOneWidget);
    expect(find.textContaining('"Normal song"'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Redownload track?'), findsNothing);
  });

  testWidgets('Update becomes Cancel while this playlist downloads', (
    tester,
  ) async {
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      status: 'pending',
    );
    await pumpPage(
      tester,
      tracks: [track],
      progress: DownloadProgress(
        playlistId: playlist.id,
        currentTrackIndex: 1,
        totalTracks: 3,
        trackProgress: 50,
        status: 'downloading',
      ),
    );
    expect(find.byKey(const ValueKey('playlist-detail-update')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlist-detail-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Stop downloading?'), findsOneWidget);
    await tester.tap(find.text('Keep downloading'));
    await tester.pumpAndSettle();
    expect(downloads.cancelCalls, 0);

    await tester.tap(find.byKey(const ValueKey('playlist-detail-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(downloads.cancelCalls, 1);
  });
}

class _Metadata implements MetadataService {
  @override
  Future<int> reconcilePlaylist(Playlist playlist) async => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playlists implements PlaylistService {
  @override
  Future<int> backfillLocalThumbnails(int playlistId) async => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playback implements PlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads implements DownloadService {
  int cancelCalls = 0;
  @override
  bool get isDownloading => false;
  @override
  Future<void> cancelActiveDownloads() async => cancelCalls++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
