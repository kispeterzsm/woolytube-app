import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class DownloadNotificationService {
  static const _channelId = 'com.woolytube.downloads';
  static const _channelName = 'WoolyTube Downloads';
  static const _completeNotificationId = 1001;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings),
    );
  }

  Future<void> showDownloadComplete(String playlistName) async {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Download completion notifications',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    await _plugin.show(
      _completeNotificationId,
      'Download complete',
      '$playlistName is up to date',
      NotificationDetails(android: androidDetails),
    );
  }
}
