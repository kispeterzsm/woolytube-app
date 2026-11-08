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
      expect(output(-17, -26), 12.5); // +6 dB gap, capped at +3
      expect(output(-17, -22), 11.5);
      // Piano or classical: nearly all of it is above the rumble.
      expect(output(-21, -21.5), 7.0);
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
    test('turns loud songs down to the target', () {
      final plan = planAudioProcessing(
        evenOut,
        const MeasuredLoudness(integratedLufs: -8, peakDb: 0),
      );
      expect(plan.filters, isEmpty);
      expect(plan.gainDb, closeTo(-6, 1e-9));
      expect(plan.gainText, '-6.00');
    });

    test('turns quiet songs up only as far as their peaks allow', () {
      expect(
        evenOutGainDb(const MeasuredLoudness(integratedLufs: -20, peakDb: -3)),
        closeTo(2, 1e-9),
      );
      expect(
        evenOutGainDb(const MeasuredLoudness(integratedLufs: -30, peakDb: -12)),
        6,
      );
      expect(
        evenOutGainDb(const MeasuredLoudness(integratedLufs: -20, peakDb: 0)),
        0,
      );
      expect(evenOutGainDb(const MeasuredLoudness(integratedLufs: -20)), 0);
    });

    test('cuts at most 20 dB', () {
      expect(evenOutGainDb(const MeasuredLoudness(integratedLufs: 10)), -20);
    });

    test('leaves unmeasured and silent songs as they are', () {
      expect(evenOutGainDb(null), 0);
      expect(evenOutGainDb(const MeasuredLoudness()), 0);
      expect(planAudioProcessing(evenOut, null), AudioProcessingPlan.none);
    });
  });

  test('strength names round-trip and unknown names read as standard', () {
    for (final strength in PlaneModeStrength.values) {
      expect(PlaneModeStrength.fromName(strength.name), strength);
    }
    expect(PlaneModeStrength.fromName(null), PlaneModeStrength.standard);
    expect(PlaneModeStrength.fromName('loud'), PlaneModeStrength.standard);
  });
}
