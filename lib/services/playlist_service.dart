import 'dart:io';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'library_gate.dart';
import 'library_layout.dart';
import 'metadata_service.dart';
import 'sponsorblock_service.dart';
import 'media_thumbnail_service.dart' as media_thumbnail_service;
import 'app_settings_service.dart';

class ForceInsertException implements Exception {
  final String message;

  const ForceInsertException(this.message);

  @override
  String toString() => message;
}

/// Thrown when the owner adds a playlist that is already in the library.
class PlaylistExistsException implements Exception {
  final String message;

  const PlaylistExistsException(this.message);

  @override
  String toString() => message;
}

class SyncResult {
  final int added;
  final int markedUnavailable;
  final int markedAvailable;
  final int removed;
  final List<Track> replacementConflicts;

  const SyncResult({
    this.added = 0,
    this.markedUnavailable = 0,
    this.markedAvailable = 0,
    this.removed = 0,
    this.replacementConflicts = const [],
  });

  bool get hasChanges =>
      added + markedUnavailable + markedAvailable + removed > 0;

  bool get hasConflicts => replacementConflicts.isNotEmpty;
}

/// Where a new or switched playlist will live, and the backup found there.
typedef _FolderChoice = ({String path, DiscoveredPlaylist? restore});

class PlaylistService {
  static const forcedInsertVideoIdPrefix =
      media_thumbnail_service.forcedInsertVideoIdPrefix;
  static const allowedAudioExtensions = [
    'm4a',
    'mp3',
    'opus',
    'ogg',
    'flac',
    'wav',
  ];
  static const allowedVideoExtensions = ['mp4', 'mkv', 'webm', 'avi', 'mov'];

  /// Longest folder name created for a playlist, in characters.
  static const _maxFolderNameLength = 120;

  final AppDatabase _db;
  final YtDlpService _ytdlp;
  final MetadataService _metadata;
  final media_thumbnail_service.MediaThumbnailService _thumbnails;
  final AppSettingsService? _settings;
  final LibraryGate _gate;

  PlaylistService(
    this._db,
    this._ytdlp,
    this._metadata, [
    media_thumbnail_service.MediaThumbnailService? thumbnails,
    AppSettingsService? settings,
    LibraryGate? gate,
  ]) : _thumbnails =
           thumbnails ?? const media_thumbnail_service.MediaThumbnailService(),
       _settings = settings,
       _gate = gate ?? LibraryGate.unlocked();

  Stream<List<Playlist>> watchAllPlaylists() => _db.watchAllPlaylists();

  Future<Playlist> getPlaylist(int id) => _db.getPlaylist(id);

  Future<Map<String, dynamic>> fetchPlaylistInfo(String url) async {
    return await _ytdlp.getPlaylistInfo(url);
  }

  /// Adds a playlist and returns its id.
  ///
  /// Every playlist gets a folder of its own. When the folder for this name
  /// already holds a backup of the same playlist (it was deleted from the
  /// app with its files kept, or the app was reinstalled), that backup is
  /// restored instead, so the original order and everything downloaded so
  /// far are kept. A folder that belongs to anything else is never reused.
  Future<int> addPlaylist({
    required String url,
    required String name,
    String? thumbnailUrl,
    bool audioOnly = false,
    bool autoUpdate = true,
    bool playChapters = true,
    int updateFrequencyHours = 24,
    bool includeThumbnails = true,
    bool sponsorBlockEnabled = true,
    List<String> sponsorBlockCategories = defaultSponsorBlockCategories,
    Map<String, SponsorBlockCategoryAction>? sponsorBlockCategoryActions,
  }) async {
    final existing = await _db.getAllPlaylists();
    for (final playlist in existing) {
      if (MetadataService.samePlaylistUrl(playlist.url, url) &&
          playlist.audioOnly == audioOnly) {
        throw PlaylistExistsException(
          '"${playlist.name}" is already in your library.',
        );
      }
    }

    final actions =
        sponsorBlockCategoryActions ?? defaultSponsorBlockCategoryActions();
    final choice = await _chooseFolder(
      audioOnly: audioOnly,
      name: name,
      url: url,
      existing: existing,
    );
    await _settings?.removeDismissedImportUrl(url);

    final restore = choice.restore;
    if (restore != null) {
      final playlistId = await _metadata.importPlaylist(restore);
      await _db.updatePlaylistFields(
        playlistId,
        PlaylistsCompanion(
          autoUpdate: Value(autoUpdate),
          playChapters: Value(playChapters),
          updateFrequencyHours: Value(updateFrequencyHours),
          includeThumbnails: Value(includeThumbnails),
          sponsorBlockEnabled: Value(sponsorBlockEnabled),
          sponsorBlockCategories: Value(
            jsonEncode(autoSkipCategoriesFromActions(actions)),
          ),
          sponsorBlockCategoryActions: Value(
            encodeSponsorBlockCategoryActions(actions),
          ),
        ),
      );
      await _writeMetadata(playlistId);
      return playlistId;
    }

    await Directory(choice.path).create(recursive: true);
    final playlistId = await _db.insertPlaylist(
      PlaylistsCompanion.insert(
        url: url,
        name: name,
        thumbnailUrl: Value(thumbnailUrl),
        audioOnly: Value(audioOnly),
        autoUpdate: Value(autoUpdate),
        playChapters: Value(playChapters),
        updateFrequencyHours: Value(updateFrequencyHours),
        includeThumbnails: Value(includeThumbnails),
        sponsorBlockEnabled: Value(sponsorBlockEnabled),
        sponsorBlockCategories: Value(
          jsonEncode(autoSkipCategoriesFromActions(actions)),
        ),
        sponsorBlockCategoryActions: Value(
          encodeSponsorBlockCategoryActions(actions),
        ),
        createdAt: DateTime.now(),
        outputPath: choice.path,
      ),
    );

    return playlistId;
  }

  /// Picks the folder for a playlist named [name]: `<base>/<name>`, or
  /// `<name> (2)`, `<name> (3)`, ... when that folder belongs to another
  /// playlist or holds media of unknown origin. A folder holding a backup of
  /// this same playlist is returned with that backup.
  Future<_FolderChoice> _chooseFolder({
    required bool audioOnly,
    required String name,
    required String url,
    required List<Playlist> existing,
  }) async {
    final base = LibraryLayout.basePathFor(audioOnly: audioOnly);
    final baseName = folderNameFor(name);
    // Shared storage on Android ignores case, so compare without it.
    final usedFolders = {
      for (final playlist in existing)
        p.normalize(p.absolute(playlist.outputPath)).toLowerCase(),
    };
    for (var n = 1; n < 10000; n++) {
      final folderName = n == 1 ? baseName : '$baseName ($n)';
      final path = p.join(base, folderName);
      if (!LibraryLayout.isPlaylistFolder(path)) continue;
      if (usedFolders.contains(p.normalize(path).toLowerCase())) continue;
      final dir = Directory(path);
      if (!await dir.exists()) return (path: path, restore: null);
      final backup = await _metadata.readFolder(path);
      if (backup != null) {
        if (MetadataService.samePlaylistUrl(backup.url, url) &&
            backup.audioOnly == audioOnly) {
          return (path: path, restore: backup);
        }
        continue;
      }
      if (!await _holdsMedia(dir)) return (path: path, restore: null);
    }
    throw StateError('No free folder name for "$name".');
  }

  static Future<bool> _holdsMedia(Directory dir) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is File &&
            MetadataService.mediaExtensions.contains(
              p.extension(entity.path).toLowerCase(),
            )) {
          return true;
        }
      }
    } on FileSystemException {
      return true;
    }
    return false;
  }

  /// A safe folder name for a playlist titled [name]: characters that are
  /// invalid on common file systems are replaced, leading and trailing dots
  /// and spaces are removed, and an empty result becomes "Playlist". The
  /// name can never point outside the library folder ("", ".", "..").
  static String folderNameFor(String name) {
    var cleaned = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    cleaned = cleaned.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    if (cleaned.length > _maxFolderNameLength) {
      cleaned = cleaned.substring(0, _maxFolderNameLength).trim();
      cleaned = cleaned.replaceAll(RegExp(r'[.\s]+$'), '');
    }
    return cleaned.isEmpty ? 'Playlist' : cleaned;
  }

  Future<void> populateTracksFromInfo(
    int playlistId,
    Map<String, dynamic> playlistInfo,
  ) => _gate.run('playlist update', () async {
    final entries = playlistInfo['entries'] as List<dynamic>? ?? [];
    await _insertNewEntries(
      playlist: await _db.getPlaylist(playlistId),
      entries: entries,
      existingTracks: await _db.getTracksForPlaylist(playlistId),
    );
    await _writeMetadata(playlistId);
  });

  /// Writes only the settings that were passed, so a stale [Playlist] snapshot
  /// in the UI can never overwrite fields changed elsewhere in the meantime.
  ///
  /// Switching between audio-only and video moves the playlist to a new
  /// folder without losing anything: tracks YouTube can no longer provide
  /// (and local files) move their existing file along, every other
  /// downloaded track keeps playing its current file until the new format
  /// has been downloaded.
  Future<void> updatePlaylistSettings({
    required int id,
    String? name,
    bool? audioOnly,
    bool? autoUpdate,
    bool? playChapters,
    int? updateFrequencyHours,
    bool? includeThumbnails,
    bool? sponsorBlockEnabled,
    List<String>? sponsorBlockCategories,
    Map<String, SponsorBlockCategoryAction>? sponsorBlockCategoryActions,
  }) async {
    final playlist = await _db.getPlaylist(id);
    final legacyCategorySet =
        sponsorBlockCategories?.where(isSponsorBlockCategory).toSet();
    final resolvedSponsorBlockActions =
        sponsorBlockCategoryActions ??
        (legacyCategorySet != null
            ? {
              for (final definition in sponsorBlockCategoryDefinitions)
                definition.id:
                    legacyCategorySet.contains(definition.id)
                        ? SponsorBlockCategoryAction.autoSkip
                        : SponsorBlockCategoryAction.disabled,
            }
            : null);

    final fields = PlaylistsCompanion(
      name: name != null ? Value(name) : const Value.absent(),
      autoUpdate: autoUpdate != null ? Value(autoUpdate) : const Value.absent(),
      playChapters:
          playChapters != null ? Value(playChapters) : const Value.absent(),
      updateFrequencyHours:
          updateFrequencyHours != null
              ? Value(updateFrequencyHours)
              : const Value.absent(),
      includeThumbnails:
          includeThumbnails != null
              ? Value(includeThumbnails)
              : const Value.absent(),
      sponsorBlockEnabled:
          sponsorBlockEnabled != null
              ? Value(sponsorBlockEnabled)
              : const Value.absent(),
      sponsorBlockCategories:
          resolvedSponsorBlockActions != null
              ? Value(
                jsonEncode(
                  autoSkipCategoriesFromActions(resolvedSponsorBlockActions),
                ),
              )
              : const Value.absent(),
      sponsorBlockCategoryActions:
          resolvedSponsorBlockActions != null
              ? Value(
                encodeSponsorBlockCategoryActions(resolvedSponsorBlockActions),
              )
              : const Value.absent(),
    );

    if (audioOnly != null && audioOnly != playlist.audioOnly) {
      await _gate.run(
        'format switch',
        () => _switchMode(playlist, audioOnly: audioOnly, fields: fields),
      );
      return;
    }

    await _db.updatePlaylistFields(id, fields);
    await _writeMetadata(id);
  }

  Future<void> _switchMode(
    Playlist playlist, {
    required bool audioOnly,
    required PlaylistsCompanion fields,
  }) async {
    final choice = await _chooseFolder(
      audioOnly: audioOnly,
      // Keep the folder name the playlist already has, so a later rename
      // in the app does not scatter its folders.
      name: p.basename(playlist.outputPath),
      url: '${playlist.url}#switch-${playlist.id}',
      existing: [
        for (final other in await _db.getAllPlaylists())
          if (other.id != playlist.id) other,
      ],
    );
    final oldFolder = playlist.outputPath;
    final newFolder = choice.path;
    await Directory(newFolder).create(recursive: true);

    await _db.updatePlaylistFields(
      playlist.id,
      fields.copyWith(audioOnly: Value(audioOnly), outputPath: Value(newFolder)),
    );
    final switched = await _db.getPlaylist(playlist.id);

    for (final track in await _db.getTracksForPlaylist(playlist.id)) {
      final path = track.filePath;
      if (track.status != 'complete' ||
          path == null ||
          !await File(path).exists()) {
        continue;
      }
      if (!canDownloadAgain(track)) {
        // Nothing better can be downloaded: take the file along.
        await _metadata.adoptKeptFile(switched, track.id);
      } else {
        await _db.setTrackReplaceRequested(track.id, true);
      }
    }

    // The old folder's sidecar would offer the same playlist for import a
    // second time after a reinstall; the new sidecar now describes it.
    final oldSidecar = File(p.join(oldFolder, MetadataService.metaFileName));
    if (await oldSidecar.exists()) {
      try {
        await oldSidecar.rename(
          p.join(oldFolder, '${MetadataService.metaFileName}.superseded'),
        );
      } catch (_) {
        // Import skips folders a playlist already uses.
      }
    }
    await _writeMetadata(playlist.id);
  }

  /// Whether YouTube can still give this track's file again.
  static bool canDownloadAgain(Track track) =>
      !isForcedInsertVideoId(track.videoId) &&
      !track.isLocalReplacement &&
      track.unavailableReason == null;

  /// Full reconciliation: detect new, unavailable, removed, and re-available
  /// tracks.
  ///
  /// Local indices are append-only. An existing track keeps its index even
  /// when YouTube reorders the playlist or removes earlier entries, because
  /// on-disk file prefixes are derived from it. Genuinely new entries are
  /// appended after the current maximum index in remote order.
  ///
  /// Throws a [StateError] when YouTube returns no entries for a playlist that
  /// already has tracks; an empty response is far more likely a transient
  /// fetch problem than a playlist that was really emptied.
  Future<SyncResult> syncPlaylist(Playlist playlist) async {
    final info = await _ytdlp.getPlaylistInfo(playlist.url);
    // Re-read inside the gate: the caller's copy may predate a format
    // switch, and the sync renames files in the current folder.
    return _gate.run(
      'playlist update',
      () async => _applySync(await _db.getPlaylist(playlist.id), info),
    );
  }

  Future<SyncResult> _applySync(
    Playlist playlist,
    Map<String, dynamic> info,
  ) async {
    final freshEntries = info['entries'] as List<dynamic>? ?? [];
    final existingTracks = await _db.getTracksForPlaylist(playlist.id);

    final freshByVideoId = _entriesByVideoId(freshEntries);
    if (freshByVideoId.isEmpty && existingTracks.isNotEmpty) {
      throw StateError(
        'YouTube returned no entries for "${playlist.name}"; the local '
        'playlist was left unchanged.',
      );
    }

    int markedUnavailable = 0, markedAvailable = 0, removed = 0;
    final replacementConflicts = <Track>[];

    // Helper: check if track has a valid file on disk
    bool hasFileOnDisk(Track t) =>
        t.filePath != null && File(t.filePath!).existsSync();

    // Process existing tracks against fresh data
    for (final track in existingTracks) {
      if (isForcedInsertVideoId(track.videoId)) continue;
      final freshEntry = freshByVideoId[track.videoId];

      if (freshEntry == null) {
        // Video removed from playlist entirely
        if (hasFileOnDisk(track)) {
          // File on disk — keep playable, just note removal
          if (track.unavailableReason != 'removed') {
            await _db.updateTrackOnlineStatus(track.id, 'removed');
            removed++;
          }
        } else if (track.status != 'unavailable' ||
            track.unavailableReason != 'removed') {
          await _db.updateTrackUnavailable(track.id, 'removed');
          removed++;
        }
        continue;
      }

      final reason = _detectUnavailability(freshEntry);

      if (reason != null) {
        // Video is unavailable online
        if (hasFileOnDisk(track)) {
          // File on disk — keep playable, just update online status
          if (track.unavailableReason != reason) {
            await _db.updateTrackOnlineStatus(track.id, reason);
          }
        } else if (track.status != 'unavailable') {
          await _db.updateTrackUnavailable(track.id, reason);
          markedUnavailable++;
        }
      } else if (track.unavailableReason != null) {
        // Video is available again (was previously flagged)
        if (hasFileOnDisk(track)) {
          if (track.isLocalReplacement) {
            // Local replacement exists — user needs to decide
            replacementConflicts.add(track);
          }
          // Clear the unavailable reason since video is back
          await _db.updateTrackOnlineStatus(track.id, null);
        } else if (track.status == 'unavailable') {
          await _db.updateTrackAvailable(
            track.id,
            title: freshEntry['title'] as String? ?? 'Unknown',
            thumbnailUrl: freshEntry['thumbnail'] as String?,
            durationSeconds: freshEntry['duration'] as int?,
          );
        } else {
          // Status is pending/error, reason was set informationally
          await _db.updateTrackOnlineStatus(track.id, null);
        }
        markedAvailable++;
      }
    }

    final added = await _insertNewEntries(
      playlist: playlist,
      entries: freshEntries,
      existingTracks: await _db.getTracksForPlaylist(playlist.id),
    );

    await _writeMetadata(playlist.id);
    return SyncResult(
      added: added,
      markedUnavailable: markedUnavailable,
      markedAvailable: markedAvailable,
      removed: removed,
      replacementConflicts: replacementConflicts,
    );
  }

  /// Maps remote entries by video ID. The first occurrence wins when YouTube
  /// lists the same video twice; entries without an ID are ignored.
  static Map<String, Map<String, dynamic>> _entriesByVideoId(
    List<dynamic> entries,
  ) {
    final byVideoId = <String, Map<String, dynamic>>{};
    for (final raw in entries) {
      final entry = raw as Map<String, dynamic>;
      final vid = entry['id'] as String? ?? '';
      if (vid.isEmpty) continue;
      byVideoId.putIfAbsent(vid, () => entry);
    }
    return byVideoId;
  }

  TracksCompanion _companionFor(
    int playlistId,
    int index,
    Map<String, dynamic> entry,
  ) {
    final reason = _detectUnavailability(entry);
    return TracksCompanion.insert(
      playlistId: playlistId,
      index: index,
      videoId: entry['id'] as String,
      title: entry['title'] as String? ?? 'Unknown',
      thumbnailUrl: Value(entry['thumbnail'] as String?),
      durationSeconds: Value(entry['duration'] as int?),
      status: Value(reason != null ? 'unavailable' : 'pending'),
      unavailableReason: Value(reason),
    );
  }

  /// Adds the remote entries that are not in [existingTracks] yet, each at
  /// the place the owner put it on YouTube, and returns how many were added.
  ///
  /// A playlist without tracks takes YouTube's own numbering. Otherwise each
  /// new entry goes right after the nearest entry before it on YouTube that
  /// is already in the app (or right before the first one, when it was added
  /// at the top). Existing tracks never change their order relative to each
  /// other: remote reorders are not mirrored, and tracks YouTube no longer
  /// lists keep their place. A track only moves to a higher number when a
  /// new entry needs its number; its file is renamed to match.
  Future<int> _insertNewEntries({
    required Playlist playlist,
    required List<dynamic> entries,
    required List<Track> existingTracks,
  }) async {
    final remote = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final raw in entries) {
      final entry = raw as Map<String, dynamic>;
      final vid = entry['id'] as String? ?? '';
      if (vid.isEmpty || !seen.add(vid)) continue;
      remote.add(entry);
    }

    if (existingTracks.isEmpty) {
      final used = <int>{};
      var maxIndex = 0;
      final rows = <TracksCompanion>[];
      for (var i = 0; i < remote.length; i++) {
        var index = remote[i]['playlist_index'] as int? ?? (i + 1);
        if (index <= 0 || used.contains(index)) index = maxIndex + 1;
        used.add(index);
        if (index > maxIndex) maxIndex = index;
        rows.add(_companionFor(playlist.id, index, remote[i]));
      }
      if (rows.isNotEmpty) await _db.insertTracks(rows);
      return rows.length;
    }

    final plan = planPlacement(
      existingTracks: existingTracks,
      remoteVideoIds: [for (final e in remote) e['id'] as String],
    );
    if (plan.newIndexByVideoId.isEmpty) return 0;

    final entryById = {for (final e in remote) e['id'] as String: e};
    await _applyRenumbering(
      playlist: playlist,
      tracks: existingTracks,
      newIndexByTrackId: plan.movedIndexByTrackId,
      newTrackCount: existingTracks.length + plan.newIndexByVideoId.length,
      inserts: [
        for (final entry in plan.newIndexByVideoId.entries)
          _companionFor(playlist.id, entry.value, entryById[entry.key]!),
      ],
    );
    return plan.newIndexByVideoId.length;
  }

  /// Works out the order after adding the remote entries that are new.
  ///
  /// Returns the index of every new video and the new index of every
  /// existing track that has to move up to make room. Indices only grow and
  /// stay unique; existing tracks keep their relative order.
  static ({
    Map<String, int> newIndexByVideoId,
    Map<int, int> movedIndexByTrackId,
  })
  planPlacement({
    required List<Track> existingTracks,
    required List<String> remoteVideoIds,
  }) {
    final ordered = [...existingTracks]
      ..sort((a, b) => a.index.compareTo(b.index));
    // The local order, as track ids (existing) or video ids (new).
    final slots = <Object>[for (final t in ordered) t.id];
    final videoOfTrack = {for (final t in ordered) t.id: t.videoId};
    final positionOfVideo = <String, int>{};
    void reindex() {
      positionOfVideo.clear();
      for (var i = 0; i < slots.length; i++) {
        final slot = slots[i];
        positionOfVideo[slot is int ? videoOfTrack[slot]! : slot as String] =
            i;
      }
    }

    reindex();
    final existingIds = {for (final t in ordered) t.videoId};
    final newIds = <String>{};
    int? cursor;
    for (var i = 0; i < remoteVideoIds.length; i++) {
      final vid = remoteVideoIds[i];
      if (existingIds.contains(vid) || newIds.contains(vid)) {
        cursor = positionOfVideo[vid];
        continue;
      }
      int insertAt;
      if (cursor != null) {
        insertAt = cursor + 1;
      } else {
        // Added above everything the app has: go right before the first
        // later entry the app already has, or at the end if there is none.
        insertAt = slots.length;
        for (var j = i + 1; j < remoteVideoIds.length; j++) {
          final next = remoteVideoIds[j];
          if (existingIds.contains(next)) {
            insertAt = positionOfVideo[next]!;
            break;
          }
        }
      }
      slots.insert(insertAt, vid);
      newIds.add(vid);
      reindex();
      cursor = insertAt;
    }

    final byId = {for (final t in ordered) t.id: t};
    final newIndexByVideoId = <String, int>{};
    final moved = <int, int>{};
    var last = 0;
    for (final slot in slots) {
      if (slot is int) {
        final track = byId[slot]!;
        final index = track.index > last ? track.index : last + 1;
        if (index != track.index) moved[track.id] = index;
        last = index;
      } else {
        last = last + 1;
        newIndexByVideoId[slot as String] = last;
      }
    }
    return (newIndexByVideoId: newIndexByVideoId, movedIndexByTrackId: moved);
  }

  /// Moves existing tracks to new (higher) indices, renaming their files to
  /// the new number, then inserts [inserts].
  ///
  /// Crash safety matches [forceInsert]: files are renamed from the highest
  /// index down, each straight to its final name, with the track's recorded
  /// path updated just before its file moves. Indices change in one
  /// transaction at the end. If the app dies part-way, every track still
  /// finds its file, the next repair puts the names back in line with the
  /// unchanged indices, and the next update simply tries again.
  Future<void> _applyRenumbering({
    required Playlist playlist,
    required List<Track> tracks,
    required Map<int, int> newIndexByTrackId,
    required int newTrackCount,
    required List<TracksCompanion> inserts,
  }) async {
    final folder = playlist.outputPath;
    final moving =
        tracks.where((t) => newIndexByTrackId.containsKey(t.id)).toList()
          ..sort((a, b) => b.index.compareTo(a.index));
    final prefixPattern = RegExp(r'^\d+_');
    for (final track in moving) {
      final path = track.filePath;
      if (path == null || !p.equals(p.dirname(path), folder)) continue;
      if (!await File(path).exists()) continue;
      final rest = p.basename(path).replaceFirst(prefixPattern, '');
      final target = p.join(
        folder,
        '${MetadataService.paddedIndex(newIndexByTrackId[track.id]!, newTrackCount)}_$rest',
      );
      if (p.equals(path, target) || await File(target).exists()) continue;
      await _db.updateTrackFields(track.id, filePath: target);
      try {
        await File(path).rename(target);
      } catch (_) {
        await _db.updateTrackFields(track.id, filePath: path);
      }
    }

    await _db.transaction(() async {
      for (final track in moving) {
        await _db.updateTrackPlacement(
          track.id,
          index: newIndexByTrackId[track.id]!,
        );
      }
      if (inserts.isNotEmpty) await _db.insertTracks(inserts);
    });
  }

  /// Removes the playlist and its tracks from the database.
  ///
  /// With [deleteFiles], this playlist's own files are deleted: the media
  /// and covers its tracks use, its sidecar, playlist file and helper
  /// folders. The folder itself is removed only when nothing else is left
  /// in it, and only if it is a playlist folder inside the library. Files
  /// that another playlist uses are never touched.
  ///
  /// Otherwise the folder's metadata is remembered as dismissed so it is not
  /// offered for import again on the next launch.
  Future<void> deletePlaylist(int id, {bool deleteFiles = false}) async {
    if (!deleteFiles) {
      final playlist = await _db.getPlaylist(id);
      await _db.deletePlaylist(id);
      await _settings?.addDismissedImportUrls([playlist.url]);
      return;
    }
    await _gate.run('playlist deletion', () async {
      final playlist = await _db.getPlaylist(id);
      final tracks = await _db.getTracksForPlaylist(id);
      final others = [
        for (final other in await _db.getAllPlaylists())
          if (other.id != id) other,
      ];
      final otherFiles = <String>{};
      for (final other in others) {
        for (final track in await _db.getTracksForPlaylist(other.id)) {
          if (track.filePath != null) {
            otherFiles.add(p.normalize(track.filePath!));
          }
          if (track.thumbnailPath != null) {
            otherFiles.add(p.normalize(track.thumbnailPath!));
          }
        }
      }
      await _db.deletePlaylist(id);

      final folder = playlist.outputPath;
      for (final track in tracks) {
        for (final path in [track.filePath, track.thumbnailPath]) {
          if (path == null || otherFiles.contains(p.normalize(path))) continue;
          if (!p.isWithin(folder, path)) continue;
          try {
            final file = File(path);
            if (await file.exists()) await file.delete();
          } catch (_) {
            // Keep going; a leftover file is harmless.
          }
        }
      }

      final sharedFolder =
          !LibraryLayout.isPlaylistFolder(folder) ||
          others.any((other) => p.equals(other.outputPath, folder));
      if (sharedFolder) return;

      for (final name in [
        MetadataService.metaFileName,
        p.basename(MetadataService.playlistFilePath(folder)),
      ]) {
        try {
          final file = File(p.join(folder, name));
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      for (final dirPath in [
        LibraryLayout.thumbnailsDir(folder),
        LibraryLayout.infoDir(folder),
        LibraryLayout.stagingRoot(folder),
        LibraryLayout.replacedDir(folder),
      ]) {
        try {
          final dir = Directory(dirPath);
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      }
      try {
        final dir = Directory(folder);
        if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
      } catch (_) {
        // Something else is in the folder; it stays.
      }
    });
  }

  /// Asks for the YouTube original of a local replacement. The replacement
  /// keeps playing until the original is completely downloaded by the next
  /// update; if YouTube cannot provide it, the replacement stays.
  Future<void> requestOriginalDownload(Track track) async {
    await _db.setTrackReplaceRequested(track.id, true);
    await _writeMetadata(track.playlistId);
  }

  /// Changes a track's title and/or the title part of its file name. The
  /// number prefix and extension stay. Returns whether anything changed.
  Future<bool> overrideTrack({
    required int trackId,
    String? title,
    String? fileName,
  }) => _gate.run('rename', () async {
    final track = await _db.getTrack(trackId);
    if (track == null) throw StateError('The track no longer exists.');
    final newTitle = title?.trim();
    final titleChanged =
        newTitle != null && newTitle.isNotEmpty && newTitle != track.title;

    String? newPath;
    final current = track.filePath;
    final wanted = fileName?.trim();
    if (current != null &&
        wanted != null &&
        wanted.isNotEmpty &&
        await File(current).exists()) {
      final name = p.basename(current);
      final prefix = RegExp(r'^\d+_').firstMatch(name)?.group(0) ?? '';
      final candidate = p.join(
        p.dirname(current),
        '$prefix${MetadataService.sanitizeFilename(wanted)}'
        '${p.extension(current)}',
      );
      if (!p.equals(candidate, current)) {
        if (await File(candidate).exists()) {
          throw StateError('A file with that name already exists');
        }
        await File(current).rename(candidate);
        newPath = candidate;
      }
    }

    if (!titleChanged && newPath == null) return false;
    await _db.updateTrackFields(
      trackId,
      title: titleChanged ? newTitle : null,
      filePath: newPath,
    );
    await _writeMetadata(track.playlistId);
    return true;
  });

  Future<List<Track>> getPendingTracks(int playlistId) =>
      _db.getPendingTracks(playlistId);

  Future<List<Track>> getAllTracks() => _db.getAllTracks();

  Stream<List<Track>> watchAllTracks() => _db.watchAllTracks();

  Future<List<Track>> getTracksForPlaylist(int playlistId) =>
      _db.getTracksForPlaylist(playlistId);

  Stream<List<Track>> watchTracksForPlaylist(int playlistId) =>
      _db.watchTracksForPlaylist(playlistId);

  Future<int> getDownloadedCount(int playlistId) =>
      _db.getDownloadedTrackCount(playlistId);

  Future<int> getTotalCount(int playlistId) =>
      _db.getTotalTrackCount(playlistId);

  static bool isForcedInsertVideoId(String videoId) =>
      videoId.startsWith(forcedInsertVideoIdPrefix);

  /// Inserts a user-supplied local file at an exact archive position.
  ///
  /// Later entries and their on-disk filename prefixes move forward together.
  /// The synthetic video ID keeps this local-only entry out of remote YouTube
  /// reconciliation while still preserving it in the metadata sidecar.
  ///
  /// Crash safety: files are renamed one at a time from the highest number
  /// down, each straight to its final name, and each track's recorded file
  /// path is updated just before its file moves. If the app dies part-way,
  /// every track still finds its own file (by its recorded path, or by its
  /// unchanged index for the one file in flight), and the next repair puts
  /// the number prefixes back in line with the indices.
  Future<Track> forceInsert({
    required int playlistId,
    required int index,
    required String sourcePath,
    String? sourceFileName,
  }) async {
    try {
      return await _gate.run(
        'force insert',
        () => _forceInsert(
          playlistId: playlistId,
          index: index,
          sourcePath: sourcePath,
          sourceFileName: sourceFileName,
        ),
      );
    } on LibraryBusyException catch (e) {
      throw ForceInsertException(e.message);
    }
  }

  Future<Track> _forceInsert({
    required int playlistId,
    required int index,
    required String sourcePath,
    String? sourceFileName,
  }) async {
    final playlist = await _db.getPlaylist(playlistId);
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const ForceInsertException('The selected file no longer exists.');
    }

    final pickedName =
        sourceFileName == null || sourceFileName.trim().isEmpty
            ? p.basename(sourcePath)
            : p.basename(sourceFileName.trim());
    final extension = p.extension(pickedName).toLowerCase();
    final extensionWithoutDot =
        extension.startsWith('.') ? extension.substring(1) : extension;
    final allowedExtensions =
        playlist.audioOnly ? allowedAudioExtensions : allowedVideoExtensions;
    if (!allowedExtensions.contains(extensionWithoutDot)) {
      final expected = playlist.audioOnly ? 'audio' : 'video';
      throw ForceInsertException(
        'Select a supported $expected file (${allowedExtensions.join(', ')}).',
      );
    }

    final outputDirectory = Directory(playlist.outputPath);
    await outputDirectory.create(recursive: true);
    final operationId = DateTime.now().microsecondsSinceEpoch.toString();

    // Copy first, into a working folder the cleanup never mistakes for a
    // finished track, and only then look at the playlist.
    final staging = Directory(
      p.join(LibraryLayout.stagingRoot(playlist.outputPath), 'insert-$operationId'),
    );
    await staging.create(recursive: true);
    final stagedSource = File(p.join(staging.path, 'source$extension'));
    try {
      await source.copy(stagedSource.path);
    } catch (error) {
      await _deleteQuietly(staging);
      throw ForceInsertException('Could not copy the selected file: $error');
    }

    final tracks = await _db.getTracksForPlaylist(playlistId);
    var highestIndex = 0;
    for (final track in tracks) {
      if (track.index > highestIndex) highestIndex = track.index;
    }
    final maximumIndex = tracks.isEmpty ? 1 : highestIndex + 1;
    if (index < 1 || index > maximumIndex) {
      await _deleteQuietly(staging);
      throw ForceInsertException('Index must be between 1 and $maximumIndex.');
    }

    final title = p.basenameWithoutExtension(pickedName).trim();
    final resolvedTitle = title.isEmpty ? 'Local file' : title;
    final safeTitle = MetadataService.sanitizeFilename(resolvedTitle);
    final newTrackCount = tracks.length + 1;
    final indexPrefix = MetadataService.paddedIndex(index, newTrackCount);
    final destinationPath = p.join(
      outputDirectory.path,
      '${indexPrefix}_$safeTitle$extension',
    );

    // Plan the renames, highest index first, each to its final name.
    final prefixPattern = RegExp(r'^\d+_(.*)$');
    final moves = <({Track track, String from, String to})>[];
    for (final track in tracks.reversed) {
      final oldPath = track.filePath;
      if (oldPath == null || !await File(oldPath).exists()) continue;
      if (!p.equals(p.dirname(oldPath), outputDirectory.path)) continue;
      final newIndex = track.index >= index ? track.index + 1 : track.index;
      final oldName = p.basename(oldPath);
      final nameWithoutPrefix =
          prefixPattern.firstMatch(oldName)?.group(1) ?? oldName;
      final newPrefix = MetadataService.paddedIndex(newIndex, newTrackCount);
      final targetPath = p.join(
        outputDirectory.path,
        '${newPrefix}_$nameWithoutPrefix',
      );
      if (p.equals(oldPath, targetPath)) continue;
      moves.add((track: track, from: oldPath, to: targetPath));
    }
    try {
      _validateForcedInsertTargets(moves, destinationPath);
    } catch (_) {
      await _deleteQuietly(staging);
      rethrow;
    }

    final done = <({Track track, String from, String to})>[];
    try {
      for (final move in moves) {
        if (await File(move.to).exists()) {
          throw ForceInsertException(
            'Cannot move ${p.basename(move.from)} because '
            '${p.basename(move.to)} already exists.',
          );
        }
        await _db.updateTrackFields(move.track.id, filePath: move.to);
        try {
          await File(move.from).rename(move.to);
        } catch (_) {
          await _db.updateTrackFields(move.track.id, filePath: move.from);
          rethrow;
        }
        done.add(move);
      }
      if (await File(destinationPath).exists()) {
        throw const ForceInsertException(
          'A file already occupies the requested index in this playlist.',
        );
      }
      await stagedSource.rename(destinationPath);
    } catch (error) {
      // Undo in reverse order; every step is a plain rename back.
      for (final move in done.reversed) {
        try {
          await File(move.to).rename(move.from);
          await _db.updateTrackFields(move.track.id, filePath: move.from);
        } catch (_) {
          // The file keeps its new name and its recorded path matches it.
        }
      }
      await _deleteQuietly(staging);
      if (error is ForceInsertException) rethrow;
      throw ForceInsertException('Could not insert the selected file: $error');
    }
    await _deleteQuietly(staging);

    late final int insertedTrackId;
    await _db.transaction(() async {
      // Shift from the highest index down so the unique (playlist, index)
      // constraint is never violated part-way through.
      for (final track in tracks.reversed) {
        if (track.index >= index) {
          await _db.updateTrackPlacement(track.id, index: track.index + 1);
        }
      }

      insertedTrackId = await _db.insertTrack(
        TracksCompanion.insert(
          playlistId: playlistId,
          index: index,
          videoId: '$forcedInsertVideoIdPrefix$operationId',
          title: resolvedTitle,
          filePath: Value(destinationPath),
          status: const Value('complete'),
          isLocalReplacement: const Value(true),
          downloadedAt: Value(DateTime.now()),
          // A local file has no SponsorBlock timeline to fetch.
          sponsorBlockCheckedAt: Value(DateTime.now()),
        ),
      );
    });

    final inserted = await _db.getTrack(insertedTrackId);
    if (inserted == null) {
      throw const ForceInsertException(
        'The inserted track could not be loaded.',
      );
    }
    await _refreshEmbeddedThumbnail(
      playlist: playlist,
      track: inserted,
      mediaPath: destinationPath,
    );
    await _writeMetadata(playlistId);
    return (await _db.getTrack(insertedTrackId))!;
  }

  /// Copies a user-selected file over a playlist entry and records any cover
  /// art embedded in that file as the track's local thumbnail. The previous
  /// file is not deleted: it is moved to `.woolytube_replaced/` in the
  /// playlist folder.
  Future<Track> replaceWithLocalFile({
    required int trackId,
    required String sourcePath,
    required String sourceFileName,
  }) => _gate.run(
    'replacement',
    () => _replaceWithLocalFile(
      trackId: trackId,
      sourcePath: sourcePath,
      sourceFileName: sourceFileName,
    ),
  );

  Future<Track> _replaceWithLocalFile({
    required int trackId,
    required String sourcePath,
    required String sourceFileName,
  }) async {
    final track = await _db.getTrack(trackId);
    if (track == null) throw StateError('The selected track no longer exists.');
    final playlist = await _db.getPlaylist(track.playlistId);
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw StateError('The selected file no longer exists.');
    }

    final pickedName = p.basename(sourceFileName.trim());
    final extension = p.extension(pickedName).toLowerCase();
    final extensionWithoutDot =
        extension.startsWith('.') ? extension.substring(1) : extension;
    if (!allowedAudioExtensions.contains(extensionWithoutDot) &&
        !allowedVideoExtensions.contains(extensionWithoutDot)) {
      throw StateError('Select a supported audio or video file.');
    }

    final totalTracks = await _db.getTotalTrackCount(playlist.id);
    final indexPrefix = MetadataService.paddedIndex(track.index, totalTracks);
    final baseName = p.basenameWithoutExtension(pickedName);
    final safeName = MetadataService.sanitizeFilename(baseName);
    final destinationPath = p.join(
      playlist.outputPath,
      '${indexPrefix}_$safeName$extension',
    );
    final operationId = DateTime.now().microsecondsSinceEpoch;
    final staging = Directory(
      p.join(LibraryLayout.stagingRoot(playlist.outputPath), 'replace-$operationId'),
    );
    final stagedFile = File(p.join(staging.path, 'source$extension'));

    await Directory(playlist.outputPath).create(recursive: true);
    String? previousPath;
    String? previousKeptAt;
    try {
      await staging.create(recursive: true);
      await source.copy(stagedFile.path);

      final current = track.filePath;
      if (current != null && await File(current).exists()) {
        previousPath = current;
        previousKeptAt = await _metadata.moveAside(playlist.outputPath, current);
      }
      if (await File(destinationPath).exists()) {
        // Some other file already has this name; keep it as well.
        await _metadata.moveAside(playlist.outputPath, destinationPath);
      }
      await stagedFile.rename(destinationPath);
    } catch (_) {
      if (previousKeptAt != null && previousPath != null) {
        try {
          await MetadataService.moveFile(previousKeptAt, previousPath);
        } catch (_) {
          // It is still safe in the replaced folder.
        }
      }
      await _deleteQuietly(staging);
      rethrow;
    }
    await _deleteQuietly(staging);

    await _db.invalidateTrackChapters(track.id);
    await _db.updateTrackStatus(
      track.id,
      'complete',
      filePath: destinationPath,
      isLocalReplacement: true,
    );
    await _db.setTrackReplaceRequested(track.id, false);
    // Remote segments were timed against the YouTube video, not this file.
    await _db.deleteRemoteSegmentsForTrack(track.id);
    await _db.updateTrackSponsorBlockCheckedAt(track.id, DateTime.now());
    final replaced = await _db.getTrack(track.id);
    if (replaced != null) {
      await _refreshEmbeddedThumbnail(
        playlist: playlist,
        track: replaced,
        mediaPath: destinationPath,
      );
    }
    await _writeMetadata(playlist.id);

    final updated = await _db.getTrack(track.id);
    if (updated == null) {
      throw StateError('The replacement could not be loaded.');
    }
    return updated;
  }

  /// Extracts artwork for local files created before thumbnail extraction was
  /// added. This is intentionally limited to user-supplied replacements.
  Future<int> backfillLocalThumbnails(int playlistId) async {
    final playlist = await _db.getPlaylist(playlistId);
    final tracks = await _db.getTracksForPlaylist(playlistId);
    var extracted = 0;
    for (final track in tracks) {
      if (!track.isLocalReplacement ||
          track.filePath == null ||
          !await File(track.filePath!).exists() ||
          media_thumbnail_service.existingThumbnailPath(track.thumbnailPath) !=
              null) {
        continue;
      }
      final path = await _refreshEmbeddedThumbnail(
        playlist: playlist,
        track: track,
        mediaPath: track.filePath!,
      );
      if (path != null) extracted++;
    }
    if (extracted > 0) await _writeMetadata(playlistId);
    return extracted;
  }

  Future<String?> _refreshEmbeddedThumbnail({
    required Playlist playlist,
    required Track track,
    required String mediaPath,
  }) async {
    try {
      final stem = LibraryLayout.trackThumbnailStem(
        playlist.outputPath,
        track.videoId,
        localFile: true,
      );
      await Directory(p.dirname(stem)).create(recursive: true);
      final thumbnailPath = await _thumbnails.extractEmbeddedThumbnail(
        mediaPath: mediaPath,
        targetStem: stem,
      );
      await _db.updateTrackThumbnailPath(track.id, thumbnailPath);
      return thumbnailPath;
    } catch (_) {
      // Artwork is optional; a local media operation must still succeed.
      return null;
    }
  }

  void _validateForcedInsertTargets(
    List<({Track track, String from, String to})> moves,
    String destinationPath,
  ) {
    final originalPaths = moves.map((move) => move.from).toSet();
    if (File(destinationPath).existsSync() &&
        !originalPaths.contains(destinationPath)) {
      throw const ForceInsertException(
        'A file already occupies the requested index in this playlist.',
      );
    }
    final targetPaths = <String>{destinationPath};
    for (final move in moves) {
      if (!targetPaths.add(move.to)) {
        throw const ForceInsertException(
          'Existing playlist files have conflicting index prefixes.',
        );
      }
      if (File(move.to).existsSync() && !originalPaths.contains(move.to)) {
        throw ForceInsertException(
          'Cannot move ${p.basename(move.from)} because '
          '${p.basename(move.to)} already exists.',
        );
      }
    }
  }

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Removed with the staging folder later.
    }
  }

  Future<void> _writeMetadata(int playlistId) async {
    try {
      final playlist = await _db.getPlaylist(playlistId);
      final tracks = await _db.getTracksForPlaylist(playlistId);
      await _metadata.writeMetadata(playlist, tracks);
    } catch (_) {
      // Non-critical — don't block playlist operations
    }
  }

  /// Returns the unavailability reason, or null if the video is available.
  String? _detectUnavailability(Map<String, dynamic> entry) {
    final availability = entry['availability'] as String? ?? '';
    if (availability == 'private') return 'private';
    if (availability == 'needs_auth') return 'needs_auth';
    if (availability == 'premium_only') return 'premium_only';
    if (availability == 'subscriber_only') return 'subscriber_only';
    if (availability == 'unavailable') return 'unavailable';

    final title = entry['title'] as String? ?? '';
    if (title == '[Private video]') return 'private';
    if (title == '[Deleted video]') return 'deleted';
    if (title == '[Unavailable]') return 'unavailable';

    return null;
  }
}
