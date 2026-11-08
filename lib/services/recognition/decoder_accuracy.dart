import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// How exactly the platform decoder places decoded audio in time. Stored
/// with every scan and every cached lookup or silence result, so results
/// from a less exact decoder can be told apart from current ones.
///
/// 1. Android's MediaExtractor seeked MP3 files by estimating the byte
///    position from the file's table of contents and labelled the audio
///    with the requested time, so MP3 windows came from seconds away.
///    Other formats were already exact. Data stored before this constant
///    existed has no version and counts as 1.
/// 2. MP3 windows are decoded from the app's own frame index and are
///    sample-exact. An indexed file is decoded exactly or the decode fails
///    (a read error is not cached, so the next try indexes again); it never
///    quietly falls back to MediaExtractor seeking. Only files whose content
///    cannot be indexed (free-format bitrate, or a frame count far from the
///    file's stated length) still go through MediaExtractor, and a scan
///    again would place them the same way, so their data is not outdated.
///
/// Bump this whenever a decoder change moves where audio lands, and say in
/// [decoderVersionTrusted] which files the older versions got wrong.
const int decoderAccuracyVersion = 2;

/// Whether data made by decoder [version] (null: stored before versions
/// existed, which is version 1) can still be used for a file that does
/// ([mpegAudio]) or does not use the MP3 decoder path.
///
/// Version 1 is only wrong for MP3, so other files keep their data.
bool decoderVersionTrusted(int? version, {required bool mpegAudio}) =>
    !mpegAudio || (version ?? 1) >= 2;

/// Whether the platform decoder reads [path] as MP3 (MPEG audio layer
/// III), the format version 1 of the decoder placed wrongly.
///
/// The Android decoder picks the path from the MIME type MediaExtractor
/// reports for the file's audio track, `audio/mpeg`, which it takes from
/// the content rather than the name. So this checks the content too: an
/// ID3v2 tag, which is skipped, followed by an MPEG layer III frame header,
/// or such a header right at the start. A `.mp3` name counts as MP3
/// without looking. Only a few bytes are read; a file that cannot be read
/// does not count.
Future<bool> isMpegAudioFile(String path) async {
  if (p.extension(path).toLowerCase() == '.mp3') return true;
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final head = await file.read(10);
    if (head.length == 10 &&
        head[0] == 0x49 && // I
        head[1] == 0x44 && // D
        head[2] == 0x33) {
      // ID3v2: the size is a syncsafe integer and excludes the header and
      // the footer, which flag 0x10 adds.
      final size =
          (head[6] & 0x7f) << 21 |
          (head[7] & 0x7f) << 14 |
          (head[8] & 0x7f) << 7 |
          (head[9] & 0x7f);
      await file.setPosition(10 + size + ((head[5] & 0x10) != 0 ? 10 : 0));
      return isMpegLayer3Header(await file.read(4));
    }
    return isMpegLayer3Header(head);
  } on FileSystemException {
    return false;
  } finally {
    await file?.close();
  }
}

/// Whether [bytes] start with an MPEG audio layer III frame header: the
/// 11-bit sync word, a known MPEG version, layer III, a bitrate index that
/// is not "bad" and a known sample rate. AAC in ADTS also starts with a
/// sync word but says layer 0, so it does not match.
bool isMpegLayer3Header(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final b1 = bytes[1];
  final b2 = bytes[2];
  if (bytes[0] != 0xff || (b1 & 0xe0) != 0xe0) return false;
  if ((b1 >> 3) & 0x03 == 0x01) return false; // reserved version
  if ((b1 >> 1) & 0x03 != 0x01) return false; // not layer III
  if (b2 >> 4 == 0x0f) return false; // bad bitrate index
  if ((b2 >> 2) & 0x03 == 0x03) return false; // reserved sample rate
  return true;
}
