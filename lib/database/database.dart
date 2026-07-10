import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../services/sponsorblock_categories.dart';

part 'database.g.dart';

class Playlists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get url => text()();
  TextColumn get name => text()();
  TextColumn get thumbnailUrl => text().nullable()();
  TextColumn get thumbnailPath => text().nullable()();
  BoolColumn get audioOnly => boolean().withDefault(const Constant(false))();
  BoolColumn get autoUpdate => boolean().withDefault(const Constant(true))();
  IntColumn get updateFrequencyHours =>
      integer().withDefault(const Constant(24))();
  BoolColumn get includeThumbnails =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get sponsorBlockEnabled =>
      boolean().withDefault(const Constant(true))();
  TextColumn get sponsorBlockCategories =>
      text().withDefault(
        const Constant('["sponsor","selfpromo","music_offtopic"]'),
      )();
  TextColumn get sponsorBlockCategoryActions =>
      text().withDefault(
        const Constant(defaultSponsorBlockCategoryActionsJson),
      )();
  DateTimeColumn get lastUpdated => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get outputPath => text()();
}

class Tracks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get playlistId => integer().references(Playlists, #id)();
  IntColumn get index => integer()();
  TextColumn get videoId => text()();
  TextColumn get title => text()();
  TextColumn get thumbnailUrl => text().nullable()();
  TextColumn get thumbnailPath => text().nullable()();
  TextColumn get filePath => text().nullable()();
  IntColumn get durationSeconds => integer().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get unavailableReason => text().nullable()();
  BoolColumn get isLocalReplacement =>
      boolean().withDefault(const Constant(false))();
  /// Exclude this track from automatic playback, while still allowing an
  /// explicit tap to play it.
  BoolColumn get alwaysSkip => boolean().withDefault(const Constant(false))();
  DateTimeColumn get downloadedAt => dateTime().nullable()();
  DateTimeColumn get sponsorBlockCheckedAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
}

class SponsorBlockSegments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();
  TextColumn get videoId => text()();
  TextColumn get source => text()(); // sponsorblock | local | override | hidden
  TextColumn get uuid => text().nullable()();
  TextColumn get category => text()();
  TextColumn get actionType => text().withDefault(const Constant('skip'))();
  IntColumn get startMs => integer()();
  IntColumn get endMs => integer()();
  IntColumn get votes => integer().nullable()();
  BoolColumn get locked => boolean().nullable()();
  TextColumn get description => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
}

@DriftDatabase(tables: [Playlists, Tracks, SponsorBlockSegments])
class AppDatabase extends _$AppDatabase {
  AppDatabase._internal(super.e);

  static AppDatabase? _instance;

  factory AppDatabase() {
    _instance ??= AppDatabase._internal(_openConnection());
    return _instance!;
  }

  factory AppDatabase.forTesting(QueryExecutor executor) {
    return AppDatabase._internal(executor);
  }

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_tracks_pl_status ON tracks (playlist_id, status)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_tracks_pl_index ON tracks (playlist_id, "index")',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sb_track_start ON sponsor_block_segments (track_id, start_ms)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sb_track_source ON sponsor_block_segments (track_id, source)',
      );
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.addColumn(tracks, tracks.unavailableReason);
      }
      if (from < 3) {
        await migrator.addColumn(tracks, tracks.isLocalReplacement);
      }
      if (from < 4) {
        await migrator.addColumn(tracks, tracks.lastError);
      }
      if (from < 5) {
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_tracks_pl_status ON tracks (playlist_id, status)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_tracks_pl_index ON tracks (playlist_id, "index")',
        );
      }
      if (from < 6) {
        await migrator.addColumn(playlists, playlists.sponsorBlockEnabled);
        await migrator.addColumn(playlists, playlists.sponsorBlockCategories);
        await migrator.createTable(sponsorBlockSegments);
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_sb_track_start ON sponsor_block_segments (track_id, start_ms)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_sb_track_source ON sponsor_block_segments (track_id, source)',
        );
      }
      if (from < 7) {
        await migrator.addColumn(
          playlists,
          playlists.sponsorBlockCategoryActions,
        );
        final rows =
            await customSelect(
              'SELECT id, sponsor_block_categories FROM playlists',
            ).get();
        for (final row in rows) {
          final id = row.read<int>('id');
          final legacy = row.read<String>('sponsor_block_categories');
          await customUpdate(
            'UPDATE playlists SET sponsor_block_category_actions = ? WHERE id = ?',
            variables: [
              Variable<String>(
                sponsorBlockCategoryActionsJsonFromLegacyJson(legacy),
              ),
              Variable<int>(id),
            ],
          );
        }
      }
      if (from < 8) {
        await migrator.addColumn(tracks, tracks.sponsorBlockCheckedAt);
      }
      if (from < 9) {
        await migrator.addColumn(tracks, tracks.alwaysSkip);
      }
    },
  );

  // Playlist queries
  Future<List<Playlist>> getAllPlaylists() => select(playlists).get();

  Stream<List<Playlist>> watchAllPlaylists() => select(playlists).watch();

  Future<Playlist> getPlaylist(int id) =>
      (select(playlists)..where((p) => p.id.equals(id))).getSingle();

  Future<int> insertPlaylist(PlaylistsCompanion playlist) =>
      into(playlists).insert(playlist);

  Future<bool> updatePlaylist(PlaylistsCompanion playlist) =>
      update(playlists).replace(playlist);

  Future<int> deletePlaylist(int id) =>
      (delete(playlists)..where((p) => p.id.equals(id))).go();

  Future<Playlist?> getPlaylistByUrl(String url) =>
      (select(playlists)..where((p) => p.url.equals(url))).getSingleOrNull();

  // Track queries
  Future<List<Track>> getTracksForPlaylist(int playlistId) =>
      (select(tracks)
            ..where((t) => t.playlistId.equals(playlistId))
            ..orderBy([(t) => OrderingTerm.asc(t.index)]))
          .get();

  Future<Track?> getTrack(int id) =>
      (select(tracks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<List<Track>> watchTracksForPlaylist(int playlistId) =>
      (select(tracks)
            ..where((t) => t.playlistId.equals(playlistId))
            ..orderBy([(t) => OrderingTerm.asc(t.index)]))
          .watch();

  Future<int> insertTrack(TracksCompanion track) => into(tracks).insert(track);

  Future<void> insertTracks(List<TracksCompanion> trackList) async {
    await batch((batch) {
      batch.insertAll(tracks, trackList);
    });
  }

  Future<bool> updateTrack(TracksCompanion track) =>
      update(tracks).replace(track);

  Future<void> updateTrackFields(
    int trackId, {
    String? title,
    String? filePath,
  }) async {
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        filePath: filePath != null ? Value(filePath) : const Value.absent(),
      ),
    );
  }

  Future<void> updateTrackStatus(
    int trackId,
    String status, {
    String? filePath,
    bool? isLocalReplacement,
    String? error,
    bool clearFilePath = false,
    bool clearDownloadedAt = false,
  }) async {
    final Value<String?> errorValue;
    if (status == 'error') {
      errorValue = Value(error);
    } else if (status == 'complete') {
      errorValue = const Value(null);
    } else {
      errorValue = const Value.absent();
    }

    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        status: Value(status),
        filePath:
            clearFilePath
                ? const Value(null)
                : filePath != null
                ? Value(filePath)
                : const Value.absent(),
        isLocalReplacement:
            isLocalReplacement != null
                ? Value(isLocalReplacement)
                : const Value.absent(),
        downloadedAt:
            status == 'complete'
                ? Value(DateTime.now())
                : clearDownloadedAt
                ? const Value(null)
                : const Value.absent(),
        lastError: errorValue,
      ),
    );
  }

  Future<List<Track>> getPendingTracks(int playlistId) =>
      (select(tracks)
            ..where(
              (t) =>
                  t.playlistId.equals(playlistId) &
                  (t.status.equals('pending') | t.status.equals('error')),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.index)]))
          .get();

  Future<int> getDownloadedTrackCount(int playlistId) async {
    final count = tracks.id.count();
    final query =
        selectOnly(tracks)
          ..addColumns([count])
          ..where(
            tracks.playlistId.equals(playlistId) &
                tracks.status.equals('complete'),
          );
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  Future<int> getTotalTrackCount(int playlistId) async {
    final count = tracks.id.count();
    final query =
        selectOnly(tracks)
          ..addColumns([count])
          ..where(tracks.playlistId.equals(playlistId));
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  Future<List<Playlist>> getPlaylistsDueForUpdate() async {
    final all =
        await (select(playlists)
          ..where((p) => p.autoUpdate.equals(true))).get();
    final now = DateTime.now();
    return all.where((p) {
      if (p.lastUpdated == null) return true;
      return now.difference(p.lastUpdated!).inHours >= p.updateFrequencyHours;
    }).toList();
  }

  Future<List<String>> getVideoIdsForPlaylist(int playlistId) async {
    final trackList =
        await (select(tracks)
          ..where((t) => t.playlistId.equals(playlistId))).get();
    return trackList.map((t) => t.videoId).toList();
  }

  Future<void> updateTrackUnavailable(
    int trackId,
    String reason, {
    int? newIndex,
  }) async {
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        status: const Value('unavailable'),
        unavailableReason: Value(reason),
        index: newIndex != null ? Value(newIndex) : const Value.absent(),
      ),
    );
  }

  Future<void> updateTrackAvailable(
    int trackId, {
    required String title,
    String? thumbnailUrl,
    int? durationSeconds,
    int? newIndex,
  }) async {
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        status: const Value('pending'),
        unavailableReason: const Value(null),
        title: Value(title),
        thumbnailUrl: Value(thumbnailUrl),
        durationSeconds: Value(durationSeconds),
        index: newIndex != null ? Value(newIndex) : const Value.absent(),
      ),
    );
  }

  Future<void> updateTrackIndex(int trackId, int newIndex) async {
    await (update(tracks)..where(
      (t) => t.id.equals(trackId),
    )).write(TracksCompanion(index: Value(newIndex)));
  }

  Future<void> updateTrackOnlineStatus(
    int trackId,
    String? unavailableReason,
  ) async {
    await (update(tracks)..where(
      (t) => t.id.equals(trackId),
    )).write(TracksCompanion(unavailableReason: Value(unavailableReason)));
  }

  Future<void> updateTrackLocalReplacement(
    int trackId,
    bool isLocalReplacement,
  ) async {
    await (update(tracks)..where(
      (t) => t.id.equals(trackId),
    )).write(TracksCompanion(isLocalReplacement: Value(isLocalReplacement)));
  }

  Future<void> updateTrackAlwaysSkip(int trackId, bool alwaysSkip) async {
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(alwaysSkip: Value(alwaysSkip)),
    );
  }

  Future<void> updateTrackSponsorBlockCheckedAt(
    int trackId,
    DateTime? checkedAt,
  ) async {
    await (update(tracks)..where(
      (t) => t.id.equals(trackId),
    )).write(TracksCompanion(sponsorBlockCheckedAt: Value(checkedAt)));
  }

  Future<void> resetTrackForRedownload(int trackId) async {
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        status: const Value('pending'),
        filePath: const Value(null),
        isLocalReplacement: const Value(false),
        unavailableReason: const Value(null),
        downloadedAt: const Value(null),
        sponsorBlockCheckedAt: const Value(null),
        lastError: const Value(null),
      ),
    );
  }

  Future<List<SponsorBlockSegment>> getSegmentsForTrack(int trackId) =>
      (select(sponsorBlockSegments)
            ..where((s) => s.trackId.equals(trackId))
            ..orderBy([(s) => OrderingTerm.asc(s.startMs)]))
          .get();

  Stream<List<SponsorBlockSegment>> watchSegmentsForTrack(int trackId) =>
      (select(sponsorBlockSegments)
            ..where((s) => s.trackId.equals(trackId))
            ..orderBy([(s) => OrderingTerm.asc(s.startMs)]))
          .watch();

  Future<void> replaceSponsorBlockSegments(
    int trackId,
    List<SponsorBlockSegmentsCompanion> segments,
  ) async {
    await transaction(() async {
      await (delete(sponsorBlockSegments)
        ..where((s) => s.trackId.equals(trackId))).go();
      if (segments.isNotEmpty) {
        await batch((batch) {
          batch.insertAll(sponsorBlockSegments, segments);
        });
      }
    });
  }

  Future<void> replaceRemoteSponsorBlockSegments(
    int trackId,
    List<SponsorBlockSegmentsCompanion> segments,
  ) async {
    await transaction(() async {
      final protectedRows =
          await (select(sponsorBlockSegments)..where(
            (s) =>
                s.trackId.equals(trackId) &
                (s.source.equals('override') | s.source.equals('hidden')) &
                s.uuid.isNotNull(),
          )).get();
      final protectedUuids = protectedRows.map((s) => s.uuid).nonNulls.toSet();

      await (delete(sponsorBlockSegments)..where(
        (s) => s.trackId.equals(trackId) & s.source.equals('sponsorblock'),
      )).go();

      final remoteSegments =
          segments.where((segment) {
            final uuid = segment.uuid.present ? segment.uuid.value : null;
            return uuid == null || !protectedUuids.contains(uuid);
          }).toList();
      if (remoteSegments.isNotEmpty) {
        await batch((batch) {
          batch.insertAll(sponsorBlockSegments, remoteSegments);
        });
      }
    });
  }

  Future<int> insertSegment(SponsorBlockSegmentsCompanion segment) =>
      into(sponsorBlockSegments).insert(segment);

  Future<int> insertLocalSegment(SponsorBlockSegmentsCompanion segment) =>
      insertSegment(segment);

  Future<void> updateSegment(
    int segmentId, {
    String? source,
    String? category,
    String? actionType,
    int? startMs,
    int? endMs,
    String? description,
  }) => (update(sponsorBlockSegments)
    ..where((s) => s.id.equals(segmentId))).write(
    SponsorBlockSegmentsCompanion(
      source: source != null ? Value(source) : const Value.absent(),
      category: category != null ? Value(category) : const Value.absent(),
      actionType: actionType != null ? Value(actionType) : const Value.absent(),
      startMs: startMs != null ? Value(startMs) : const Value.absent(),
      endMs: endMs != null ? Value(endMs) : const Value.absent(),
      description:
          description != null ? Value(description) : const Value.absent(),
    ),
  );

  Future<void> deleteSegment(int segmentId) =>
      (delete(sponsorBlockSegments)..where((s) => s.id.equals(segmentId))).go();

  Future<void> deleteLocalSegmentsForTrack(int trackId) =>
      (delete(sponsorBlockSegments)..where(
        (s) => s.trackId.equals(trackId) & s.source.equals('local'),
      )).go();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'woolytube.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
