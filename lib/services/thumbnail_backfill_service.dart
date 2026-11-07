import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import '../database/database.dart';
import 'library_layout.dart';
import 'log_service.dart';
import 'media_thumbnail_service.dart';
import 'metadata_service.dart';

/// The image cache's file for [url], or null when the app never showed it.
typedef CachedImageLookup = Future<File?> Function(String url);

/// Downloads the image at [url] into [target]. Returns whether it worked.
typedef ImageDownloader = Future<bool> Function(String url, File target);

/// Looks [url] up in the cache the app's network images use. Expired entries
/// still count: they are often the only copy left of a deleted video's cover.
Future<File?> lookupCachedNetworkImage(String url) async {
  final info = await CachedNetworkImageProvider.defaultCacheManager
      .getFileFromCache(url);
  final file = info?.file;
  if (file == null || !await file.exists()) return null;
  return file;
}

const _maxImageBytes = 10 * 1024 * 1024;

/// Downloads an image over http(s). Fails on any status but 200, on bodies
/// that are not an image, and on slow or stalled connections.
Future<bool> downloadImageToFile(String url, File target) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return false;
  }
  final client =
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..idleTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      return false;
    }
    final type = response.headers.contentType;
    if (type != null && type.primaryType != 'image') {
      await response.drain<void>().catchError((_) {});
      return false;
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      body.add(chunk);
      if (body.length > _maxImageBytes) return false;
    }
    final bytes = body.takeBytes();
    if (ThumbnailBackfillService.imageExtension(bytes) == null) return false;
    await target.writeAsBytes(bytes, flush: true);
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Gives tracks and playlists an offline cover file in the playlist's
/// `.woolytube_thumbnails/` folder, so covers still show without network and
/// after YouTube deletes a video.
///
/// Only ever adds image files and records their paths; never touches media.
/// Works through tracks one at a time: libraries have thousands of tracks
/// and phones are slow. New covers are recorded in small batches, so the
/// open pages update a few times instead of once per cover.
///
/// It never takes the library gate (that would refuse the owner's own
/// actions for minutes); instead it pauses while [shouldPause] says an
/// operation that moves or deletes playlist folders runs, and it never
/// creates a playlist folder that is gone.
class ThumbnailBackfillService {
  ThumbnailBackfillService(
    this._db,
    this._metadata,
    this._thumbnails,
    this._log, {
    CachedImageLookup? lookupCachedImage,
    ImageDownloader? downloadImage,
    bool Function()? shouldPause,
  }) : _lookupCachedImage = lookupCachedImage ?? lookupCachedNetworkImage,
       _downloadImage = downloadImage ?? downloadImageToFile,
       _shouldPause = shouldPause;

  final AppDatabase _db;
  final MetadataService _metadata;
  final MediaThumbnailService _thumbnails;
  final LogService _log;
  final CachedImageLookup _lookupCachedImage;
  final ImageDownloader _downloadImage;
  final bool Function()? _shouldPause;

  /// New covers are recorded once this many are found ...
  static const _writeBatchSize = 25;

  /// ... or this long after the first one waiting, whichever comes first.
  static const _writeBatchDelay = Duration(milliseconds: 1500);

  static const imageExtensions = ['.jpg', '.jpeg', '.png', '.webp', '.gif'];

  /// Tracks that yielded no cover this session, with whether network was
  /// allowed then. A later attempt with network may still find one.
  final _noCover = <int, bool>{};

  /// Thumbnail paths already seen on disk this session, so opening a large
  /// playlist again does not check thousands of files.
  final _verified = <int, String>{};

  final _runs = <int, Future<void>>{};
  Future<int>? _backfillAll;
  var _tmpCounter = 0;

  /// Adds a local cover to every downloaded track of [playlist] that has
  /// none. Tries, in order: an image already named for the track, the art
  /// embedded in the media file, the app's image cache, and (only when
  /// [allowNetwork]) a download. Returns the number of covers added.
  Future<int> ensureTrackThumbnails(
    Playlist playlist, {
    bool allowNetwork = false,
  }) => _serialized(
    playlist.id,
    () => _ensureTrackThumbnails(playlist, allowNetwork),
  );

  /// Gives [playlist] a local cover if it has none: the cached playlist
  /// image, else a download when [allowNetwork], else a copy of the first
  /// track's cover. Returns the new cover's path, or null.
  Future<String?> ensurePlaylistCover(
    Playlist playlist, {
    bool allowNetwork = false,
  }) => _serialized(
    playlist.id,
    () => _ensurePlaylistCover(playlist.id, allowNetwork),
  );

  /// Covers, then track thumbnails, for every playlist. Playlists still
  /// without a cover then get one from their first track. Returns the
  /// number of images added.
  Future<int> backfillAll({bool allowNetwork = false}) {
    return _backfillAll ??= _runBackfillAll(
      allowNetwork,
    ).whenComplete(() => _backfillAll = null);
  }

  /// Forgets what this service remembers about [trackIds] (after a
  /// playlist was deleted or moved to another folder).
  void forgetTracks(Iterable<int> trackIds) {
    for (final id in trackIds) {
      _verified.remove(id);
      _noCover.remove(id);
    }
  }

  Future<int> _runBackfillAll(bool allowNetwork) async {
    var added = 0;
    final withoutCover = <int>[];
    for (final playlist in await _db.getAllPlaylists()) {
      try {
        final cover = await ensurePlaylistCover(
          playlist,
          allowNetwork: allowNetwork,
        );
        if (cover != null) {
          added++;
        } else if (!await thumbnailFileExists(playlist.thumbnailPath)) {
          withoutCover.add(playlist.id);
        }
      } catch (e) {
        _log.warn('cover backfill failed for ${playlist.name}: $e');
      }
    }
    // Read the playlists again: one may have been deleted or moved to
    // another folder while the covers were fetched.
    for (final playlist in await _db.getAllPlaylists()) {
      try {
        added += await ensureTrackThumbnails(
          playlist,
          allowNetwork: allowNetwork,
        );
      } catch (e) {
        _log.warn('thumbnail backfill failed for ${playlist.name}: $e');
      }
    }
    for (final id in withoutCover) {
      final playlist = await _db.getPlaylistOrNull(id);
      if (playlist == null) continue;
      try {
        if (await ensurePlaylistCover(playlist) != null) added++;
      } catch (e) {
        _log.warn('cover backfill failed for ${playlist.name}: $e');
      }
    }
    return added;
  }

  /// Waits while an operation that moves or deletes playlist folders runs.
  Future<void> _waitWhilePaused() async {
    final shouldPause = _shouldPause;
    if (shouldPause == null) return;
    while (shouldPause()) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  /// Whether [folder] is still the folder of playlist [playlistId] and
  /// exists.
  Future<bool> _stillInPlace(int playlistId, String folder) async {
    final current = await _db.getPlaylistOrNull(playlistId);
    if (current == null || current.outputPath != folder) return false;
    return Directory(folder).exists();
  }

  /// Runs work for one playlist strictly one after another, so the startup
  /// backfill and a page opening the same playlist never race on its files.
  Future<T> _serialized<T>(int playlistId, Future<T> Function() action) {
    final previous = _runs[playlistId] ?? Future<void>.value();
    final current = previous.then((_) => action());
    final done = current.then<void>((_) {}, onError: (_) {});
    _runs[playlistId] = done;
    unawaited(
      done.whenComplete(() {
        if (identical(_runs[playlistId], done)) _runs.remove(playlistId);
      }),
    );
    return current;
  }

  Future<int> _ensureTrackThumbnails(
    Playlist playlist,
    bool allowNetwork,
  ) async {
    await _waitWhilePaused();
    // The caller's copy may be out of date (a format switch moves the
    // playlist to another folder).
    final fresh = await _db.getPlaylistOrNull(playlist.id);
    if (fresh == null) return 0;
    playlist = fresh;
    final folder = playlist.outputPath;
    // Never create anything inside a folder that is gone.
    if (!await Directory(folder).exists()) return 0;
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    var added = 0;
    final found = <int, String>{};
    final sinceFirstFound = Stopwatch();

    Future<void> record() async {
      if (found.isEmpty) return;
      final batch = Map.of(found);
      found.clear();
      sinceFirstFound
        ..stop()
        ..reset();
      // Only covers inside the playlist's current folder are recorded.
      final current = await _db.getPlaylistOrNull(playlist.id);
      if (current == null || current.outputPath != folder) return;
      await _db.updateTrackThumbnailPaths(batch);
      for (final entry in batch.entries) {
        _verified[entry.key] = entry.value;
        _noCover.remove(entry.key);
      }
      added += batch.length;
    }

    try {
      for (final track in tracks) {
        if (track.status != 'complete' || track.filePath == null) continue;
        final current = track.thumbnailPath;
        if (current != null && current.isNotEmpty) {
          if (_verified[track.id] == current) continue;
          if (await thumbnailFileExists(current)) {
            _verified[track.id] = current;
            continue;
          }
        }
        final triedWithNetwork = _noCover[track.id];
        if (triedWithNetwork != null && (triedWithNetwork || !allowNetwork)) {
          continue;
        }
        // This track needs work, which may write into the folder: make
        // sure the playlist is still there and not being moved.
        if (_shouldPause?.call() ?? false) {
          await record();
          await _waitWhilePaused();
        }
        if (!await _stillInPlace(playlist.id, folder)) break;
        String? cover;
        try {
          cover = await _findTrackThumbnail(playlist, track, allowNetwork);
        } catch (e) {
          _log.warn('thumbnail for "${track.title}" failed: $e');
        }
        if (cover == null) {
          _noCover[track.id] = allowNetwork;
          continue;
        }
        found[track.id] = cover;
        if (!sinceFirstFound.isRunning) sinceFirstFound.start();
        if (found.length >= _writeBatchSize ||
            sinceFirstFound.elapsed >= _writeBatchDelay) {
          await record();
        }
      }
    } finally {
      await record();
    }
    if (added > 0) await _metadata.writeMetadataFor(playlist.id);
    return added;
  }

  Future<String?> _findTrackThumbnail(
    Playlist playlist,
    Track track,
    bool allowNetwork,
  ) async {
    final folder = playlist.outputPath;
    final stem = LibraryLayout.trackThumbnailStem(
      folder,
      track.videoId,
      localFile: track.isLocalReplacement,
    );
    final existing = await _existingImage(stem);
    if (existing != null) return existing;

    final mediaPath = track.filePath!;
    if (await File(mediaPath).exists()) {
      if (!await _prepareDir(p.dirname(stem))) return null;
      final extracted = await _thumbnails.extractEmbeddedThumbnail(
        mediaPath: mediaPath,
        targetStem: stem,
      );
      if (extracted != null) return extracted;
    }

    // A local file's cover must come from the file itself, and forced
    // inserts have no YouTube video to take one from.
    if (track.isLocalReplacement ||
        track.videoId.startsWith(forcedInsertVideoIdPrefix)) {
      return null;
    }
    final url = resolveRemoteThumbnailUrl(
      thumbnailUrl: track.thumbnailUrl,
      youtubeVideoId: track.videoId,
    );
    if (url == null) return null;
    return _fetchImage(url, stem, allowNetwork: allowNetwork);
  }

  Future<String?> _ensurePlaylistCover(
    int playlistId,
    bool allowNetwork,
  ) async {
    await _waitWhilePaused();
    final playlist = await _db.getPlaylistOrNull(playlistId);
    if (playlist == null) return null;
    if (await thumbnailFileExists(playlist.thumbnailPath)) return null;
    final folder = playlist.outputPath;
    if (!await Directory(folder).exists()) return null;
    final stem = LibraryLayout.playlistCoverStem(folder);

    var cover = await _existingImage(stem);
    final url = playlist.thumbnailUrl;
    if (cover == null && url != null && url.isNotEmpty) {
      cover = await _fetchImage(url, stem, allowNetwork: allowNetwork);
    }
    if (cover == null) {
      for (final track in await _db.getTracksForPlaylist(playlist.id)) {
        final source = track.thumbnailPath;
        if (source == null || !await thumbnailFileExists(source)) continue;
        cover = await _installImage(stem, (tmp) async {
          await File(source).copy(tmp.path);
          return true;
        });
        if (cover != null) break;
      }
    }
    if (cover == null) return null;
    if (!await _stillInPlace(playlist.id, folder)) return null;
    await _db.updatePlaylistFields(
      playlist.id,
      PlaylistsCompanion(thumbnailPath: Value(cover)),
    );
    await _metadata.writeMetadataFor(playlist.id);
    return cover;
  }

  /// The image cache's copy of [url], else a download when allowed.
  Future<String?> _fetchImage(
    String url,
    String stem, {
    required bool allowNetwork,
  }) async {
    File? cached;
    try {
      cached = await _lookupCachedImage(url);
    } catch (_) {
      // No cache available; try the network instead.
    }
    if (cached != null) {
      final source = cached;
      try {
        final copied = await _installImage(stem, (tmp) async {
          await source.copy(tmp.path);
          return true;
        });
        if (copied != null) return copied;
      } catch (_) {
        // A damaged cache entry; the network may still have the image.
      }
    }
    if (!allowNetwork) return null;
    return _installImage(stem, (tmp) => _downloadImage(url, tmp));
  }

  /// Writes an image to a temporary file with [produce], then moves it to
  /// `<stem>.<ext>` with the extension of its real format. Nothing named
  /// like a cover exists until the image is complete.
  Future<String?> _installImage(
    String stem,
    Future<bool> Function(File tmp) produce,
  ) async {
    if (!await _prepareDir(p.dirname(stem))) return null;
    final tmp = File(
      '$stem.tmp.${DateTime.now().microsecondsSinceEpoch}.${_tmpCounter++}',
    );
    try {
      if (!await produce(tmp) || !await tmp.exists()) return null;
      final extension = imageExtension(await _readHeader(tmp));
      if (extension == null) return null;
      final target = '$stem$extension';
      await tmp.rename(target);
      noteThumbnailWritten(target);
      return target;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // A leftover temp file is harmless.
      }
    }
  }

  static Future<List<int>> _readHeader(File file) async {
    final raf = await file.open();
    try {
      return await raf.read(16);
    } finally {
      await raf.close();
    }
  }

  /// The extension of the image format [bytes] start with, or null when
  /// they are not a JPEG, PNG, WebP or GIF image.
  static String? imageExtension(List<int> bytes) {
    bool startsWith(List<int> magic, [int offset = 0]) {
      if (bytes.length < offset + magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[offset + i] != magic[i]) return false;
      }
      return true;
    }

    if (startsWith(const [0xFF, 0xD8, 0xFF])) return '.jpg';
    if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return '.png';
    }
    if (startsWith('RIFF'.codeUnits) && startsWith('WEBP'.codeUnits, 8)) {
      return '.webp';
    }
    if (startsWith('GIF87a'.codeUnits) || startsWith('GIF89a'.codeUnits)) {
      return '.gif';
    }
    return null;
  }

  static Future<String?> _existingImage(String stem) async {
    for (final extension in imageExtensions) {
      final path = '$stem$extension';
      if (await File(path).exists()) return path;
    }
    return null;
  }

  /// Creates the thumbnails folder with a `.nomedia` file so gallery apps
  /// do not list the covers. Returns false, creating nothing, when the
  /// playlist folder it belongs in is gone: a deleted playlist's folder must
  /// never come back.
  static Future<bool> _prepareDir(String dir) async {
    if (!await Directory(p.dirname(dir)).exists()) return false;
    try {
      await Directory(dir).create();
    } on FileSystemException {
      if (!await Directory(dir).exists()) return false;
    }
    try {
      final marker = File(p.join(dir, '.nomedia'));
      if (!await marker.exists()) await marker.create();
    } catch (_) {
      // Only hides covers from gallery apps.
    }
    return true;
  }
}
