import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/main.dart';
import 'package:woolytube/providers/playback_providers.dart';
import 'package:woolytube/providers/playlist_counts_provider.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/download_errors.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/update_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';
import 'package:woolytube/widgets/update_frequency_dropdown.dart';

import 'helpers/test_database.dart';

void main() {
  group('friendlyDownloadError', () {
    test('maps known yt-dlp failures', () {
      expect(
        friendlyDownloadError('ERROR: Sign in to confirm your age'),
        'Age-restricted — needs sign-in',
      );
      expect(friendlyDownloadError('ERROR: Private video'), 'Private video');
      expect(
        friendlyDownloadError('HTTP Error 403: Forbidden'),
        'Blocked by YouTube (rate-limited)',
      );
      expect(
        friendlyDownloadError('Unable to download: network unreachable'),
        'Network error',
      );
    });

    test('falls back to the first non-empty line, truncated', () {
      expect(
        friendlyDownloadError('\n  Something odd happened\nsecond line'),
        'Something odd happened',
      );
      final long = 'x' * 200;
      expect(friendlyDownloadError(long).length, 123);
      expect(friendlyDownloadError('   '), 'Download failed');
    });

    test('detects age gates', () {
      expect(isAgeGateDownloadError('please confirm your age'), isTrue);
      expect(isAgeGateDownloadError('Private video'), isFalse);
    });
  });

  group('countTracksByPlaylist', () {
    test('counts tracks per playlist by state', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final a = await insertTestPlaylist(db, url: 'a');
      final b = await insertTestPlaylist(db, url: 'b');
      final tracks = [
        await insertTestTrack(db, playlistId: a.id, status: 'complete'),
        await insertTestTrack(
          db,
          playlistId: a.id,
          index: 2,
          videoId: 'v2',
          status: 'pending',
        ),
        await insertTestTrack(
          db,
          playlistId: a.id,
          index: 3,
          videoId: 'v4',
          status: 'unavailable',
          unavailableReason: removedFromYouTubeReason,
        ),
        await insertTestTrack(
          db,
          playlistId: a.id,
          index: 4,
          videoId: 'v5',
          status: 'error',
        ),
        await insertTestTrack(
          db,
          playlistId: b.id,
          videoId: 'v3',
          status: 'complete',
        ),
      ];
      final counts = countTracksByPlaylist(tracks);
      expect(
        counts[a.id],
        const PlaylistCounts(
          total: 4,
          downloaded: 1,
          unavailable: 1,
          failed: 1,
        ),
      );
      expect(counts[a.id]!.available, 3);
      expect(counts[b.id], const PlaylistCounts(total: 1, downloaded: 1));
      expect(counts.containsKey(999), isFalse);

      // The database aggregate the home page uses agrees.
      final fromDb = await db.watchPlaylistTrackCounts().first;
      expect(fromDb, counts);
    });
  });

  group('nearestUpdateFrequency', () {
    test('snaps to the closest offered option', () {
      expect(nearestUpdateFrequency(1), 1);
      expect(nearestUpdateFrequency(5), 1);
      expect(nearestUpdateFrequency(20), 24);
      expect(nearestUpdateFrequency(100), 72);
      expect(nearestUpdateFrequency(500), 168);
    });
  });

  testWidgets('app surfaces download errors and playback notices globally', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final progress = StreamController<DownloadProgress>.broadcast();
    final messages = StreamController<String>.broadcast();
    addTearDown(progress.close);
    addTearDown(messages.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initProvider.overrideWith((ref) async => true),
          updateServiceProvider.overrideWithValue(_Updates()),
          playlistsProvider.overrideWith(
            (ref) => Stream.value(const <Playlist>[]),
          ),
          allTracksProvider.overrideWith(
            (ref) => Stream.value(const <Track>[]),
          ),
          downloadProgressProvider.overrideWith((ref) => progress.stream),
          playbackMessagesProvider.overrideWith((ref) => messages.stream),
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(null),
          ),
          isInPictureInPictureProvider.overrideWith(
            (ref) => Stream.value(false),
          ),
        ],
        child: const WoolyTubeApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No playlists yet'), findsOneWidget);

    progress.add(
      const DownloadProgress(
        playlistId: 1,
        currentTrackIndex: 1,
        totalTracks: 1,
        trackProgress: 0,
        status: 'error',
        error: 'ERROR: [youtube] abc: Private video\nmore detail',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Download failed: Private video'), findsOneWidget);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('more detail'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    messages.add('Audio focus was denied');
    await tester.pumpAndSettle();
    expect(find.text('Audio focus was denied'), findsOneWidget);
  });

  testWidgets('home explains when yt-dlp could not start; Retry restarts '
      'only yt-dlp', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var inits = 0;
    final ytdlp = _YtDlp(failures: 1);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initProvider.overrideWith((ref) async {
            inits++;
            return true;
          }),
          ytdlpServiceProvider.overrideWithValue(ytdlp),
          ytDlpInitErrorProvider.overrideWith((ref) => 'No space left'),
          updateServiceProvider.overrideWithValue(_Updates()),
          playlistsProvider.overrideWith(
            (ref) => Stream.value(const <Playlist>[]),
          ),
          allTracksProvider.overrideWith(
            (ref) => Stream.value(const <Track>[]),
          ),
          downloadProgressProvider.overrideWith(
            (ref) => const Stream<DownloadProgress>.empty(),
          ),
          playbackMessagesProvider.overrideWith(
            (ref) => const Stream<String>.empty(),
          ),
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(null),
          ),
          isInPictureInPictureProvider.overrideWith(
            (ref) => Stream.value(false),
          ),
        ],
        child: const WoolyTubeApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The library still opens; only downloads are affected.
    expect(find.text('No playlists yet'), findsOneWidget);
    expect(
      find.text('Downloads are unavailable: No space left'),
      findsOneWidget,
    );

    // A failed retry shows the new reason. The startup (permission prompts,
    // library repair) does not run again.
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(ytdlp.initializeCalls, 1);
    expect(inits, 1);
    expect(
      find.text('Downloads are unavailable: still broken'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Downloads are unavailable'), findsNothing);
  });

  testWidgets('a successful yt-dlp retry removes the notice', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final ytdlp = _YtDlp(failures: 0);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initProvider.overrideWith((ref) async => true),
          ytdlpServiceProvider.overrideWithValue(ytdlp),
          ytDlpInitErrorProvider.overrideWith((ref) => 'No space left'),
          updateServiceProvider.overrideWithValue(_Updates()),
          playlistsProvider.overrideWith(
            (ref) => Stream.value(const <Playlist>[]),
          ),
          downloadProgressProvider.overrideWith(
            (ref) => const Stream<DownloadProgress>.empty(),
          ),
          playbackMessagesProvider.overrideWith(
            (ref) => const Stream<String>.empty(),
          ),
          currentTrackProvider.overrideWith(
            (ref) => Stream<Track?>.value(null),
          ),
          isInPictureInPictureProvider.overrideWith(
            (ref) => Stream.value(false),
          ),
        ],
        child: const WoolyTubeApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(ytdlp.initializeCalls, 1);
    expect(find.textContaining('Downloads are unavailable'), findsNothing);
  });

  group('isVersionNewer', () {
    test('detects newer patch, minor, and major versions', () {
      expect(isVersionNewer('1.0.1', '1.0.0'), isTrue);
      expect(isVersionNewer('1.1.0', '1.0.9'), isTrue);
      expect(isVersionNewer('2.0.0', '1.9.9'), isTrue);
    });

    test('ignores tags and build metadata while comparing', () {
      expect(isVersionNewer('v1.2.4', '1.2.3+42'), isTrue);
      expect(isVersionNewer('1.2.3', 'v1.2.3+42'), isFalse);
    });

    test('rejects older, equal, and invalid versions', () {
      expect(isVersionNewer('1.2.2', '1.2.3'), isFalse);
      expect(isVersionNewer('1.2.3', '1.2.3'), isFalse);
      expect(isVersionNewer('latest', '1.2.3'), isFalse);
      expect(isVersionNewer('1.2.3', 'current'), isFalse);
    });
  });

  group('normalizeVersion', () {
    test('strips common release tag decorations', () {
      expect(normalizeVersion('v0.5.6'), '0.5.6');
      expect(normalizeVersion('1.2.3+7'), '1.2.3');
      expect(normalizeVersion('1.2.3-beta.1'), '1.2.3');
    });
  });

  group('findCompatibleApkUri', () {
    final assets = [
      {
        'name': 'woolytube-1.2.2.apk',
        'browser_download_url': 'https://example.com/woolytube-universal.apk',
      },
      {
        'name': 'woolytube-1.2.2-arm64-v8a.apk',
        'browser_download_url': 'https://example.com/woolytube-arm64.apk',
      },
      {
        'name': 'woolytube-1.2.2-armeabi-v7a.apk',
        'browser_download_url': 'https://example.com/woolytube-armv7.apk',
      },
    ];

    test('prefers the first ABI supported by the device', () {
      expect(
        findCompatibleApkUri(assets, ['arm64-v8a', 'armeabi-v7a']),
        Uri.parse('https://example.com/woolytube-arm64.apk'),
      );
    });

    test('falls back to a universal APK for older releases', () {
      expect(
        findCompatibleApkUri(assets, ['x86_64']),
        Uri.parse('https://example.com/woolytube-universal.apk'),
      );
    });

    test('does not select an APK for a different ABI', () {
      expect(findCompatibleApkUri(assets.skip(1).toList(), ['x86_64']), isNull);
    });
  });
}

class _YtDlp implements YtDlpService {
  _YtDlp({required this.failures});

  int failures;
  var initializeCalls = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (failures > 0) {
      failures--;
      throw 'still broken';
    }
  }

  // The self-update after a successful start is not part of these tests.
  @override
  Future<bool> hasActiveDownloads() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Updates implements UpdateService {
  @override
  Future<AppUpdate?> checkForUpdate({String? currentVersion}) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
