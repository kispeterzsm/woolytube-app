import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/chapters.dart';
import 'package:woolytube/services/recognition/chapter_estimator.dart';
import 'package:woolytube/services/recognition/shazam_client.dart';

void main() {
  for (final name in ['guardians', 'city-pop', 'nightcore-top-50']) {
    test('reproduces the prototype draft for $name', () {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/recognition/$name.estimator.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final samples = [
        for (final o in fixture['observations'] as List)
          RecognitionSample(
            sampleStartMs: o['sampleStartMs'] as int,
            sampleDurationMs: o['sampleDurationMs'] as int,
            result: ShazamResult.fromJson({
              if (o['trackKey'] != null)
                'track': {
                  'key': o['trackKey'],
                  'title': o['title'],
                  'subtitle': o['artist'],
                },
              'matches': o['matches'],
            }),
          ),
      ];
      final proposals = ChapterEstimator.estimate(
        runName: name,
        durationMs: fixture['durationMs'] as int,
        samples: samples,
        quietIntervals: [
          for (final s in fixture['silences'] as List)
            ((s[0] as num).toDouble(), (s[1] as num).toDouble()),
        ],
      );
      final expected =
          (fixture['expected'] as List).cast<Map<String, dynamic>>();
      expect(proposals.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        final json = proposals[i].toJson();
        for (final key in expected[i].keys) {
          expect(
            json[key],
            expected[i][key],
            reason: '$name chapter $i field $key',
          );
        }
      }
      // The drafts tile the file without gaps.
      expect(proposals.first.startMs, 0);
      expect(proposals.last.endMs, fixture['durationMs']);
      for (var i = 0; i + 1 < proposals.length; i++) {
        expect(proposals[i].endMs, proposals[i + 1].startMs);
      }
      final chapters = proposals.map((p) => p.toChapter()).toList();
      validateChapters(chapters, durationMs: fixture['durationMs'] as int);
      expect(chapters.every((c) => c.origin == ChapterOrigin.auto), isTrue);
    });
  }

  group('neighbours snapping to one quiet gap', () {
    RecognitionSample sample(int startMs, String? key, [double offset = 0]) =>
        RecognitionSample(
          sampleStartMs: startMs,
          sampleDurationMs: 12000,
          result: ShazamResult.fromJson({
            if (key != null) ...{
              'track': {'key': key, 'title': 'Song $key', 'subtitle': 'Artist'},
              'matches': [
                {'id': 'ref-$key', 'offset': offset},
              ],
            },
          }),
        );

    // Song A, then one unrecognized sample straddling the change to B. B's
    // catalog offsets put its start at 152 s.
    final samples = [
      sample(30000, 'A', 30),
      sample(90000, 'A', 90),
      sample(150000, null),
      sample(210000, 'B', 58),
      sample(270000, 'B', 118),
    ];

    for (final (name, silences) in [
      // Both groups pick the same gap: the unrecognized one would be empty.
      ('same gap', <QuietInterval>[(155, 160)]),
      // The unrecognized group takes the longer, later gap and B an earlier
      // one: the unrecognized one would run backwards.
      ('crossing gaps', <QuietInterval>[(152, 152.5), (159, 161)]),
    ]) {
      test('$name gives no empty proposals and unique IDs', () {
        final proposals = ChapterEstimator.estimate(
          runName: 'r1',
          durationMs: 300000,
          samples: samples,
          quietIntervals: silences,
        );
        expect(proposals.map((p) => p.title), [
          'Artist — Song A',
          'Artist — Song B',
        ]);
        expect(proposals.every((p) => p.endMs > p.startMs), isTrue);
        expect(proposals.map((p) => p.id).toSet(), hasLength(2));
        expect(proposals.first.startMs, 0);
        expect(proposals.last.endMs, 300000);
        expect(proposals.first.endMs, proposals.last.startMs);
        validateChapters(
          proposals.map((p) => p.toChapter()).toList(),
          durationMs: 300000,
        );
      });
    }
  });

  test('review reasons carry the prefixes the chapter service clears', () {
    const proposal = ChapterProposal(
      id: 'x',
      title: 'Unrecognized section',
      startMs: 0,
      endMs: 10,
      trackKey: null,
      referenceId: null,
      sampleCount: 1,
      referenceSampleCount: 0,
      referenceStartMs: null,
      referenceSpreadMs: null,
      boundaryMethod: 'sample-bracket',
      selectedQuietIntervalMs: null,
      nearestSilenceMs: null,
      distanceFromSilenceEndMs: null,
      consistentReference: false,
      notes: [
        ChapterProposal.unrecognizedNote,
        ChapterProposal.provisionalBoundaryNote,
      ],
      firstSampleMs: 0,
      lastSampleMs: 0,
    );
    expect(proposal.reviewReasons.first, startsWith('Name: '));
    expect(proposal.reviewReasons.last, startsWith('Timing: '));
    expect(ChapterProposal.fromJson(proposal.toJson()).notes, proposal.notes);
  });

  test('pythonRound matches banker\'s rounding', () {
    expect(pythonRound(2.5), 2);
    expect(pythonRound(3.5), 4);
    expect(pythonRound(2.4999), 2);
    expect(pythonRound(-2.5), -2);
    expect(pythonRound(211847.3), 211847);
  });
}
