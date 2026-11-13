import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/download_errors.dart';
import 'package:woolytube/services/track_status_labels.dart';

import '../helpers/test_database.dart';

void main() {
  group('shortDownloadError', () {
    test('names the reason in a few words', () {
      expect(
        shortDownloadError(
          "ERROR: [youtube] abc: Sign in to confirm you're not a bot.",
        ),
        'Bot check, try later',
      );
      expect(shortDownloadError('HTTP Error 403: Forbidden'), 'Rate-limited');
      expect(
        shortDownloadError('ERROR: Sign in to confirm your age'),
        'Age-restricted',
      );
      expect(shortDownloadError('ERROR: Private video'), 'Private video');
      expect(
        shortDownloadError('This video has been removed by the uploader'),
        'Removed from YouTube',
      );
      expect(
        shortDownloadError('Unable to download: network unreachable'),
        'Network error',
      );
    });

    test('an unknown error is just "Download failed"', () {
      expect(
        shortDownloadError('Something odd happened while merging formats'),
        'Download failed',
      );
      expect(shortDownloadError(''), 'Download failed');
    });

    test('leaves the full wording unchanged', () {
      expect(
        friendlyDownloadError('HTTP Error 403: Forbidden'),
        'Blocked by YouTube (rate-limited)',
      );
      expect(
        friendlyDownloadError("Sign in to confirm you're not a bot"),
        'YouTube asked to confirm this is not a bot. Try again later.',
      );
    });
  });

  group('track status', () {
    late AppDatabase db;
    late int playlistId;
    var index = 0;

    setUp(() async {
      db = openTestDatabase();
      playlistId = (await insertTestPlaylist(db)).id;
    });
    tearDown(() => db.close());

    Future<Track> track({
      String status = 'complete',
      int? durationSeconds = 3753,
      String? unavailableReason,
      String? lastError,
      bool replaceRequested = false,
      bool isLocalReplacement = false,
    }) => insertTestTrack(
      db,
      playlistId: playlistId,
      index: ++index,
      videoId: 'video-$index',
      status: status,
      durationSeconds: durationSeconds,
      unavailableReason: unavailableReason,
      lastError: lastError,
      replaceRequested: replaceRequested,
      isLocalReplacement: isLocalReplacement,
    );

    test('a plain track is its length', () async {
      expect(shortTrackStatus(await track()), '1:02:33');
      expect(shortTrackStatus(await track(durationSeconds: 225)), '3:45');
      expect(shortTrackStatus(await track(durationSeconds: null)), '');
    });

    test('a failed download names only the reason', () async {
      final failed = await track(
        status: 'error',
        lastError: 'HTTP Error 403: Forbidden',
      );
      expect(shortTrackStatus(failed), 'Rate-limited');
      expect(
        trackStatusInFull(failed),
        'Download failed: Blocked by YouTube (rate-limited)',
      );
    });

    test('an unavailable video has no video ID', () async {
      final gone = await track(
        status: 'unavailable',
        unavailableReason: 'private',
      );
      expect(shortTrackStatus(gone), 'Private video');
      expect(trackStatusInFull(gone), 'Private video');
    });

    test('a kept file of a removed video is short on the row', () async {
      final kept = await track(unavailableReason: removedFromYouTubeReason);
      expect(shortTrackStatus(kept), '1:02:33 · Removed, kept');
      expect(trackStatusInFull(kept), 'Removed from YouTube (local file)');
    });

    test('a failed new copy says so, the file stays', () async {
      final mine = await track(
        isLocalReplacement: true,
        replaceRequested: true,
        lastError: 'Video unavailable. This video is not available',
      );
      expect(shortTrackStatus(mine), '1:02:33 · No YouTube copy');
      expect(
        trackStatusInFull(mine),
        'YouTube version unavailable · keeping your file',
      );
      final other = await track(
        replaceRequested: true,
        lastError: 'HTTP Error 403: Forbidden',
      );
      expect(shortTrackStatus(other), '1:02:33 · New copy failed');
    });
  });
}
