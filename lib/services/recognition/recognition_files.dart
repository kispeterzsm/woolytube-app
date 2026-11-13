/// `.woolytube_info/<safeId>.recognition.json`: a track's last song
/// recognition run, with the owner's review edits, plus the lookups and
/// quiet gaps it was made from in a compact form.
///
/// The app keeps runs in its private storage under the database's track
/// id, which a reinstall does not keep. This copy in the playlist folder is
/// keyed by the video id and the file's content key (size plus a hash of
/// its head and tail) instead, so after copying the folders to another
/// phone the run can be reviewed, and scanned again without the network,
/// as long as the file is the same.
library;

import 'dart:convert';

import '../info_files.dart';
import '../library_layout.dart';

/// Format version of the file. A file of a newer version is read where it
/// can be but never overwritten.
const recognitionFileVersion = 1;

/// What a recognition file holds.
class RecognitionFolderCopy {
  const RecognitionFolderCopy({
    required this.version,
    required this.contentKey,
    required this.run,
    this.samples = const [],
    this.silences = const [],
  });

  final int version;

  /// The content key of the file the run was made from.
  final String contentKey;

  /// The run as `RecognitionRun.toJson` writes it, without a track id; its
  /// `fileKey` is [contentKey].
  final Map<String, dynamic> run;

  /// Cached lookups in the app's private cache format (see [expandSample]).
  final List<Map<String, dynamic>> samples;

  /// Cached quiet gaps: `from`, `to` and the private cache's content.
  final List<({int fromMs, int toMs, Map<String, dynamic> content})> silences;
}

/// The file's JSON.
///
/// [run] is `RecognitionRun.toJson()`; its track id is left out and its
/// file key replaced by [contentKey]. [samples] are entries of the private
/// lookup cache, stored compactly ([compactSample]); [silences] are the
/// private quiet-gap cache entries by their stretch.
Map<String, dynamic> recognitionFileJson({
  required String videoId,
  required String contentKey,
  required Map<String, dynamic> run,
  List<Map<String, dynamic>> samples = const [],
  List<({int fromMs, int toMs, Object? content})> silences = const [],
}) {
  final compactSamples = [
    for (final sample in samples)
      if (compactSample(sample) case final compact?) compact,
  ]..sort((a, b) => (a['startMs'] as int).compareTo(b['startMs'] as int));
  final compactSilences = [
    for (final s in silences)
      if (_compactSilence(s.fromMs, s.toMs, s.content) case final compact?)
        compact,
  ]..sort((a, b) => (a['from'] as int).compareTo(b['from'] as int));
  return {
    'app': 'WoolyTube',
    'version': recognitionFileVersion,
    'videoId': videoId,
    'contentKey': contentKey,
    'run': {
      for (final entry in run.entries)
        if (entry.key != 'trackId') entry.key: entry.value,
      'fileKey': contentKey,
    },
    if (compactSamples.isNotEmpty) 'samples': compactSamples,
    if (compactSilences.isNotEmpty) 'silences': compactSilences,
  };
}

/// A private lookup cache entry (`sampleStartMs`, `sampleDurationMs`,
/// `recordedAt`, `decoderVersion` and Shazam's whole `response`) with only
/// what a scan reads from the response: the song and where it matched.
/// Null for an entry that cannot be read.
Map<String, dynamic>? compactSample(Map<String, dynamic> cached) {
  final start = cached['sampleStartMs'];
  if (start is! num) return null;
  final response = cached['response'];
  final track = response is Map ? response['track'] : null;
  final matches = response is Map ? response['matches'] : null;
  final key = track is Map ? track['key']?.toString() : null;
  return {
    'startMs': start.toInt(),
    if (cached['sampleDurationMs'] case final num duration)
      'durationMs': duration.toInt(),
    if (cached['decoderVersion'] case final num version)
      'decoderVersion': version.toInt(),
    if (cached['recordedAt'] case final String at) 'recordedAt': at,
    if (key != null) ...{
      'key': key,
      if (track is Map && track['title'] != null)
        'title': track['title'].toString(),
      if (track is Map && track['subtitle'] != null)
        'artist': track['subtitle'].toString(),
      'matches': [
        if (matches is List)
          for (final match in matches)
            if (match is Map && match['offset'] is num && match['id'] != null)
              [match['id'].toString(), match['offset']],
      ],
    },
  };
}

/// The private lookup cache entry of a [compactSample]: Shazam's response
/// rebuilt with the parts a scan reads. Null when it cannot be read.
Map<String, dynamic>? expandSample(Object? compact) {
  if (compact is! Map) return null;
  final start = compact['startMs'];
  if (start is! num) return null;
  final key = compact['key'];
  final matches = compact['matches'];
  return {
    'sampleStartMs': start.toInt(),
    if (compact['durationMs'] case final num duration)
      'sampleDurationMs': duration.toInt(),
    if (compact['recordedAt'] case final String at) 'recordedAt': at,
    if (compact['decoderVersion'] case final num version)
      'decoderVersion': version.toInt(),
    'response': {
      if (key != null) ...{
        'track': {
          'key': key.toString(),
          if (compact['title'] != null) 'title': compact['title'].toString(),
          if (compact['artist'] != null)
            'subtitle': compact['artist'].toString(),
        },
        'matches': [
          if (matches is List)
            for (final match in matches)
              if (match is List && match.length >= 2 && match[1] is num)
                {'id': match[0].toString(), 'offset': match[1]},
        ],
      },
    },
  };
}

/// A private quiet-gap cache entry: `{decoderVersion, intervals}`, or a
/// bare list of intervals from before decoder versions existed.
Map<String, dynamic>? _compactSilence(int fromMs, int toMs, Object? content) {
  final Object? intervals;
  final Object? version;
  if (content is Map) {
    intervals = content['intervals'];
    version = content['decoderVersion'];
  } else {
    intervals = content;
    version = null;
  }
  if (intervals is! List) return null;
  return {
    'from': fromMs,
    'to': toMs,
    if (version is num) 'decoderVersion': version.toInt(),
    'intervals': intervals,
  };
}

/// Reads a recognition file's [json]; null when it has no usable run.
RecognitionFolderCopy? recognitionFolderCopyFromJson(Object? json) {
  if (json is! Map) return null;
  final contentKey = json['contentKey'];
  final run = json['run'];
  if (contentKey is! String || contentKey.isEmpty || run is! Map) return null;
  final samples = <Map<String, dynamic>>[];
  if (json['samples'] case final List list) {
    for (final entry in list) {
      if (expandSample(entry) case final sample?) samples.add(sample);
    }
  }
  final silences = <({int fromMs, int toMs, Map<String, dynamic> content})>[];
  if (json['silences'] case final List list) {
    for (final entry in list) {
      if (entry is! Map) continue;
      final from = entry['from'];
      final to = entry['to'];
      final intervals = entry['intervals'];
      if (from is! num || to is! num || intervals is! List) continue;
      silences.add((
        fromMs: from.toInt(),
        toMs: to.toInt(),
        content: {
          if (entry['decoderVersion'] case final num version)
            'decoderVersion': version.toInt(),
          'intervals': intervals,
        },
      ));
    }
  }
  return RecognitionFolderCopy(
    version: (json['version'] as num?)?.toInt() ?? 1,
    contentKey: contentKey,
    run: Map<String, dynamic>.from(run),
    samples: samples,
    silences: silences,
  );
}

/// The recognition file of [videoId] in [playlistPath], or null.
Future<RecognitionFolderCopy?> readRecognitionFile(
  String playlistPath,
  String videoId,
) async => recognitionFolderCopyFromJson(
  await readInfoJson(LibraryLayout.recognitionJsonPath(playlistPath, videoId)),
);

/// Writes [json] (see [recognitionFileJson]) as the recognition file of
/// [videoId] in [playlistPath]. Unchanged content is not rewritten, and a
/// file a newer app wrote is kept. Returns whether it wrote.
Future<bool> writeRecognitionFile(
  String playlistPath,
  String videoId,
  Map<String, dynamic> json,
) async {
  final path = LibraryLayout.recognitionJsonPath(playlistPath, videoId);
  final existing = await readInfoJson(path);
  if (existing != null &&
      ((existing['version'] as num?)?.toInt() ?? 1) > recognitionFileVersion) {
    return false;
  }
  return writeInfoFile(path, jsonEncode(json));
}
