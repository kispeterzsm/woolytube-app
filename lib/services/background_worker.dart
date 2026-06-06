import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'log_service.dart';
import 'metadata_service.dart';
import 'notification_service.dart';
import 'download_service.dart';
import 'playlist_service.dart';

/// Secondary Dart entrypoint invoked by AutoUpdateWorker via a headless
/// FlutterEngine.  The Kotlin side listens on the "com.woolytube/background"
/// MethodChannel for "taskComplete" / "taskFailed" to know when we're done.
@pragma('vm:entry-point')
void backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  final controlChannel = MethodChannel('com.woolytube/background');

  try {
    if (!await DownloadService.acquireLock()) {
      controlChannel.invokeMethod('taskComplete', null);
      return;
    }

    try {
      final db = AppDatabase();
      final ytdlp = YtDlpService();
      await ytdlp.initialize();

      final log = LogService();
      final metadata = MetadataService(db);
      final notifications = DownloadNotificationService();
      await notifications.initialize();

      final duePlaylists = await db.getPlaylistsDueForUpdate();
      if (duePlaylists.isEmpty) {
        controlChannel.invokeMethod('taskComplete', null);
        return;
      }

      final playlistService = PlaylistService(db, ytdlp, metadata);
      final downloadService =
          DownloadService(db, ytdlp, log, metadata, notifications);

      for (final playlist in duePlaylists) {
        try {
          await playlistService.syncPlaylist(playlist);
          // Re-fetch after sync since tracks may have changed
          final freshPlaylist = await db.getPlaylist(playlist.id);
          await downloadService.downloadPlaylist(freshPlaylist);
        } catch (_) {
          // Continue with next playlist
        }
      }

      controlChannel.invokeMethod('taskComplete', null);
    } finally {
      await DownloadService.releaseLock();
    }
  } catch (e) {
    controlChannel.invokeMethod('taskFailed', {'error': e.toString()});
  }
}
