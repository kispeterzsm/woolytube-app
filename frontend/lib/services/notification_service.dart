import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class DownloadNotificationService {
  static const _channelId = 'com.woolytube.downloads';
  static const _channelName = 'WoolyTube Downloads';
  static const _progressNotificationId = 1000;
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

  Future<void> showDownloadProgress({
    required String playlistName,
    required int currentTrack,
    required int totalTracks,
    required int progressPercent,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Download progress notifications',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      showProgress: true,
      maxProgress: 100,
      progress: progressPercent,
      onlyAlertOnce: true,
    );
    await _plugin.show(
      _progressNotificationId,
      'Downloading $playlistName',
      'Track $currentTrack of $totalTracks',
      NotificationDetails(android: androidDetails),
    );
  }

  Future<void> showDownloadComplete(String playlistName) async {
    await _plugin.cancel(_progressNotificationId);
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Download progress notifications',
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

  Future<void> cancel() async {
    await _plugin.cancel(_progressNotificationId);
  }
}
