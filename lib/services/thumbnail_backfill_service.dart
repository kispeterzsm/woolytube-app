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
/// and phones are slow.
class ThumbnailBackfillService {
  ThumbnailBackfillService(
    this._db,
    this._metadata,
    this._thumbnails,
    this._log, {
    CachedImageLookup? lookupCachedImage,
    ImageDownloader? downloadImage,
  }) : _lookupCachedImage = lookupCachedImage ?? lookupCachedNetworkImage,
       _downloadImage = downloadImage ?? downloadImageToFile;

  final AppDatabase _db;
  final MetadataService _metadata;
  final MediaThumbnailService _thumbnails;
  final LogService _log;
  final CachedImageLookup _lookupCachedImage;
  final ImageDownloader _downloadImage;

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

  Future<int> _runBackfillAll(bool allowNetwork) async {
    final playlists = await _db.getAllPlaylists();
    var added = 0;
    final withoutCover = <Playlist>[];
    for (final playlist in playlists) {
      try {
        final cover = await ensurePlaylistCover(
          playlist,
          allowNetwork: allowNetwork,
        );
        if (cover != null) {
          added++;
        } else if (existingThumbnailPath(playlist.thumbnailPath) == null) {
          withoutCover.add(playlist);
        }
      } catch (e) {
        _log.warn('cover backfill failed for ${playlist.name}: $e');
      }
    }
    for (final playlist in playlists) {
      try {
        added += await ensureTrackThumbnails(
          playlist,
          allowNetwork: allowNetwork,
        );
      } catch (e) {
        _log.warn('thumbnail backfill failed for ${playlist.name}: $e');
      }
    }
    for (final playlist in withoutCover) {
      try {
        if (await ensurePlaylistCover(playlist) != null) added++;
      } catch (e) {
        _log.warn('cover backfill failed for ${playlist.name}: $e');
      }
    }
    return added;
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
    final folder = playlist.outputPath;
    // Never create anything inside a folder that is gone.
    if (!await Directory(folder).exists()) return 0;
    final tracks = await _db.getTracksForPlaylist(playlist.id);
    var added = 0;
    for (final track in tracks) {
      if (track.status != 'complete' || track.filePath == null) continue;
      final current = track.thumbnailPath;
      if (current != null && current.isNotEmpty) {
        if (_verified[track.id] == current) continue;
        if (await File(current).exists()) {
          _verified[track.id] = current;
          continue;
        }
      }
      final triedWithNetwork = _noCover[track.id];
      if (triedWithNetwork != null && (triedWithNetwork || !allowNetwork)) {
        continue;
      }
      String? found;
      try {
        found = await _findTrackThumbnail(playlist, track, allowNetwork);
      } catch (e) {
        _log.warn('thumbnail for "${track.title}" failed: $e');
      }
      if (found == null) {
        _noCover[track.id] = allowNetwork;
        continue;
      }
      await _db.updateTrackThumbnailPath(track.id, found);
      _verified[track.id] = found;
      _noCover.remove(track.id);
      added++;
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
      await _prepareDir(p.dirname(stem));
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
    final playlist = await _db.getPlaylist(playlistId);
    if (existingThumbnailPath(playlist.thumbnailPath) != null) return null;
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
        final source = existingThumbnailPath(track.thumbnailPath);
        if (source == null) continue;
        cover = await _installImage(stem, (tmp) async {
          await File(source).copy(tmp.path);
          return true;
        });
        if (cover != null) break;
      }
    }
    if (cover == null) return null;
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
    await _prepareDir(p.dirname(stem));
    final tmp = File(
      '$stem.tmp.${DateTime.now().microsecondsSinceEpoch}.${_tmpCounter++}',
    );
    try {
      if (!await produce(tmp) || !await tmp.exists()) return null;
      final extension = imageExtension(await _readHeader(tmp));
      if (extension == null) return null;
      final target = '$stem$extension';
      await tmp.rename(target);
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
  /// do not list the covers.
  static Future<void> _prepareDir(String dir) async {
    await Directory(dir).create(recursive: true);
    try {
      final marker = File(p.join(dir, '.nomedia'));
      if (!await marker.exists()) await marker.create();
    } catch (_) {
      // Only hides covers from gallery apps.
    }
  }
}
