import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';
import 'ytdlp_service.dart';
import 'library_gate.dart';
import 'library_layout.dart';
import 'metadata_service.dart';
export 'metadata_service.dart' show PlaylistExistsException;
import 'sponsorblock_service.dart';
import 'media_thumbnail_service.dart' as media_thumbnail_service;
import 'app_settings_service.dart';
import 'video_quality.dart';
import 'lyrics/lyrics_models.dart';
import 'lyrics/lyrics_service.dart'
    show dropLyricsForReplacedMedia, persistLyricsFile;

/// Thrown by [PlaylistService.syncPlaylist] when the owner stopped the
/// update while YouTube was being asked for the playlist.
class SyncCancelledException implements Exception {
  const SyncCancelledException();

  @override
  String toString() => 'The update was stopped.';
}

class ForceInsertException implements Exception {
  final String message;

  const ForceInsertException(this.message);

  @override
  String toString() => message;
}

/// Thrown when the owner adds a playlist that is already in the library.
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

  /// Runs [action] inside the library gate. A short check that holds the
  /// gate (a playlist page linking its files) is waited for instead of
  /// refusing the owner's action.
  Future<T> _locked<T>(String operation, Future<T> Function() action) =>
      _gate.run(operation, action, wait: LibraryGate.userWait);

  Stream<List<Playlist>> watchAllPlaylists() => _db.watchAllPlaylists();

  Future<void> _ordering = Future.value();

  /// Moves playlist [id] in the home page order to just before [beforeId],
  /// or to the end when [beforeId] is null. Playlists the home page does
  /// not show keep their place relative to the others. Only the database
  /// changes: the order is not part of the metadata files. Moves run one
  /// after another, each on the order the previous one left.
  Future<void> movePlaylist(int id, {int? beforeId}) {
    final move = _ordering.then((_) async {
      if (beforeId == id) return;
      final order = [for (final p in await _db.getAllPlaylists()) p.id];
      if (!order.remove(id)) return;
      final at = beforeId == null ? -1 : order.indexOf(beforeId);
      order.insert(at < 0 ? order.length : at, id);
      await _db.setPlaylistOrder(order);
    });
    _ordering = move.catchError((_) {});
    return move;
  }

  /// Per playlist: total, downloaded, unavailable and failed track counts.
  /// Emits only when a number changes.
  Stream<Map<int, PlaylistCounts>> watchPlaylistTrackCounts() =>
      _db.watchPlaylistTrackCounts();

  final _syncing = <int>{};
  final _syncGeneration = <int, int>{};
  var _nextSyncGeneration = 0;
  final _syncingController = StreamController<Set<int>>.broadcast();

  /// Playlists whose update is asking YouTube for the playlist or applying
  /// the answer right now (the download that follows is reported by the
  /// download service).
  Set<int> get syncingPlaylistIds => Set.unmodifiable(_syncing);

  /// [syncingPlaylistIds] after every change.
  Stream<Set<int>> get syncingStream => _syncingController.stream;

  void _setSyncing(int playlistId, bool syncing) {
    final changed =
        syncing ? _syncing.add(playlistId) : _syncing.remove(playlistId);
    if (changed && !_syncingController.isClosed) {
      _syncingController.add(Set.unmodifiable(_syncing));
    }
  }

  /// Stops the update of [playlistId] while YouTube is still being asked:
  /// its answer is then ignored and nothing changes. The playlist stops
  /// counting as updating at once, so it can be updated again right away.
  /// Returns whether such an update was running. Once the answer is being
  /// applied, it finishes.
  bool cancelSync(int playlistId) {
    if (!_syncing.contains(playlistId)) return false;
    if (_applyingSyncs.contains(playlistId)) return false;
    _syncGeneration.remove(playlistId);
    _setSyncing(playlistId, false);
    return true;
  }

  /// Playlists whose YouTube answer is being written; too late to cancel.
  final _applyingSyncs = <int>{};

  void dispose() {
    _syncingController.close();
  }

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
    bool isTemporary = false,
    int? videoQuality,
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
    // A backup of this playlist may sit in a folder with another name (the
    // playlist was renamed on YouTube, or the owner typed a new name).
    DiscoveredPlaylist? backup;
    try {
      for (final found in await _metadata.findUnimportedPlaylists()) {
        if (MetadataService.samePlaylistUrl(found.url, url) &&
            found.audioOnly == audioOnly) {
          backup = found;
          break;
        }
      }
    } catch (_) {
      // Without a readable library there is nothing to restore.
    }
    final restore =
        backup ??
        (await _chooseFolder(
          audioOnly: audioOnly,
          name: name,
          url: url,
          existing: existing,
        )).restore;
    await _settings?.removeDismissedImportUrl(url);

    if (restore != null) {
      final playlistId = await _metadata.importPlaylist(restore);
      // Only what the add form asks about; SponsorBlock choices made for
      // this playlist before are kept.
      await _db.updatePlaylistFields(
        playlistId,
        PlaylistsCompanion(
          autoUpdate: Value(autoUpdate),
          playChapters: Value(playChapters),
          updateFrequencyHours: Value(updateFrequencyHours),
          includeThumbnails: Value(includeThumbnails),
          isTemporary: isTemporary ? const Value(true) : const Value.absent(),
        ),
      );
      await _writeMetadata(playlistId);
      return playlistId;
    }

    final choice = await _chooseFolder(
      audioOnly: audioOnly,
      name: name,
      url: url,
      existing: existing,
      allowRestore: false,
    );

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
        isTemporary: Value(isTemporary),
        videoQuality: Value(
          videoQuality != null && videoQuality > 0 ? videoQuality : null,
        ),
      ),
    );

    return playlistId;
  }

  /// Name of the temporary playlist when it is created.
  static const temporaryPlaylistName = 'Temporary';

  /// Video quality the temporary playlist starts with.
  static const temporaryPlaylistQuality = 720;

  Future<void> _temporaryChanges = Future.value();

  /// Runs [action] after every earlier temporary-playlist change, so two
  /// quick adds never create two playlists or give two videos one number.
  Future<T> _serialTemporary<T>(Future<T> Function() action) {
    final result = _temporaryChanges.then((_) => action());
    _temporaryChanges = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// The app's own "Temporary" playlist for single videos, created (or
  /// restored from its folder) the first time it is needed. It never asks
  /// YouTube for a playlist and is never updated on a schedule.
  Future<Playlist> ensureTemporaryPlaylist() =>
      _serialTemporary(_ensureTemporaryPlaylist);

  Future<Playlist> _ensureTemporaryPlaylist() async {
    final existing = await _db.getTemporaryPlaylist();
    if (existing != null) return existing;
    int id;
    try {
      id = await addPlaylist(
        url: temporaryPlaylistUrl,
        name: temporaryPlaylistName,
        audioOnly: false,
        autoUpdate: false,
        isTemporary: true,
        videoQuality: temporaryPlaylistQuality,
      );
    } on PlaylistExistsException {
      final again = await _db.getTemporaryPlaylist();
      if (again != null) return again;
      rethrow;
    }
    return _db.getPlaylist(id);
  }

  /// Adds one video to the temporary playlist, after its last one.
  ///
  /// [entry] has the shape of a playlist entry from yt-dlp: `id`, `title`,
  /// and optionally `thumbnail` and `duration`. A video that is already in
  /// it is not added again ([added] is false; [track] is the one there).
  ///
  /// Only a database row is added, no file is touched, so this works while
  /// a download (even one of the temporary playlist) is running.
  Future<({Playlist playlist, Track track, bool added})> addToTemporary(
    Map<String, dynamic> entry,
  ) {
    final videoId = entry['id'] as String? ?? '';
    if (videoId.isEmpty) {
      return Future.error(ArgumentError('The video has no id.'));
    }
    return _serialTemporary(() async {
      final playlist = await _ensureTemporaryPlaylist();
      final tracks = await _db.getTracksForPlaylist(playlist.id);
      for (final track in tracks) {
        if (track.videoId == videoId) {
          return (playlist: playlist, track: track, added: false);
        }
      }
      final index = await _nextUnusedIndex(playlist, tracks);
      final trackId = await _db.insertTrack(
        _companionFor(playlist.id, index, entry),
      );
      await _writeMetadata(playlist.id);
      final track = await _db.getTrack(trackId);
      if (track == null) throw StateError('The video could not be saved.');
      return (playlist: playlist, track: track, added: true);
    });
  }

  /// A number no track and no file of [playlist] has used: higher than
  /// every track and every numbered file in its folder (or moved aside).
  /// A number is never given out again while a file with it is left, which
  /// a new video's download would otherwise take as its own.
  Future<int> _nextUnusedIndex(Playlist playlist, List<Track> tracks) async {
    var highest = 0;
    for (final track in tracks) {
      if (track.index > highest) highest = track.index;
    }
    final numbered = RegExp(r'^(\d+)_');
    for (final dirPath in [
      playlist.outputPath,
      LibraryLayout.replacedDir(playlist.outputPath),
    ]) {
      try {
        final dir = Directory(dirPath);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final match = numbered.firstMatch(p.basename(entity.path));
          final number = match == null ? null : int.tryParse(match.group(1)!);
          if (number != null && number > highest) highest = number;
        }
      } on FileSystemException {
        // An unreadable folder: the tracks' numbers are all there is.
      }
    }
    return highest + 1;
  }

  /// Removes the tracks [trackIds] of [playlistId] and deletes their files:
  /// media, cover, kept video info and older copies moved aside under the
  /// track's number. Files another track uses are kept. When the playlist
  /// is left empty, a cover copied from one of its videos goes too.
  ///
  /// Meant for the temporary playlist, whose numbers are never reused (a
  /// YouTube playlist would bring the videos back on its next update).
  /// Stop a download of the playlist first: like any file deletion this
  /// waits for no download and throws [LibraryBusyException] while one
  /// runs. [beforeDelete] runs once the library is free, right before
  /// anything is deleted, so the player can let go of the files
  /// ([PlaybackService.tracksRemoved]) only when they really go.
  Future<void> removeTracks(
    int playlistId,
    Iterable<int> trackIds, {
    Future<void> Function()? beforeDelete,
  }) async {
    final ids = trackIds.toSet();
    if (ids.isEmpty) return;
    await _locked('video removal', () async {
      final playlist = await _db.getPlaylist(playlistId);
      final all = await _db.getAllTracks();
      final removed = <Track>[];
      final kept = <String>{};
      final keptVideoIds = <String>{};
      for (final track in all) {
        if (track.playlistId == playlistId && ids.contains(track.id)) {
          removed.add(track);
          continue;
        }
        for (final path in [track.filePath, track.thumbnailPath]) {
          if (path != null) kept.add(p.normalize(path));
        }
        if (track.playlistId == playlistId) keptVideoIds.add(track.videoId);
      }
      if (removed.isEmpty) return;
      await beforeDelete?.call();
      final left =
          all.where((t) => t.playlistId == playlistId).length - removed.length;
      await _db.deleteTracks([for (final track in removed) track.id]);

      final folder = playlist.outputPath;
      Future<void> deleteFile(String path) async {
        if (kept.contains(p.normalize(path)) || !p.isWithin(folder, path)) {
          return;
        }
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Keep going; a leftover file is harmless.
        }
      }

      final removedNumbers = <int>{};
      for (final track in removed) {
        removedNumbers.add(track.index);
        if (track.filePath != null) await deleteFile(track.filePath!);
        if (track.thumbnailPath != null) {
          await deleteFile(track.thumbnailPath!);
          media_thumbnail_service.noteThumbnailRemoved(track.thumbnailPath);
        }
        if (!keptVideoIds.contains(track.videoId)) {
          await deleteFile(LibraryLayout.infoJsonPath(folder, track.videoId));
          await deleteFile(LibraryLayout.lyricsJsonPath(folder, track.videoId));
        }
      }
      final numbered = RegExp(r'^(\d+)_');
      try {
        final replaced = Directory(LibraryLayout.replacedDir(folder));
        if (await replaced.exists()) {
          await for (final entity in replaced.list()) {
            if (entity is! File) continue;
            final match = numbered.firstMatch(p.basename(entity.path));
            final number = match == null ? null : int.tryParse(match.group(1)!);
            if (number != null && removedNumbers.contains(number)) {
              await deleteFile(entity.path);
            }
          }
        }
      } on FileSystemException {
        // Older copies stay; they only take space.
      }

      final url = playlist.thumbnailUrl;
      if (left == 0 && (url == null || url.isEmpty)) {
        // The cover was copied from one of the videos that are gone.
        final coverStem = LibraryLayout.playlistCoverStem(folder);
        try {
          final covers = Directory(LibraryLayout.thumbnailsDir(folder));
          if (await covers.exists()) {
            await for (final entity in covers.list()) {
              if (entity is File &&
                  p.withoutExtension(entity.path) == coverStem) {
                await deleteFile(entity.path);
                media_thumbnail_service.noteThumbnailRemoved(entity.path);
              }
            }
          }
        } on FileSystemException {
          // The old cover stays on disk but is no longer shown.
        }
        if (playlist.thumbnailPath != null) {
          await _db.updatePlaylistFields(
            playlistId,
            const PlaylistsCompanion(thumbnailPath: Value(null)),
          );
        }
      }
      await _writeMetadata(playlistId);
    });
  }

  /// Removes every video of [playlistId] (see [removeTracks]). The playlist
  /// itself stays.
  Future<void> clearPlaylist(
    int playlistId, {
    Future<void> Function()? beforeDelete,
  }) async {
    final tracks = await _db.getTracksForPlaylist(playlistId);
    await removeTracks(playlistId, [
      for (final track in tracks) track.id,
    ], beforeDelete: beforeDelete);
  }

  /// Picks the folder for a playlist named [name]: `<base>/<name>`, or
  /// `<name> (2)`, `<name> (3)`, ... when that folder belongs to another
  /// playlist or holds media of unknown origin. A folder holding a backup of
  /// this same playlist is returned with that backup when [allowRestore];
  /// otherwise any folder with a sidecar counts as taken.
  Future<_FolderChoice> _chooseFolder({
    required bool audioOnly,
    required String name,
    required String url,
    required List<Playlist> existing,
    bool allowRestore = true,
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
        if (allowRestore &&
            MetadataService.samePlaylistUrl(backup.url, url) &&
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
    var cleaned =
        name
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
  ) => _locked('playlist update', () async {
    final entries = playlistInfo['entries'] as List<dynamic>? ?? [];
    await _metadata.reconcilePlaylist(await _db.getPlaylist(playlistId));
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
    // `Value(null)` turns lyrics off; absent leaves the mode alone.
    Value<LyricsMode?> lyricsMode = const Value.absent(),
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
      lyricsMode:
          lyricsMode.present
              ? Value(LyricsMode.toDb(lyricsMode.value))
              : const Value.absent(),
    );

    if (audioOnly != null && audioOnly != playlist.audioOnly) {
      await _locked(
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
    final others = [
      for (final other in await _db.getAllPlaylists())
        if (other.id != playlist.id) other,
    ];
    final oldFolder = playlist.outputPath;

    // Switching back to a format the playlist had before: reuse that folder
    // and the files it still holds instead of downloading them again.
    String? newFolder;
    final earlierFiles = <String, String>{};
    final earlier = p.join(
      LibraryLayout.basePathFor(audioOnly: audioOnly),
      p.basename(oldFolder),
    );
    final earlierInUse = others.any(
      (o) => o.outputPath.toLowerCase() == earlier.toLowerCase(),
    );
    if (!earlierInUse && LibraryLayout.isPlaylistFolder(earlier)) {
      final set = await _metadata.readSupersededFolder(earlier);
      if (set != null &&
          MetadataService.samePlaylistUrl(set.url, playlist.url) &&
          set.audioOnly == audioOnly) {
        newFolder = earlier;
        for (final t in set.tracks) {
          final name = t.fileName;
          if (name == null) continue;
          final file = p.normalize(p.join(earlier, name));
          if (p.equals(p.dirname(file), earlier) && await File(file).exists()) {
            earlierFiles[t.videoId] = file;
          }
        }
      }
    }
    newFolder ??=
        (await _chooseFolder(
          audioOnly: audioOnly,
          // Keep the folder name the playlist already has, so a later
          // rename in the app does not scatter its folders.
          name: p.basename(oldFolder),
          url: playlist.url,
          // A kept backup in the target folder is a different set of files;
          // a switch must never write over it or adopt its files.
          allowRestore: false,
          existing: others,
        )).path;
    await Directory(newFolder).create(recursive: true);

    final targetFolder = newFolder;

    // Decide for every track first, then commit all of it at once, so an
    // interrupted switch never leaves some tracks without a plan.
    final targetBase = LibraryLayout.basePathFor(audioOnly: audioOnly);
    final adopt = <int>[];
    final request = <int>[];
    final link = <int, String>{};
    for (final track in await _db.getTracksForPlaylist(playlist.id)) {
      final path = track.filePath;
      if (track.status != 'complete' ||
          path == null ||
          !await File(path).exists()) {
        continue;
      }
      final earlierFile = earlierFiles[track.videoId];
      if (earlierFile != null && !track.isLocalReplacement) {
        link[track.id] = earlierFile;
      } else if (p.isWithin(targetBase, path) || !canDownloadAgain(track)) {
        // Already in the target format, or nothing better can be
        // downloaded: take the file along.
        adopt.add(track.id);
      } else {
        request.add(track.id);
      }
    }
    await _db.transaction(() async {
      await _db.updatePlaylistFields(
        playlist.id,
        fields.copyWith(
          audioOnly: Value(audioOnly),
          outputPath: Value(targetFolder),
        ),
      );
      for (final id in request) {
        await _db.setTrackReplaceRequested(id, true);
      }
      for (final id in [...adopt, ...link.keys]) {
        await _db.setTrackReplaceRequested(id, false);
      }
      for (final entry in link.entries) {
        await _db.updateTrackFields(entry.key, filePath: entry.value);
      }
    });

    // Moving files can be interrupted; the next update finishes it (see
    // MetadataService.adoptStrayFiles).
    final switched = await _db.getPlaylist(playlist.id);
    for (final id in adopt) {
      await _metadata.adoptKeptFile(switched, id);
    }
    // A reinstall imports only the new folder: the kept video info and the
    // lyrics go along. Lyrics are written from the database, which also
    // replaces stale files left in a reused earlier folder.
    for (final track in await _db.getTracksForPlaylist(playlist.id)) {
      try {
        final info = File(LibraryLayout.infoJsonPath(oldFolder, track.videoId));
        final target = LibraryLayout.infoJsonPath(targetFolder, track.videoId);
        if (!p.equals(oldFolder, targetFolder) && await info.exists()) {
          await Directory(p.dirname(target)).create(recursive: true);
          await info.copy(target);
        }
        await persistLyricsFile(_db, track.id);
      } catch (_) {
        // Extras; the switch itself is done.
      }
    }

    // New sidecar first, then set the old one aside: the old folder's
    // sidecar would offer the same playlist for import a second time after
    // a reinstall.
    await _writeMetadata(playlist.id);
    final reusedSidecar = File(
      p.join(newFolder, '${MetadataService.metaFileName}.superseded'),
    );
    if (await reusedSidecar.exists()) {
      try {
        await reusedSidecar.delete();
      } catch (_) {}
    }
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
  }

  /// Older versions could give two playlists one folder (same name, or the
  /// same URL added twice). They would overwrite each other's sidecar and
  /// renumber each other's files. Moves every playlist but the oldest into
  /// a folder of its own, taking its own files along. A file both use is
  /// copied if it is this playlist's song (its name matches the title), and
  /// otherwise left to the other playlist, this track downloading its own.
  /// Call only while holding the library gate.
  Future<int> separateSharedFolders() async {
    var separated = 0;
    while (true) {
      final all = await _db.getAllPlaylists();
      final byFolder = <String, List<Playlist>>{};
      for (final playlist in all) {
        byFolder
            .putIfAbsent(
              p.normalize(p.absolute(playlist.outputPath)).toLowerCase(),
              () => [],
            )
            .add(playlist);
      }
      final shared = byFolder.values.where((g) => g.length > 1).toList();
      if (shared.isEmpty) return separated;
      final group = shared.first..sort((a, b) => a.id.compareTo(b.id));
      final mover = group.last;
      await _moveToOwnFolder(mover, [
        for (final other in group)
          if (other.id != mover.id) other,
      ], all);
      separated++;
    }
  }

  Future<void> _moveToOwnFolder(
    Playlist mover,
    List<Playlist> staying,
    List<Playlist> all,
  ) async {
    final oldFolder = mover.outputPath;
    final choice = await _chooseFolder(
      audioOnly: mover.audioOnly,
      name: mover.name,
      url: mover.url,
      allowRestore: false,
      existing: all,
    );
    final newFolder = choice.path;
    await Directory(newFolder).create(recursive: true);

    final stayingFiles = <String>{};
    for (final other in staying) {
      for (final t in await _db.getTracksForPlaylist(other.id)) {
        for (final f in [t.filePath, t.thumbnailPath]) {
          if (f != null) stayingFiles.add(p.normalize(f).toLowerCase());
        }
      }
    }

    String targetFor(String path) =>
        p.join(newFolder, p.relative(path, from: oldFolder));

    for (final track in await _db.getTracksForPlaylist(mover.id)) {
      final media = track.filePath;
      if (media != null &&
          p.isWithin(oldFolder, media) &&
          await File(media).exists()) {
        final usedByOther = stayingFiles.contains(
          p.normalize(media).toLowerCase(),
        );
        if (!usedByOther) {
          final target = await MetadataService.uniquePath(targetFor(media));
          await Directory(p.dirname(target)).create(recursive: true);
          await MetadataService.moveFile(media, target);
          await _db.updateTrackFields(track.id, filePath: target);
        } else if (titleMatchesFileName(track.title, media)) {
          final target = await MetadataService.uniquePath(targetFor(media));
          await Directory(p.dirname(target)).create(recursive: true);
          await File(media).copy(target);
          await _db.updateTrackFields(track.id, filePath: target);
        } else {
          // The other playlist's song; this track gets its own again.
          await _db.updateTrackStatus(
            track.id,
            'pending',
            clearFilePath: true,
            clearDownloadedAt: true,
          );
        }
      }
      final cover = track.thumbnailPath;
      if (cover != null &&
          p.isWithin(oldFolder, cover) &&
          await File(cover).exists()) {
        final target = targetFor(cover);
        await Directory(p.dirname(target)).create(recursive: true);
        if (stayingFiles.contains(p.normalize(cover).toLowerCase())) {
          await File(cover).copy(target);
        } else {
          await MetadataService.moveFile(cover, target);
          media_thumbnail_service.noteThumbnailRemoved(cover);
        }
        media_thumbnail_service.noteThumbnailWritten(target);
        await _db.updateTrackThumbnailPath(track.id, target);
      }
      for (final (from, to) in [
        (
          LibraryLayout.infoJsonPath(oldFolder, track.videoId),
          LibraryLayout.infoJsonPath(newFolder, track.videoId),
        ),
        (
          LibraryLayout.lyricsJsonPath(oldFolder, track.videoId),
          LibraryLayout.lyricsJsonPath(newFolder, track.videoId),
        ),
      ]) {
        final file = File(from);
        if (!await file.exists()) continue;
        await Directory(p.dirname(to)).create(recursive: true);
        await file.copy(to);
      }
    }
    await _db.updatePlaylistFields(
      mover.id,
      PlaylistsCompanion(
        outputPath: Value(newFolder),
        thumbnailPath: const Value(null),
      ),
    );
    await _writeMetadata(mover.id);
    for (final other in staying) {
      await _writeMetadata(other.id);
    }
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
  ///
  /// Only one update per playlist runs at a time: a second request while one
  /// is running throws [LibraryBusyException]. [cancelSync] stops it while
  /// YouTube is being asked ([SyncCancelledException]).
  Future<SyncResult> syncPlaylist(Playlist playlist) async {
    // No YouTube playlist is behind the temporary one; asking for its
    // made-up address would only fail.
    if (playlist.isTemporary) return const SyncResult();
    if (_syncing.contains(playlist.id)) {
      throw const LibraryBusyException(
        'This playlist is already being updated.',
      );
    }
    // Asking YouTube for a long playlist takes a while; do not do it only
    // to be refused by the running download afterwards.
    final active = _gate.activeOperation;
    if (active != null && !LibraryGate.shortOperations.contains(active)) {
      throw LibraryBusyException('Wait until the current $active finishes.');
    }
    final generation = ++_nextSyncGeneration;
    _syncGeneration[playlist.id] = generation;
    bool isCurrent() => _syncGeneration[playlist.id] == generation;
    _setSyncing(playlist.id, true);
    try {
      // Recorded even when the check fails, so the scheduled update takes
      // the playlists it tried longest ago first.
      await _db.markPlaylistUpdateAttempt(playlist.id, DateTime.now());
      if (!isCurrent()) throw const SyncCancelledException();
      final info = await _ytdlp.getPlaylistInfo(playlist.url);
      if (!isCurrent()) throw const SyncCancelledException();
      _applyingSyncs.add(playlist.id);
      // Re-read inside the gate: the caller's copy may predate a format
      // switch, and the sync renames files in the current folder.
      return await _locked('playlist update', () async {
        final current = await _db.getPlaylistOrNull(playlist.id);
        if (current == null) {
          throw StateError('"${playlist.name}" was deleted.');
        }
        return _applySync(current, info);
      });
    } finally {
      // A cancelled call that returns late must not end a newer update.
      if (isCurrent()) {
        _applyingSyncs.remove(playlist.id);
        _syncGeneration.remove(playlist.id);
        _setSyncing(playlist.id, false);
      }
    }
  }

  /// Puts every track of [playlistId] that a download found removed from
  /// YouTube back in the queue, so the next update tries them again.
  /// Returns how many there were.
  Future<int> retryRemovedTracks(int playlistId) async {
    var count = 0;
    for (final track in await _db.getTracksForPlaylist(playlistId)) {
      if (track.unavailableReason != removedFromYouTubeReason) continue;
      await _db.clearRemovedFromYouTube(track.id);
      count++;
    }
    if (count > 0) await _writeMetadata(playlistId);
    return count;
  }

  /// Puts one track that a download found removed from YouTube back in the
  /// queue (see [retryRemovedTracks]).
  Future<void> retryRemovedTrack(int trackId) async {
    final track = await _db.getTrack(trackId);
    if (track == null) return;
    await _db.clearRemovedFromYouTube(trackId);
    await _writeMetadata(track.playlistId);
  }

  Future<SyncResult> _applySync(
    Playlist playlist,
    Map<String, dynamic> info,
  ) async {
    // A renumbering interrupted earlier can leave a track whose recorded
    // path is gone while its file still has the old number. Link files
    // first, so the plan below starts from where the files really are.
    await _metadata.reconcilePlaylist(playlist);
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
    Future<bool> hasFileOnDisk(Track t) async =>
        t.filePath != null && await File(t.filePath!).exists();

    // Decide for every track first, then write all changes in one
    // transaction: one update of the open pages instead of one per track.
    final changes = <Future<void> Function()>[];

    // Process existing tracks against fresh data
    for (final track in existingTracks) {
      if (isForcedInsertVideoId(track.videoId)) continue;
      final freshEntry = freshByVideoId[track.videoId];

      if (freshEntry == null) {
        // Video removed from playlist entirely
        if (await hasFileOnDisk(track)) {
          // File on disk — keep playable, just note removal
          if (track.unavailableReason != 'removed') {
            changes.add(() => _db.updateTrackOnlineStatus(track.id, 'removed'));
            removed++;
          }
        } else if (track.status != 'unavailable' ||
            track.unavailableReason != 'removed') {
          changes.add(() => _db.updateTrackUnavailable(track.id, 'removed'));
          removed++;
        }
        continue;
      }

      final reason = _detectUnavailability(freshEntry);

      if (reason != null) {
        // Video is unavailable online
        if (await hasFileOnDisk(track)) {
          // File on disk — keep playable, just update online status
          if (track.unavailableReason != reason) {
            changes.add(() => _db.updateTrackOnlineStatus(track.id, reason));
          }
        } else if (track.status != 'unavailable') {
          changes.add(() => _db.updateTrackUnavailable(track.id, reason));
          markedUnavailable++;
        }
      } else if (track.unavailableReason == removedFromYouTubeReason) {
        // A download found the video taken down for good. The playlist
        // listing often still shows such a video as normal, so it does not
        // count as "available again"; only a manual retry brings it back.
        continue;
      } else if (track.unavailableReason != null) {
        // Video is available again (was previously flagged)
        if (await hasFileOnDisk(track)) {
          if (track.isLocalReplacement) {
            // Local replacement exists — user needs to decide
            replacementConflicts.add(track);
          }
          // Clear the unavailable reason since video is back
          changes.add(() => _db.updateTrackOnlineStatus(track.id, null));
        } else if (track.status == 'unavailable') {
          changes.add(
            () => _db.updateTrackAvailable(
              track.id,
              title: freshEntry['title'] as String? ?? 'Unknown',
              thumbnailUrl: freshEntry['thumbnail'] as String?,
              durationSeconds: (freshEntry['duration'] as num?)?.toInt(),
            ),
          );
        } else {
          // Status is pending/error, reason was set informationally
          changes.add(() => _db.updateTrackOnlineStatus(track.id, null));
        }
        markedAvailable++;
      }
    }
    if (changes.isNotEmpty) {
      await _db.transaction(() async {
        for (final change in changes) {
          await change();
        }
      });
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
    // Flat playlist entries of live streams and premieres have no duration,
    // and some have no thumbnail; store "unknown", not "" and 0:00.
    final thumbnail = entry['thumbnail'] as String?;
    final duration = (entry['duration'] as num?)?.toInt();
    return TracksCompanion.insert(
      playlistId: playlistId,
      index: index,
      videoId: entry['id'] as String,
      title: entry['title'] as String? ?? 'Unknown',
      thumbnailUrl: Value(
        thumbnail == null || thumbnail.isEmpty ? null : thumbnail,
      ),
      durationSeconds: Value(
        duration == null || duration <= 0 ? null : duration,
      ),
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
        positionOfVideo[slot is int ? videoOfTrack[slot]! : slot as String] = i;
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
  /// index down, each straight to its final name, with the tracks' recorded
  /// paths updated just before their files move (a chunk of tracks per
  /// transaction). Indices change in one transaction at the end. If the app
  /// dies part-way, every track still finds its file (by its recorded path,
  /// or by its unchanged index for files not moved yet), the next repair
  /// puts the names back in line with the unchanged indices, and the next
  /// update simply tries again.
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

    // One listing instead of two disk checks per track. Android's shared
    // storage ignores letter case, so compare names without it.
    final present = <String>{};
    final dir = Directory(folder);
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File) present.add(p.normalize(entity.path).toLowerCase());
      }
    }
    String key(String path) => p.normalize(path).toLowerCase();

    // Plan every rename in order: a file moved earlier frees its name for
    // the next one.
    final planned = <({int trackId, String from, String to})>[];
    for (final track in moving) {
      final path = track.filePath;
      if (path == null || !p.equals(p.dirname(path), folder)) continue;
      if (!present.contains(key(path))) continue;
      final rest = p.basename(path).replaceFirst(prefixPattern, '');
      final target = p.join(
        folder,
        '${MetadataService.paddedIndex(newIndexByTrackId[track.id]!, newTrackCount)}_$rest',
      );
      if (p.equals(path, target) || present.contains(key(target))) continue;
      present
        ..remove(key(path))
        ..add(key(target));
      planned.add((trackId: track.id, from: path, to: target));
    }

    const chunkSize = 50;
    for (var start = 0; start < planned.length; start += chunkSize) {
      final chunk = planned.sublist(
        start,
        start + chunkSize > planned.length ? planned.length : start + chunkSize,
      );
      await _db.updateTrackFilePaths({for (final m in chunk) m.trackId: m.to});
      final failed = <int, String>{};
      for (final move in chunk) {
        try {
          if (await File(move.to).exists()) {
            throw FileSystemException('Target exists', move.to);
          }
          await File(move.from).rename(move.to);
        } catch (_) {
          failed[move.trackId] = move.from;
        }
      }
      await _db.updateTrackFilePaths(failed);
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
    await _locked('playlist deletion', () async {
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
      media_thumbnail_service.forgetThumbnailsUnder(folder);
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

  /// Sets the highest video resolution new downloads of [id] use (null = the
  /// best). Files already downloaded stay until [requestRedownload].
  Future<void> setPlaylistVideoQuality(int id, int? maxHeight) async {
    await _db.updatePlaylistFields(
      id,
      PlaylistsCompanion(
        videoQuality: Value(
          maxHeight != null && maxHeight > 0 ? maxHeight : null,
        ),
      ),
    );
    await _writeMetadata(id);
  }

  /// Sets [trackId]'s own video quality: null follows the playlist, 0 = the
  /// best, N = up to N p. Its file stays until it is downloaded again.
  Future<void> setTrackVideoQuality(int trackId, int? quality) async {
    final track = await _db.getTrack(trackId);
    if (track == null) return;
    await _db.setTrackVideoQuality(
      trackId,
      quality == null ? null : (quality < 0 ? 0 : quality),
    );
    await _writeMetadata(track.playlistId);
  }

  /// The downloaded tracks of [playlist] whose file would change when
  /// downloaded again because their cap moved from [oldMax] to [newMax]
  /// (null = the best).
  ///
  /// Without [only] this is a change of the playlist's quality, so tracks
  /// with a quality of their own are left out. Tracks YouTube cannot give
  /// again (local files, removed videos) never count.
  Future<List<Track>> tracksAffectedByQualityChange(
    Playlist playlist, {
    required int? oldMax,
    required int? newMax,
    Iterable<Track>? only,
  }) async {
    if (playlist.audioOnly || oldMax == newMax) return const [];
    final candidates =
        only?.toList() ??
        [
          for (final track in await _db.getTracksForPlaylist(playlist.id))
            if (track.videoQuality == null) track,
        ];
    final affected = <Track>[];
    for (final track in candidates) {
      final path = track.filePath;
      if (track.status != 'complete' ||
          path == null ||
          !canDownloadAgain(track) ||
          !await File(path).exists()) {
        continue;
      }
      final resolution = await _downloadedResolution(playlist, track);
      if (isAffectedByQualityChange(
        oldMax: oldMax,
        newMax: newMax,
        resolution: resolution,
        downloadedMaxHeight: track.downloadedMaxHeight,
      )) {
        affected.add(track);
      }
    }
    return affected;
  }

  /// The shorter side of [track]'s downloaded video from its kept
  /// `.info.json`; null when unknown.
  Future<int?> _downloadedResolution(Playlist playlist, Track track) async {
    try {
      final file = File(
        LibraryLayout.infoJsonPath(playlist.outputPath, track.videoId),
      );
      if (!await file.exists()) return null;
      final info = jsonDecode(await file.readAsString());
      return info is Map<String, dynamic>
          ? videoResolutionFromInfo(info)
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Asks for a new copy of each of [trackIds]: the next download of
  /// [playlistId] replaces their files, each only once its new copy is
  /// complete.
  Future<void> requestRedownload(int playlistId, List<int> trackIds) async {
    if (trackIds.isEmpty) return;
    await _db.transaction(() async {
      for (final id in trackIds) {
        await _db.setTrackReplaceRequested(id, true);
      }
    });
    await _writeMetadata(playlistId);
  }

  /// Changes a track's title and/or the title part of its file name. The
  /// number prefix and extension stay. Returns whether anything changed.
  Future<bool> overrideTrack({
    required int trackId,
    String? title,
    String? fileName,
  }) async {
    // Renaming a file must wait for downloads; changing only the title
    // does not touch any file.
    if (fileName == null || fileName.trim().isEmpty) {
      return _overrideTrack(trackId: trackId, title: title, fileName: null);
    }
    return _locked(
      'rename',
      () => _overrideTrack(trackId: trackId, title: title, fileName: fileName),
    );
  }

  Future<bool> _overrideTrack({
    required int trackId,
    String? title,
    String? fileName,
  }) async {
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
  }

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
      return await _locked(
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
      p.join(
        LibraryLayout.stagingRoot(playlist.outputPath),
        'insert-$operationId',
      ),
    );
    await staging.create(recursive: true);
    final stagedSource = File(p.join(staging.path, 'source$extension'));
    try {
      await source.copy(stagedSource.path);
    } catch (error) {
      await _deleteQuietly(staging);
      throw ForceInsertException('Could not copy the selected file: $error');
    }

    await _metadata.reconcilePlaylist(playlist);
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
      await _validateForcedInsertTargets(moves, destinationPath);
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
  }) => _locked(
    'replacement',
    () => _replaceWithLocalFile(
      trackId: trackId,
      sourcePath: sourcePath,
      sourceFileName: sourceFileName,
    ),
  );

  /// [replaceWithLocalFile] for a file downloaded from a reupload link. The
  /// caller must already hold the library gate (the download service holds
  /// it for the whole download). The file is named after the track's title,
  /// like the rest of the playlist.
  Future<Track> replaceWithReuploadFile({
    required int trackId,
    required String downloadedPath,
  }) async {
    if (!_gate.isBusy) {
      throw StateError('A reupload is only adopted inside the library gate.');
    }
    final track = await _db.getTrack(trackId);
    if (track == null) throw StateError('The selected track no longer exists.');
    // Same title length cap as a normal download: names are limited to
    // 255 bytes and non-Latin letters take several bytes each.
    var runes = MetadataService.sanitizeFilename(track.title).runes.toList();
    while (runes.length > 1 &&
        utf8.encode(String.fromCharCodes(runes)).length > 150) {
      runes = runes.sublist(0, runes.length - 1);
    }
    final name =
        String.fromCharCodes(runes).trim() + p.extension(downloadedPath);
    return _replaceWithLocalFile(
      trackId: trackId,
      sourcePath: downloadedPath,
      sourceFileName: name,
    );
  }

  /// The Wayback Machine's saved copy of a YouTube video, the same copy
  /// quiteaplaylist.com offers for download. yt-dlp reads it with its
  /// web-archive extractor; a video that was never saved fails with "not
  /// archived or indexed".
  static String archivedCopyUrl(String videoId) =>
      'https://web.archive.org/web/2oe_/http://wayback-fakeurl.archive.org/'
      'yt/$videoId';

  /// Whether [input] is a link yt-dlp can be given as a reupload: a web
  /// address that is not a whole playlist or channel.
  static Uri? parseReuploadUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    final host = uri.host.toLowerCase();
    final isYouTube =
        host == 'youtu.be' ||
        host == 'youtube.com' ||
        host.endsWith('.youtube.com');
    if (isYouTube) {
      final path = uri.path.toLowerCase();
      final single =
          host == 'youtu.be' ||
          (path == '/watch' && uri.queryParameters['v'] != null) ||
          path.startsWith('/shorts/') ||
          path.startsWith('/live/') ||
          path.startsWith('/embed/');
      if (!single) return null;
    }
    return uri;
  }

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
      p.join(
        LibraryLayout.stagingRoot(playlist.outputPath),
        'replace-$operationId',
      ),
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
        previousKeptAt = await _metadata.moveAside(
          playlist.outputPath,
          current,
        );
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
    // Lyrics timed to the old file (chapters, transcripts, synced lines).
    await dropLyricsForReplacedMedia(_db, track.id);
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
          await media_thumbnail_service.thumbnailFileExists(
            track.thumbnailPath,
          )) {
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
      if (thumbnailPath == null) {
        // This file has no cover; an earlier local file's cover under the
        // same name would otherwise come back on the next backfill.
        for (final ext in const ['.jpg', '.jpeg', '.png', '.webp', '.gif']) {
          final stale = File('$stem$ext');
          if (await stale.exists()) await stale.delete();
          media_thumbnail_service.noteThumbnailRemoved(stale.path);
        }
      }
      await _db.updateTrackThumbnailPath(track.id, thumbnailPath);
      return thumbnailPath;
    } catch (_) {
      // Artwork is optional; a local media operation must still succeed.
      return null;
    }
  }

  Future<void> _validateForcedInsertTargets(
    List<({Track track, String from, String to})> moves,
    String destinationPath,
  ) async {
    final originalPaths = moves.map((move) => move.from).toSet();
    if (await File(destinationPath).exists() &&
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
      if (await File(move.to).exists() && !originalPaths.contains(move.to)) {
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
      // Reads the playlist and its tracks itself when the write starts.
      await _metadata.writeMetadataFor(playlistId);
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
