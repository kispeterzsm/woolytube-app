import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'log_service.dart';
import 'metadata_service.dart';
import 'notification_service.dart';
import 'download_service.dart';
import 'library_gate.dart';
import 'media_thumbnail_service.dart';
import 'playlist_service.dart';
import 'sponsorblock_service.dart';

/// Secondary Dart entrypoint invoked by AutoUpdateWorker via a headless
/// FlutterEngine.  The Kotlin side listens on the "com.woolytube/background"
/// MethodChannel for "taskComplete" / "taskFailed" to know when we're done.
@pragma('vm:entry-point')
void backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  final controlChannel = MethodChannel('com.woolytube/background');
  final lock = DownloadLock();

  try {
    final ytdlp = YtDlpService();
    // The foreground app shares this process's yt-dlp runtime. Never start a
    // second download next to one it is running, and never run while it
    // holds the lock (a sync between two tracks has no process). The
    // download service re-checks the lock before every playlist.
    if (await ytdlp.hasActiveDownloads() ||
        await lock.isHeldByOther(DownloadLock.backgroundOwner)) {
      controlChannel.invokeMethod('taskComplete', null);
      return;
    }

    {
      final db = AppDatabase();
      await ytdlp.initialize();

      final log = LogService();
      final metadata = MetadataService(db);
      final sponsorBlock = SponsorBlockService(db, log);
      final notifications = DownloadNotificationService();
      await notifications.initialize();

      final duePlaylists = await db.getPlaylistsDueForUpdate();
      if (duePlaylists.isEmpty) {
        controlChannel.invokeMethod('taskComplete', null);
        return;
      }

      const thumbnails = MediaThumbnailService();
      final gate = LibraryGate(lock: lock, owner: DownloadLock.backgroundOwner);
      final playlistService = PlaylistService(
        db,
        ytdlp,
        metadata,
        thumbnails,
        null,
        gate,
      );
      final downloadService = DownloadService(
        db,
        ytdlp,
        log,
        metadata,
        notifications,
        sponsorBlock,
        null,
        lock,
        DownloadLock.backgroundOwner,
        gate,
        thumbnails,
      );

      for (final playlist in duePlaylists) {
        var synced = true;
        try {
          await playlistService.syncPlaylist(playlist);
        } catch (e) {
          synced = false;
          // The playlist may have become private or been deleted on YouTube.
          // Tracks already known can often still be downloaded one by one,
          // so carry on with them.
          log.warn('Sync of "${playlist.name}" failed: $e');
        }
        try {
          // Re-fetch after sync since tracks may have changed
          final freshPlaylist = await db.getPlaylist(playlist.id);
          await downloadService.downloadPlaylist(
            freshPlaylist,
            sourceChecked: synced,
          );
        } catch (_) {
          // Continue with next playlist
        }
      }

      controlChannel.invokeMethod('taskComplete', null);
    }
  } catch (e) {
    controlChannel.invokeMethod('taskFailed', {'error': e.toString()});
  }
}
