import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../database/database.dart';
import 'auto_update_runner.dart';
import 'ytdlp_service.dart';
import 'log_service.dart';
import 'metadata_service.dart';
import 'notification_service.dart';
import 'download_service.dart';
import 'library_gate.dart';
import 'lyrics/lyrics_service.dart';
import 'media_thumbnail_service.dart';
import 'playlist_service.dart';
import 'sponsorblock_service.dart';

/// Kotlin (AutoUpdateWorker) ↔ headless engine. Dart sends "taskComplete"
/// or "taskFailed" when done; Kotlin sends "stop" when the run must end
/// (time budget, the worker being stopped, or the app engine taking over).
const backgroundControlChannelName = 'com.woolytube/background';

/// Secondary Dart entrypoint invoked by AutoUpdateWorker via a headless
/// FlutterEngine. The worker only starts it when the app's own engine is not
/// running; otherwise the update runs there (see auto_update_runner.dart).
@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  const controlChannel = MethodChannel(backgroundControlChannelName);
  const ytdlpControlChannel = MethodChannel(ytdlpControlChannelName);
  // Lines from this engine are marked "(background)" in the Debug log.
  final log = LogService(source: LogService.backgroundSource);

  AutoUpdateRunner? runner;
  var stopRequested = false;
  // Answers at once: the reply only acknowledges the request, and native
  // treats a late reply as unhandled. The run reports its end through
  // taskComplete.
  Object? stop() {
    stopRequested = true;
    final active = runner;
    if (active != null) unawaited(active.requestStop());
    return true;
  }

  controlChannel.setMethodCallHandler((call) async {
    if (call.method == 'stop') return stop();
    throw MissingPluginException('No handler for ${call.method}');
  });
  // The Cancel button of the download notification, or the app being
  // swiped away.
  ytdlpControlChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'ping':
        // Native shows the notification's Cancel button only for engines
        // that answer this.
        return true;
      case 'cancelRequestedByUser':
        return stop();
    }
    throw MissingPluginException('No handler for ${call.method}');
  });

  AppDatabase? db;
  AutoUpdateReport report;
  try {
    report = await runBackgroundAutoUpdate(
      openDatabase: () => db = AppDatabase(),
      isStopRequested: () => stopRequested,
      onRunner: (created) => runner = created,
      log: log,
    );
  } catch (e, stack) {
    debugPrint('Background update failed: $e\n$stack');
    log.error('Scheduled update failed: $e');
    report = AutoUpdateReport(AutoUpdateStatus.failed, error: '$e');
  }

  await finishBackgroundRun(
    report,
    log: log,
    closeDatabase: () async => db?.close(),
    reportToNative: controlChannel.invokeMethod,
  );
}

/// Ends a headless run: closes the database, saves the log and only then
/// reports [report] to the worker, which destroys the engine right after
/// the reply (anything not yet written would be lost).
@visibleForTesting
Future<void> finishBackgroundRun(
  AutoUpdateReport report, {
  required LogService log,
  required Future<void> Function() closeDatabase,
  required Future<Object?> Function(String method, Object? arguments)
  reportToNative,
}) async {
  try {
    await closeDatabase();
  } catch (_) {}
  try {
    await log.flush();
  } catch (_) {}
  try {
    if (report.status == AutoUpdateStatus.failed) {
      await reportToNative('taskFailed', {
        'error': report.error ?? 'unknown error',
      });
    } else {
      await reportToNative('taskComplete', report.toMap());
    }
  } catch (e) {
    debugPrint('Background update could not report back: $e');
  }
}

/// The body of [backgroundMain], separated from the channels.
@visibleForTesting
Future<AutoUpdateReport> runBackgroundAutoUpdate({
  required AppDatabase Function() openDatabase,
  required bool Function() isStopRequested,
  required void Function(AutoUpdateRunner runner) onRunner,
  YtDlpService? ytdlp,
  DownloadLock? lock,
  AutoUpdateAttemptLog? attempts,
  LogService? log,
  DownloadNotificationService? notifications,
  MediaThumbnailService thumbnails = const MediaThumbnailService(),
  DateTime Function()? clock,
}) async {
  final yt = ytdlp ?? YtDlpService();
  final downloadLock = lock ?? DownloadLock();
  final logService = log ?? LogService(source: LogService.backgroundSource);
  final attemptLog = attempts ?? AutoUpdateAttemptLog();
  final now = clock ?? DateTime.now;

  // The app shares this process's yt-dlp runtime. Never start next to a
  // download it is running, and never while it holds the library (a sync
  // between two tracks has no process).
  if (await yt.hasActiveDownloads() ||
      await downloadLock.isHeldByOther(DownloadLock.backgroundOwner)) {
    logService.info('Scheduled update skipped: the app is downloading');
    return const AutoUpdateReport(AutoUpdateStatus.busy);
  }

  final db = openDatabase();
  // Decide first whether there is anything to do: most hourly runs have
  // nothing due, and starting yt-dlp and notifications costs time.
  final due = duePlaylistsInOrder(
    await db.getAllPlaylists(),
    await attemptLog.read(),
    now(),
  );
  if (due.isEmpty) return const AutoUpdateReport(AutoUpdateStatus.nothingDue);
  if (isStopRequested()) {
    return AutoUpdateReport(AutoUpdateStatus.stopped, due: due.length);
  }

  await yt.initialize();
  final notificationService = notifications ?? DownloadNotificationService();
  try {
    await notificationService.initialize();
  } catch (e) {
    logService.warn('Notifications unavailable: $e');
  }

  final metadata = MetadataService(db);
  final sponsorBlock = SponsorBlockService(db, logService);
  final lyrics = LyricsService(db, logService, ytdlp: yt);
  final gate = LibraryGate(
    lock: downloadLock,
    owner: DownloadLock.backgroundOwner,
  );
  final playlistService = PlaylistService(
    db,
    yt,
    metadata,
    thumbnails,
    null,
    gate,
  );
  final downloadService = DownloadService(
    db,
    yt,
    logService,
    metadata,
    notificationService,
    sponsorBlock,
    null,
    downloadLock,
    DownloadLock.backgroundOwner,
    gate,
    thumbnails,
    lyrics,
  );

  final runner = AutoUpdateRunner(
    syncPlaylist: playlistService.syncPlaylist,
    reloadPlaylist: db.getPlaylist,
    downloadPlaylist: downloadService.downloadPlaylist,
    cancelDownload: downloadService.cancelActiveDownloads,
    activeTrackId: () => downloadService.activeTrackId,
    blockedReason: () async {
      if (await downloadLock.isHeldByOther(DownloadLock.backgroundOwner)) {
        return 'a download started from the app is running';
      }
      if (!downloadService.isDownloading && await yt.hasActiveDownloads()) {
        return 'the app is downloading';
      }
      return null;
    },
    attempts: attemptLog,
    log: logService,
    clock: now,
  );
  onRunner(runner);
  if (isStopRequested()) await runner.requestStop();
  try {
    return await runner.run(due);
  } finally {
    sponsorBlock.dispose();
    lyrics.dispose();
  }
}
