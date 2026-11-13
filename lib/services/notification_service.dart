import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'download_errors.dart';
import 'playlist_summary.dart';

typedef NotificationPresenter =
    Future<void> Function(
      int id,
      String? title,
      String? body,
      NotificationDetails details,
    );

class DownloadNotificationService {
  // Android notification-channel alert settings cannot be changed after a
  // channel is created. Use a new channel ID so upgrades from the old audible
  // downloads channel also become silent.
  static const _channelId = 'com.woolytube.downloads.silent';
  static const _channelName = 'WoolyTube Downloads';
  static const _completeNotificationId = 1001;

  /// Failure notifications use ids above this, so a playlist's failure
  /// does not replace its own completion notification.
  static const _failureIdOffset = 1 << 20;

  final FlutterLocalNotificationsPlugin _plugin;
  final NotificationPresenter? _presenter;

  DownloadNotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    NotificationPresenter? presenter,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _presenter = presenter;

  Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings(
      '@drawable/ic_stat_woolytube',
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings),
    );
  }

  /// [expandedBody] is shown in full when the notification is expanded.
  static NotificationDetails _details({String? expandedBody}) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Download completion notifications',
          importance: Importance.low,
          priority: Priority.low,
          playSound: false,
          enableVibration: false,
          silent: true,
          onlyAlertOnce: true,
          styleInformation:
              expandedBody == null
                  ? null
                  : BigTextStyleInformation(expandedBody),
        ),
      );

  Future<void> _show(
    int id,
    String title,
    String body, {
    bool expandable = false,
    String? expandedBody,
  }) async {
    final details = _details(
      expandedBody: expandedBody ?? (expandable ? body : null),
    );
    final presenter = _presenter;
    if (presenter != null) {
      await presenter(id, title, body, details);
    } else {
      await _plugin.show(id, title, body, details);
    }
  }

  /// Posts a completion notification. Pass the playlist id as
  /// [notificationId] so several playlists finishing close together each keep
  /// their own notification instead of overwriting one shared entry.
  ///
  /// With [trackTitle], the notification is about that one track. Audio
  /// playlists ([audioOnly]) say "song" instead of "video". [failures] adds
  /// how many downloads of the run failed, and names them when expanded.
  Future<void> showDownloadComplete(
    String playlistName, {
    int downloadedCount = 1,
    int notificationId = _completeNotificationId,
    String? trackTitle,
    bool audioOnly = false,
    List<DownloadFailure> failures = const [],
  }) async {
    if (downloadedCount < 1) return;

    final noun = audioOnly ? 'song' : 'video';
    final String title;
    final String body;
    if (trackTitle != null) {
      title = 'Downloaded "$trackTitle"';
      body = 'Saved to $playlistName';
    } else {
      final plural = downloadedCount == 1 ? noun : '${noun}s';
      title =
          downloadedCount == 1
              ? 'New $noun downloaded'
              : 'New ${noun}s downloaded';
      body =
          '$downloadedCount new $plural downloaded to $playlistName'
          '${failures.isEmpty ? '' : ' · ${downloadFailuresCount(failures)}'}';
    }
    if (failures.isEmpty) {
      await _show(notificationId, title, body);
      return;
    }
    // Expanded, it also names what failed.
    await _show(
      notificationId,
      title,
      body,
      expandedBody: [body, ...downloadFailureLines(failures)].join('\n'),
    );
  }

  /// Tells which tracks of a playlist could not be downloaded, and why,
  /// for runs nobody watched (the scheduled update). Names the first few
  /// (`"Title" – video unavailable`) and counts the rest. A track that
  /// keeps its file is not called a failed download: "vibe mix: YouTube
  /// copy unavailable, your file is kept".
  Future<void> showDownloadProblems(
    String playlistName,
    List<DownloadFailure> failures, {
    int notificationId = _completeNotificationId,
  }) async {
    if (failures.isEmpty) return;
    await _show(
      notificationId + _failureIdOffset,
      '$playlistName: ${downloadFailuresHeadline(failures)}',
      downloadFailureLines(failures).join('\n'),
      expandable: true,
    );
  }
}
