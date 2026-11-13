import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../database/database.dart';
import '../services/ytdlp_service.dart';
import 'playback_providers.dart';
import '../services/backup_check_service.dart';
import '../services/chapter_service.dart';
import '../services/playlist_service.dart';
import '../services/download_service.dart';
import '../services/log_service.dart';
import '../services/loudness_service.dart';
import '../services/loudness_mirror.dart';
import '../services/metadata_service.dart';
import '../services/notification_service.dart';
import '../services/update_service.dart';
import '../services/sponsorblock_service.dart';
import '../services/media_thumbnail_service.dart';
import '../services/app_settings_service.dart';
import '../services/download_network_policy.dart';
import '../services/info_backfill_service.dart';
import '../services/library_gate.dart';
import '../services/settings_mirror.dart';
import '../services/sidecar_mirror.dart';
import '../services/label_service.dart';
import '../services/library_export_service.dart';
import '../services/library_file.dart';
import '../services/library_mirror.dart';
import '../services/library_restore_service.dart';
import '../services/thumbnail_backfill_service.dart';
import '../services/recognition/audio_window_decoder.dart';
import '../services/recognition/shazam_client.dart';
import '../services/recognition/song_recognition_service.dart';
import '../services/lyrics/lyrics_models.dart';
import '../services/lyrics/lyrics_search.dart';
import '../services/lyrics/lyrics_service.dart';

final chapterServiceProvider = Provider<ChapterService>(
  (ref) => ChapterService(
    ref.watch(databaseProvider),
    ref.watch(ytdlpServiceProvider),
    metadata: ref.watch(metadataServiceProvider),
  ),
);

// Core singletons
final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase();
});

final logServiceProvider = Provider<LogService>((ref) {
  final service = LogService();
  ref.onDispose(() => service.dispose());
  return service;
});

final ytdlpServiceProvider = Provider<YtDlpService>((ref) {
  return YtDlpService();
});

final metadataServiceProvider = Provider<MetadataService>((ref) {
  return MetadataService(
    ref.watch(databaseProvider),
    log: ref.watch(logServiceProvider),
  );
});

final mediaThumbnailServiceProvider = Provider<MediaThumbnailService>((ref) {
  return const MediaThumbnailService();
});

final pendingImportsProvider = StateProvider<List<DiscoveredPlaylist>>(
  (ref) => [],
);

/// Lets only one operation change library files at a time (downloads, sync,
/// force insert, replacement, renames, format switch, deletion), also
/// against the background worker.
final libraryGateProvider = Provider<LibraryGate>((ref) {
  return LibraryGate(lock: DownloadLock(), owner: DownloadLock.foregroundOwner);
});

/// Why yt-dlp could not start, or null when it is ready. The library and
/// playback work without it; only downloads and updates need it.
final ytDlpInitErrorProvider = StateProvider<String?>((ref) => null);

/// True while [LibraryStartup.retryYtDlp] is trying to start yt-dlp again.
final ytDlpRetryingProvider = StateProvider<bool>((ref) => false);

/// Whether the app may read and write the shared Music/Movies folders: null
/// until checked. Without it the library cannot be repaired, restored or
/// mirrored; a page can offer [LibraryStartup.requestStorageAccess].
final storageAccessProvider = StateProvider<bool?>((ref) => null);

final playlistServiceProvider = Provider<PlaylistService>((ref) {
  final service = PlaylistService(
    ref.watch(databaseProvider),
    ref.watch(ytdlpServiceProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(mediaThumbnailServiceProvider),
    ref.watch(appSettingsServiceProvider),
    ref.watch(libraryGateProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final notificationServiceProvider = Provider<DownloadNotificationService>((
  ref,
) {
  final service = DownloadNotificationService();
  service.initialize();
  return service;
});

final updateServiceProvider = Provider<UpdateService>((ref) {
  return UpdateService();
});

final appSettingsServiceProvider = Provider<AppSettingsService>((ref) {
  return AppSettingsService();
});

final downloadNetworkPolicyProvider = Provider<DownloadNetworkPolicy>((ref) {
  return DownloadNetworkPolicy(ref.watch(appSettingsServiceProvider));
});

final sponsorBlockServiceProvider = Provider<SponsorBlockService>((ref) {
  final service = SponsorBlockService(
    ref.watch(databaseProvider),
    ref.watch(logServiceProvider),
  );
  ref.onDispose(() => service.dispose());
  return service;
});

final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService(
    ref.watch(databaseProvider),
    ref.watch(ytdlpServiceProvider),
    ref.watch(logServiceProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(notificationServiceProvider),
    ref.watch(sponsorBlockServiceProvider),
    null,
    DownloadLock.foregroundOwner,
    ref.watch(libraryGateProvider),
    ref.watch(mediaThumbnailServiceProvider),
    ref.watch(lyricsServiceProvider),
  );
  ref.onDispose(() => service.dispose());
  return service;
});

/// Gate operations during which the cover backfill waits: they move,
/// rename or delete files in playlist folders. A download only adds files
/// and a playlist check only links them, so the backfill keeps going then.
const _backfillPausingOperationsExempt = {'download', 'playlist check'};

/// Saves offline covers for tracks and playlists that only had a YouTube
/// image URL.
final thumbnailBackfillServiceProvider = Provider<ThumbnailBackfillService>((
  ref,
) {
  final gate = ref.watch(libraryGateProvider);
  return ThumbnailBackfillService(
    ref.watch(databaseProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(mediaThumbnailServiceProvider),
    ref.watch(logServiceProvider),
    shouldPause: () {
      final operation = gate.activeOperation;
      return operation != null &&
          !_backfillPausingOperationsExempt.contains(operation);
    },
  );
});

/// Measures songs' loudness for plane mode and "Even out volume". Waits
/// while files are moved or deleted, like the cover backfill.
final loudnessServiceProvider = Provider<LoudnessService>((ref) {
  final gate = ref.watch(libraryGateProvider);
  final service = LoudnessService(
    ref.watch(databaseProvider),
    log: ref.watch(logServiceProvider),
    shouldPause: () {
      final operation = gate.activeOperation;
      return operation != null &&
          !_backfillPausingOperationsExempt.contains(operation);
    },
  );
  ref.onDispose(service.dispose);
  // Until the setting is read, the library waits for the charger (the
  // default); the player's own requests are measured either way.
  unawaited(
    ref
        .read(appSettingsServiceProvider)
        .getLoudnessOnlyWhileCharging()
        .then(service.setOnlyWhileCharging, onError: (Object _) {}),
  );
  return service;
});

/// How far measuring the library's loudness has come.
final loudnessProgressProvider = StreamProvider<LoudnessProgress>((ref) {
  return ref.watch(loudnessServiceProvider).progressStream;
});

/// Connects the player to the loudness measurements once the library is
/// ready. The player switches measuring on and off with its settings; new
/// downloads are looked for whenever a download run ends.
final playbackLoudnessLinkProvider = Provider<void>((ref) {
  final loudness = ref.watch(loudnessServiceProvider);
  final playback = ref.watch(playbackServiceProvider);
  final downloads = ref.watch(downloadServiceProvider);
  playback.attachLoudness(loudness);
  var busy = false;
  final runs = downloads.progressStream.listen((progress) {
    if (progress.isBusy) {
      busy = true;
    } else if (busy) {
      busy = false;
      loudness.rescan();
    }
  });
  ref.onDispose(runs.cancel);
});

/// Rewrites each playlist folder's metadata file and playlist file shortly
/// after any change in the database, so no edit is lost on a reinstall.
final sidecarMirrorProvider = Provider<SidecarMirror>((ref) {
  final mirror = SidecarMirror(
    ref.watch(databaseProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(libraryGateProvider),
    log: ref.watch(logServiceProvider),
  );
  ref.onDispose(mirror.dispose);
  return mirror;
});

/// Rewrites each playlist folder's loudness file at most once a minute
/// while songs are measured, and takes measurements kept in the folders
/// back once per start.
final loudnessMirrorProvider = Provider<LoudnessMirror>((ref) {
  final mirror = LoudnessMirror(
    ref.watch(databaseProvider),
    ref.watch(libraryGateProvider),
    log: ref.watch(logServiceProvider),
    onSeeded: (_) => ref.read(loudnessServiceProvider).rescan(),
  );
  ref.onDispose(mirror.dispose);
  return mirror;
});

final libraryExportServiceProvider = Provider<LibraryExportService>((ref) {
  return LibraryExportService(
    ref.watch(databaseProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(thumbnailBackfillServiceProvider),
    ref.watch(appSettingsServiceProvider),
    ref.watch(logServiceProvider),
  );
});

/// Rewrites the settings file in the library folder shortly after any
/// setting changes, so copying the folders takes the settings along.
final settingsMirrorProvider = Provider<SettingsMirror>((ref) {
  final mirror = SettingsMirror(
    ref.watch(databaseProvider),
    ref.watch(libraryExportServiceProvider),
    log: ref.watch(logServiceProvider),
    // Playlists of a copied library, found at startup and not restored
    // yet.
    libraryWaitsForRestore: () => ref.read(pendingImportsProvider).isNotEmpty,
  );
  ref.onDispose(mirror.dispose);
  return mirror;
});

/// The library file in the top library folders: home page order and where
/// the player was.
final libraryFileServiceProvider = Provider<LibraryFileService>((ref) {
  return LibraryFileService(
    ref.watch(databaseProvider),
    log: ref.watch(logServiceProvider),
  );
});

/// Rewrites the library file shortly after the home page order or the
/// player's "where I was" point changes.
final libraryMirrorProvider = Provider<LibraryMirror>((ref) {
  final mirror = LibraryMirror(
    ref.watch(databaseProvider),
    ref.watch(libraryFileServiceProvider),
    log: ref.watch(logServiceProvider),
  );
  ref.onDispose(mirror.dispose);
  return mirror;
});

/// "Check backup": whether the library folders hold everything, and the
/// fix for what they lack.
final backupCheckServiceProvider = Provider<BackupCheckService>((ref) {
  return BackupCheckService(
    ref.watch(databaseProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(libraryExportServiceProvider),
    ref.watch(libraryFileServiceProvider),
    ref.watch(libraryGateProvider),
    log: ref.watch(logServiceProvider),
    libraryWaitsForRestore: () => ref.read(pendingImportsProvider).isNotEmpty,
    infoBackfill: ref.watch(infoBackfillStoreProvider),
  );
});

/// What the background fetch of YouTube info remembers (shared with the
/// scheduled update's engine through a file).
final infoBackfillStoreProvider = Provider<InfoBackfillStore>(
  (ref) => InfoBackfillStore(),
);

/// Saves the YouTube description of older downloads, slowly, on Wi-Fi, and
/// never while a download or another library change runs.
final infoBackfillServiceProvider = Provider<InfoBackfillService>((ref) {
  final ytdlp = ref.watch(ytdlpServiceProvider);
  final gate = ref.watch(libraryGateProvider);
  final network = ref.watch(downloadNetworkPolicyProvider);
  return InfoBackfillService(
    ref.watch(databaseProvider),
    fetchInfo: ytdlp.getVideoInfoToKeep,
    isOnWifi:
        () async =>
            await network.currentConnection() == DownloadConnection.wifi,
    store: ref.watch(infoBackfillStoreProvider),
    // Read only when a fetch is due: building the download service is not
    // needed before that.
    isBusy:
        () => gate.isBusy || ref.read(downloadServiceProvider).isDownloading,
    prepare: () async => ytdlp.isInitialized,
    log: ref.watch(logServiceProvider),
  );
});

/// Runs [infoBackfillServiceProvider] while the app is open and idle.
final infoBackfillSchedulerProvider = Provider<InfoBackfillScheduler>((ref) {
  final scheduler = InfoBackfillScheduler(
    ref.watch(infoBackfillServiceProvider),
  );
  ref.onDispose(scheduler.stop);
  return scheduler;
});

/// The owner's labels on files and chapters.
final labelServiceProvider = Provider<LabelService>(
  (ref) => LabelService(ref.watch(databaseProvider)),
);

/// The labels in use, in the owner's order. Kept while the app runs: rows
/// all over the app show their colors.
final labelsProvider = StreamProvider<List<Label>>(
  (ref) => ref.watch(labelServiceProvider).watchLabels(),
);

/// The labels in use by uid, for showing what a file or chapter carries.
final labelsByUidProvider = Provider<Map<String, Label>>((ref) {
  final labels = ref.watch(labelsProvider).valueOrNull ?? const <Label>[];
  return {for (final label in labels) label.uid: label};
});

/// Imports a copied library with its order, settings and last song.
final libraryRestoreServiceProvider = Provider<LibraryRestoreService>((ref) {
  return LibraryRestoreService(
    ref.watch(databaseProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(libraryExportServiceProvider),
    ref.watch(libraryFileServiceProvider),
    log: ref.watch(logServiceProvider),
  );
});

/// Minimum spacing between yt-dlp self-update attempts.
const ytDlpUpdateInterval = Duration(hours: 24);

/// Decides whether the yt-dlp self-update may run at startup.
///
/// The update is a nightly-channel binary download. It is skipped when one
/// ran within [ytDlpUpdateInterval], while a download is using the current
/// binary (swapping it under a running process breaks that download), and on
/// mobile data unless the user allows automatic downloads there.
Future<bool> shouldRunYtDlpSelfUpdate({
  required YtDlpService ytdlp,
  required AppSettingsService settings,
  required DownloadNetworkPolicy networkPolicy,
  DateTime? now,
}) async {
  final current = now ?? DateTime.now();
  final lastAttempt = await settings.getLastYtDlpUpdateAttempt();
  if (lastAttempt != null &&
      current.difference(lastAttempt) < ytDlpUpdateInterval) {
    return false;
  }
  if (await ytdlp.hasActiveDownloads()) return false;
  return networkPolicy.allowsAutomaticNetworkUse();
}

/// Whether the app may use the shared folders; with [ask], asks for it.
typedef StorageAccessCheck = Future<bool> Function({required bool ask});

/// Everything the app does once at startup besides showing the library, and
/// what it does when it comes back to the foreground.
///
/// The library opens as soon as yt-dlp was tried and the permissions were
/// asked. The repair of what a killed process left behind, the search for
/// playlists to restore, the metadata mirror and the cover backfill then run
/// in the background, in that order. They need storage access; when it is
/// granted later (in the system settings), [onAppResumed] starts them.
class LibraryStartup {
  /// [storageAccess] replaces the platform permission check (for tests).
  LibraryStartup(this._ref, {StorageAccessCheck? storageAccess})
    : _storageAccess = storageAccess ?? _platformStorageAccess;

  final Ref _ref;
  final StorageAccessCheck _storageAccess;

  /// How often the app checks whether the background worker changed the
  /// database (see [AppDatabase.refreshIfChangedExternally]).
  static const externalChangeInterval = Duration(seconds: 10);

  bool _libraryStarted = false;
  Future<void>? _libraryRun;
  Timer? _externalChanges;
  bool _disposed = false;

  LogService get _log => _ref.read(logServiceProvider);

  /// Starts yt-dlp, recording why it could not start in
  /// [ytDlpInitErrorProvider], and starts its self-update when it is due.
  /// Safe to call again (the Retry of the "yt-dlp could not start" notice).
  Future<void> initializeYtDlp() async {
    final ytdlp = _ref.read(ytdlpServiceProvider);
    try {
      await ytdlp.initialize();
      _ref.read(ytDlpInitErrorProvider.notifier).state = null;
      // yt-dlp self-update is a network call; must not block the UI.
      unawaited(_maybeUpdateYtDlp());
    } catch (e) {
      _log.error('yt-dlp could not start: $e');
      _ref.read(ytDlpInitErrorProvider.notifier).state = '$e';
    }
  }

  /// Tries to start yt-dlp again, and only that (no permission prompts, no
  /// library repair). [ytDlpRetryingProvider] is true meanwhile.
  Future<void> retryYtDlp() async {
    final retrying = _ref.read(ytDlpRetryingProvider.notifier);
    if (retrying.state) return;
    retrying.state = true;
    try {
      await initializeYtDlp();
    } finally {
      retrying.state = false;
    }
  }

  Future<void> _maybeUpdateYtDlp() async {
    final ytdlp = _ref.read(ytdlpServiceProvider);
    final settings = _ref.read(appSettingsServiceProvider);
    try {
      final shouldRun = await shouldRunYtDlpSelfUpdate(
        ytdlp: ytdlp,
        settings: settings,
        networkPolicy: _ref.read(downloadNetworkPolicyProvider),
      );
      if (!shouldRun) {
        _log.info(
          'yt-dlp update skipped (recent attempt, busy or mobile data)',
        );
        return;
      }
      await settings.setLastYtDlpUpdateAttempt(DateTime.now());
      await ytdlp.updateYtDlp();
      _log.info('yt-dlp updated to latest');
    } catch (e) {
      _log.warn('yt-dlp update failed: $e');
    }
  }

  /// Whether the app may use the shared Music/Movies folders. Android 11
  /// and later need "All files access"; older versions the storage
  /// permission. With [ask], the system screen to allow it is opened.
  Future<bool> checkStorageAccess({bool ask = false}) async {
    var granted = false;
    try {
      granted = await _storageAccess(ask: ask);
    } catch (e) {
      _log.warn('storage access check failed: $e');
    }
    if (!_disposed) _ref.read(storageAccessProvider.notifier).state = granted;
    return granted;
  }

  static Future<bool> _platformStorageAccess({required bool ask}) async {
    final status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return true;
    if (status.isRestricted) {
      // Before Android 11 there is no "All files access".
      if (await Permission.storage.isGranted) return true;
      return ask && (await Permission.storage.request()).isGranted;
    }
    return ask && (await Permission.manageExternalStorage.request()).isGranted;
  }

  /// Asks for storage access (for a "Grant access" button) and starts the
  /// library work once it is granted.
  Future<bool> requestStorageAccess() async {
    final granted = await checkStorageAccess(ask: true);
    if (granted) unawaited(startLibrary());
    return granted;
  }

  /// Runs the storage-dependent startup once per session: repair, restore
  /// search, metadata mirror and cover backfill. Does nothing without
  /// storage access (files would look deleted and be "repaired" away).
  Future<void> startLibrary() {
    if (_libraryStarted) return _libraryRun ?? Future.value();
    if (_ref.read(storageAccessProvider) != true) return Future.value();
    _libraryStarted = true;
    return _libraryRun = _runLibraryStartup();
  }

  Future<void> _runLibraryStartup() async {
    final log = _log;
    final sw = Stopwatch()..start();
    // A killed process cannot clear its transient database state. Never
    // disturb a live scheduled download in a second Flutter engine in this
    // process: the gate keeps the repair away from it.
    try {
      final repaired = await _ref.read(libraryGateProvider).run(
        'startup check',
        () async {
          // Older versions could give two playlists one folder; split them
          // before anything writes into it.
          final separated =
              await _ref.read(playlistServiceProvider).separateSharedFolders();
          if (separated > 0) {
            log.info('startup: gave $separated playlists their own folder');
          }
          return _ref
              .read(metadataServiceProvider)
              .recoverInterruptedDownloads(
                onProblem:
                    (playlist, e) => log.warn(
                      'startup: could not check "${playlist.name}": $e',
                    ),
              );
        },
      );
      if (repaired > 0) {
        log.info(
          'startup: recovered $repaired interrupted download '
          'files/states',
        );
      }
    } on LibraryBusyException catch (e) {
      log.info('startup: recovery skipped: $e');
    } catch (e) {
      log.warn('Interrupted download recovery failed: $e');
    }
    log.info('startup: recovery ${sw.elapsedMilliseconds}ms');

    // Playlists left by a previous installation, to offer for restore.
    try {
      final metadata = _ref.read(metadataServiceProvider);
      final dismissed =
          await _ref.read(appSettingsServiceProvider).getDismissedImportUrls();
      final unimported = await metadata.findUnimportedPlaylists(
        excludeUrls: dismissed,
        skipOtherModeCopies: true,
      );
      if (unimported.isNotEmpty && !_disposed) {
        _ref.read(pendingImportsProvider.notifier).state = unimported;
      }
    } catch (e) {
      log.warn('startup: restore search failed: $e');
    }
    log.info('startup: scan ${sw.elapsedMilliseconds}ms');

    if (_disposed) return;
    // From now on every edit reaches the playlist folders' metadata files.
    _ref.read(sidecarMirrorProvider).start();
    // And every settings change reaches the settings file.
    _ref.read(settingsMirrorProvider).start();
    // And the home page order and the last song reach the library file.
    _ref.read(libraryMirrorProvider).start();
    // And the loudness measurements reach each playlist folder.
    _ref.read(loudnessMirrorProvider).start();
    // Offline covers for older downloads; not urgent.
    unawaited(_backfillThumbnails());
    // Lyrics files a failed write left missing; not urgent either.
    unawaited(_repairLyricsFiles());
    // YouTube info of older downloads, a few minutes later and slowly.
    _ref.read(infoBackfillSchedulerProvider).start();
  }

  /// Writes the lyrics files that are missing (a write failed earlier).
  Future<void> _repairLyricsFiles() async {
    try {
      await Future<void>.delayed(const Duration(seconds: 40));
      if (_disposed) return;
      await _ref.read(backupCheckServiceProvider).repairMissingLyricsFiles();
    } catch (e) {
      _log.warn('lyrics file repair failed: $e');
    }
  }

  /// Gives the existing library offline covers. Covers are downloaded only
  /// when automatic network use is allowed.
  Future<void> _backfillThumbnails() async {
    final log = _log;
    try {
      final networkPolicy = _ref.read(downloadNetworkPolicyProvider);
      final backfill = _ref.read(thumbnailBackfillServiceProvider);
      // Let the library open first; this is not urgent.
      await Future<void>.delayed(const Duration(seconds: 5));
      if (_disposed) return;
      var allowNetwork = false;
      try {
        allowNetwork = await networkPolicy.allowsAutomaticNetworkUse();
      } catch (e) {
        log.warn('thumbnail backfill: network check failed: $e');
      }
      final added = await backfill.backfillAll(allowNetwork: allowNetwork);
      if (added > 0) log.info('thumbnail backfill: saved $added covers');
    } catch (e) {
      log.warn('thumbnail backfill failed: $e');
    }
  }

  /// Starts watching for database changes made by the background worker.
  void watchExternalChanges() {
    _externalChanges ??= Timer.periodic(
      externalChangeInterval,
      (_) => unawaited(_refreshExternal()),
    );
    unawaited(_refreshExternal());
  }

  Future<void> _refreshExternal() async {
    try {
      await _ref.read(databaseProvider).refreshIfChangedExternally();
    } catch (_) {
      // Checked again on the next tick.
    }
  }

  /// Call when the app comes back to the foreground: shows what the
  /// background worker changed meanwhile, and starts the library work if
  /// storage access was granted in the system settings in the meantime.
  Future<void> onAppResumed() async {
    watchExternalChanges();
    if (_ref.read(storageAccessProvider) != true) {
      if (await checkStorageAccess()) unawaited(startLibrary());
    } else if (_libraryStarted && !_disposed) {
      _ref.read(infoBackfillSchedulerProvider).wake();
    }
  }

  /// Call when the app goes to the background: no need to poll then.
  void onAppPaused() {
    _externalChanges?.cancel();
    _externalChanges = null;
  }

  void dispose() {
    _disposed = true;
    _externalChanges?.cancel();
    _externalChanges = null;
  }
}

final libraryStartupProvider = Provider<LibraryStartup>((ref) {
  final startup = LibraryStartup(ref);
  ref.onDispose(startup.dispose);
  return startup;
});

// Initialization state: true once the library can be shown. Only yt-dlp and
// the permission prompts are waited for; the library work continues in the
// background (see [LibraryStartup]).
final initProvider = FutureProvider<bool>((ref) async {
  final startup = ref.read(libraryStartupProvider);
  final log = ref.read(logServiceProvider);
  final sw = Stopwatch()..start();

  // The downloader is only needed for downloads and updates. If it cannot
  // start (for example on a full phone), the library must still open and
  // play offline.
  await startup.initializeYtDlp();
  log.info('init: ytdlp.initialize ${sw.elapsedMilliseconds}ms');

  final storageGranted = await startup.checkStorageAccess(ask: true);

  // Request notification permission for Android 13+ (media controls)
  try {
    if (!await Permission.notification.isGranted) {
      await Permission.notification.request();
    }
  } catch (e) {
    log.warn('notification permission check failed: $e');
  }
  log.info('init: permissions ${sw.elapsedMilliseconds}ms');

  if (storageGranted) {
    unawaited(startup.startLibrary());
  } else {
    log.warn('init: no storage access; library repair and import scan wait');
  }
  startup.watchExternalChanges();

  log.info('init: total ${sw.elapsedMilliseconds}ms');
  return true;
});

// Playlist streams
final playlistsProvider = StreamProvider<List<Playlist>>((ref) {
  return ref.watch(playlistServiceProvider).watchAllPlaylists();
});

/// Every track of the library. Expensive to keep up to date (the whole
/// table is read after every track change), so it is only live while
/// something watches it, such as the library search. For per-playlist counts
/// use [playlistTrackCountsStreamProvider].
final allTracksProvider = StreamProvider.autoDispose<List<Track>>((ref) {
  return ref.watch(playlistServiceProvider).watchAllTracks();
});

/// How long the tracks of a playlist stay cached after its page closed, so
/// going back to it shows the list at once.
const tracksCacheDuration = Duration(minutes: 2);

/// The tracks of one playlist, in order. Only emits when the list changed.
/// Kept for [tracksCacheDuration] after the last page watching it closed,
/// then the database query stops.
final tracksProvider = StreamProvider.autoDispose.family<List<Track>, int>((
  ref,
  playlistId,
) {
  final link = ref.keepAlive();
  Timer? release;
  ref.onCancel(() {
    release?.cancel();
    release = Timer(tracksCacheDuration, link.close);
  });
  ref.onResume(() => release?.cancel());
  ref.onDispose(() => release?.cancel());
  return ref.watch(playlistServiceProvider).watchTracksForPlaylist(playlistId);
});

/// One track (null once deleted). Only emits when the track changed.
final trackProvider = StreamProvider.autoDispose.family<Track?, int>((
  ref,
  trackId,
) {
  return ref.watch(databaseProvider).watchTrack(trackId);
});

/// Per playlist: total, downloaded, unavailable ("Removed from YouTube",
/// private, deleted, ...) and failed track counts. One cheap query that only
/// emits when a number changes.
final playlistTrackCountsStreamProvider =
    StreamProvider<Map<int, PlaylistCounts>>((ref) {
      return ref.watch(playlistServiceProvider).watchPlaylistTrackCounts();
    });

/// The playlists the home page, its search and the reorder page show, in
/// the home order: all of them, except the temporary playlist while it has
/// no videos.
final visiblePlaylistsProvider = Provider<AsyncValue<List<Playlist>>>((ref) {
  final playlists = ref.watch(playlistsProvider);
  int? temporaryId;
  for (final playlist in playlists.valueOrNull ?? const <Playlist>[]) {
    if (playlist.isTemporary) {
      temporaryId = playlist.id;
      break;
    }
  }
  if (temporaryId == null) return playlists;
  // Only whether it is empty: download progress does not rebuild the home
  // page.
  final hasVideos = ref.watch(
    playlistTrackCountsStreamProvider.select(
      (counts) => (counts.valueOrNull?[temporaryId]?.total ?? 0) > 0,
    ),
  );
  if (hasVideos) return playlists;
  return playlists.whenData(
    (list) => [
      for (final playlist in list)
        if (!playlist.isTemporary) playlist,
    ],
  );
});

/// Playlists whose update is asking YouTube for the playlist right now (see
/// [PlaylistService.syncingPlaylistIds]); the download that follows shows in
/// [downloadProgressProvider].
final syncingPlaylistsProvider = StreamProvider<Set<int>>((ref) async* {
  final service = ref.watch(playlistServiceProvider);
  yield service.syncingPlaylistIds;
  yield* service.syncingStream;
});

/// Playlists waiting for the running download, in order.
final downloadQueueProvider = StreamProvider<List<int>>((ref) async* {
  final service = ref.watch(downloadServiceProvider);
  yield service.queuedPlaylistIds;
  yield* service.queueStream;
});

/// Download progress. Reports arrive at most a few times a second and
/// compare by value; watch only the part a widget shows, for example
/// `ref.watch(downloadProgressProvider.select((a) => a.valueOrNull?.status))`,
/// and keep the per-percent progress in a small widget of its own.
final downloadProgressProvider = StreamProvider<DownloadProgress>((ref) {
  return ref.watch(downloadServiceProvider).progressStream;
});

/// Recognizes songs inside long downloaded files to propose chapters.
final songRecognitionServiceProvider = Provider<SongRecognitionService>((ref) {
  final service = SongRecognitionService(
    ref.watch(databaseProvider),
    decoder: const PlatformAudioWindowDecoder(),
    recognizer: ShazamClient(),
    rootDirectory: getApplicationSupportDirectory,
    notifier: YtDlpScanForegroundNotifier(
      ref.watch(ytdlpServiceProvider),
      downloadActive: () => ref.read(downloadServiceProvider).isDownloading,
    ),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Fetches lyrics and transcripts and applies the user's corrections.
final lyricsServiceProvider = Provider<LyricsService>((ref) {
  final service = LyricsService(
    ref.watch(databaseProvider),
    ref.watch(logServiceProvider),
    ytdlp: ref.watch(ytdlpServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Ids of the tracks in [docs] whose lyrics need nothing more: lyrics were
/// found, the song is instrumental, or the user said it has none.
Set<int> lyricsSettledTrackIds(List<LyricsDoc> docs) => {
  for (final doc in docs)
    if (doc.status == LyricsStatus.found ||
        doc.status == LyricsStatus.instrumental ||
        (doc.status == LyricsStatus.none && doc.pinned))
      doc.trackId,
};

/// [lyricsSettledTrackIds] of a playlist's tracks, again after every change.
final lyricsSettledTracksProvider = StreamProvider.autoDispose
    .family<Set<int>, int>((ref, playlistId) async* {
      final db = ref.watch(databaseProvider);
      // Re-read on each lyrics write rather than keeping a live query open.
      final changes = db.watchLyricsChanges();
      yield lyricsSettledTrackIds(await db.lyricsDocsForPlaylist(playlistId));
      await for (final _ in changes) {
        yield lyricsSettledTrackIds(await db.lyricsDocsForPlaylist(playlistId));
      }
    });

/// Searches stored lyrics and transcripts.
final lyricsSearchProvider = Provider<LyricsSearch>((ref) {
  final search = LyricsSearch(ref.watch(databaseProvider));
  ref.onDispose(search.dispose);
  return search;
});

final recognitionProgressProvider = StreamProvider<RecognitionProgress>((ref) {
  return ref.watch(songRecognitionServiceProvider).progressStream;
});
