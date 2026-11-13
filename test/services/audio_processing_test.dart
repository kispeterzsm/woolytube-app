import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/audio_processing.dart';

/// The gains inside a plane mode filter string: (level gain, output gain).
(double, double) _gains(String filters) {
  final gains =
      RegExp(
        r'volume=(-?[\d.]+)dB',
      ).allMatches(filters).map((m) => double.parse(m.group(1)!)).toList();
  expect(gains, hasLength(2), reason: filters);
  return (gains[0], gains[1]);
}

void main() {
  const plane = AudioProcessingSettings(planeMode: true);
  const strong = AudioProcessingSettings(
    planeMode: true,
    strength: PlaneModeStrength.strong,
  );
  const evenOut = AudioProcessingSettings(evenOutVolume: true);

  group('no processing', () {
    test('both settings off leave mpv untouched', () {
      final plan = planAudioProcessing(
        const AudioProcessingSettings(),
        const MeasuredLoudness(integratedLufs: -8, peakDb: 0),
      );
      expect(plan, AudioProcessingPlan.none);
      expect(plan.filters, isEmpty);
      expect(plan.gainText, '0.00');
    });

    test('measuring is only needed while a setting uses it', () {
      expect(const AudioProcessingSettings().needsLoudness, isFalse);
      expect(plane.needsLoudness, isTrue);
      expect(evenOut.needsLoudness, isTrue);
    });
  });

  group('plane mode', () {
    test('builds the labelled compressor chain in a fixed order', () {
      final filters = planeModeFilters(
        PlaneModeStrength.standard,
        const MeasuredLoudness(integratedLufs: -14, cabinLufs: -17),
      );
      expect(
        filters,
        '@plane:lavfi=[volume=-6.00dB,'
        'acompressor=threshold=-28dB:ratio=2.5:attack=15:release=300'
        ':knee=2.83:detection=rms:link=maximum,'
        'equalizer=f=350:t=o:w=2:g=4,'
        'volume=9.50dB,'
        'alimiter=limit=-1.5dB:attack=5:release=50:level=disabled]',
      );
    });

    test('strong compresses harder and lifts more', () {
      final filters = planeModeFilters(
        PlaneModeStrength.strong,
        const MeasuredLoudness(integratedLufs: -14, cabinLufs: -17),
      );
      expect(filters, contains('threshold=-32dB:ratio=3:attack=10'));
      expect(filters, contains('release=250'));
      expect(filters, contains('equalizer=f=350:t=o:w=2:g=6'));
      expect(_gains(filters).$2, 13);
    });

    test('every song reaches the compressor at the same loudness', () {
      for (final lufs in [-7.0, -14.0, -21.0]) {
        final (level, _) = _gains(
          planeModeFilters(
            PlaneModeStrength.standard,
            MeasuredLoudness(integratedLufs: lufs, cabinLufs: lufs - 3),
          ),
        );
        expect(lufs + level, closeTo(-20, 1e-9));
      }
    });

    test('very quiet or loud files are levelled only within limits', () {
      final quiet = _gains(
        planeModeFilters(
          PlaneModeStrength.standard,
          const MeasuredLoudness(integratedLufs: -45),
        ),
      );
      final loud = _gains(
        planeModeFilters(
          PlaneModeStrength.standard,
          const MeasuredLoudness(integratedLufs: 10),
        ),
      );
      expect(quiet.$1, 12);
      expect(loud.$1, -24);
    });

    test('bass-heavy songs get more output, bass-light ones less', () {
      double output(double integrated, double cabin) =>
          _gains(
            planeModeFilters(
              PlaneModeStrength.standard,
              MeasuredLoudness(integratedLufs: integrated, cabinLufs: cabin),
            ),
          ).$2;
      // A typical gap of 3 dB gets no correction.
      expect(output(-14, -17), 9.5);
      // Bass-heavy electronic music: much of it is masked by the engines.
      expect(output(-17, -26), 14.5); // +6 dB over typical, capped at +5
      expect(output(-14, -23), 14.5); // exactly +5
      expect(output(-17, -22), 11.5);
      // Piano or classical: nearly all of it is above the rumble.
      expect(output(-21, -21.5), 7.0);
      expect(output(-20, -20), 6.5); // capped at -3
    });

    test('an unmeasured song is planned at a typical loudness', () {
      final (level, output) = _gains(
        planeModeFilters(PlaneModeStrength.standard, null),
      );
      expect(level, -6); // as if -14 LUFS
      expect(output, 9.5); // no cabin correction
      expect(
        planAudioProcessing(plane, null).filters,
        planeModeFilters(PlaneModeStrength.standard, null),
      );
    });

    test('a silent file is planned like an unmeasured one', () {
      expect(
        planeModeFilters(PlaneModeStrength.standard, const MeasuredLoudness()),
        planeModeFilters(PlaneModeStrength.standard, null),
      );
    });

    test('a known loudness without a cabin value gets no correction', () {
      final (_, output) = _gains(
        planeModeFilters(
          PlaneModeStrength.standard,
          const MeasuredLoudness(integratedLufs: -12),
        ),
      );
      expect(output, 9.5);
    });

    test('plane mode replaces "Even out volume" and uses no extra gain', () {
      const both = AudioProcessingSettings(
        planeMode: true,
        evenOutVolume: true,
      );
      final plan = planAudioProcessing(
        both,
        const MeasuredLoudness(integratedLufs: -8, peakDb: 0),
      );
      expect(plan.filters, startsWith('@$planeModeFilterLabel:lavfi=['));
      expect(plan.gainDb, 0);
      expect(planAudioProcessing(strong, null).filters, contains('g=6'));
    });
  });

  group('even out volume', () {
    const quiet = AudioProcessingSettings(
      evenOutVolume: true,
      evenOutMode: EvenOutMode.quiet,
    );

    test('Normal is the default mode', () {
      expect(evenOut.evenOutMode, EvenOutMode.normal);
      expect(EvenOutMode.normal.targetLufs, -14);
      expect(EvenOutMode.quiet.targetLufs, -18);
    });

    test('turns loud songs down to the target with a plain gain', () {
      final plan = planAudioProcessing(
        evenOut,
        const MeasuredLoudness(integratedLufs: -8, peakDb: 0),
      );
      expect(plan.filters, isEmpty);
      expect(plan.gainDb, closeTo(-6, 1e-9));
      expect(plan.gainText, '-6.00');
      expect(
        planAudioProcessing(
          quiet,
          const MeasuredLoudness(integratedLufs: -8, peakDb: 0),
        ),
        const AudioProcessingPlan(gainDb: -10),
      );
    });

    test('a boost that fits under the peaks is a plain gain', () {
      for (final mode in EvenOutMode.values) {
        expect(
          evenOutPlan(
            mode,
            MeasuredLoudness(integratedLufs: mode.targetLufs - 4, peakDb: -6),
          ),
          const AudioProcessingPlan(gainDb: 4),
          reason: mode.name,
        );
      }
    });

    test('Normal lifts quiet songs past their peaks with a limiter', () {
      final plan = evenOutPlan(
        EvenOutMode.normal,
        const MeasuredLoudness(integratedLufs: -20, peakDb: -0.2),
      );
      expect(plan.gainDb, 0);
      expect(
        plan.filters,
        '@evenout:lavfi=[volume=6.00dB,'
        'alimiter=limit=-1dB:attack=5:release=50:level=disabled]',
      );
      expect(plan.filters, evenOutLimiterFilters(6));
    });

    test('Normal lifts by at most 10 dB', () {
      expect(
        evenOutPlan(
          EvenOutMode.normal,
          const MeasuredLoudness(integratedLufs: -40, peakDb: -1),
        ).filters,
        contains('volume=10.00dB'),
      );
      // Within the peaks a plain gain, capped the same way.
      expect(
        evenOutPlan(
          EvenOutMode.normal,
          const MeasuredLoudness(integratedLufs: -40, peakDb: -30),
        ),
        const AudioProcessingPlan(gainDb: 10),
      );
    });

    test('Quiet lifts only as far as the peaks allow, never limits', () {
      expect(
        evenOutPlan(
          EvenOutMode.quiet,
          const MeasuredLoudness(integratedLufs: -24, peakDb: -3),
        ),
        const AudioProcessingPlan(gainDb: 2),
      );
      expect(
        evenOutPlan(
          EvenOutMode.quiet,
          const MeasuredLoudness(integratedLufs: -24, peakDb: 0),
        ),
        AudioProcessingPlan.none,
      );
      expect(
        evenOutPlan(
          EvenOutMode.quiet,
          const MeasuredLoudness(integratedLufs: -24),
        ),
        AudioProcessingPlan.none,
      );
    });

    test('a song without a known peak is limited in Normal', () {
      expect(
        evenOutPlan(
          EvenOutMode.normal,
          const MeasuredLoudness(integratedLufs: -16),
        ).filters,
        evenOutLimiterFilters(2),
      );
    });

    test('cuts at most 20 dB', () {
      expect(
        evenOutPlan(
          EvenOutMode.normal,
          const MeasuredLoudness(integratedLufs: 10),
        ),
        const AudioProcessingPlan(gainDb: -20),
      );
    });

    test('leaves unmeasured and silent songs as they are', () {
      for (final mode in EvenOutMode.values) {
        expect(evenOutPlan(mode, null), AudioProcessingPlan.none);
        expect(
          evenOutPlan(mode, const MeasuredLoudness()),
          AudioProcessingPlan.none,
        );
      }
      expect(planAudioProcessing(evenOut, null), AudioProcessingPlan.none);
    });

    test('its filter and plane mode\'s never share a label', () {
      expect(evenOutFilterLabel, isNot(planeModeFilterLabel));
      const loudness = MeasuredLoudness(
        integratedLufs: -22,
        cabinLufs: -24,
        peakDb: 0,
      );
      final levelled = planAudioProcessing(evenOut, loudness);
      expect(levelled.filters, startsWith('@$evenOutFilterLabel:lavfi=['));
      expect(levelled.filters, isNot(contains('@$planeModeFilterLabel')));
      // Plane mode replaces the whole chain, so the limiter of "Even out
      // volume" is never stacked on plane mode's.
      final plane = planAudioProcessing(
        evenOut.copyWith(planeMode: true),
        loudness,
      );
      expect(plane.filters, startsWith('@$planeModeFilterLabel:lavfi=['));
      expect(plane.filters, isNot(contains('@$evenOutFilterLabel')));
      expect(plane.gainDb, 0);
    });
  });

  test('mode names round-trip and unknown names read as normal', () {
    for (final mode in EvenOutMode.values) {
      expect(EvenOutMode.fromName(mode.name), mode);
    }
    expect(EvenOutMode.fromName(null), EvenOutMode.normal);
    expect(EvenOutMode.fromName('loud'), EvenOutMode.normal);
  });

  test('strength names round-trip and unknown names read as standard', () {
    for (final strength in PlaneModeStrength.values) {
      expect(PlaneModeStrength.fromName(strength.name), strength);
    }
    expect(PlaneModeStrength.fromName(null), PlaneModeStrength.standard);
    expect(PlaneModeStrength.fromName('loud'), PlaneModeStrength.standard);
  });
}
