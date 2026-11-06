import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../database/database.dart';
import '../services/ytdlp_service.dart';
import '../services/chapter_service.dart';
import '../services/playlist_service.dart';
import '../services/download_service.dart';
import '../services/log_service.dart';
import '../services/metadata_service.dart';
import '../services/notification_service.dart';
import '../services/update_service.dart';
import '../services/sponsorblock_service.dart';
import '../services/media_thumbnail_service.dart';
import '../services/app_settings_service.dart';
import '../services/download_network_policy.dart';
import '../services/library_gate.dart';
import '../services/sidecar_mirror.dart';
import '../services/library_export_service.dart';
import '../services/thumbnail_backfill_service.dart';

final chapterServiceProvider = Provider<ChapterService>(
  (ref) => ChapterService(
    ref.watch(databaseProvider),
    ref.watch(ytdlpServiceProvider),
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
  return MetadataService(ref.watch(databaseProvider));
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

final playlistServiceProvider = Provider<PlaylistService>((ref) {
  return PlaylistService(
    ref.watch(databaseProvider),
    ref.watch(ytdlpServiceProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(mediaThumbnailServiceProvider),
    ref.watch(appSettingsServiceProvider),
    ref.watch(libraryGateProvider),
  );
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
    ref.watch(appSettingsServiceProvider),
    null,
    DownloadLock.foregroundOwner,
    ref.watch(libraryGateProvider),
    ref.watch(mediaThumbnailServiceProvider),
  );
  ref.onDispose(() => service.dispose());
  return service;
});

/// Saves offline covers for tracks and playlists that only had a YouTube
/// image URL.
final thumbnailBackfillServiceProvider = Provider<ThumbnailBackfillService>((
  ref,
) {
  return ThumbnailBackfillService(
    ref.watch(databaseProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(mediaThumbnailServiceProvider),
    ref.watch(logServiceProvider),
  );
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

final libraryExportServiceProvider = Provider<LibraryExportService>((ref) {
  return LibraryExportService(
    ref.watch(databaseProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(thumbnailBackfillServiceProvider),
    ref.watch(appSettingsServiceProvider),
    ref.watch(logServiceProvider),
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

Future<void> _maybeUpdateYtDlp(Ref ref, LogService log) async {
  final ytdlp = ref.read(ytdlpServiceProvider);
  final settings = ref.read(appSettingsServiceProvider);
  try {
    final shouldRun = await shouldRunYtDlpSelfUpdate(
      ytdlp: ytdlp,
      settings: settings,
      networkPolicy: ref.read(downloadNetworkPolicyProvider),
    );
    if (!shouldRun) {
      log.info('yt-dlp update skipped (recent attempt, busy or mobile data)');
      return;
    }
    await settings.setLastYtDlpUpdateAttempt(DateTime.now());
    await ytdlp.updateYtDlp();
    log.info('yt-dlp updated to latest');
  } catch (e) {
    log.warn('yt-dlp update failed: $e');
  }
}

/// Gives the existing library offline covers. Runs in the background after
/// startup; covers are downloaded only when automatic network use is allowed.
Future<void> _backfillThumbnails(Ref ref, LogService log) async {
  try {
    final networkPolicy = ref.read(downloadNetworkPolicyProvider);
    final backfill = ref.read(thumbnailBackfillServiceProvider);
    // Let the library open first; this is not urgent.
    await Future<void>.delayed(const Duration(seconds: 5));
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

// Initialization state
final initProvider = FutureProvider<bool>((ref) async {
  final ytdlp = ref.watch(ytdlpServiceProvider);
  final log = ref.watch(logServiceProvider);
  final sw = Stopwatch()..start();

  // The downloader is only needed for downloads and updates. If it cannot
  // start (for example on a full phone), the library must still open and
  // play offline.
  try {
    await ytdlp.initialize();
    ref.read(ytDlpInitErrorProvider.notifier).state = null;
    // yt-dlp self-update is a network call; must not block the splash screen.
    unawaited(_maybeUpdateYtDlp(ref, log));
  } catch (e) {
    log.error('yt-dlp could not start: $e');
    ref.read(ytDlpInitErrorProvider.notifier).state = '$e';
  }
  log.info('init: ytdlp.initialize ${sw.elapsedMilliseconds}ms');

  // Request storage permission for Android 11+
  var storageGranted = await Permission.manageExternalStorage.isGranted;
  if (!storageGranted) {
    final status = await Permission.manageExternalStorage.request();
    storageGranted = status.isGranted;
    if (!storageGranted) {
      await openAppSettings();
    }
  }

  // Request notification permission for Android 13+ (media controls)
  if (!await Permission.notification.isGranted) {
    await Permission.notification.request();
  }
  log.info('init: permissions ${sw.elapsedMilliseconds}ms');

  // A killed process cannot clear its transient database state. Reconcile it
  // before exposing the UI, but never disturb a live scheduled download in a
  // second Flutter engine in this process.
  // Without storage access the files are invisible, and a repair would
  // mistake them for deleted. The gate keeps it away from a scheduled
  // download running in the background.
  if (storageGranted) {
    try {
      final repaired = await ref.read(libraryGateProvider).run(
        'startup check',
        () async {
          // Older versions could give two playlists one folder; split
          // them before anything writes into it.
          final separated =
              await ref.read(playlistServiceProvider).separateSharedFolders();
          if (separated > 0) {
            log.info('init: gave $separated playlists their own folder');
          }
          return ref
              .read(metadataServiceProvider)
              .recoverInterruptedDownloads();
        },
      );
      if (repaired > 0) {
        log.info('init: recovered $repaired interrupted download files/states');
      }
    } on LibraryBusyException catch (e) {
      log.info('init: recovery skipped: $e');
    } catch (e) {
      log.warn('Interrupted download recovery failed: $e');
    }
  } else {
    log.warn('init: no storage access; library repair and import scan skipped');
  }
  log.info('init: recovery ${sw.elapsedMilliseconds}ms');

  // Scan for importable playlists from previous installation
  if (storageGranted) {
    try {
      final metadata = ref.watch(metadataServiceProvider);
      final dismissed =
          await ref.watch(appSettingsServiceProvider).getDismissedImportUrls();
      final unimported = await metadata.findUnimportedPlaylists(
        excludeUrls: dismissed,
        skipOtherModeCopies: true,
      );
      if (unimported.isNotEmpty) {
        ref.read(pendingImportsProvider.notifier).state = unimported;
      }
    } catch (_) {
      // Non-critical — don't block app startup
    }
  }
  log.info('init: scan ${sw.elapsedMilliseconds}ms');

  // Offline covers for older downloads. Never blocks startup; without
  // storage access the files cannot be read or written.
  if (storageGranted) {
    unawaited(_backfillThumbnails(ref, log));
    // From now on every edit reaches the playlist folders' metadata files.
    ref.read(sidecarMirrorProvider).start();
  }

  log.info('init: total ${sw.elapsedMilliseconds}ms');
  return true;
});

// Playlist streams
final playlistsProvider = StreamProvider<List<Playlist>>((ref) {
  return ref.watch(playlistServiceProvider).watchAllPlaylists();
});

final allTracksProvider = StreamProvider<List<Track>>((ref) {
  return ref.watch(playlistServiceProvider).watchAllTracks();
});

final tracksProvider = StreamProvider.family<List<Track>, int>((
  ref,
  playlistId,
) {
  return ref.watch(playlistServiceProvider).watchTracksForPlaylist(playlistId);
});

// Download progress stream
final downloadProgressProvider = StreamProvider<DownloadProgress>((ref) {
  return ref.watch(downloadServiceProvider).progressStream;
});
