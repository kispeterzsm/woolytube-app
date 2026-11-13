import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/add_playlist_defaults.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/audio_processing.dart';
import 'package:woolytube/services/library_export_service.dart';
import 'package:woolytube/services/library_layout.dart';
import 'package:woolytube/services/log_service.dart';
import 'package:woolytube/services/media_thumbnail_service.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playback_settings_store.dart';
import 'package:woolytube/services/settings_changes.dart';
import 'package:woolytube/services/settings_mirror.dart';
import 'package:woolytube/services/thumbnail_backfill_service.dart';

import '../helpers/test_database.dart';

/// The owner's settings are kept in `woolytube_settings.json` in the library
/// folder at all times, and a restore brings every one of them back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const backgroundChannel = MethodChannel('com.woolytube/background');

  late Directory tempDir;
  late String audioBase;
  late AppDatabase db;
  late AppSettingsService settings;
  late LibraryExportService exporter;
  late LogService log;

  String settingsPath() => p.join(
    audioBase,
    LibraryExportService.backupDirName,
    LibraryExportService.settingsFileName,
  );

  Map<String, dynamic> readFile() =>
      jsonDecode(File(settingsPath()).readAsStringSync())
          as Map<String, dynamic>;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, (call) async => null);
    tempDir = await Directory.systemTemp.createTemp('woolytube_settings_');
    audioBase = p.join(tempDir.path, 'Music', 'WoolyTube');
    LibraryLayout.overrideBasePathsForTesting(
      audio: audioBase,
      video: p.join(tempDir.path, 'Movies', 'WoolyTube'),
    );
    db = openTestDatabase();
    settings = AppSettingsService();
    log = LogService.memoryOnly();
    final metadata = MetadataService(db);
    exporter = LibraryExportService(
      db,
      metadata,
      ThumbnailBackfillService(
        db,
        metadata,
        const MediaThumbnailService(),
        log,
        lookupCachedImage: (_) async => null,
        downloadImage: (_, __) async => false,
      ),
      settings,
      log,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, null);
    await db.close();
    LibraryLayout.resetBasePathsForTesting();
    await tempDir.delete(recursive: true);
  });

  /// Changes every setting the owner can choose away from its default, the
  /// way the app does.
  Future<void> chooseEverything() async {
    await settings.setAutoDownloadWithMobileData(true);
    await settings.setPauseOnAudioInterruption(false);
    await settings.setEvenOutVolume(true);
    await settings.setEvenOutMode(EvenOutMode.quiet);
    await settings.setLoudnessOnlyWhileCharging(false);
    await settings.setPlaneModeStrength(PlaneModeStrength.strong);
    final player = SharedPreferencesPlaybackSettingsStore();
    await player.savePlaneMode(true);
    await player.saveShuffle(true);
    await player.saveAutoplay(false);
    await player.saveAudioOnly(true);
    await AddPlaylistDefaults().save(
      const AddPlaylistOptions(
        audioOnly: true,
        autoUpdate: false,
        updateFrequencyHours: 168,
        playChapters: false,
        includeThumbnails: false,
      ),
    );
  }

  /// Also stores the app's own bookkeeping.
  Future<void> storeBookkeeping() async {
    await settings.addDismissedImportUrls(['https://example.com/gone']);
    await settings.setLastYtDlpUpdateAttempt(DateTime(2026, 11, 1));
    await settings.setPlaneModeTipShown();
    await SharedPreferencesPlaybackSettingsStore().saveSession(
      const PlaybackSession(playlistId: 3, trackId: 7, positionMs: 1234),
    );
  }

  Future<void> expectEverythingChosen() async {
    expect(await settings.getAutoDownloadWithMobileData(), isTrue);
    expect(await settings.getPauseOnAudioInterruption(), isFalse);
    expect(await settings.getEvenOutVolume(), isTrue);
    expect(await settings.getEvenOutMode(), EvenOutMode.quiet);
    expect(await settings.getLoudnessOnlyWhileCharging(), isFalse);
    expect(await settings.getPlaneModeStrength(), PlaneModeStrength.strong);
    final player = await SharedPreferencesPlaybackSettingsStore().load();
    expect(player.planeMode, isTrue);
    expect(player.shuffle, isTrue);
    expect(player.autoplay, isFalse);
    expect(player.audioOnly, isTrue);
    final defaults = await AddPlaylistDefaults().load();
    expect(defaults.audioOnly, isTrue);
    expect(defaults.autoUpdate, isFalse);
    expect(defaults.updateFrequencyHours, 168);
    expect(defaults.playChapters, isFalse);
    expect(defaults.includeThumbnails, isFalse);
  }

  test('every setting the owner chooses round-trips through the file, and '
      'the bookkeeping stays behind', () async {
    await chooseEverything();
    await storeBookkeeping();
    await exporter.writeSettingsFile();

    // A fresh install.
    SharedPreferences.setMockInitialValues({});
    expect(
      await exporter.restoreSettings(),
      AppSettingsService.backedUpSettings.length,
    );
    await expectEverythingChosen();
    expect(await settings.getDismissedImportUrls(), isEmpty);
    expect(await settings.getLastYtDlpUpdateAttempt(), isNull);
    expect(await settings.getPlaneModeTipShown(), isFalse);
    expect(
      (await SharedPreferencesPlaybackSettingsStore().load()).session,
      isNull,
    );
  });

  test('every key the app stores is either backed up or bookkeeping', () async {
    await chooseEverything();
    await storeBookkeeping();
    final preferences = await SharedPreferences.getInstance();
    final backedUp = {
      for (final setting in AppSettingsService.backedUpSettings) setting.key,
    };
    const bookkeeping = {
      AppSettingsService.dismissedImportUrlsKey,
      AppSettingsService.lastYtDlpUpdateAttemptKey,
      AppSettingsService.planeModeTipShownKey,
      SharedPreferencesPlaybackSettingsStore.sessionKey,
    };
    expect(
      preferences.getKeys(),
      unorderedEquals({...backedUp, ...bookkeeping}),
    );
  });

  test('the file lists the settings by section and once more flat, for '
      'older app versions', () async {
    await chooseEverything();
    await storeBookkeeping();
    await exporter.writeSettingsFile();

    final file = readFile();
    expect(file['app'], 'WoolyTube');
    expect(file['version'], 2);
    final sections = (file['sections'] as Map).cast<String, Map>();
    expect(sections.keys, [
      AppSettingsService.appSection,
      AppSettingsService.playerSection,
      AppSettingsService.newPlaylistDefaultsSection,
    ]);
    expect(sections[AppSettingsService.playerSection], {
      SharedPreferencesPlaybackSettingsStore.planeModeKey: true,
      SharedPreferencesPlaybackSettingsStore.shuffleKey: true,
      SharedPreferencesPlaybackSettingsStore.autoplayKey: false,
      SharedPreferencesPlaybackSettingsStore.audioOnlyKey: true,
    });
    expect(
      sections[AppSettingsService
          .newPlaylistDefaultsSection]![AddPlaylistDefaults.frequencyKey],
      168,
    );
    final flat = file['settings'] as Map;
    expect(flat.length, AppSettingsService.backedUpSettings.length);
    for (final section in sections.values) {
      for (final entry in section.entries) {
        expect(flat[entry.key], entry.value);
      }
    }
  });

  test('an older flat file still restores, and the sections of a version 2 '
      'file win over its flat list', () async {
    await Directory(p.dirname(settingsPath())).create(recursive: true);
    // Version 1, as the "Back up library" button wrote it.
    File(settingsPath()).writeAsStringSync(
      jsonEncode({
        'app': 'WoolyTube',
        'exportedAt': '2026-11-08T07:46:00.000Z',
        'settings': {
          AppSettingsService.evenOutVolumeKey: true,
          AppSettingsService.dismissedImportUrlsKey: ['x'],
          SharedPreferencesPlaybackSettingsStore.sessionKey: '{}',
        },
      }),
    );
    expect(await exporter.restoreSettings(), 1);
    expect(await settings.getEvenOutVolume(), isTrue);
    expect(await settings.getDismissedImportUrls(), isEmpty);

    File(settingsPath()).writeAsStringSync(
      jsonEncode({
        'version': 2,
        'sections': {
          'app': {AppSettingsService.evenOutVolumeKey: false},
          'newPlaylistDefaults': {
            // Hand-edited: snapped to an offered interval.
            AddPlaylistDefaults.frequencyKey: 70,
            // Not a value this setting takes.
            AddPlaylistDefaults.autoUpdateKey: 'yes',
          },
        },
        'settings': {AppSettingsService.evenOutVolumeKey: true},
      }),
    );
    expect(await exporter.restoreSettings(), 2);
    expect(await settings.getEvenOutVolume(), isFalse);
    expect((await AddPlaylistDefaults().load()).updateFrequencyHours, 72);
    expect((await AddPlaylistDefaults().load()).autoUpdate, isTrue);
  });

  test('writes asked for at the same time run one after another', () async {
    await settings.setEvenOutVolume(true);
    final first = exporter.writeSettingsFile();
    await settings.setEvenOutVolume(false);
    final paths = await Future.wait([first, exporter.writeSettingsFile()]);
    expect(paths.toSet(), {settingsPath()});
    expect(
      (readFile()['settings'] as Map)[AppSettingsService.evenOutVolumeKey],
      isFalse,
    );
    expect(File('${settingsPath()}.partial').existsSync(), isFalse);
  });

  group('the settings mirror', () {
    late StreamController<void> changes;
    late SettingsMirror mirror;

    setUp(() {
      changes = StreamController<void>.broadcast();
      mirror = SettingsMirror(
        db,
        exporter,
        log: log,
        changes: changes.stream,
        delay: const Duration(milliseconds: 20),
        startDelay: const Duration(milliseconds: 20),
      );
    });

    tearDown(() async {
      await mirror.dispose();
      await changes.close();
    });

    Future<void> waitForMirror() =>
        Future<void>.delayed(const Duration(milliseconds: 120));

    test('writes the file once at start and again after a change', () async {
      await settings.setEvenOutVolume(true);
      mirror.start();
      await waitForMirror();
      expect(
        (readFile()['settings'] as Map)[AppSettingsService.evenOutVolumeKey],
        isTrue,
      );

      await settings.setEvenOutVolume(false);
      // Several changes in a row are written once, after they stop.
      changes.add(null);
      changes.add(null);
      await waitForMirror();
      expect(
        (readFile()['settings'] as Map)[AppSettingsService.evenOutVolumeKey],
        isFalse,
      );
    });

    test('every setter tells the mirror', () async {
      var told = 0;
      final subscription = SettingsChanges.stream.listen((_) => told++);
      addTearDown(subscription.cancel);
      await chooseEverything();
      await Future<void>.delayed(Duration.zero);
      // Six app settings, four player options, the add-playlist defaults.
      expect(told, 11);

      told = 0;
      await storeBookkeeping();
      await Future<void>.delayed(Duration.zero);
      expect(told, 0, reason: 'bookkeeping and the last song are not kept');
    });

    test('an unchanged file is not written again', () async {
      await settings.setEvenOutVolume(true);
      await mirror.flush();
      File(settingsPath()).writeAsStringSync('{"edited": true}');

      changes.add(null);
      mirror.start();
      await waitForMirror();
      expect(readFile(), {'edited': true});

      // A new run compares with the file instead.
      final again = SettingsMirror(db, exporterFor(db, settings, log));
      File(settingsPath()).deleteSync();
      await again.flush();
      final written = File(settingsPath()).lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await SettingsMirror(db, exporterFor(db, settings, log)).flush();
      expect(File(settingsPath()).lastModifiedSync(), written);
    });

    test('a fresh install keeps a copied settings file until the library is '
        'restored', () async {
      final held = SettingsMirror(
        db,
        exporter,
        libraryWaitsForRestore: () => true,
        changes: changes.stream,
      );
      await Directory(p.dirname(settingsPath())).create(recursive: true);
      final copied = jsonEncode({
        'version': 2,
        'sections': {
          'app': {AppSettingsService.evenOutVolumeKey: true},
        },
      });
      File(settingsPath()).writeAsStringSync(copied);

      await held.flush();
      await settings.setEvenOutMode(EvenOutMode.quiet);
      await held.flush();
      expect(File(settingsPath()).readAsStringSync(), copied);

      // Restored: from now on the file follows this phone.
      await exporter.restoreSettings();
      await insertTestPlaylist(db, outputPath: p.join(audioBase, 'Mix'));
      await held.flush();
      final settingsNow = readFile()['settings'] as Map;
      expect(settingsNow[AppSettingsService.evenOutVolumeKey], isTrue);
      expect(settingsNow[AppSettingsService.evenOutModeKey], 'quiet');
    });

    test('a dismissed restore, or none to do, lets the file follow this '
        'phone', () async {
      var waiting = true;
      final held = SettingsMirror(
        db,
        exporter,
        libraryWaitsForRestore: () => waiting,
        changes: changes.stream,
      );
      await Directory(p.dirname(settingsPath())).create(recursive: true);
      File(settingsPath()).writeAsStringSync('{}');
      await settings.setEvenOutVolume(true);
      await held.flush();
      expect(readFile(), isEmpty);

      waiting = false;
      await held.flush();
      expect(
        (readFile()['settings'] as Map)[AppSettingsService.evenOutVolumeKey],
        isTrue,
      );

      // Without a copied library the file is written from the start.
      File(settingsPath()).deleteSync();
      await mirror.flush();
      expect(File(settingsPath()).existsSync(), isTrue);
    });

    test('a failing write is logged once until it works again', () async {
      // A file where the backup folder should be.
      await Directory(audioBase).create(recursive: true);
      File(
        p.join(audioBase, LibraryExportService.backupDirName),
      ).writeAsStringSync('in the way');
      await mirror.flush();
      await settings.setEvenOutVolume(true);
      await mirror.flush();
      expect(
        log.entries.where((e) => e.message.contains('settings file')),
        hasLength(1),
      );
    });
  });
}

LibraryExportService exporterFor(
  AppDatabase db,
  AppSettingsService settings,
  LogService log,
) {
  final metadata = MetadataService(db);
  return LibraryExportService(
    db,
    metadata,
    ThumbnailBackfillService(
      db,
      metadata,
      const MediaThumbnailService(),
      log,
      lookupCachedImage: (_) async => null,
      downloadImage: (_, __) async => false,
    ),
    settings,
    log,
  );
}
