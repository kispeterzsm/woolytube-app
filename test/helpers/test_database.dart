import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/sponsorblock_categories.dart';

AppDatabase openTestDatabase() {
  return AppDatabase.forTesting(NativeDatabase.memory());
}

Future<Playlist> insertTestPlaylist(
  AppDatabase db, {
  String url = 'https://www.youtube.com/playlist?list=test',
  String name = 'Test Playlist',
  String? thumbnailUrl,
  String? thumbnailPath,
  bool audioOnly = false,
  bool autoUpdate = true,
  int updateFrequencyHours = 24,
  bool includeThumbnails = true,
  bool sponsorBlockEnabled = true,
  String sponsorBlockCategories = '["sponsor","selfpromo","music_offtopic"]',
  String sponsorBlockCategoryActions = defaultSponsorBlockCategoryActionsJson,
  DateTime? lastUpdated,
  DateTime? createdAt,
  String outputPath = '/tmp/woolytube-test',
}) async {
  final id = await db.insertPlaylist(
    PlaylistsCompanion.insert(
      url: url,
      name: name,
      thumbnailUrl: Value(thumbnailUrl),
      thumbnailPath: Value(thumbnailPath),
      audioOnly: Value(audioOnly),
      autoUpdate: Value(autoUpdate),
      updateFrequencyHours: Value(updateFrequencyHours),
      includeThumbnails: Value(includeThumbnails),
      sponsorBlockEnabled: Value(sponsorBlockEnabled),
      sponsorBlockCategories: Value(sponsorBlockCategories),
      sponsorBlockCategoryActions: Value(sponsorBlockCategoryActions),
      lastUpdated: Value(lastUpdated),
      createdAt: createdAt ?? DateTime(2024),
      outputPath: outputPath,
    ),
  );
  return db.getPlaylist(id);
}

Future<Track> insertTestTrack(
  AppDatabase db, {
  required int playlistId,
  int index = 1,
  String videoId = 'video-1',
  String title = 'Track 1',
  String? thumbnailUrl,
  String? thumbnailPath,
  String? filePath,
  int? durationSeconds,
  String status = 'pending',
  String? unavailableReason,
  bool isLocalReplacement = false,
  bool alwaysSkip = false,
  DateTime? downloadedAt,
  DateTime? sponsorBlockCheckedAt,
  String? lastError,
}) async {
  final id = await db.insertTrack(
    TracksCompanion.insert(
      playlistId: playlistId,
      index: index,
      videoId: videoId,
      title: title,
      thumbnailUrl: Value(thumbnailUrl),
      thumbnailPath: Value(thumbnailPath),
      filePath: Value(filePath),
      durationSeconds: Value(durationSeconds),
      status: Value(status),
      unavailableReason: Value(unavailableReason),
      isLocalReplacement: Value(isLocalReplacement),
      alwaysSkip: Value(alwaysSkip),
      downloadedAt: Value(downloadedAt),
      sponsorBlockCheckedAt: Value(sponsorBlockCheckedAt),
      lastError: Value(lastError),
    ),
  );
  return (await db.getTracksForPlaylist(
    playlistId,
  )).singleWhere((track) => track.id == id);
}
