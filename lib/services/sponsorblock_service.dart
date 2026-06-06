import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../database/database.dart';
import 'log_service.dart';

const sponsorBlockCategories = [
  'sponsor',
  'selfpromo',
  'interaction',
  'intro',
  'outro',
  'preview',
  'hook',
  'music_offtopic',
  'filler',
];

const defaultSponsorBlockCategories = [
  'sponsor',
  'selfpromo',
  'music_offtopic',
];

const sponsorBlockCategoryLabels = {
  'sponsor': 'Sponsor',
  'selfpromo': 'Self-promotion',
  'interaction': 'Interaction',
  'intro': 'Intro',
  'outro': 'Outro',
  'preview': 'Preview',
  'hook': 'Hook',
  'music_offtopic': 'Music/off-topic',
  'filler': 'Filler',
};

class SponsorBlockService {
  static const _host = 'sponsor.ajay.app';

  final AppDatabase _db;
  final LogService _log;
  final HttpClient _httpClient;

  SponsorBlockService(this._db, this._log, {HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  Future<void> refreshTrackSegments(Track track) async {
    if (track.isLocalReplacement) {
      return;
    }

    try {
      final segments = await fetchSegments(track.videoId, track.id);
      await _db.replaceSponsorBlockSegments(track.id, segments);
      _log.info(
        'SponsorBlock: ${segments.length} segments cached for ${track.title}',
      );
    } catch (e) {
      _log.warn('SponsorBlock fetch failed for ${track.videoId}: $e');
    }
  }

  Future<List<SponsorBlockSegmentsCompanion>> fetchSegments(
    String videoId,
    int trackId,
  ) async {
    final hash = sha256.convert(utf8.encode(videoId)).toString();
    final uri = Uri.https(_host, '/api/skipSegments/${hash.substring(0, 4)}', {
      'categories': jsonEncode(sponsorBlockCategories),
      'actionTypes': jsonEncode(['skip']),
    });

    final request = await _httpClient.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == HttpStatus.notFound) return const [];
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }

    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];

    final now = DateTime.now();
    final result = <SponsorBlockSegmentsCompanion>[];
    for (final candidate in decoded) {
      if (candidate is! Map<String, dynamic>) continue;
      if (candidate['videoID'] != videoId) continue;
      final segments = candidate['segments'];
      if (segments is! List) continue;

      for (final item in segments) {
        if (item is! Map<String, dynamic>) continue;
        if (item['actionType'] != null && item['actionType'] != 'skip') {
          continue;
        }

        final rawSegment = item['segment'];
        if (rawSegment is! List || rawSegment.length < 2) continue;
        final start = (rawSegment[0] as num?)?.toDouble();
        final end = (rawSegment[1] as num?)?.toDouble();
        if (start == null || end == null || end <= start) continue;

        final category = item['category'] as String? ?? '';
        if (!sponsorBlockCategories.contains(category)) continue;

        result.add(
          SponsorBlockSegmentsCompanion.insert(
            trackId: trackId,
            videoId: videoId,
            source: 'sponsorblock',
            uuid: Value(item['UUID'] as String?),
            category: category,
            actionType: Value(item['actionType'] as String? ?? 'skip'),
            startMs: (start * 1000).round(),
            endMs: (end * 1000).round(),
            votes: Value((item['votes'] as num?)?.toInt()),
            locked: Value(_parseLocked(item['locked'])),
            description: Value(item['description'] as String?),
            createdAt: now,
          ),
        );
      }
    }
    return result;
  }

  bool? _parseLocked(Object? raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    return null;
  }

  void dispose() {
    _httpClient.close(force: true);
  }
}
