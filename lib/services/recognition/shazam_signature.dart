import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'shazam_hanning.dart';

/// One spectral peak of a Shazam signature.
class FrequencyPeak {
  final int fftPassNumber;
  final int peakMagnitude;
  final int correctedPeakFrequencyBin;

  const FrequencyPeak(
    this.fftPassNumber,
    this.peakMagnitude,
    this.correctedPeakFrequencyBin,
  );

  double get seconds => fftPassNumber * 128 / 16000;
  double get frequencyHz => correctedPeakFrequencyBin * (16000 / 2 / 1024 / 64);

  @override
  bool operator ==(Object other) =>
      other is FrequencyPeak &&
      other.fftPassNumber == fftPassNumber &&
      other.peakMagnitude == peakMagnitude &&
      other.correctedPeakFrequencyBin == correctedPeakFrequencyBin;

  @override
  int get hashCode =>
      Object.hash(fftPassNumber, peakMagnitude, correctedPeakFrequencyBin);

  @override
  String toString() =>
      'Peak($fftPassNumber, $peakMagnitude, $correctedPeakFrequencyBin)';
}

/// A fingerprint of 16 kHz mono audio in the binary format Shazam's tagging
/// endpoint accepts. Only this fingerprint leaves the device, never audio.
class ShazamSignature {
  static const sampleRateHz = 16000;
  static const dataUriPrefix = 'data:audio/vnd.shazam.sig;base64,';

  final int numberSamples;

  /// Band index (0: 250-520 Hz, 1: 520-1450 Hz, 2: 1450-3500 Hz,
  /// 3: 3500-5500 Hz) to peaks in detection order.
  final Map<int, List<FrequencyPeak>> bands;

  const ShazamSignature({required this.numberSamples, required this.bands});

  int get sampleMs => numberSamples * 1000 ~/ sampleRateHz;
  int get peakCount => bands.values.fold(0, (sum, peaks) => sum + peaks.length);

  String get uri => '$dataUriPrefix${base64Encode(encode())}';

  Uint8List encode() {
    final contents = BytesBuilder(copy: false);
    for (final band in bands.keys.toList()..sort()) {
      final peaks = bands[band]!;
      if (peaks.isEmpty) continue;
      final peakBytes = BytesBuilder(copy: false);
      var fftPassNumber = 0;
      for (final peak in peaks) {
        if (peak.fftPassNumber - fftPassNumber >= 255) {
          peakBytes.addByte(0xff);
          peakBytes.add(_u32(peak.fftPassNumber));
          fftPassNumber = peak.fftPassNumber;
        }
        peakBytes.addByte(peak.fftPassNumber - fftPassNumber);
        peakBytes.add(_u16(peak.peakMagnitude));
        peakBytes.add(_u16(peak.correctedPeakFrequencyBin));
        fftPassNumber = peak.fftPassNumber;
      }
      final data = peakBytes.takeBytes();
      contents.add(_u32(0x60030040 + band));
      contents.add(_u32(data.length));
      contents.add(data);
      contents.add(Uint8List((4 - data.length % 4) % 4));
    }
    final body = contents.takeBytes();
    final sizeMinusHeader = body.length + 8;

    final out = ByteData(48 + sizeMinusHeader);
    out.setUint32(0, 0xcafe2580, Endian.little);
    // CRC written below.
    out.setUint32(8, sizeMinusHeader, Endian.little);
    out.setUint32(12, 0x94119c00, Endian.little);
    out.setUint32(28, 3 << 27, Endian.little); // 16 kHz
    out.setUint32(
      40,
      numberSamples + (sampleRateHz * 0.24).toInt(),
      Endian.little,
    );
    out.setUint32(44, (15 << 19) + 0x40000, Endian.little);
    out.setUint32(48, 0x40000000, Endian.little);
    out.setUint32(52, sizeMinusHeader, Endian.little);
    final bytes = out.buffer.asUint8List();
    bytes.setRange(56, 56 + body.length, body);
    out.setUint32(4, crc32(bytes, 8), Endian.little);
    return bytes;
  }

  static Uint8List _u32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);
  static Uint8List _u16(int value) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    table[i] = c;
  }
  return table;
}();

/// Standard CRC-32 (zlib) over [bytes] from [start].
int crc32(Uint8List bytes, [int start = 0]) {
  var crc = 0xffffffff;
  for (var i = start; i < bytes.length; i++) {
    crc = _crcTable[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

/// Port of the SongRec / shazamio-core signature algorithm.
///
/// Feeds 16 kHz signed 16-bit mono samples through a 2048-point windowed FFT
/// every 128 samples, spreads spectral maxima over neighbouring bins and
/// passes, and keeps the peaks that stand out in both frequency and time.
class ShazamSignatureGenerator {
  static const _fftSize = 2048;
  static const _bins = 1025;
  static const _history = 256;
  static const _step = 128;

  static final Float32List _hanning = Float32List.fromList(shazamHanningWindow);

  static ShazamSignature fromSamples(Int16List samples) {
    final generator = ShazamSignatureGenerator._();
    final usable = samples.length - samples.length % _step;
    for (var offset = 0; offset < usable; offset += _step) {
      generator._doFft(samples, offset);
      generator._doPeakSpreading();
      if (generator._spreadWritten >= 46) generator._doPeakRecognition();
    }
    return ShazamSignature(
      numberSamples: usable,
      bands: {
        for (var band = 0; band < 4; band++)
          if (generator._bands[band].isNotEmpty) band: generator._bands[band],
      },
    );
  }

  ShazamSignatureGenerator._();

  final Int16List _ring = Int16List(_fftSize);
  int _ringPosition = 0;

  final List<Float32List> _fftOutputs = [
    for (var i = 0; i < _history; i++) Float32List(_bins),
  ];
  int _fftPosition = 0;

  final List<Float32List> _spread = [
    for (var i = 0; i < _history; i++) Float32List(_bins),
  ];
  int _spreadPosition = 0;
  int _spreadWritten = 0;

  final List<List<FrequencyPeak>> _bands = [[], [], [], []];

  final _Fft _fft = _Fft(_fftSize);
  final Float64List _real = Float64List(_fftSize);
  final Float64List _imag = Float64List(_fftSize);

  void _doFft(Int16List samples, int offset) {
    for (var i = 0; i < _step; i++) {
      _ring[(_ringPosition + i) % _fftSize] = samples[offset + i];
    }
    _ringPosition = (_ringPosition + _step) % _fftSize;
    // Oldest sample first.
    for (var i = 0; i < _fftSize; i++) {
      _real[i] = _hanning[i] * _ring[(_ringPosition + i) % _fftSize];
      _imag[i] = 0;
    }
    _fft.transform(_real, _imag);
    final out = _fftOutputs[_fftPosition];
    for (var i = 0; i < _bins; i++) {
      final power = (_real[i] * _real[i] + _imag[i] * _imag[i]) / (1 << 17);
      out[i] = power < 1e-10 ? 1e-10 : power;
    }
    _fftPosition = (_fftPosition + 1) % _history;
  }

  void _doPeakSpreading() {
    final origin = _fftOutputs[(_fftPosition - 1 + _history) % _history];
    final spread = Float32List.fromList(origin);
    for (var i = 0; i <= _bins - 3; i++) {
      spread[i] = math.max(spread[i], math.max(origin[i + 1], origin[i + 2]));
    }
    for (final former in const [-1, -3, -6]) {
      final target = _spread[(_spreadPosition + former + _history) % _history];
      for (var i = 0; i < _bins; i++) {
        if (spread[i] > target[i]) target[i] = spread[i];
      }
    }
    _spread[_spreadPosition].setAll(0, spread);
    _spreadPosition = (_spreadPosition + 1) % _history;
    _spreadWritten++;
  }

  static const _neighborOffsets = [-10, -7, -4, -3, 1, 2, 5, 8];
  static const _otherOffsets = [
    -53,
    -45,
    165,
    172,
    179,
    186,
    193,
    200,
    214,
    221,
    228,
    235,
    242,
    249,
  ];

  void _doPeakRecognition() {
    final fftMinus46 = _fftOutputs[(_fftPosition - 46 + _history) % _history];
    final fftMinus49 = _spread[(_spreadPosition - 49 + _history) % _history];
    const threshold = 1 / 64;
    for (var bin = 10; bin < 1015; bin++) {
      final value = fftMinus46[bin];
      if (value < threshold || value < fftMinus49[bin - 1]) continue;
      var maxNeighbor = 0.0;
      for (final offset in _neighborOffsets) {
        maxNeighbor = math.max(maxNeighbor, fftMinus49[bin + offset]);
      }
      if (value <= maxNeighbor) continue;
      var maxOther = maxNeighbor;
      for (final offset in _otherOffsets) {
        final row = _spread[(_spreadPosition + offset + _history) % _history];
        maxOther = math.max(maxOther, row[bin - 1]);
      }
      if (value <= maxOther) continue;

      final fftNumber = _spreadWritten - 46;
      final magnitude = _magnitude(value);
      final before = _magnitude(fftMinus46[bin - 1]);
      final after = _magnitude(fftMinus46[bin + 1]);
      final variation1 = magnitude * 2 - before - after;
      final variation2 = (after - before) * 32 / variation1;
      // The reference truncates the sub-bin offset on its own before adding
      // it, and classifies the whole hertz value.
      // Rust's `as i32` saturates on infinity and maps NaN to zero, and the
      // sum is then wrapped to 16 bits.
      final correctedBin = (bin * 64 + _saturatingInt(variation2)) & 0xffff;
      final frequencyHz = (correctedBin * (16000 / 2 / 1024 / 64)).toInt();
      final int band;
      if (frequencyHz >= 250 && frequencyHz <= 519) {
        band = 0;
      } else if (frequencyHz >= 520 && frequencyHz <= 1449) {
        band = 1;
      } else if (frequencyHz >= 1450 && frequencyHz <= 3499) {
        band = 2;
      } else if (frequencyHz >= 3500 && frequencyHz <= 5500) {
        band = 3;
      } else {
        continue;
      }
      _bands[band].add(
        FrequencyPeak(fftNumber, magnitude.toInt(), correctedBin),
      );
    }
  }

  static int _saturatingInt(double value) {
    if (value.isNaN) return 0;
    if (value >= 2147483647) return 2147483647;
    if (value <= -2147483648) return -2147483648;
    return value.toInt();
  }

  /// The reference clamps the logarithm, not the power, so quiet neighbour
  /// bins all collapse to the same value.
  static double _magnitude(double power) =>
      math.max(math.log(power), 1 / 64) * 1477.3 + 6144;
}

/// In-place iterative radix-2 complex FFT.
class _Fft {
  _Fft(this.size)
    : _reverse = Uint16List(size),
      _cos = Float64List(size ~/ 2),
      _sin = Float64List(size ~/ 2) {
    final bits = (math.log(size) / math.ln2).round();
    for (var i = 0; i < size; i++) {
      var reversed = 0;
      for (var b = 0; b < bits; b++) {
        if ((i >> b) & 1 == 1) reversed |= 1 << (bits - 1 - b);
      }
      _reverse[i] = reversed;
    }
    for (var i = 0; i < size ~/ 2; i++) {
      final angle = -2 * math.pi * i / size;
      _cos[i] = math.cos(angle);
      _sin[i] = math.sin(angle);
    }
  }

  final int size;
  final Uint16List _reverse;
  final Float64List _cos;
  final Float64List _sin;

  void transform(Float64List real, Float64List imag) {
    for (var i = 0; i < size; i++) {
      final j = _reverse[i];
      if (j > i) {
        final tr = real[i];
        real[i] = real[j];
        real[j] = tr;
        final ti = imag[i];
        imag[i] = imag[j];
        imag[j] = ti;
      }
    }
    for (var len = 2; len <= size; len <<= 1) {
      final half = len >> 1;
      final stride = size ~/ len;
      for (var start = 0; start < size; start += len) {
        for (var k = 0; k < half; k++) {
          final c = _cos[k * stride];
          final s = _sin[k * stride];
          final a = start + k;
          final b = a + half;
          final tr = real[b] * c - imag[b] * s;
          final ti = real[b] * s + imag[b] * c;
          real[b] = real[a] - tr;
          imag[b] = imag[a] - ti;
          real[a] += tr;
          imag[a] += ti;
        }
      }
    }
  }
}
