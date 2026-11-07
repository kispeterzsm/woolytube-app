import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../services/sponsorblock_categories.dart';
import '../services/chapters.dart';

part 'database.g.dart';

class Playlists extends Table {
  BoolColumn get playChapters => boolean().nullable()();
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

  /// When an update (manual or scheduled) last started checking this
  /// playlist, successful or not. The scheduled worker takes the playlists
  /// it tried longest ago first, so one playlist that never finishes in
  /// time cannot keep the others from ever being updated.
  DateTimeColumn get lastUpdateAttempt => dateTime().nullable()();
}

class Tracks extends Table {
  TextColumn get chaptersJson => text().nullable()();

  /// null inherits the playlist preference.
  BoolColumn get chaptersEnabled => boolean().nullable()();
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

  /// The file should be replaced by a fresh download (the YouTube original
  /// of a local replacement, or the other format after a mode switch). The
  /// current file stays in use until the new one is completely on disk.
  BoolColumn get replaceRequested =>
      boolean().withDefault(const Constant(false))();
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

const _accentFolding = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'æ': 'ae', //
  'ç': 'c', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'í': 'i', 'ì': 'i', //
  'î': 'i', 'ï': 'i', 'ñ': 'n', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', //
  'ő': 'o', 'õ': 'o', 'ø': 'o', 'œ': 'oe', 'ß': 'ss', 'ú': 'u', 'ù': 'u', //
  'û': 'u', 'ü': 'u', 'ű': 'u', 'ý': 'y', 'ÿ': 'y',
};

/// Reduces [text] to lowercase ASCII letters and digits, folding accents the
/// way yt-dlp's restricted file names do, so a title can be compared with
/// the file name it produced.
String foldForFileNameMatch(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final folded = _accentFolding[char] ?? char;
    for (final unit in folded.codeUnits) {
      if ((unit >= 0x61 && unit <= 0x7a) || (unit >= 0x30 && unit <= 0x39)) {
        buffer.writeCharCode(unit);
      }
    }
  }
  return buffer.toString();
}

/// Whether the title part of [filePath] (after the `<index>_` prefix) looks
/// like it was made from [title].
bool titleMatchesFileName(String title, String filePath) {
  final base = p.basenameWithoutExtension(filePath);
  final rest = base.replaceFirst(RegExp(r'^\d+_'), '');
  final foldedTitle = foldForFileNameMatch(title);
  final foldedRest = foldForFileNameMatch(rest);
  if (foldedTitle.isEmpty || foldedRest.isEmpty) return false;
  return foldedTitle == foldedRest ||
      foldedTitle.startsWith(foldedRest) ||
      foldedRest.startsWith(foldedTitle);
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
  int get schemaVersion => 13;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
    onCreate: (migrator) async {
      await migrator.createAll();
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_tracks_pl_status ON tracks (playlist_id, status)',
      );
      await customStatement(_createUniqueTrackIndexSql);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sb_track_start ON sponsor_block_segments (track_id, start_ms)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_sb_track_source ON sponsor_block_segments (track_id, source)',
      );
      await _createRevisionTracking();
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
      if (from < 10) {
        await migrator.addColumn(playlists, playlists.playChapters);
        await migrator.addColumn(tracks, tracks.chaptersJson);
        await migrator.addColumn(tracks, tracks.chaptersEnabled);
      }
      if (from < 9) {
        await migrator.addColumn(tracks, tracks.alwaysSkip);
      }
      if (from < 11) {
        await _repairDuplicateTrackIndices();
        await customStatement('DROP INDEX IF EXISTS idx_tracks_pl_index');
        await customStatement(_createUniqueTrackIndexSql);
      }
      if (from < 12) {
        await migrator.addColumn(tracks, tracks.replaceRequested);
      }
      if (from < 13) {
        await migrator.addColumn(playlists, playlists.lastUpdateAttempt);
        await _createRevisionTracking();
      }
    },
  );

  /// A counter per playlist that SQLite itself raises whenever the playlist,
  /// one of its tracks or one of their skip segments changes, from any
  /// connection (the app or the background worker). The metadata mirror
  /// compares it with the counter it last wrote, so it only rebuilds the
  /// files of playlists that really changed.
  ///
  /// The table is not a drift table on purpose: writes made by the triggers
  /// do not wake drift's stream queries.
  Future<void> _createRevisionTracking() async {
    await customStatement(
      'CREATE TABLE IF NOT EXISTS playlist_revisions ('
      'playlist_id INTEGER NOT NULL PRIMARY KEY, '
      'revision INTEGER NOT NULL DEFAULT 0)',
    );
    String bump(String playlistIdExpr) =>
        'INSERT INTO playlist_revisions (playlist_id, revision) '
        'SELECT $playlistIdExpr, 1 WHERE $playlistIdExpr IS NOT NULL '
        'ON CONFLICT(playlist_id) DO UPDATE SET revision = revision + 1;';
    String segmentPlaylist(String row) =>
        '(SELECT playlist_id FROM tracks WHERE id = $row.track_id)';
    final triggers = {
      'trg_rev_tracks_insert':
          'AFTER INSERT ON tracks BEGIN '
          '${bump('NEW.playlist_id')} END',
      'trg_rev_tracks_update':
          'AFTER UPDATE ON tracks BEGIN '
          '${bump('NEW.playlist_id')} END',
      'trg_rev_tracks_delete':
          'AFTER DELETE ON tracks BEGIN '
          '${bump('OLD.playlist_id')} END',
      'trg_rev_segments_insert':
          'AFTER INSERT ON sponsor_block_segments BEGIN '
          '${bump(segmentPlaylist('NEW'))} END',
      'trg_rev_segments_update':
          'AFTER UPDATE ON sponsor_block_segments BEGIN '
          '${bump(segmentPlaylist('NEW'))} END',
      'trg_rev_segments_delete':
          'AFTER DELETE ON sponsor_block_segments BEGIN '
          '${bump(segmentPlaylist('OLD'))} END',
      'trg_rev_playlists_insert':
          'AFTER INSERT ON playlists BEGIN '
          '${bump('NEW.id')} END',
      // A changed update-attempt stamp does not change the metadata file.
      'trg_rev_playlists_update':
          'AFTER UPDATE ON playlists WHEN '
          'NEW.last_update_attempt IS OLD.last_update_attempt OR '
          'NEW.name IS NOT OLD.name OR NEW.url IS NOT OLD.url OR '
          'NEW.output_path IS NOT OLD.output_path OR '
          'NEW.last_updated IS NOT OLD.last_updated BEGIN '
          '${bump('NEW.id')} END',
      'trg_rev_playlists_delete':
          'AFTER DELETE ON playlists BEGIN '
          'DELETE FROM playlist_revisions WHERE playlist_id = OLD.id; END',
    };
    for (final entry in triggers.entries) {
      await customStatement(
        'CREATE TRIGGER IF NOT EXISTS ${entry.key} ${entry.value}',
      );
    }
  }

  static const _createUniqueTrackIndexSql =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_pl_index_unique '
      'ON tracks (playlist_id, "index")';

  /// Older versions could give two tracks of one playlist the same index, for
  /// example when a sync renumbered a pending track onto a downloaded one,
  /// and the download then adopted the other track's file by its prefix.
  ///
  /// The row that really owns the contested file keeps the index: the one
  /// that got the file first (an adopting row was stamped later), then the
  /// one whose title matches the file name, then the oldest row. The other
  /// rows are appended after the playlist's current maximum. A moved row
  /// that points at the same file as the kept row loses that file so it is
  /// downloaded again under its own index instead of playing another
  /// track's media; a moved row with its own file keeps it (reconcile keeps
  /// an existing file path and renames it to the new prefix).
  Future<void> _repairDuplicateTrackIndices() async {
    final groups =
        await customSelect(
          'SELECT playlist_id, "index" FROM tracks '
          'GROUP BY playlist_id, "index" HAVING COUNT(*) > 1 '
          'ORDER BY playlist_id, "index"',
        ).get();
    final maxIndexByPlaylist = <int, int>{};
    for (final group in groups) {
      final playlistId = group.read<int>('playlist_id');
      final index = group.read<int>('index');
      var maxIndex = maxIndexByPlaylist[playlistId];
      if (maxIndex == null) {
        final row =
            await customSelect(
              'SELECT MAX("index") AS max_index FROM tracks '
              'WHERE playlist_id = ?',
              variables: [Variable<int>(playlistId)],
            ).getSingle();
        maxIndex = row.readNullable<int>('max_index') ?? 0;
      }
      final rows =
          await customSelect(
            'SELECT id, file_path, title, downloaded_at, chapters_json '
            'FROM tracks WHERE playlist_id = ? AND "index" = ? ORDER BY id',
            variables: [Variable<int>(playlistId), Variable<int>(index)],
          ).get();
      final ranked = [...rows]..sort(_compareFileOwnership);
      for (final row in ranked.skip(1)) {
        final id = row.read<int>('id');
        maxIndex = maxIndex! + 1;
        await customUpdate(
          'UPDATE tracks SET "index" = ? WHERE id = ?',
          variables: [Variable<int>(maxIndex), Variable<int>(id)],
          updates: {tracks},
        );
        final filePath = row.readNullable<String>('file_path');
        if (filePath == null) continue;
        final shared =
            await customSelect(
              'SELECT COUNT(*) AS shared FROM tracks '
              'WHERE playlist_id = ? AND file_path = ? AND id <> ?',
              variables: [
                Variable<int>(playlistId),
                Variable<String>(filePath),
                Variable<int>(id),
              ],
            ).getSingle();
        if (shared.read<int>('shared') > 0) {
          await customUpdate(
            "UPDATE tracks SET status = 'pending', file_path = NULL, "
            'downloaded_at = NULL, thumbnail_path = NULL, '
            'is_local_replacement = 0 WHERE id = ?',
            variables: [Variable<int>(id)],
            updates: {tracks},
          );
        }
      }
      maxIndexByPlaylist[playlistId] = maxIndex!;
    }
  }

  /// Orders rows that share an index so the likely owner of the file comes
  /// first. See [_repairDuplicateTrackIndices].
  static int _compareFileOwnership(QueryRow a, QueryRow b) {
    final aPath = a.readNullable<String>('file_path');
    final bPath = b.readNullable<String>('file_path');
    if ((aPath == null) != (bPath == null)) return aPath == null ? 1 : -1;
    // drift stores dates as unix seconds by default.
    final aAt = a.readNullable<int>('downloaded_at');
    final bAt = b.readNullable<int>('downloaded_at');
    if (aAt != bAt) {
      if (aAt == null) return 1;
      if (bAt == null) return -1;
      return aAt.compareTo(bAt);
    }
    if (aPath != null && bPath != null) {
      final aScore = titleMatchesFileName(a.read<String>('title'), aPath);
      final bScore = titleMatchesFileName(b.read<String>('title'), bPath);
      if (aScore != bScore) return aScore ? -1 : 1;
    }
    final aChapters = a.readNullable<String>('chapters_json') != null;
    final bChapters = b.readNullable<String>('chapters_json') != null;
    if (aChapters != bChapters) return aChapters ? -1 : 1;
    return a.read<int>('id').compareTo(b.read<int>('id'));
  }

  // Playlist queries
  Future<List<Playlist>> getAllPlaylists() => select(playlists).get();

  Stream<List<Playlist>> watchAllPlaylists() =>
      select(playlists).watch().distinct(listsEqual);

  Future<Playlist> getPlaylist(int id) =>
      (select(playlists)..where((p) => p.id.equals(id))).getSingle();

  /// The playlist, or null when it was deleted.
  Future<Playlist?> getPlaylistOrNull(int id) =>
      (select(playlists)..where((p) => p.id.equals(id))).getSingleOrNull();

  /// Stamps the start of an update check (see [Playlists.lastUpdateAttempt]).
  Future<void> markPlaylistUpdateAttempt(int id, DateTime at) =>
      updatePlaylistFields(
        id,
        PlaylistsCompanion(lastUpdateAttempt: Value(at)),
      );

  Future<int> insertPlaylist(PlaylistsCompanion playlist) =>
      into(playlists).insert(playlist);

  Future<bool> updatePlaylist(PlaylistsCompanion playlist) =>
      update(playlists).replace(playlist);

  /// Writes only the columns present in [fields], leaving the rest untouched.
  Future<void> updatePlaylistFields(int id, PlaylistsCompanion fields) =>
      (update(playlists)..where((p) => p.id.equals(id))).write(fields);

  Future<void> markPlaylistUpdated(int id, DateTime at) =>
      updatePlaylistFields(id, PlaylistsCompanion(lastUpdated: Value(at)));

  /// Removes a playlist together with its tracks and their segments.
  Future<int> deletePlaylist(int id) => transaction(() async {
    final trackIds =
        (await (selectOnly(tracks)
                  ..addColumns([tracks.id])
                  ..where(tracks.playlistId.equals(id)))
                .get())
            .map((row) => row.read(tracks.id)!)
            .toList();
    if (trackIds.isNotEmpty) {
      await (delete(sponsorBlockSegments)
        ..where((s) => s.trackId.isIn(trackIds))).go();
    }
    await (delete(tracks)..where((t) => t.playlistId.equals(id))).go();
    return (delete(playlists)..where((p) => p.id.equals(id))).go();
  });

  Future<Playlist?> getPlaylistByUrl(String url) =>
      (select(playlists)..where((p) => p.url.equals(url))).getSingleOrNull();

  // Track queries
  Future<List<Track>> getAllTracks() =>
      (select(tracks)..orderBy([
        (t) => OrderingTerm.asc(t.playlistId),
        (t) => OrderingTerm.asc(t.index),
      ])).get();

  /// Every track of the library. Drift re-runs the query after any write to
  /// the tracks table; identical results are not passed on.
  Stream<List<Track>> watchAllTracks() => (select(tracks)..orderBy([
    (t) => OrderingTerm.asc(t.playlistId),
    (t) => OrderingTerm.asc(t.index),
  ])).watch().distinct(listsEqual);

  /// Per playlist: how many tracks it has, how many are downloaded, how many
  /// YouTube no longer provides (and have no file), and how many failed.
  /// Cheap (one aggregate over an index) and only emits when a number
  /// changes, so it does not wake the home page on every track write.
  Stream<Map<int, PlaylistCounts>> watchPlaylistTrackCounts() => customSelect(
        'SELECT playlist_id, COUNT(*) AS total, '
        "COALESCE(SUM(status = 'complete'), 0) AS downloaded, "
        "COALESCE(SUM(status = 'unavailable'), 0) AS unavailable, "
        "COALESCE(SUM(status = 'error'), 0) AS failed "
        'FROM tracks GROUP BY playlist_id',
        readsFrom: {tracks},
      )
      .watch()
      .map(
        (rows) => {
          for (final row in rows)
            row.read<int>('playlist_id'): PlaylistCounts(
              total: row.read<int>('total'),
              downloaded: row.read<int>('downloaded'),
              unavailable: row.read<int>('unavailable'),
              failed: row.read<int>('failed'),
            ),
        },
      )
      .distinct(_mapsEqual);

  Future<List<Track>> getTracksForPlaylist(int playlistId) =>
      (select(tracks)
            ..where((t) => t.playlistId.equals(playlistId))
            ..orderBy([(t) => OrderingTerm.asc(t.index)]))
          .get();

  Future<Track?> getTrack(int id) =>
      (select(tracks)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// The playlist's tracks in order. Writes to other playlists' tracks
  /// make drift re-run the query; an unchanged result is not passed on.
  Stream<List<Track>> watchTracksForPlaylist(int playlistId) => (select(tracks)
        ..where((t) => t.playlistId.equals(playlistId))
        ..orderBy([(t) => OrderingTerm.asc(t.index)]))
      .watch()
      .distinct(listsEqual);

  /// One track, or null once it is deleted.
  Stream<Track?> watchTrack(int id) =>
      (select(tracks)
        ..where((t) => t.id.equals(id))).watchSingleOrNull().distinct();

  Future<int> insertTrack(TracksCompanion track) => into(tracks).insert(track);

  Future<void> insertTracks(List<TracksCompanion> trackList) async {
    await batch((batch) {
      batch.insertAll(tracks, trackList);
    });
  }

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

  /// Points several tracks at new files in one transaction (one stream
  /// update instead of one per track).
  Future<void> updateTrackFilePaths(Map<int, String> pathsByTrackId) async {
    if (pathsByTrackId.isEmpty) return;
    await batch((b) {
      for (final entry in pathsByTrackId.entries) {
        b.update(
          tracks,
          TracksCompanion(filePath: Value(entry.value)),
          where: (t) => t.id.equals(entry.key),
        );
      }
    });
  }

  /// Records several cover images in one transaction.
  Future<void> updateTrackThumbnailPaths(
    Map<int, String?> pathsByTrackId,
  ) async {
    if (pathsByTrackId.isEmpty) return;
    await batch((b) {
      for (final entry in pathsByTrackId.entries) {
        b.update(
          tracks,
          TracksCompanion(thumbnailPath: Value(entry.value)),
          where: (t) => t.id.equals(entry.key),
        );
      }
    });
  }

  /// Sets [status]. 'complete' stamps `downloadedAt` with now, unless
  /// [keepDownloadedAt] (relinking a file that was already downloaded
  /// before, which must not rewrite its history).
  Future<void> updateTrackStatus(
    int trackId,
    String status, {
    String? filePath,
    bool? isLocalReplacement,
    String? error,
    bool clearFilePath = false,
    bool clearDownloadedAt = false,
    bool keepDownloadedAt = false,
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
            status == 'complete' && !keepDownloadedAt
                ? Value(DateTime.now())
                : clearDownloadedAt
                ? const Value(null)
                : const Value.absent(),
        lastError: errorValue,
      ),
    );
  }

  /// Tracks an update should download. A local replacement whose file is
  /// missing (for example still being copied back after a restore) is not
  /// among them unless the owner asked for the original: downloading would
  /// silently swap the owner's chosen file for the YouTube version.
  Future<List<Track>> getPendingTracks(int playlistId) =>
      (select(tracks)
            ..where(
              (t) =>
                  t.playlistId.equals(playlistId) &
                  (t.status.equals('pending') | t.status.equals('error')) &
                  (t.isLocalReplacement.equals(false) |
                      t.replaceRequested.equals(true)),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.index)]))
          .get();

  /// Downloaded tracks whose file should be replaced by a fresh download.
  Future<List<Track>> getReplacementRequests(int playlistId) =>
      (select(tracks)
            ..where(
              (t) =>
                  t.playlistId.equals(playlistId) &
                  t.status.equals('complete') &
                  t.replaceRequested.equals(true),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.index)]))
          .get();

  Future<void> setTrackReplaceRequested(int trackId, bool requested) =>
      (update(tracks)..where(
        (t) => t.id.equals(trackId),
      )).write(TracksCompanion(replaceRequested: Value(requested)));

  /// Records a finished download that is now the track's file.
  Future<void> markTrackDownloaded(
    int trackId, {
    required String filePath,
    required String? thumbnailPath,
  }) => (update(tracks)..where((t) => t.id.equals(trackId))).write(
    TracksCompanion(
      status: const Value('complete'),
      filePath: Value(filePath),
      thumbnailPath: Value(thumbnailPath),
      isLocalReplacement: const Value(false),
      replaceRequested: const Value(false),
      downloadedAt: Value(DateTime.now()),
      lastError: const Value(null),
    ),
  );

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

  /// How much earlier than its interval a playlist already counts as due.
  /// The worker runs about hourly; without some slack, a playlist stamped 58
  /// minutes ago would wait for the next run and "every hour" would become
  /// every two hours.
  static const updateDueTolerance = Duration(minutes: 15);

  /// Auto-updating playlists whose interval has passed, the one tried
  /// longest ago first (never tried first).
  Future<List<Playlist>> getPlaylistsDueForUpdate({DateTime? now}) async {
    final all =
        await (select(playlists)
          ..where((p) => p.autoUpdate.equals(true))).get();
    final current = now ?? DateTime.now();
    final due =
        all.where((p) {
          final last = p.lastUpdated;
          if (last == null) return true;
          final interval = Duration(hours: p.updateFrequencyHours);
          final threshold =
              interval > updateDueTolerance * 2
                  ? interval - updateDueTolerance
                  : interval;
          return current.difference(last) >= threshold;
        }).toList();
    due.sort((a, b) {
      final aAt = a.lastUpdateAttempt, bAt = b.lastUpdateAttempt;
      if (aAt == null || bAt == null) {
        if (aAt == bAt) return a.id.compareTo(b.id);
        return aAt == null ? -1 : 1;
      }
      final byTime = aAt.compareTo(bAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return due;
  }

  Future<void> updateTrackUnavailable(int trackId, String reason) async {
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        status: const Value('unavailable'),
        unavailableReason: Value(reason),
      ),
    );
  }

  /// Marks a track YouTube has permanently taken down, found out by a
  /// failed download. A track without a file becomes 'unavailable', so
  /// updates stop retrying it; a downloaded file stays and keeps playing.
  Future<void> markTrackRemovedFromYouTube(int trackId, String error) async {
    final track = await getTrack(trackId);
    if (track == null) return;
    final hasFile = track.status == 'complete' && track.filePath != null;
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        status: hasFile ? const Value.absent() : const Value('unavailable'),
        unavailableReason: const Value(removedFromYouTubeReason),
        lastError: Value(error),
      ),
    );
  }

  /// Puts a track that a download found removed from YouTube back in the
  /// queue, so the next update (or a manual retry) tries it again. A track
  /// with a downloaded file keeps it.
  Future<void> clearRemovedFromYouTube(int trackId) async {
    await transaction(() async {
      final track = await getTrack(trackId);
      if (track == null ||
          track.unavailableReason != removedFromYouTubeReason) {
        return;
      }
      final hasFile = track.status == 'complete' && track.filePath != null;
      await (update(tracks)..where((t) => t.id.equals(trackId))).write(
        TracksCompanion(
          unavailableReason: const Value(null),
          status: hasFile ? const Value.absent() : const Value('pending'),
          lastError: const Value(null),
        ),
      );
    });
  }

  Future<void> updateTrackAvailable(
    int trackId, {
    required String title,
    String? thumbnailUrl,
    int? durationSeconds,
  }) async {
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        status: const Value('pending'),
        unavailableReason: const Value(null),
        title: Value(title),
        thumbnailUrl: Value(
          thumbnailUrl == null || thumbnailUrl.isEmpty ? null : thumbnailUrl,
        ),
        durationSeconds: Value(
          durationSeconds == null || durationSeconds <= 0
              ? null
              : durationSeconds,
        ),
      ),
    );
  }

  Future<void> updateTrackPlacement(
    int trackId, {
    required int index,
    String? filePath,
  }) async {
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        index: Value(index),
        filePath: filePath != null ? Value(filePath) : const Value.absent(),
      ),
    );
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

  Future<void> updateTrackThumbnailPath(
    int trackId,
    String? thumbnailPath,
  ) async {
    await (update(tracks)..where(
      (t) => t.id.equals(trackId),
    )).write(TracksCompanion(thumbnailPath: Value(thumbnailPath)));
  }

  Future<void> updateTrackAlwaysSkip(int trackId, bool alwaysSkip) async {
    await (update(tracks)..where(
      (t) => t.id.equals(trackId),
    )).write(TracksCompanion(alwaysSkip: Value(alwaysSkip)));
  }

  Future<void> updateTrackSponsorBlockCheckedAt(
    int trackId,
    DateTime? checkedAt,
  ) async {
    await (update(tracks)..where(
      (t) => t.id.equals(trackId),
    )).write(TracksCompanion(sponsorBlockCheckedAt: Value(checkedAt)));
  }

  Future<void> writeTrackChapters(int trackId, ChapterData data) =>
      (update(tracks)..where(
        (t) => t.id.equals(trackId),
      )).write(TracksCompanion(chaptersJson: Value(data.encode())));

  Future<void> setTrackChapterOverride(int trackId, bool? enabled) =>
      (update(tracks)..where(
        (t) => t.id.equals(trackId),
      )).write(TracksCompanion(chaptersEnabled: Value(enabled)));

  Future<void> invalidateTrackChapters(int trackId) async {
    final track = await getTrack(trackId);
    if (track?.chaptersJson != null) {
      await writeTrackChapters(
        trackId,
        ChapterData.decode(track!.chaptersJson).invalidate(),
      );
    }
  }

  Future<void> resetTrackForRedownload(int trackId) async {
    await invalidateTrackChapters(trackId);
    await (update(tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        status: const Value('pending'),
        filePath: const Value(null),
        thumbnailPath: const Value(null),
        isLocalReplacement: const Value(false),
        unavailableReason: const Value(null),
        downloadedAt: const Value(null),
        sponsorBlockCheckedAt: const Value(null),
        lastError: const Value(null),
      ),
    );
  }

  /// Returns a track left in the transient `downloading` state to the queue.
  ///
  /// A process can disappear between setting `downloading` and recording the
  /// completed file. This deliberately preserves playlist/index metadata while
  /// clearing state that only applies to a finished download.
  ///
  /// With [onlyIfDownloading], a track that has meanwhile finished (for
  /// example a cancel that arrives while the file is being saved) is left
  /// alone. The local-file flag is kept: an interrupted download replaced
  /// nothing.
  ///
  /// A track marked removed from YouTube whose manual retry was interrupted
  /// goes back to 'unavailable' with its removal message, not to the queue:
  /// the mark always means "no file and not retried by updates".
  Future<void> resetInterruptedTrack(
    int trackId, {
    bool onlyIfDownloading = false,
  }) async {
    await transaction(() async {
      final track = await getTrack(trackId);
      if (track == null) return;
      if (onlyIfDownloading && track.status != 'downloading') return;
      final removed = track.unavailableReason == removedFromYouTubeReason;
      await (update(tracks)..where((t) => t.id.equals(trackId))).write(
        TracksCompanion(
          status: Value(removed ? 'unavailable' : 'pending'),
          filePath: const Value(null),
          downloadedAt: const Value(null),
          lastError: removed ? const Value.absent() : const Value(null),
        ),
      );
    });
  }

  /// Ends a failed manual retry of a track marked removed from YouTube: it
  /// stays 'unavailable' with its removal message, whatever the retry
  /// failed with (a bot check must not put it back into every update).
  Future<void> restoreRemovedFromYouTube(int trackId) async {
    await (update(tracks)..where(
      (t) =>
          t.id.equals(trackId) &
          t.unavailableReason.equals(removedFromYouTubeReason) &
          t.status.isNotIn(const ['complete']),
    )).write(const TracksCompanion(status: Value('unavailable')));
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

  /// Stores the results of several SponsorBlock checks at once: each
  /// track's remote segments are replaced (local, override and hidden ones
  /// stay) and its check time is set. One transaction, one stream update.
  Future<void> storeSponsorBlockResults(
    Map<int, List<SponsorBlockSegmentsCompanion>> segmentsByTrackId,
    DateTime checkedAt,
  ) async {
    if (segmentsByTrackId.isEmpty) return;
    await transaction(() async {
      for (final entry in segmentsByTrackId.entries) {
        await replaceRemoteSponsorBlockSegments(entry.key, entry.value);
        await updateTrackSponsorBlockCheckedAt(entry.key, checkedAt);
      }
    });
  }

  /// The change counter of every playlist (see [_createRevisionTracking]).
  /// A playlist without an entry has not changed since the counters were
  /// introduced and counts as revision 0.
  Future<Map<int, int>> playlistRevisions() async {
    final rows =
        await customSelect(
          'SELECT playlist_id, revision FROM playlist_revisions',
        ).get();
    return {
      for (final row in rows)
        row.read<int>('playlist_id'): row.read<int>('revision'),
    };
  }

  /// The change counter of one playlist.
  Future<int> playlistRevision(int playlistId) async {
    final row =
        await customSelect(
          'SELECT revision FROM playlist_revisions WHERE playlist_id = ?',
          variables: [Variable<int>(playlistId)],
        ).getSingleOrNull();
    return row?.read<int>('revision') ?? 0;
  }

  int? _dataVersion;

  /// Drift only refreshes its streams for writes made through this
  /// connection. The background worker writes through its own, so call this
  /// when the app comes back to the foreground or while a background update
  /// may be running: it asks SQLite whether another connection committed
  /// since the last call and, if so, makes every stream query run again.
  /// Returns whether anything was refreshed.
  Future<bool> refreshIfChangedExternally() async {
    final row = await customSelect('PRAGMA data_version').getSingle();
    final version = row.read<int>('data_version');
    final previous = _dataVersion;
    _dataVersion = version;
    if (previous == null || previous == version) return false;
    notifyUpdates({
      TableUpdate.onTable(playlists),
      TableUpdate.onTable(tracks),
      TableUpdate.onTable(sponsorBlockSegments),
    });
    return true;
  }

  Future<void> deleteSegment(int segmentId) =>
      (delete(sponsorBlockSegments)..where((s) => s.id.equals(segmentId))).go();

  Future<void> deleteLocalSegmentsForTrack(int trackId) =>
      (delete(sponsorBlockSegments)..where(
        (s) => s.trackId.equals(trackId) & s.source.equals('local'),
      )).go();

  /// Drops segments fetched from SponsorBlock while keeping local, override
  /// and hidden entries. Used when a track's media no longer matches the
  /// YouTube video those segments were timed against.
  Future<void> deleteRemoteSegmentsForTrack(int trackId) =>
      (delete(sponsorBlockSegments)..where(
        (s) => s.trackId.equals(trackId) & s.source.equals('sponsorblock'),
      )).go();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'woolytube.sqlite'));
    // The app and the hourly background worker open this file through two
    // connections. WAL lets one read while the other writes, and the busy
    // timeout makes a write wait for the other side's transaction instead
    // of failing at once with "database is locked". The backup copy uses
    // VACUUM INTO, which works with WAL.
    return NativeDatabase.createInBackground(
      file,
      setup: (raw) {
        raw.execute('PRAGMA journal_mode=WAL');
        raw.execute('PRAGMA busy_timeout=5000');
        raw.execute('PRAGMA synchronous=NORMAL');
      },
    );
  });
}

/// `unavailableReason` of a track whose download failed because YouTube
/// took the video down for good (copyright claim, guideline violation,
/// terminated account). Shown as "Removed from YouTube".
const removedFromYouTubeReason = 'removed_by_youtube';

/// Track counts of one playlist, see [AppDatabase.watchPlaylistTrackCounts].
class PlaylistCounts {
  const PlaylistCounts({
    required this.total,
    required this.downloaded,
    this.unavailable = 0,
    this.failed = 0,
  });

  /// Every track of the playlist.
  final int total;

  /// Tracks with a downloaded file.
  final int downloaded;

  /// Tracks YouTube no longer provides and that have no file; updates do
  /// not download them.
  final int unavailable;

  /// Tracks whose last download failed; the next update tries them again.
  final int failed;

  /// Tracks that are, or can still be, downloaded.
  int get available => total - unavailable;

  @override
  bool operator ==(Object other) =>
      other is PlaylistCounts &&
      other.total == total &&
      other.downloaded == downloaded &&
      other.unavailable == unavailable &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(total, downloaded, unavailable, failed);

  @override
  String toString() =>
      'PlaylistCounts(total: $total, downloaded: $downloaded, '
      'unavailable: $unavailable, failed: $failed)';
}

/// Element-wise equality of two lists (drift's data classes compare by
/// value), so a stream can skip results identical to the previous one.
bool listsEqual<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapsEqual<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}
