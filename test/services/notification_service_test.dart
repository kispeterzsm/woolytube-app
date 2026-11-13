import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/download_errors.dart';
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

      expect(presenter.id, 1001);
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

  test('each playlist gets its own completion notification', () async {
    final presenter = RecordingNotificationPresenter();
    final service = DownloadNotificationService(presenter: presenter.call);

    await service.showDownloadComplete('Playlist 7', notificationId: 7);

    expect(presenter.id, 7);
    expect(presenter.body, '1 new video downloaded to Playlist 7');
  });

  test('failure notifications name the playlist and the tracks', () async {
    final presenter = RecordingNotificationPresenter();
    final service = DownloadNotificationService(presenter: presenter.call);

    await service.showDownloadProblems('vibe mix', const [
      DownloadFailure(
        trackId: 59,
        title: 'Old School Nightcore Mix',
        error: 'Video unavailable. This video is not available',
        replacement: true,
      ),
    ], notificationId: 7);

    expect(presenter.id, 7 + (1 << 20));
    expect(presenter.title, 'vibe mix: 1 download failed');
    expect(
      presenter.body,
      '"Old School Nightcore Mix" – YouTube version unavailable',
    );
    final android = presenter.details!.android!;
    expect(android.silent, isTrue);
    expect(android.styleInformation, isA<BigTextStyleInformation>());

    await service.showDownloadProblems('Mix', [
      for (var i = 1; i <= 4; i++)
        DownloadFailure(trackId: i, title: 'Song $i', error: 'Private video'),
    ]);
    expect(presenter.title, 'Mix: 4 downloads failed');
    expect(
      presenter.body,
      '"Song 1" – private video\n"Song 2" – private video\n'
      '"Song 3" – private video\n+1 more',
    );
  });

  test('no failures, no notification', () async {
    final presenter = RecordingNotificationPresenter();
    final service = DownloadNotificationService(presenter: presenter.call);
    await service.showDownloadProblems('Mix', const []);
    expect(presenter.id, isNull);
  });
}
