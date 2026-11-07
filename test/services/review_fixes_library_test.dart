import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/library_export_service.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/media_thumbnail_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/sidecar_mirror.dart';
import 'package:woolytube/services/thumbnail_backfill_service.dart';

import '../helpers/test_database.dart';

const _url = 'https://www.youtube.com/playlist?list=PL1';
const _otherUrl = 'https://www.youtube.com/playlist?list=PL2';

/// Import, the startup banner, settings restore and the sidecar mirror
/// (review findings R09, R15, R26, R27).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backgroundChannel = MethodChannel('com.woolytube/background');

  late AppDatabase db;
  late Directory tempDir;
  late String audioBase;
  late String videoBase;
  late MetadataService metadata;
  late List<MethodCall> backgroundCalls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    backgroundCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, (call) async {
          backgroundCalls.add(call);
          return null;
        });
    db = openTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('woolytube_review_lib_');
    audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
    videoBase = p.join(tempDir.path, 'Movies', 'WoolyTube');
    await Directory(audioBase).create(recursive: true);
    await Directory(videoBase).create(recursive: true);
    LibraryLayout.overrideBasePathsForTesting(
      audio: audioBase,
      video: videoBase,
    );
    metadata = MetadataService(db);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, null);
    LibraryLayout.resetBasePathsForTesting();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  DiscoveredPlaylist candidate(
    String folder,
    String url, {
    required bool audioOnly,
  }) => DiscoveredPlaylist(
    folderPath: folder,
    url: url,
    name: p.basename(folder),
    audioOnly: audioOnly,
    autoUpdate: true,
    updateFrequencyHours: 24,
    includeThumbnails: true,
    sponsorBlockEnabled: true,
    sponsorBlockCategories: '[]',
    createdAt: DateTime.utc(2024),
    tracks: const [],
  );

  List<String> folderNames(List<DiscoveredPlaylist> found) => [
    for (final d in found) p.relative(d.folderPath, from: tempDir.path),
  ];

  group('import (R09, R15)', () {
    test('import refuses a folder already in the library, in any letter '
        'case, and the same playlist in the same mode', () async {
      await insertTestPlaylist(
        db,
        url: _url,
        name: 'Chill',
        audioOnly: true,
        outputPath: p.join(audioBase, 'Chill'),
      );

      // Shared storage ignores case: "CHILL" is the folder "Chill" uses.
      await expectLater(
        metadata.importPlaylist(
          candidate(p.join(audioBase, 'CHILL'), _otherUrl, audioOnly: true),
        ),
        throwsA(isA<PlaylistExistsException>()),
      );
      // The same playlist (extra URL parameters do not matter) in the same
      // mode, from another folder.
      await expectLater(
        metadata.importPlaylist(
          candidate(
            p.join(audioBase, 'Chill backup'),
            '$_url&si=share-token',
            audioOnly: true,
          ),
        ),
        throwsA(isA<PlaylistExistsException>()),
      );
      expect(await db.getAllPlaylists(), hasLength(1));

      // The other mode is a separate download and may be imported.
      final videoId = await metadata.importPlaylist(
        candidate(p.join(videoBase, 'Chill'), _url, audioOnly: false),
      );
      expect((await db.getPlaylist(videoId)).audioOnly, isFalse);
      expect(await db.getAllPlaylists(), hasLength(2));
    });

    test(
      'unimported playlists are offered once per playlist and mode',
      () async {
        final found = await metadata.findUnimportedPlaylists(
          candidates: [
            candidate(p.join(audioBase, 'Mix'), _url, audioOnly: true),
            // Another folder holding the same playlist in the same mode.
            candidate(
              p.join(audioBase, 'Mix (2)'),
              '$_url&si=abc',
              audioOnly: true,
            ),
            candidate(p.join(videoBase, 'Mix'), _url, audioOnly: false),
            candidate(p.join(audioBase, 'Other'), _otherUrl, audioOnly: true),
          ],
        );

        expect(folderNames(found), [
          'Music/WoolyTube/Mix',
          'Movies/WoolyTube/Mix',
          'Music/WoolyTube/Other',
        ]);
      },
    );

    test('the startup banner skips a copy of a playlist the library has in '
        'the other mode; the Restore screen still lists it', () async {
      await insertTestPlaylist(
        db,
        url: _url,
        name: 'Mix',
        audioOnly: true,
        outputPath: p.join(audioBase, 'Mix'),
      );
      final candidates = [
        // Left behind by an older version after a switch to audio.
        candidate(p.join(videoBase, 'Mix'), _url, audioOnly: false),
        candidate(p.join(videoBase, 'Other'), _otherUrl, audioOnly: false),
      ];

      final banner = await metadata.findUnimportedPlaylists(
        candidates: candidates,
        skipOtherModeCopies: true,
      );
      final restoreScreen = await metadata.findUnimportedPlaylists(
        candidates: candidates,
      );

      expect(folderNames(banner), ['Movies/WoolyTube/Other']);
      expect(folderNames(restoreScreen), [
        'Movies/WoolyTube/Mix',
        'Movies/WoolyTube/Other',
      ]);
    });
  });

  group('settings restore (R26)', () {
    final dismissed = ['https://www.youtube.com/playlist?list=gone'];
    final backupValues = <String, Object>{
      AppSettingsService.autoDownloadWithMobileDataKey: true,
      AppSettingsService.downloadSubtitlesKey: true,
      AppSettingsService.pauseOnAudioInterruptionKey: false,
      AppSettingsService.subtitleLanguagesKey: 'en,hu',
      AppSettingsService.dismissedImportUrlsKey: dismissed,
      AppSettingsService.lastYtDlpUpdateAttemptKey: 1700000000000,
    };

    Future<void> expectOnlyPreferencesRestored(
      AppSettingsService settings,
    ) async {
      expect(await settings.getAutoDownloadWithMobileData(), isTrue);
      expect(await settings.getDownloadSubtitles(), isTrue);
      expect(await settings.getPauseOnAudioInterruption(), isFalse);
      expect(await settings.getSubtitleLanguages(), 'en,hu');
      // App bookkeeping stays this device's own.
      expect(await settings.getDismissedImportUrls(), isEmpty);
      expect(await settings.getLastYtDlpUpdateAttempt(), isNull);
    }

    test('importSettings applies only the four preferences', () async {
      final settings = AppSettingsService();

      final applied = await settings.importSettings({
        ...backupValues,
        'some_future_setting': 'x',
      });

      expect(applied, 4);
      await expectOnlyPreferencesRestored(settings);
      // The new mobile-data choice reaches the update scheduler.
      expect(backgroundCalls.map((c) => c.method), ['scheduleAutoUpdate']);
      expect(backgroundCalls.single.arguments, {'allowMobileData': true});
    });

    test('restoreSettings reads the file an export wrote', () async {
      SharedPreferences.setMockInitialValues(backupValues);
      final settings = AppSettingsService();
      final media = const MediaThumbnailService();
      final exporter = LibraryExportService(
        db,
        metadata,
        ThumbnailBackfillService(
          db,
          metadata,
          media,
          LogService(),
          lookupCachedImage: (_) async => null,
          downloadImage: (_, __) async => false,
        ),
        settings,
        LogService(),
      );
      final written = await exporter.writeSettingsFile();
      expect(
        written,
        p.join(
          audioBase,
          LibraryExportService.backupDirName,
          LibraryExportService.settingsFileName,
        ),
      );

      // A fresh install: nothing set yet.
      SharedPreferences.setMockInitialValues({});
      expect(await settings.getDownloadSubtitles(), isFalse);

      expect(await exporter.restoreSettings(), 4);
      await expectOnlyPreferencesRestored(settings);

      // A backup copied somewhere else restores the same way.
      final copy = p.join(tempDir.path, 'Copied backup');
      await Directory(
        p.join(copy, LibraryExportService.backupDirName),
      ).create(recursive: true);
      await File(written).copy(
        p.join(
          copy,
          LibraryExportService.backupDirName,
          LibraryExportService.settingsFileName,
        ),
      );
      await File(written).delete();
      SharedPreferences.setMockInitialValues({});
      expect(await exporter.restoreSettings(), isNull);
      expect(await exporter.restoreSettings(folder: copy), 4);
      await expectOnlyPreferencesRestored(settings);
    });
  });

  group('sidecar mirror (R27)', () {
    late LibraryGate gate;
    late SidecarMirror mirror;

    setUp(() {
      gate = LibraryGate.unlocked();
      mirror = SidecarMirror(
        db,
        metadata,
        gate,
        delay: const Duration(milliseconds: 20),
      );
    });

    tearDown(() => mirror.dispose());

    Future<Playlist> playlistIn(String folder, {String url = _url}) async {
      await Directory(folder).create(recursive: true);
      final playlist = await insertTestPlaylist(
        db,
        url: url,
        name: p.basename(folder),
        audioOnly: true,
        outputPath: folder,
      );
      await insertTestTrack(db, playlistId: playlist.id, videoId: 'v1');
      return playlist;
    }

    File sidecarIn(String folder) =>
        File(p.join(folder, MetadataService.metaFileName));

    /// Waits up to [timeout] for [file] to appear.
    Future<bool> appears(
      File file, {
      Duration timeout = const Duration(seconds: 2),
    }) async {
      final end = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(end)) {
        if (await file.exists()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return file.exists();
    }

    /// Lets a flush that is still writing the playlist file finish before
    /// the test folder is removed.
    Future<void> letFlushFinish() =>
        Future<void>.delayed(const Duration(milliseconds: 100));

    test('start writes the sidecars once without any table change', () async {
      final folder = p.join(audioBase, 'Edited while closed');
      await playlistIn(folder);
      // Let the insert events pass before the mirror listens.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await sidecarIn(folder).exists(), isFalse);

      mirror.start();

      expect(await appears(sidecarIn(folder)), isTrue);
      await letFlushFinish();
    });

    test('flush skips a folder two playlists share', () async {
      final shared = p.join(audioBase, 'Shared');
      await playlistIn(shared);
      await playlistIn(shared, url: _otherUrl);
      final own = p.join(audioBase, 'Own');
      await playlistIn(own, url: 'https://www.youtube.com/playlist?list=PL3');

      await mirror.flush();

      expect(await sidecarIn(own).exists(), isTrue);
      // Each would overwrite the other's sidecar.
      expect(await sidecarIn(shared).exists(), isFalse);
    });

    test('flush waits while a playlist is being deleted, but not for a '
        'download', () async {
      final folder = p.join(audioBase, 'Busy');
      await playlistIn(folder);

      // Downloads and syncs write their own sidecars; no need to wait.
      expect(await gate.tryEnter('download'), isNull);
      await mirror.flush();
      expect(await sidecarIn(folder).exists(), isTrue);
      await gate.exit();
      await sidecarIn(folder).delete();

      expect(await gate.tryEnter('playlist deletion'), isNull);
      await mirror.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await sidecarIn(folder).exists(), isFalse);

      // Once the deletion is over, the postponed write happens.
      await gate.exit();
      expect(await appears(sidecarIn(folder)), isTrue);
      await letFlushFinish();
    });
  });
}
