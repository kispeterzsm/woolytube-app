import 'dart:io';
import 'dart:typed_data';

import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/recognition/audio_window_decoder.dart';
import 'package:woolytube/services/recognition/chapter_estimator.dart';
import 'package:woolytube/services/recognition/shazam_client.dart';
import 'package:woolytube/services/recognition/shazam_signature.dart';
import 'package:woolytube/services/recognition/song_recognition_service.dart';

class SilentDecoder implements AudioWindowDecoder {
  @override
  Future<Int16List> decode(
    String path, {
    required Duration start,
    required Duration duration,
  }) async => Int16List(duration.inMilliseconds * 16);

  @override
  Future<Duration?> probeDuration(String path) async =>
      const Duration(minutes: 3);
}

class NoMatchRecognizer implements ShazamRecognizer {
  @override
  Future<ShazamResult> recognize(ShazamSignature signature) async =>
      ShazamResult.fromJson(const {});
}

SongRecognitionService fakeRecognitionService(AppDatabase db, Directory root) =>
    SongRecognitionService(
      db,
      decoder: SilentDecoder(),
      recognizer: NoMatchRecognizer(),
      rootDirectory: () async => root,
    );

ChapterProposal proposal(
  String id,
  String title,
  int startMs,
  int endMs, {
  String? trackKey = 'key',
  List<String> notes = const [],
}) => ChapterProposal(
  id: id,
  title: title,
  startMs: startMs,
  endMs: endMs,
  trackKey: trackKey,
  referenceId: trackKey == null ? null : 'ref-$trackKey',
  sampleCount: 2,
  referenceSampleCount: 2,
  referenceStartMs: startMs,
  referenceSpreadMs: 40,
  boundaryMethod: startMs == 0 ? 'file-start' : 'quiet-transition',
  selectedQuietIntervalMs: null,
  nearestSilenceMs: null,
  distanceFromSilenceEndMs: null,
  consistentReference: true,
  notes: notes,
  firstSampleMs: startMs,
  lastSampleMs: endMs,
);

RecognitionRun fakeRun(
  int trackId,
  List<ChapterProposal> proposals, {
  int durationMs = 180000,
  String fileKey = 'key',
}) => RecognitionRun(
  runId: 'run1',
  trackId: trackId,
  fileKey: fileKey,
  epoch: 0,
  durationMs: durationMs,
  completedAt: DateTime(2026),
  sampleCount: 4,
  matchedSamples: 3,
  proposals: proposals,
);
