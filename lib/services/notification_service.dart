import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
      '@mipmap/ic_launcher',
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings),
    );
  }

  static NotificationDetails get _details => const NotificationDetails(
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
    ),
  );

  Future<void> _show(int id, String title, String body) async {
    final presenter = _presenter;
    if (presenter != null) {
      await presenter(id, title, body, _details);
    } else {
      await _plugin.show(id, title, body, _details);
    }
  }

  /// Posts a completion notification. Pass the playlist id as
  /// [notificationId] so several playlists finishing close together each keep
  /// their own notification instead of overwriting one shared entry.
  ///
  /// With [trackTitle], the notification is about that one track. Audio
  /// playlists ([audioOnly]) say "song" instead of "video". [failedCount]
  /// adds how many downloads of the run failed.
  Future<void> showDownloadComplete(
    String playlistName, {
    int downloadedCount = 1,
    int notificationId = _completeNotificationId,
    String? trackTitle,
    bool audioOnly = false,
    int failedCount = 0,
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
          '${failedCount > 0 ? ' · $failedCount failed' : ''}';
    }
    await _show(notificationId, title, body);
  }

  /// Tells that a playlist's downloads all failed, for runs nobody watched
  /// (the scheduled background update).
  Future<void> showDownloadsFailed(
    String playlistName, {
    required int failedCount,
    required String reason,
    int notificationId = _completeNotificationId,
  }) async {
    if (failedCount < 1) return;
    final plural = failedCount == 1 ? 'download' : 'downloads';
    await _show(
      notificationId + _failureIdOffset,
      'Could not update $playlistName',
      '$failedCount $plural failed: $reason',
    );
  }
}
