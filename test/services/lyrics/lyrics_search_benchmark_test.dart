// Query time on a synthetic 5,000-song library. Slow to set up, so it only
// runs with LYRICS_BENCH=1:
//   LYRICS_BENCH=1 flutter test test/services/lyrics/lyrics_search_benchmark_test.dart
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/lyrics/lyrics_models.dart';
import 'package:woolytube/services/lyrics/lyrics_search.dart';

import '../../helpers/test_database.dart';
import 'lyrics_search_test.dart' show loadSample, sampleLines;

void main() {
  test(
    'search stays fast at 5,000 songs',
    () async {
      final db = openTestDatabase();
      final search = LyricsSearch(db);
      final random = Random(7);
      final playlist = await insertTestPlaylist(db, lyricsMode: 'lyrics');

      // About 30k made-up words with a Zipf-like spread, plus common words.
      const syllables = [
        'ka', 'lo', 'mi', 'ra', 'te', 'su', 'ne', 'vo', 'da', 'ri', 'po', //
        'shi', 'an', 'el', 'or', 'un', 'ber', 'tan', 'gol', 'wen', 'dra',
      ];
      final words =
          <String>{
            'love',
            'night',
            'heart',
            'baby',
            'time',
            'feel',
            'never',
            'world',
            'know',
            'away',
            'light',
            'dance',
            'tonight',
            'forever',
            'dream',
          }.toList();
      while (words.length < 30000) {
        final n = 1 + random.nextInt(4);
        words.add(
          List.generate(
            n,
            (_) => syllables[random.nextInt(syllables.length)],
          ).join(),
        );
      }
      String word() {
        final r = random.nextDouble();
        return words[(pow(r, 3) * words.length).floor()];
      }

      final songs = loadSample();
      final setup = Stopwatch()..start();
      for (var i = 0; i < 5000; i++) {
        final track = await insertTestTrack(
          db,
          playlistId: playlist.id,
          index: i + 1,
          videoId: 'v$i',
        );
        final real = i % 200 == 0 && i ~/ 200 < songs.length;
        final lines =
            real
                ? sampleLines(songs[i ~/ 200])
                : [
                  for (var l = 0; l < 50; l++)
                    LyricsLineDraft(
                      List.generate(
                        5 + random.nextInt(4),
                        (_) => word(),
                      ).join(' '),
                      startMs: l * 3000,
                    ),
                ];
        await db.replaceLyricsDoc(
          LyricsDocDraft(
            trackId: track.id,
            kind: LyricsMode.lyrics,
            status: LyricsStatus.found,
            synced: true,
            checkedAt: DateTime(2026),
            lines: lines,
          ),
        );
      }
      final lineCount = (await db
              .customSelect('SELECT COUNT(*) AS n FROM lyrics_lines')
              .getSingle())
          .read<int>('n');
      final terms = (await db.lyricsVocabulary()).length;
      stdout.writeln(
        'setup ${setup.elapsedMilliseconds} ms: $lineCount lines, '
        '$terms terms',
      );

      final vocabulary = Stopwatch()..start();
      await search.search('warm up');
      stdout.writeln(
        'first search (loads vocabulary) ${vocabulary.elapsedMilliseconds} ms',
      );

      const queries = [
        'theres an endless road to rediscover',
        'when the sun shines we shine together',
        'dont wory be hapy',
        'trying to call home from a payphone',
        'kick start my heart',
        'szetszorom konnyu szivvel',
        'lemmon tre',
        'love tonight forever',
        'i wish that i could be like the cool kids',
        'rediscov',
      ];
      final times = <int>[];
      for (final query in queries) {
        final watch = Stopwatch()..start();
        final hits = await search.search(query);
        watch.stop();
        times.add(watch.elapsedMicroseconds);
        stdout.writeln(
          '${(watch.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms '
          '"$query" → ${hits.length} hits'
          '${hits.isEmpty ? '' : ', top "${hits.first.lineText}" '
                  '${hits.first.score.toStringAsFixed(2)}'}',
        );
      }
      times.sort();
      stdout.writeln(
        'median ${(times[times.length ~/ 2] / 1000).toStringAsFixed(1)} ms, '
        'max ${(times.last / 1000).toStringAsFixed(1)} ms',
      );
      search.dispose();
      await db.close();
    },
    skip: Platform.environment['LYRICS_BENCH'] == null,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
