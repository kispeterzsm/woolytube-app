import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/notification_service.dart';

class RecordingNotificationPresenter {
  int? id;
  String? title;
  String? body;
  NotificationDetails? details;

  Future<void> call(
    int id,
    String? title,
    String? body,
    NotificationDetails notificationDetails,
  ) async {
    this.id = id;
    this.title = title;
    this.body = body;
    details = notificationDetails;
  }
}

void main() {
  test(
    'download completion notifications use a silent Android channel',
    () async {
      final presenter = RecordingNotificationPresenter();
      final service = DownloadNotificationService(presenter: presenter.call);

      await service.showDownloadComplete('My Playlist', downloadedCount: 2);

      expect(presenter.title, 'New videos downloaded');
      expect(presenter.body, '2 new videos downloaded to My Playlist');
      final android = presenter.details!.android!;
      expect(android.channelId, 'com.woolytube.downloads.silent');
      expect(android.importance, Importance.low);
      expect(android.priority, Priority.low);
      expect(android.playSound, isFalse);
      expect(android.enableVibration, isFalse);
      expect(android.silent, isTrue);
    },
  );

  test('zero downloads do not post a notification', () async {
    final presenter = RecordingNotificationPresenter();
    final service = DownloadNotificationService(presenter: presenter.call);

    await service.showDownloadComplete('My Playlist', downloadedCount: 0);

    expect(presenter.id, isNull);
  });
}
