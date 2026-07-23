import 'dart:io';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'metadata_service.dart';
import 'sponsorblock_service.dart';

class ForceInsertException implements Exception {
  final String message;

  const ForceInsertException(this.message);

  @override
  String toString() => message;
}

class _ForcedInsertFileMove {
  final int trackId;
  final String originalPath;
  final String temporaryPath;
  final String targetPath;
  String currentPath;

  _ForcedInsertFileMove({
    required this.trackId,
    required this.originalPath,
    required this.temporaryPath,
    required this.targetPath,
  }) : currentPath = originalPath;
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

class PlaylistService {
  static const forcedInsertVideoIdPrefix = 'force-insert:';
  static const allowedAudioExtensions = [
    'm4a',
    'mp3',
    'opus',
    'ogg',
    'flac',
    'wav',
  ];
  static const allowedVideoExtensions = ['mp4', 'mkv', 'webm', 'avi', 'mov'];

  final AppDatabase _db;
  final YtDlpService _ytdlp;
  final MetadataService _metadata;

  PlaylistService(this._db, this._ytdlp, this._metadata);

  Stream<List<Playlist>> watchAllPlaylists() => _db.watchAllPlaylists();

  Future<Playlist> getPlaylist(int id) => _db.getPlaylist(id);

  Future<Map<String, dynamic>> fetchPlaylistInfo(String url) async {
    return await _ytdlp.getPlaylistInfo(url);
  }

  Future<int> addPlaylist({
    required String url,
    required String name,
    String? thumbnailUrl,
    bool audioOnly = false,
    bool autoUpdate = true,
    int updateFrequencyHours = 24,
    bool includeThumbnails = true,
    bool sponsorBlockEnabled = true,
    List<String> sponsorBlockCategories = defaultSponsorBlockCategories,
    Map<String, SponsorBlockCategoryAction>? sponsorBlockCategoryActions,
  }) async {
    final actions =
        sponsorBlockCategoryActions ?? defaultSponsorBlockCategoryActions();
    final basePath =
        audioOnly
            ? '/storage/emulated/0/Music/WoolyTube'
            : '/storage/emulated/0/Movies/WoolyTube';
    final sanitizedName = _sanitizeFolderName(name);
    final outputPath = '$basePath/$sanitizedName';

    await Directory(outputPath).create(recursive: true);

    final playlistId = await _db.insertPlaylist(
      PlaylistsCompanion.insert(
        url: url,
        name: name,
        thumbnailUrl: Value(thumbnailUrl),
        audioOnly: Value(audioOnly),
        autoUpdate: Value(autoUpdate),
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
        outputPath: outputPath,
      ),
    );

    return playlistId;
  }

  Future<void> populateTracksFromInfo(
    int playlistId,
    Map<String, dynamic> playlistInfo,
  ) async {
    final entries = playlistInfo['entries'] as List<dynamic>? ?? [];
    final tracks = <TracksCompanion>[];

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i] as Map<String, dynamic>;
      final videoId = entry['id'] as String? ?? '';
      if (videoId.isEmpty) continue;

      final playlistIndex = entry['playlist_index'] as int? ?? (i + 1);
      final reason = _detectUnavailability(entry);

      tracks.add(
        TracksCompanion.insert(
          playlistId: playlistId,
          index: playlistIndex,
          videoId: videoId,
          title: entry['title'] as String? ?? 'Unknown',
          thumbnailUrl: Value(entry['thumbnail'] as String?),
          durationSeconds: Value(entry['duration'] as int?),
          status: Value(reason != null ? 'unavailable' : 'pending'),
          unavailableReason: Value(reason),
        ),
      );
    }

    if (tracks.isNotEmpty) {
      await _db.insertTracks(tracks);
    }

    await _writeMetadata(playlistId);
  }

  Future<void> updatePlaylistSettings({
    required int id,
    String? name,
    bool? audioOnly,
    bool? autoUpdate,
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

    String outputPath = playlist.outputPath;
    if (audioOnly != null && audioOnly != playlist.audioOnly) {
      final basePath =
          audioOnly
              ? '/storage/emulated/0/Music/WoolyTube'
              : '/storage/emulated/0/Movies/WoolyTube';
      final folderName = _sanitizeFolderName(name ?? playlist.name);
      outputPath = '$basePath/$folderName';
      await Directory(outputPath).create(recursive: true);
    }

    await _db.updatePlaylist(
      PlaylistsCompanion(
        id: Value(id),
        url: Value(playlist.url),
        name: Value(name ?? playlist.name),
        thumbnailUrl: Value(playlist.thumbnailUrl),
        thumbnailPath: Value(playlist.thumbnailPath),
        audioOnly: Value(audioOnly ?? playlist.audioOnly),
        autoUpdate: Value(autoUpdate ?? playlist.autoUpdate),
        updateFrequencyHours: Value(
          updateFrequencyHours ?? playlist.updateFrequencyHours,
        ),
        includeThumbnails: Value(
          includeThumbnails ?? playlist.includeThumbnails,
        ),
        sponsorBlockEnabled: Value(
          sponsorBlockEnabled ?? playlist.sponsorBlockEnabled,
        ),
        sponsorBlockCategories: Value(
          resolvedSponsorBlockActions != null
              ? jsonEncode(
                autoSkipCategoriesFromActions(resolvedSponsorBlockActions),
              )
              : playlist.sponsorBlockCategories,
        ),
        sponsorBlockCategoryActions: Value(
          resolvedSponsorBlockActions != null
              ? encodeSponsorBlockCategoryActions(resolvedSponsorBlockActions)
              : playlist.sponsorBlockCategoryActions,
        ),
        lastUpdated: Value(playlist.lastUpdated),
        createdAt: Value(playlist.createdAt),
        outputPath: Value(outputPath),
      ),
    );

    await _writeMetadata(id);
  }

  /// Full reconciliation: detect new, unavailable, removed, and re-available tracks.
  Future<SyncResult> syncPlaylist(Playlist playlist) async {
    final info = await _ytdlp.getPlaylistInfo(playlist.url);
    final freshEntries = info['entries'] as List<dynamic>? ?? [];
    final existingTracks = await _db.getTracksForPlaylist(playlist.id);
    final forcedInsertIndices =
        existingTracks
            .where((track) => isForcedInsertVideoId(track.videoId))
            .map((track) => track.index)
            .toList()
          ..sort();

    final existingByVideoId = <String, Track>{};
    for (final t in existingTracks) {
      existingByVideoId[t.videoId] = t;
    }

    final freshByVideoId = <String, Map<String, dynamic>>{};
    final freshIndexByVideoId = <String, int>{};
    for (var i = 0; i < freshEntries.length; i++) {
      final entry = freshEntries[i] as Map<String, dynamic>;
      final vid = entry['id'] as String? ?? '';
      if (vid.isNotEmpty) {
        freshByVideoId[vid] = entry;
        final remoteIndex = entry['playlist_index'] as int? ?? (i + 1);
        freshIndexByVideoId[vid] = _remoteToLocalIndex(
          remoteIndex,
          forcedInsertIndices,
        );
      }
    }

    int added = 0, markedUnavailable = 0, markedAvailable = 0, removed = 0;
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
      final freshIndex = freshIndexByVideoId[track.videoId] ?? track.index;

      if (reason != null) {
        // Video is unavailable online
        if (hasFileOnDisk(track)) {
          // File on disk — keep playable, just update online status
          if (track.unavailableReason != reason) {
            await _db.updateTrackOnlineStatus(track.id, reason);
          }
          // Don't change index for tracks with files
        } else if (track.status != 'unavailable') {
          await _db.updateTrackUnavailable(
            track.id,
            reason,
            newIndex: freshIndex,
          );
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
            newIndex: freshIndex,
          );
        } else {
          // Status is pending/error, reason was set informationally
          await _db.updateTrackOnlineStatus(track.id, null);
        }
        markedAvailable++;
      } else if (freshIndex != track.index && track.status != 'complete') {
        // Index changed and track not yet downloaded — safe to update
        await _db.updateTrackIndex(track.id, freshIndex);
      }
    }

    // Add genuinely new tracks
    final newTracks = <TracksCompanion>[];
    for (var i = 0; i < freshEntries.length; i++) {
      final entry = freshEntries[i] as Map<String, dynamic>;
      final vid = entry['id'] as String? ?? '';
      if (vid.isEmpty || existingByVideoId.containsKey(vid)) continue;

      final reason = _detectUnavailability(entry);
      final remoteIndex = entry['playlist_index'] as int? ?? (i + 1);
      final playlistIndex = _remoteToLocalIndex(
        remoteIndex,
        forcedInsertIndices,
      );
      newTracks.add(
        TracksCompanion.insert(
          playlistId: playlist.id,
          index: playlistIndex,
          videoId: vid,
          title: entry['title'] as String? ?? 'Unknown',
          thumbnailUrl: Value(entry['thumbnail'] as String?),
          durationSeconds: Value(entry['duration'] as int?),
          status: Value(reason != null ? 'unavailable' : 'pending'),
          unavailableReason: Value(reason),
        ),
      );
      added++;
    }

    if (newTracks.isNotEmpty) {
      await _db.insertTracks(newTracks);
    }

    await _writeMetadata(playlist.id);
    return SyncResult(
      added: added,
      markedUnavailable: markedUnavailable,
      markedAvailable: markedAvailable,
      removed: removed,
      replacementConflicts: replacementConflicts,
    );
  }

  Future<void> deletePlaylist(int id) async {
    await _db.deletePlaylist(id);
  }

  Future<List<Track>> getPendingTracks(int playlistId) =>
      _db.getPendingTracks(playlistId);

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

  static int _remoteToLocalIndex(
    int remoteIndex,
    List<int> forcedInsertIndices,
  ) {
    var localIndex = remoteIndex;
    for (final forcedIndex in forcedInsertIndices) {
      if (forcedIndex <= localIndex) localIndex++;
    }
    return localIndex;
  }

  /// Inserts a user-supplied local file at an exact archive position.
  ///
  /// Later entries and their on-disk filename prefixes move forward together.
  /// The synthetic video ID keeps this local-only entry out of remote YouTube
  /// reconciliation while still preserving it in the metadata sidecar.
  Future<Track> forceInsert({
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

    final tracks = await _db.getTracksForPlaylist(playlistId);
    var highestIndex = 0;
    for (final track in tracks) {
      if (track.index > highestIndex) highestIndex = track.index;
    }
    final maximumIndex = tracks.isEmpty ? 1 : highestIndex + 1;
    if (index < 1 || index > maximumIndex) {
      throw ForceInsertException('Index must be between 1 and $maximumIndex.');
    }

    final outputDirectory = Directory(playlist.outputPath);
    await outputDirectory.create(recursive: true);

    final title = p.basenameWithoutExtension(pickedName).trim();
    final resolvedTitle = title.isEmpty ? 'Local file' : title;
    final safeTitle = MetadataService.sanitizeFilename(resolvedTitle);
    final newTrackCount = tracks.length + 1;
    final indexPrefix = MetadataService.paddedIndex(index, newTrackCount);
    final destinationPath = p.join(
      outputDirectory.path,
      '${indexPrefix}_$safeTitle$extension',
    );
    final operationId = DateTime.now().microsecondsSinceEpoch.toString();
    final stagedSourcePath = p.join(
      outputDirectory.path,
      '.woolytube-force-insert-$operationId$extension',
    );
    final stagedSource = File(stagedSourcePath);
    final moves = <_ForcedInsertFileMove>[];
    final prefixPattern = RegExp(r'^\d+_(.*)$');

    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      final oldPath = track.filePath;
      if (oldPath == null || !await File(oldPath).exists()) continue;

      final newIndex = track.index >= index ? track.index + 1 : track.index;
      final oldName = p.basename(oldPath);
      final prefixMatch = prefixPattern.firstMatch(oldName);
      final nameWithoutPrefix = prefixMatch?.group(1) ?? oldName;
      final newPrefix = MetadataService.paddedIndex(newIndex, newTrackCount);
      final targetPath = p.join(
        outputDirectory.path,
        '${newPrefix}_$nameWithoutPrefix',
      );
      if (p.equals(oldPath, targetPath)) continue;

      moves.add(
        _ForcedInsertFileMove(
          trackId: track.id,
          originalPath: oldPath,
          temporaryPath: p.join(
            outputDirectory.path,
            '.woolytube-force-move-$operationId-$i${p.extension(oldPath)}',
          ),
          targetPath: targetPath,
        ),
      );
    }

    late final int insertedTrackId;
    var insertedFilePlaced = false;
    try {
      await source.copy(stagedSourcePath);
      _validateForcedInsertTargets(moves, destinationPath);

      for (final move in moves) {
        await File(move.currentPath).rename(move.temporaryPath);
        move.currentPath = move.temporaryPath;
      }
      for (final move in moves) {
        await File(move.currentPath).rename(move.targetPath);
        move.currentPath = move.targetPath;
      }
      await stagedSource.rename(destinationPath);
      insertedFilePlaced = true;

      await _db.transaction(() async {
        final movesByTrackId = {for (final move in moves) move.trackId: move};
        for (final track in tracks) {
          final newIndex = track.index >= index ? track.index + 1 : track.index;
          final move = movesByTrackId[track.id];
          if (newIndex != track.index || move != null) {
            await _db.updateTrackPlacement(
              track.id,
              index: newIndex,
              filePath: move?.targetPath,
            );
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
          ),
        );
      });
    } catch (error) {
      try {
        final destination = File(destinationPath);
        if (insertedFilePlaced && await destination.exists()) {
          await destination.delete();
        }
      } catch (_) {
        // Best-effort rollback continues with the pre-existing files.
      }
      await _rollbackForcedInsertMoves(moves);
      try {
        if (await stagedSource.exists()) await stagedSource.delete();
      } catch (_) {
        // Best effort.
      }
      if (error is ForceInsertException) rethrow;
      throw ForceInsertException('Could not insert the selected file: $error');
    }

    await _writeMetadata(playlistId);
    final insertedTrack = await _db.getTrack(insertedTrackId);
    if (insertedTrack == null) {
      throw const ForceInsertException(
        'The inserted track could not be loaded.',
      );
    }
    return insertedTrack;
  }

  void _validateForcedInsertTargets(
    List<_ForcedInsertFileMove> moves,
    String destinationPath,
  ) {
    final originalPaths = moves.map((move) => move.originalPath).toSet();
    if (File(destinationPath).existsSync() &&
        !originalPaths.contains(destinationPath)) {
      throw const ForceInsertException(
        'A file already occupies the requested index in this playlist.',
      );
    }
    final targetPaths = <String>{destinationPath};
    for (final move in moves) {
      if (!targetPaths.add(move.targetPath)) {
        throw const ForceInsertException(
          'Existing playlist files have conflicting index prefixes.',
        );
      }
      if (File(move.targetPath).existsSync() &&
          !originalPaths.contains(move.targetPath)) {
        throw ForceInsertException(
          'Cannot move ${p.basename(move.originalPath)} because '
          '${p.basename(move.targetPath)} already exists.',
        );
      }
    }
  }

  Future<void> _rollbackForcedInsertMoves(
    List<_ForcedInsertFileMove> moves,
  ) async {
    for (final move in moves.reversed) {
      if (move.currentPath == move.originalPath ||
          move.currentPath == move.temporaryPath) {
        continue;
      }
      try {
        if (await File(move.currentPath).exists()) {
          await File(move.currentPath).rename(move.temporaryPath);
          move.currentPath = move.temporaryPath;
        }
      } catch (_) {
        // Continue restoring any other files.
      }
    }
    for (final move in moves.reversed) {
      if (move.currentPath != move.temporaryPath) continue;
      try {
        if (await File(move.currentPath).exists()) {
          await File(move.currentPath).rename(move.originalPath);
          move.currentPath = move.originalPath;
        }
      } catch (_) {
        // Best effort.
      }
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
    if (availability == 'unavailable') return 'unavailable';

    final title = entry['title'] as String? ?? '';
    if (title == '[Private video]') return 'private';
    if (title == '[Deleted video]') return 'deleted';
    if (title == '[Unavailable]') return 'unavailable';

    return null;
  }

  String _sanitizeFolderName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  }
}
