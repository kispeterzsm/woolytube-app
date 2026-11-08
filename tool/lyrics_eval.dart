// Runs the real title parser, LRCLIB client and matcher over the tracks of
// a playlist sidecar and prints what each lookup decided.
//
//   dart run tool/lyrics_eval.dart <woolytube_meta.json> [--limit N]
//       [--seed S] [--videos id,id] [--describe]
//
// --limit N     look up N tracks (default 40), a random sample when --seed
//               is given, otherwise the first N
// --videos      only these video ids
// --describe    also read each video's YouTube page for its channel and
//               description, like the info.json kept on the phone
//
// Uses the live network at about one request per second.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:woolytube/services/lyrics/lrclib_client.dart';
import 'package:woolytube/services/lyrics/lyrics_matcher.dart';
import 'package:woolytube/services/lyrics/title_parser.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first.startsWith('-')) {
    stderr.writeln(
      'usage: dart run tool/lyrics_eval.dart <woolytube_meta.json> '
      '[--limit N] [--seed S] [--videos id,id] [--describe]',
    );
    exitCode = 64;
    return;
  }
  var limit = 40;
  int? seed;
  Set<String>? videos;
  var describe = false;
  for (var i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--limit':
        limit = int.parse(args[++i]);
      case '--seed':
        seed = int.parse(args[++i]);
      case '--videos':
        videos = args[++i].split(',').map((v) => v.trim()).toSet();
      case '--describe':
        describe = true;
      default:
        stderr.writeln('unknown option ${args[i]}');
        exitCode = 64;
        return;
    }
  }

  final sidecar =
      jsonDecode(await File(args.first).readAsString()) as Map<String, dynamic>;
  var tracks = [
    for (final t in (sidecar['tracks'] as List).cast<Map<String, dynamic>>())
      if (t['title'] is String && t['videoId'] is String)
        if (videos == null || videos.contains(t['videoId'])) t,
  ];
  if (seed != null) tracks.shuffle(Random(seed));
  tracks = tracks.take(limit).toList();

  final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final client = LrclibClient(http: http, userAgent: lyricsUserAgent('eval'));
  final matcher = LyricsMatcher(client);

  var found = 0;
  var synced = 0;
  var instrumental = 0;
  var missed = 0;
  var failed = 0;
  final watch = Stopwatch()..start();
  for (final (i, track) in tracks.indexed) {
    final title = track['title'] as String;
    final videoId = track['videoId'] as String;
    final duration = (track['durationSeconds'] as num?)?.toDouble();
    VideoMeta? meta;
    if (describe) {
      meta = await _watchPageMeta(http, videoId);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final query = parseSongTitle(title, meta: meta);
    final line = StringBuffer(
      '${'${i + 1}'.padLeft(3)} ${_cut(title, 58).padRight(58)} '
      '[${query.artist ?? '-'} | ${query.title}'
      '${query.nightcore ? ' | nc' : ''}'
      '${query.alternatives.isEmpty ? '' : ' | alt ${query.alternatives.first}'}] ',
    );
    try {
      final result = await matcher.match(query, durationSeconds: duration);
      final record = result.record;
      if (result.found && record != null) {
        found++;
        if (result.synced) synced++;
        // When the record's last synced line starts (after the time
        // scale), against the file's length.
        final span = syncedSpanOf(record);
        final last =
            span == null
                ? ''
                : ', last line ${(span.lastMs * result.timeScale / 1000).round()}s';
        line.write(
          '-> ${record.artistName} - ${record.trackName} #${record.id} '
          '(${result.step}, ${result.synced ? 'synced' : 'plain'}'
          '${result.timeScale == 1.0 ? '' : ', x${result.timeScale.toStringAsFixed(2)}'}'
          ', ${record.duration?.round()}s vs ${duration?.round()}s$last)',
        );
      } else if (result.status == 'instrumental') {
        instrumental++;
        line.write(
          '-> INSTRUMENTAL ${record?.artistName} - ${record?.trackName}',
        );
      } else {
        missed++;
        line.write('-> MISS (${result.reason})');
      }
    } on LrclibException catch (e) {
      failed++;
      line.write('-> ERROR $e');
    }
    stdout.writeln(line);
  }
  http.close(force: true);
  final total = tracks.length;
  String pct(int n) => total == 0 ? '0' : (100 * n / total).toStringAsFixed(1);
  stdout.writeln(
    '\n$total tracks: found $found (${pct(found)}%, $synced synced), '
    'instrumental $instrumental, missed $missed, errors $failed; '
    '${client.requestCount} LRCLIB requests in ${watch.elapsed.inSeconds}s',
  );
}

String _cut(String text, int length) =>
    text.length <= length ? text : '${text.substring(0, length - 1)}…';

final _channel = RegExp(r'"ownerChannelName":"((?:[^"\\]|\\.)*)"');
final _description = RegExp(r'"shortDescription":"((?:[^"\\]|\\.)*)"');

/// The channel and description from a video's YouTube page, standing in for
/// the info.json the app keeps.
Future<VideoMeta?> _watchPageMeta(HttpClient http, String videoId) async {
  try {
    final request = await http.getUrl(
      Uri.parse('https://www.youtube.com/watch?v=$videoId&hl=en'),
    );
    request.headers
      ..set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/130.0 Safari/537.36',
      )
      ..set(HttpHeaders.acceptLanguageHeader, 'en-US')
      ..set(HttpHeaders.cookieHeader, 'CONSENT=YES+1');
    final response = await request.close();
    final html = await response.transform(utf8.decoder).join();
    String? read(RegExp pattern) {
      final match = pattern.firstMatch(html);
      return match == null ? null : jsonDecode('"${match[1]}"') as String;
    }

    return VideoMeta(uploader: read(_channel), description: read(_description));
  } catch (e) {
    stderr.writeln('could not read the page of $videoId: $e');
    return null;
  }
}
