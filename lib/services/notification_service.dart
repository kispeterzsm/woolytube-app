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

  Future<void> showDownloadComplete(
    String playlistName, {
    int downloadedCount = 1,
  }) async {
    if (downloadedCount < 1) return;

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Download completion notifications',
      importance: Importance.low,
      priority: Priority.low,
      playSound: false,
      enableVibration: false,
      silent: true,
      onlyAlertOnce: true,
    );
    final plural = downloadedCount == 1 ? 'video' : 'videos';
    final title =
        downloadedCount == 1 ? 'New video downloaded' : 'New videos downloaded';
    final body = '$downloadedCount new $plural downloaded to $playlistName';
    final details = NotificationDetails(android: androidDetails);
    final presenter = _presenter;
    if (presenter != null) {
      await presenter(_completeNotificationId, title, body, details);
    } else {
      await _plugin.show(_completeNotificationId, title, body, details);
    }
  }
}
