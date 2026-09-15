import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/home_page.dart';
import 'package:woolytube/pages/playlist_detail_page.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/update_service.dart';
import '../helpers/test_database.dart';

void main() {
  for (final home in [true, false]) {
    testWidgets(
      'tapping a chapter search result selects that chapter in ${home ? 'home' : 'playlist'}',
      (tester) async {
        final db = openTestDatabase();
        addTearDown(db.close);
        final playlist = await insertTestPlaylist(db, audioOnly: true);
        final album = (await insertTestTrack(
          db,
          playlistId: playlist.id,
          title: 'Full album',
          status: 'complete',
          filePath: '/tmp/album.m4a',
        )).copyWith(
          chaptersJson: Value(
            const ChapterData(
              downloaded: [
                MediaChapter(
                  id: 'intro',
                  title: 'Introduction',
                  startMs: 0,
                  endMs: 20000,
                ),
                MediaChapter(
                  id: 'melody',
                  title: 'Hidden Melody',
                  startMs: 20000,
                  endMs: 40000,
                ),
              ],
            ).encode(),
          ),
        );
        final other = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: 2,
          videoId: 'other',
          title: 'Another file',
          status: 'complete',
          filePath: '/tmp/other.m4a',
        );
        final tracks = [album, other];
        final playback = _Playback();
        final albumTitle = find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == 'Full album',
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              metadataServiceProvider.overrideWithValue(_Metadata()),
              playlistServiceProvider.overrideWithValue(_Playlists()),
              updateServiceProvider.overrideWithValue(_Updates()),
              playlistsProvider.overrideWith((ref) => Stream.value([playlist])),
              allTracksProvider.overrideWith((ref) => Stream.value(tracks)),
              tracksProvider(
                playlist.id,
              ).overrideWith((ref) => Stream.value(tracks)),
              playbackServiceProvider.overrideWithValue(playback),
              currentTrackProvider.overrideWith(
                (ref) => Stream<Track?>.value(null),
              ),
              isPlayingProvider.overrideWith((ref) => Stream.value(false)),
              shuffleEnabledProvider.overrideWith((ref) => Stream.value(false)),
              autoplayEnabledProvider.overrideWith((ref) => Stream.value(true)),
              audioOnlyModeProvider.overrideWith((ref) => Stream.value(true)),
              upNextQueueProvider.overrideWith(
                (ref) => Stream.value(<Track>[]),
              ),
              downloadProgressProvider.overrideWith(
                (ref) => Stream.value(DownloadProgress.idle),
              ),
            ],
            child: MaterialApp(
              home:
                  home
                      ? const HomePage()
                      : PlaylistDetailPage(playlistId: playlist.id),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.search));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), ' HIDDEN melody ');
        await tester.pumpAndSettle();
        expect(find.text('Another file'), findsNothing);
        await tester.tap(albumTitle);
        await tester.pump();
        expect(playback.trackId, album.id);
        expect(playback.chapterId, 'melody');
        expect(playback.queueIds, [album.id, other.id]);

        for (final query in ['Full album', '1', '   ']) {
          await tester.enterText(find.byType(TextField), query);
          await tester.pumpAndSettle();
          await tester.tap(albumTitle);
          await tester.pump();
          expect(playback.chapterId, isNull, reason: query);
        }

        await tester.enterText(find.byType(TextField), 'Hidden Melody');
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.search_off));
        await tester.pumpAndSettle();
        if (home) {
          await tester.tap(find.byIcon(Icons.search));
          await tester.pumpAndSettle();
        }
        await tester.tap(albumTitle);
        await tester.pump();
        expect(playback.chapterId, isNull);
      },
    );
  }
}

class _Playback implements PlaybackService {
  int? trackId;
  String? chapterId;
  List<int>? queueIds;
  @override
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
    String? chapterId,
    bool whole = false,
  }) async {
    trackId = track.id;
    this.chapterId = chapterId;
    queueIds = allTracks.map((track) => track.id).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  Future<int> getDownloadedCount(int playlistId) async => 2;
  @override
  Future<int> getTotalCount(int playlistId) async => 2;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Updates implements UpdateService {
  @override
  Future<AppUpdate?> checkForUpdate({String? currentVersion}) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
