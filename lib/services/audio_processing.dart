/// How plane mode and "Even out volume" change what mpv plays.
///
/// Plane mode helps when engine noise drowns the music in earbuds without
/// noise cancelling. Each song is first brought to the same loudness, then a
/// gentle compressor lifts its quiet parts, a low-mid lift keeps instruments
/// and voices clear of the rumble, and a limiter stops the result from
/// clipping. Songs whose bass the engines would mask anyway get a little more
/// level, songs that are mostly mid and treble a little less. The numbers
/// come from listening-level simulations in docs/research/plane-mode.md.
library;

/// How hard plane mode works.
enum PlaneModeStrength {
  /// Lifts quiet parts by up to about 5 dB; fine for long listening.
  standard,

  /// Lifts quiet parts further, for loud cabins and very dynamic music. It
  /// pumps more audibly on bass-heavy songs.
  strong;

  /// The stored name; unknown names read as [standard].
  static PlaneModeStrength fromName(String? name) => PlaneModeStrength.values
      .firstWhere((s) => s.name == name, orElse: () => standard);

  String get label => switch (this) {
    standard => 'Standard',
    strong => 'Strong',
  };
}

/// A song's measured loudness (see the loudness analyzer in the yt-dlp
/// plugin). Any value can be missing: a silent file has no loudness.
class MeasuredLoudness {
  /// EBU R128 integrated loudness of the whole file, LUFS.
  final double? integratedLufs;

  /// The same measurement of only the part above about 300 Hz: what is left
  /// to hear when engine rumble masks the bass.
  final double? cabinLufs;

  /// Highest sample of the file, dBFS.
  final double? peakDb;

  const MeasuredLoudness({this.integratedLufs, this.cabinLufs, this.peakDb});

  @override
  bool operator ==(Object other) =>
      other is MeasuredLoudness &&
      other.integratedLufs == integratedLufs &&
      other.cabinLufs == cabinLufs &&
      other.peakDb == peakDb;

  @override
  int get hashCode => Object.hash(integratedLufs, cabinLufs, peakDb);

  @override
  String toString() =>
      'MeasuredLoudness(I: $integratedLufs, cabin: $cabinLufs, '
      'peak: $peakDb)';
}

/// The listener's sound settings.
class AudioProcessingSettings {
  final bool planeMode;
  final PlaneModeStrength strength;
  final bool evenOutVolume;

  const AudioProcessingSettings({
    this.planeMode = false,
    this.strength = PlaneModeStrength.standard,
    this.evenOutVolume = false,
  });

  /// Whether songs need their loudness measured.
  bool get needsLoudness => planeMode || evenOutVolume;

  AudioProcessingSettings copyWith({
    bool? planeMode,
    PlaneModeStrength? strength,
    bool? evenOutVolume,
  }) => AudioProcessingSettings(
    planeMode: planeMode ?? this.planeMode,
    strength: strength ?? this.strength,
    evenOutVolume: evenOutVolume ?? this.evenOutVolume,
  );

  @override
  bool operator ==(Object other) =>
      other is AudioProcessingSettings &&
      other.planeMode == planeMode &&
      other.strength == strength &&
      other.evenOutVolume == evenOutVolume;

  @override
  int get hashCode => Object.hash(planeMode, strength, evenOutVolume);
}

/// What mpv gets for one file: its audio filter chain (the `af` option) and
/// a plain gain in dB (`replaygain-fallback`, applied after the filters).
class AudioProcessingPlan {
  /// Value for mpv's `af` option; empty for no filters.
  final String filters;

  /// Value for mpv's `replaygain-fallback` option, in dB.
  final double gainDb;

  const AudioProcessingPlan({this.filters = '', this.gainDb = 0});

  static const none = AudioProcessingPlan();

  /// The gain as mpv option text.
  String get gainText => gainDb.toStringAsFixed(2);

  @override
  bool operator ==(Object other) =>
      other is AudioProcessingPlan &&
      other.filters == filters &&
      other.gainDb == gainDb;

  @override
  int get hashCode => Object.hash(filters, gainDb);

  @override
  String toString() => 'AudioProcessingPlan(af: "$filters", gain: $gainText)';
}

/// mpv's label for the plane mode filter, so it can be told apart from any
/// other filter.
const planeModeFilterLabel = 'plane';

/// Loudness every song is brought to before the compressor, so its
/// threshold means the same on every song. LUFS.
const _compressorInputLufs = -20.0;

/// Assumed for a song that was not measured yet: about what YouTube plays
/// music at. Loud masters then get compressed a little harder until they
/// are measured; the limiter keeps them from clipping.
const _unmeasuredLufs = -14.0;

/// Typical gap between integrated and cabin loudness for pop with vocals.
/// Songs with a bigger gap carry more bass that the engines mask.
const _typicalCabinGapDb = 3.0;

/// Limits for the per-song gains, in dB.
const _minLevelGainDb = -24.0;
const _maxLevelGainDb = 12.0;
const _maxCabinCorrectionDb = 3.0;

/// Ceiling for plane mode's output, dBFS. 1.5 dB below full scale leaves
/// room for the peaks between samples that a sample-peak limiter misses.
const _limiterCeilingDb = -1.5;

/// "Even out volume" brings songs to this loudness, LUFS: what YouTube and
/// Spotify's normal setting play at.
const evenOutTargetLufs = -14.0;

/// "Even out volume" turns loud songs down by at most this much, dB.
const _maxEvenOutCutDb = -20.0;

/// ... and quiet songs up by at most this much, never past their peak
/// headroom (it has no limiter). dB.
const _maxEvenOutBoostDb = 6.0;

/// Headroom kept above a song's peak when "Even out volume" turns it up, dB.
const _evenOutPeakMarginDb = 1.0;

class _CompressorPreset {
  final double thresholdDb;
  final double ratio;
  final double attackMs;
  final double releaseMs;
  final double lowMidLiftDb;

  /// Gain after the compressor, so a typical song comes out at about -15
  /// LUFS (standard) or -14 LUFS (strong).
  final double makeupDb;

  const _CompressorPreset({
    required this.thresholdDb,
    required this.ratio,
    required this.attackMs,
    required this.releaseMs,
    required this.lowMidLiftDb,
    required this.makeupDb,
  });
}

const _presets = {
  PlaneModeStrength.standard: _CompressorPreset(
    thresholdDb: -28,
    ratio: 2.5,
    attackMs: 15,
    releaseMs: 300,
    lowMidLiftDb: 4,
    makeupDb: 9.5,
  ),
  PlaneModeStrength.strong: _CompressorPreset(
    thresholdDb: -32,
    ratio: 3,
    attackMs: 10,
    releaseMs: 250,
    lowMidLiftDb: 6,
    makeupDb: 13,
  ),
};

double _clamp(double value, double low, double high) =>
    value < low ? low : (value > high ? high : value);

String _db(double value) => '${value.toStringAsFixed(2)}dB';

String _number(double value) {
  final text = value.toStringAsFixed(2);
  return text.contains('.')
      ? text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : text;
}

/// Works out the filters and gain for one song.
///
/// [loudness] is null when the song was not measured yet. Plane mode then
/// assumes a typical loudness; "Even out volume" leaves the song as it is.
AudioProcessingPlan planAudioProcessing(
  AudioProcessingSettings settings,
  MeasuredLoudness? loudness,
) {
  if (settings.planeMode) {
    return AudioProcessingPlan(
      filters: planeModeFilters(settings.strength, loudness),
    );
  }
  if (settings.evenOutVolume) {
    return AudioProcessingPlan(gainDb: evenOutGainDb(loudness));
  }
  return AudioProcessingPlan.none;
}

/// The gain "Even out volume" gives a song: down to [evenOutTargetLufs], or
/// up towards it as far as the song's peaks allow. 0 when unmeasured.
double evenOutGainDb(MeasuredLoudness? loudness) {
  final integrated = loudness?.integratedLufs;
  if (integrated == null) return 0;
  final gain = evenOutTargetLufs - integrated;
  if (gain <= 0) return gain < _maxEvenOutCutDb ? _maxEvenOutCutDb : gain;
  // mpv applies this gain with a hard clip, so a song is only turned up as
  // far as its loudest sample allows.
  final peak = loudness!.peakDb;
  if (peak == null) return 0;
  final headroom = -_evenOutPeakMarginDb - peak;
  final limit = headroom < _maxEvenOutBoostDb ? headroom : _maxEvenOutBoostDb;
  return limit <= 0 ? 0 : _clamp(gain, 0, limit);
}

/// mpv's `af` value for plane mode on a song of [loudness].
String planeModeFilters(
  PlaneModeStrength strength,
  MeasuredLoudness? loudness,
) {
  final preset = _presets[strength]!;
  final integrated = loudness?.integratedLufs ?? _unmeasuredLufs;
  final levelGain = _clamp(
    _compressorInputLufs - integrated,
    _minLevelGainDb,
    _maxLevelGainDb,
  );
  final cabin = loudness?.cabinLufs;
  final cabinCorrection =
      (loudness?.integratedLufs == null || cabin == null)
          ? 0.0
          : _clamp(
            (integrated - cabin) - _typicalCabinGapDb,
            -_maxCabinCorrectionDb,
            _maxCabinCorrectionDb,
          );
  final outputGain = preset.makeupDb + cabinCorrection;
  final graph = [
    'volume=${_db(levelGain)}',
    'acompressor=threshold=${_number(preset.thresholdDb)}dB'
        ':ratio=${_number(preset.ratio)}'
        ':attack=${_number(preset.attackMs)}'
        ':release=${_number(preset.releaseMs)}'
        ':knee=2.83:detection=rms:link=maximum',
    'equalizer=f=350:t=o:w=2:g=${_number(preset.lowMidLiftDb)}',
    'volume=${_db(outputGain)}',
    'alimiter=limit=${_number(_limiterCeilingDb)}dB'
        ':attack=5:release=50:level=disabled',
  ].join(',');
  return '@$planeModeFilterLabel:lavfi=[$graph]';
}
