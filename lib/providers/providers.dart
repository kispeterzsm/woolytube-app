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

final playlistServiceProvider = Provider<PlaylistService>((ref) {
  return PlaylistService(
    ref.watch(databaseProvider),
    ref.watch(ytdlpServiceProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(mediaThumbnailServiceProvider),
    ref.watch(appSettingsServiceProvider),
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
  );
  ref.onDispose(() => service.dispose());
  return service;
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

// Initialization state
final initProvider = FutureProvider<bool>((ref) async {
  final ytdlp = ref.watch(ytdlpServiceProvider);
  final log = ref.watch(logServiceProvider);
  final sw = Stopwatch()..start();

  await ytdlp.initialize();
  log.info('init: ytdlp.initialize ${sw.elapsedMilliseconds}ms');

  // yt-dlp self-update is a network call; must not block the splash screen.
  unawaited(_maybeUpdateYtDlp(ref, log));

  // Request storage permission for Android 11+
  if (!await Permission.manageExternalStorage.isGranted) {
    final status = await Permission.manageExternalStorage.request();
    if (!status.isGranted) {
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
  try {
    if (!await ytdlp.hasActiveDownloads()) {
      final repaired =
          await ref
              .watch(metadataServiceProvider)
              .recoverInterruptedDownloads();
      if (repaired > 0) {
        log.info('init: recovered $repaired interrupted download files/states');
      }
    }
  } catch (e) {
    log.warn('Interrupted download recovery failed: $e');
  }
  log.info('init: recovery ${sw.elapsedMilliseconds}ms');

  // Scan for importable playlists from previous installation
  try {
    final metadata = ref.watch(metadataServiceProvider);
    final dismissed =
        await ref.watch(appSettingsServiceProvider).getDismissedImportUrls();
    final unimported = await metadata.findUnimportedPlaylists(
      excludeUrls: dismissed,
    );
    if (unimported.isNotEmpty) {
      ref.read(pendingImportsProvider.notifier).state = unimported;
    }
  } catch (_) {
    // Non-critical — don't block app startup
  }
  log.info('init: scan ${sw.elapsedMilliseconds}ms');

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
