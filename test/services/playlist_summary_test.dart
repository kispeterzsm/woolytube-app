import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/download_errors.dart';
import 'package:woolytube/services/playlist_summary.dart';

void main() {
  group('playlist counts in words', () {
    // "If you have something to say" on the owner's phone.
    const spitItOut = PlaylistCounts(
      total: 108,
      downloaded: 105,
      unavailable: 1,
      failed: 2,
    );

    test('the card and the page count against the whole playlist', () {
      expect(playlistDownloadedText(spitItOut), '105 of 108 downloaded');
      expect(
        [
          for (final (kind, count) in trackCountNotes(spitItOut))
            trackCountLabel(kind, count),
        ],
        ['2 failed', '1 unavailable'],
      );
      expect(
        playlistSummaryText(spitItOut, duration: '18 min'),
        '108 tracks · 105 downloaded · 2 failed · 1 unavailable · 18 min',
      );
    });

    test('only unavailable tracks missing: nothing left to download', () {
      const counts = PlaylistCounts(
        total: 664,
        downloaded: 662,
        unavailable: 2,
      );
      expect(playlistDownloadedText(counts), '664 tracks');
      expect(
        playlistSummaryText(counts),
        '664 tracks · 662 downloaded · 2 unavailable',
      );
    });

    test('kept files are downloaded, with a note, never failed', () {
      // vibe mix: track 59 keeps the user's file, no YouTube copy.
      const vibeMix = PlaylistCounts(
        total: 80,
        downloaded: 80,
        noYouTubeCopy: 1,
        removedKept: 2,
      );
      expect(playlistDownloadedText(vibeMix), '80 tracks');
      expect(
        playlistSummaryText(vibeMix),
        '80 tracks · all downloaded · 2 removed, kept · 1 no YouTube copy',
      );
      expect(
        trackCountNotes(vibeMix).map((note) => note.$1.isProblem),
        everyElement(isFalse),
      );
    });

    test('tracks still waiting are not "all downloaded"', () {
      const counts = PlaylistCounts(total: 3, downloaded: 1);
      expect(counts.notDownloaded, 2);
      expect(playlistDownloadedText(counts), '1 of 3 downloaded');
      expect(playlistSummaryText(counts), '3 tracks · 1 downloaded');
      expect(
        playlistSummaryText(const PlaylistCounts(total: 0, downloaded: 0)),
        'No tracks',
      );
    });
  });

  group('download failures in words', () {
    const keptFile = DownloadFailure(
      trackId: 59,
      title: 'Old School Nightcore Mix',
      error: 'Video unavailable. This video is not available',
      replacement: true,
    );
    const failed = DownloadFailure(
      trackId: 3,
      title: 'Song',
      error: 'Private video',
    );

    test('a kept file is not a failed download', () {
      expect(keptFile.youTubeCopyUnavailable, isTrue);
      expect(
        downloadFailuresHeadline([keptFile]),
        'YouTube copy unavailable, your file is kept',
      );
      expect(downloadFailuresCount([keptFile]), '1 no YouTube copy');
      expect(downloadFailureLines([keptFile]), [
        '"Old School Nightcore Mix" – YouTube version unavailable, file kept',
      ]);
    });

    test('mixed and plural', () {
      expect(downloadFailuresHeadline([failed]), '1 download failed');
      expect(
        downloadFailuresHeadline([failed, failed, keptFile]),
        '2 downloads failed · YouTube copy unavailable, your file is kept',
      );
      expect(
        downloadFailuresHeadline([keptFile, keptFile]),
        '2 YouTube copies unavailable, your files are kept',
      );
      const blocked = DownloadFailure(
        trackId: 60,
        title: 'Other',
        error: 'HTTP Error 403: Forbidden',
        replacement: true,
      );
      expect(blocked.youTubeCopyUnavailable, isFalse);
      expect(
        downloadFailuresHeadline([blocked]),
        'YouTube copy failed, your file is kept',
      );
      expect(
        downloadFailuresCount([failed, keptFile]),
        '1 failed · 1 no YouTube copy',
      );
    });
  });
}
