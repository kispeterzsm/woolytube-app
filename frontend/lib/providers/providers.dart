import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../database/database.dart';
import '../services/ytdlp_service.dart';
import '../services/playlist_service.dart';
import '../services/download_service.dart';
import '../services/log_service.dart';
import '../services/metadata_service.dart';
import '../services/notification_service.dart';

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

final pendingImportsProvider =
    StateProvider<List<DiscoveredPlaylist>>((ref) => []);

final playlistServiceProvider = Provider<PlaylistService>((ref) {
  return PlaylistService(
    ref.watch(databaseProvider),
    ref.watch(ytdlpServiceProvider),
    ref.watch(metadataServiceProvider),
  );
});

final notificationServiceProvider = Provider<DownloadNotificationService>((ref) {
  final service = DownloadNotificationService();
  service.initialize();
  return service;
});

final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService(
    ref.watch(databaseProvider),
    ref.watch(ytdlpServiceProvider),
    ref.watch(logServiceProvider),
    ref.watch(metadataServiceProvider),
    ref.watch(notificationServiceProvider),
  );
  ref.onDispose(() => service.dispose());
  return service;
});

// Initialization state
final initProvider = FutureProvider<bool>((ref) async {
  final ytdlp = ref.watch(ytdlpServiceProvider);
  final log = ref.watch(logServiceProvider);
  await ytdlp.initialize();
  log.info('yt-dlp initialized');

  // Update yt-dlp to latest version
  try {
    await ytdlp.updateYtDlp();
    log.info('yt-dlp updated to latest');
  } catch (e) {
    log.warn('yt-dlp update failed: $e');
  }

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

  // Scan for importable playlists from previous installation
  try {
    final metadata = ref.watch(metadataServiceProvider);
    final unimported = await metadata.findUnimportedPlaylists();
    if (unimported.isNotEmpty) {
      ref.read(pendingImportsProvider.notifier).state = unimported;
    }
  } catch (_) {
    // Non-critical — don't block app startup
  }

  // Reconcile database with filesystem for all existing playlists
  try {
    final db = ref.watch(databaseProvider);
    final metadata = ref.watch(metadataServiceProvider);
    final playlists = await db.getAllPlaylists();
    for (final playlist in playlists) {
      await metadata.reconcilePlaylist(playlist);
    }
  } catch (_) {
    // Non-critical — don't block app startup
  }

  return true;
});

// Playlist streams
final playlistsProvider = StreamProvider<List<Playlist>>((ref) {
  return ref.watch(playlistServiceProvider).watchAllPlaylists();
});

final tracksProvider =
    StreamProvider.family<List<Track>, int>((ref, playlistId) {
  return ref.watch(playlistServiceProvider).watchTracksForPlaylist(playlistId);
});

// Download progress stream
final downloadProgressProvider = StreamProvider<DownloadProgress>((ref) {
  return ref.watch(downloadServiceProvider).progressStream;
});
