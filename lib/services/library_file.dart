import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/database.dart';
import 'library_layout.dart';
import 'log_service.dart';
import 'metadata_service.dart';
import 'playback_settings_store.dart';

/// One playlist in the library file: what finds it again on another phone,
/// where the database ids are different. A playlist is its URL and mode
/// (audio or video); the folder name tells two copies apart.
class LibraryPlaylistRef {
  const LibraryPlaylistRef({
    required this.url,
    required this.audioOnly,
    required this.folder,
    this.name,
  });

  factory LibraryPlaylistRef.of(Playlist playlist) => LibraryPlaylistRef(
    url: playlist.url,
    audioOnly: playlist.audioOnly,
    folder: p.basename(playlist.outputPath),
    name: playlist.name,
  );

  final String url;
  final bool audioOnly;

  /// The playlist folder's name (not its path, which differs per phone).
  final String folder;

  /// For people reading the file; not used to find the playlist.
  final String? name;

  Map<String, Object?> toJson() => {
    'url': url,
    'audioOnly': audioOnly,
    'folder': folder,
    if (name != null) 'name': name,
  };

  static LibraryPlaylistRef? fromJson(Object? value) {
    if (value is! Map) return null;
    final url = value['url'];
    if (url is! String || url.isEmpty) return null;
    final folder = value['folder'];
    final name = value['name'];
    return LibraryPlaylistRef(
      url: url,
      audioOnly: value['audioOnly'] == true,
      folder: folder is String ? folder : '',
      name: name is String ? name : null,
    );
  }

  /// Whether [playlist] is this one: the same URL and mode.
  bool matches(Playlist playlist) =>
      playlist.audioOnly == audioOnly &&
      MetadataService.samePlaylistUrl(playlist.url, url);

  bool sameFolderAs(Playlist playlist) =>
      folder.toLowerCase() == p.basename(playlist.outputPath).toLowerCase();
}

/// Where the player was, by video id instead of database ids, so it can
/// come back on another phone.
class PortableResumePoint {
  const PortableResumePoint({
    required this.playlist,
    required this.videoId,
    this.index,
    this.chapterId,
    this.positionMs = 0,
    this.whole = false,
  });

  final LibraryPlaylistRef playlist;
  final String videoId;

  /// The track's position in the playlist, which tells two entries of one
  /// video apart.
  final int? index;

  final String? chapterId;

  /// Position on the file's own timeline.
  final int positionMs;

  /// The file was playing as one piece although it has chapters.
  final bool whole;

  Map<String, Object?> toJson() => {
    'playlist': playlist.toJson(),
    'videoId': videoId,
    if (index != null) 'index': index,
    if (chapterId != null) 'chapterId': chapterId,
    'positionMs': positionMs,
    'whole': whole,
  };

  static PortableResumePoint? fromJson(Object? value) {
    if (value is! Map) return null;
    final playlist = LibraryPlaylistRef.fromJson(value['playlist']);
    final videoId = value['videoId'];
    if (playlist == null || videoId is! String || videoId.isEmpty) {
      return null;
    }
    final index = value['index'];
    final chapterId = value['chapterId'];
    final position = value['positionMs'];
    return PortableResumePoint(
      playlist: playlist,
      videoId: videoId,
      index: index is int ? index : null,
      chapterId: chapterId is String ? chapterId : null,
      positionMs: position is int && position > 0 ? position : 0,
      whole: value['whole'] == true,
    );
  }
}

/// The content of `woolytube_library.json`.
class LibraryFileData {
  const LibraryFileData({
    this.playlists = const [],
    this.resume,
    this.updatedAt,
    this.raw = const {},
  });

  /// The home page order.
  final List<LibraryPlaylistRef> playlists;

  /// Where the player was, or null.
  final PortableResumePoint? resume;

  /// When the content last changed.
  final DateTime? updatedAt;

  /// The whole file as read, with keys this app does not know.
  final Map<String, dynamic> raw;

  static LibraryFileData fromJson(Map<String, dynamic> json) {
    final list = json['playlists'];
    final updatedAt = json['updatedAt'];
    return LibraryFileData(
      playlists: [
        if (list is List)
          for (final entry in list)
            if (LibraryPlaylistRef.fromJson(entry) case final ref?) ref,
      ],
      resume: PortableResumePoint.fromJson(json['resume']),
      updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
      raw: json,
    );
  }

  /// The position of [playlist] in [playlists], or null when it is not
  /// listed.
  int? positionOf(Playlist playlist) {
    int? first;
    for (var i = 0; i < playlists.length; i++) {
      final ref = playlists[i];
      if (!ref.matches(playlist)) continue;
      if (ref.sameFolderAs(playlist)) return i;
      first ??= i;
    }
    return first;
  }
}

/// What [LibraryFileService.check] found about one library file.
class LibraryFileState {
  const LibraryFileState({
    required this.path,
    required this.upToDate,
    this.savedAt,
    this.newerFormat = false,
  });

  final String path;

  /// When its content last changed; null when there is no readable file.
  final DateTime? savedAt;

  /// It holds the library as it is now (or a newer app wrote it, and it is
  /// left alone).
  final bool upToDate;

  /// A newer app wrote it; this one leaves it alone.
  final bool newerFormat;
}

/// Keeps `woolytube_library.json` in the top folder of both library roots
/// (`Music/WoolyTube` and `Movies/WoolyTube`): what belongs to the library
/// as a whole and not to one playlist folder. That is the home page order,
/// where the player was, and (later) the labels. Copying either folder to
/// another phone takes them along, and "Import all" on a fresh install puts
/// them back.
///
/// Writes go to a temporary file renamed into place, unchanged content is
/// not rewritten, keys a newer app added are kept, and a file of a newer
/// format is not overwritten. Playlists and the "where I was" point of a
/// library that is still waiting to be restored are kept too, so a fresh
/// install never replaces what it is about to restore.
class LibraryFileService {
  LibraryFileService(
    this._db, {
    LogService? log,
    PlaybackSettingsStore? playbackStore,
    DateTime Function()? clock,
  }) : _log = log,
       _store = playbackStore ?? SharedPreferencesPlaybackSettingsStore(),
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final LogService? _log;
  final PlaybackSettingsStore _store;
  final DateTime Function() _clock;

  static const fileName = 'woolytube_library.json';

  /// The format this app writes. A file of a newer format is left alone.
  static const fileVersion = 1;

  /// Where the file lives: the top folder of the audio and the video
  /// library.
  static List<String> get roots => [
    LibraryLayout.audioBasePath,
    LibraryLayout.videoBasePath,
  ];

  static String pathIn(String folder) => p.join(folder, fileName);

  /// The keys [build] writes; everything else in the file is kept as it is.
  /// `labels` belongs to the labels, which a later app version fills in.
  static const _ownKeys = {
    'app',
    'version',
    'updatedAt',
    'playlists',
    'resume',
  };

  /// The newest library file: the one in [folder] (a copied backup the
  /// owner picked) when it has one, else the more recent one of the two
  /// library roots. Null when there is none or none can be read.
  Future<LibraryFileData?> read({String? folder}) async {
    if (folder != null) {
      final picked = await _readFile(pathIn(folder));
      if (picked != null) return picked;
    }
    LibraryFileData? newest;
    for (final root in roots) {
      final data = await _readFile(pathIn(root));
      if (data == null) continue;
      if (newest == null) {
        newest = data;
        continue;
      }
      final a = newest.updatedAt;
      final b = data.updatedAt;
      if (b != null && (a == null || b.isAfter(a))) newest = data;
    }
    return newest;
  }

  static Future<LibraryFileData?> _readFile(String path) async {
    final json = await _readJson(path);
    return json == null ? null : LibraryFileData.fromJson(json);
  }

  static Future<Map<String, dynamic>?> _readJson(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static int _versionOf(Map<String, dynamic> json) {
    final version = json['version'];
    return version is int ? version : 0;
  }

  // ---------------------------------------------------------------------
  // Writing

  int _holds = 0;
  bool _heldBack = false;
  Future<int>? _writing;

  /// The content (without `updatedAt`) this run last wrote or found on
  /// disk, by file path.
  final _writtenBodies = <String, String>{};

  /// Versions of files of a newer format already reported.
  final _reportedNewer = <String>{};

  /// Runs [action] (a restore) without the file being written meanwhile:
  /// a half-restored library must not replace the order being restored.
  /// The file is written afterwards if something asked for it.
  Future<T> holdWrites<T>(Future<T> Function() action) async {
    _holds++;
    try {
      // A write already under way finishes first, from the library as it
      // was before the restore.
      final underWay = _writing;
      if (underWay != null) {
        await underWay.then<void>((_) {}, onError: (Object _) {});
      }
      return await action();
    } finally {
      _holds--;
      if (_holds == 0 && _heldBack) {
        _heldBack = false;
        unawaited(
          write().then<void>(
            (_) {},
            onError:
                (Object e) => _log?.warn('Could not save the library file: $e'),
          ),
        );
      }
    }
  }

  /// Writes the library file into both library roots and returns how many
  /// files changed. `Music/WoolyTube` is created when missing;
  /// `Movies/WoolyTube` only gets the file when it exists. Writes run one
  /// after another.
  Future<int> write() {
    if (_holds > 0) {
      _heldBack = true;
      return Future.value(0);
    }
    final previous = _writing;
    final next =
        previous == null
            ? _writeNow()
            : previous.then(
              (_) => _writeNow(),
              onError: (Object _) => _writeNow(),
            );
    _writing = next;
    next.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_writing, next)) _writing = null;
    });
    return next;
  }

  Future<int> _writeNow() async {
    if (_holds > 0) {
      // A restore started while this write waited its turn.
      _heldBack = true;
      return 0;
    }
    final existing = await read();
    final body = await build(existing: existing);
    final bodyText = _encode(body);
    // Nothing worth a file yet (a new library): no folder is made for it.
    final empty = _isEmpty(body);
    var written = 0;
    for (final root in roots) {
      final dir = Directory(root);
      final isAudioRoot = root == LibraryLayout.audioBasePath;
      if (!isAudioRoot && !await dir.exists()) continue;
      final path = pathIn(root);
      final file = File(path);
      if (_writtenBodies[path] == bodyText && await file.exists()) continue;
      final onDisk = await _readJson(path);
      if (onDisk != null) {
        final version = _versionOf(onDisk);
        if (version > fileVersion) {
          if (_reportedNewer.add(path)) {
            _log?.info(
              'Kept $path: a newer app wrote it (format $version, this '
              'app knows $fileVersion).',
            );
          }
          continue;
        }
        if (_encode(Map.of(onDisk)..remove('updatedAt')) == bodyText) {
          _writtenBodies[path] = bodyText;
          continue;
        }
      } else if (empty && !await file.exists()) {
        continue;
      }
      if (!await dir.exists()) await dir.create(recursive: true);
      final content = _encode({
        ...body,
        'updatedAt': _clock().toUtc().toIso8601String(),
      });
      final tmp = File('$path.partial');
      try {
        await tmp.writeAsString(content, flush: true);
        await tmp.rename(path);
      } catch (_) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {
          // Replaced by the next write.
        }
        rethrow;
      }
      _writtenBodies[path] = bodyText;
      written++;
    }
    return written;
  }

  /// The keys of [build] for an empty library: app, version, playlists
  /// and labels.
  static const _emptyBodyKeys = 4;

  static bool _isEmpty(Map<String, dynamic> body) {
    final labels = body['labels'];
    return (body['playlists'] as List).isEmpty &&
        body['resume'] == null &&
        labels is List &&
        labels.isEmpty &&
        body.length == _emptyBodyKeys;
  }

  /// The library file in each library root, without writing anything:
  /// when it was saved and whether it holds the library as it is now. A
  /// root that gets no file (the video root when it does not exist, or
  /// any root while the library has nothing to keep) is left out.
  ///
  /// The "where I was" point is not compared: while something plays it is
  /// saved only every half minute, which is not a missing backup.
  Future<List<LibraryFileState>> check() async {
    final body = await build(existing: await read());
    final empty = _isEmpty(body);
    String withoutResume(Map<String, dynamic> json) => _encode(
      Map.of(json)
        ..remove('updatedAt')
        ..remove('resume'),
    );
    final expected = withoutResume(body);
    final states = <LibraryFileState>[];
    for (final root in roots) {
      if (root != LibraryLayout.audioBasePath &&
          !await Directory(root).exists()) {
        continue;
      }
      final path = pathIn(root);
      final onDisk = await _readJson(path);
      if (onDisk == null) {
        if (empty && !await File(path).exists()) continue;
        states.add(LibraryFileState(path: path, upToDate: false));
        continue;
      }
      final newer = _versionOf(onDisk) > fileVersion;
      final updatedAt = onDisk['updatedAt'];
      var savedAt =
          updatedAt is String ? DateTime.tryParse(updatedAt)?.toLocal() : null;
      try {
        savedAt ??= await File(path).lastModified();
      } catch (_) {
        // Shown without a time.
      }
      states.add(
        LibraryFileState(
          path: path,
          savedAt: savedAt,
          upToDate: newer || withoutResume(onDisk) == expected,
          newerFormat: newer,
        ),
      );
    }
    return states;
  }

  static String _encode(Map<String, dynamic> json) =>
      const JsonEncoder.withIndent('  ').convert(json);

  /// What the file holds now, without `updatedAt`: the database's home page
  /// order and the player's "where I was" point, merged with [existing].
  ///
  /// From [existing], keys this app does not know are kept, and so are
  /// playlists not in the database whose folder is still there (a copied
  /// library waiting to be restored, or a folder whose import was
  /// dismissed), each after the playlist it followed. Its "where I was"
  /// point is kept while the player has none and its playlist is not in
  /// the database.
  Future<Map<String, dynamic>> build({LibraryFileData? existing}) async {
    final playlists = await _db.getAllPlaylists();
    final order = [for (final pl in playlists) LibraryPlaylistRef.of(pl)];
    if (existing != null && existing.playlists.isNotEmpty) {
      await _keepWaitingPlaylists(order, playlists, existing.playlists);
    }

    PortableResumePoint? resume;
    PlaybackSession? session;
    try {
      session = (await _store.load()).session;
    } catch (_) {
      session = null;
    }
    if (session != null) {
      resume = await _portable(session);
    } else {
      final kept = existing?.resume;
      if (kept != null && !playlists.any(kept.playlist.matches)) {
        resume = kept;
      }
    }

    final raw = existing?.raw ?? const <String, dynamic>{};
    return {
      'app': 'WoolyTube',
      'version': fileVersion,
      'playlists': [for (final ref in order) ref.toJson()],
      if (resume != null) 'resume': resume.toJson(),
      // Filled by the labels; kept as a newer app wrote them.
      'labels': raw['labels'] ?? const <Object?>[],
      for (final entry in raw.entries)
        if (!_ownKeys.contains(entry.key) && entry.key != 'labels')
          entry.key: entry.value,
    };
  }

  Future<void> _keepWaitingPlaylists(
    List<LibraryPlaylistRef> order,
    List<Playlist> inDatabase,
    List<LibraryPlaylistRef> previous,
  ) async {
    // Insert after the entry that came before it in the previous file.
    var insertAt = 0;
    for (final ref in previous) {
      final match = inDatabase.where(ref.matches).firstOrNull;
      if (match != null) {
        final at = order.indexWhere((o) => o.matches(match));
        if (at >= 0) insertAt = at + 1;
        continue;
      }
      if (ref.folder.isEmpty) continue;
      final folder = p.join(
        LibraryLayout.basePathFor(audioOnly: ref.audioOnly),
        ref.folder,
      );
      if (!await File(p.join(folder, MetadataService.metaFileName)).exists()) {
        continue;
      }
      if (order.any(
        (o) =>
            o.audioOnly == ref.audioOnly &&
            MetadataService.samePlaylistUrl(o.url, ref.url),
      )) {
        continue;
      }
      order.insert(insertAt.clamp(0, order.length), ref);
      insertAt++;
    }
  }

  Future<PortableResumePoint?> _portable(PlaybackSession session) async {
    final playlist = await _db.getPlaylistOrNull(session.playlistId);
    if (playlist == null) return null;
    final track = await _db.getTrack(session.trackId);
    if (track == null || track.playlistId != playlist.id) return null;
    return PortableResumePoint(
      playlist: LibraryPlaylistRef.of(playlist),
      videoId: track.videoId,
      index: track.index,
      chapterId: session.chapterId,
      positionMs: session.positionMs,
      whole: session.whole,
    );
  }

  // ---------------------------------------------------------------------
  // Restoring

  /// Puts the playlists [placed] (just imported) where [file] had them in
  /// the home page order. The other playlists keep their order: each placed
  /// one goes after the nearest playlist that came before it in [file]
  /// (or before the nearest that came after it). Placed playlists the file
  /// does not list stay at the end. Returns how many were placed by the
  /// file.
  Future<int> applyOrder(LibraryFileData file, Set<int> placed) async {
    if (placed.isEmpty || file.playlists.isEmpty) return 0;
    final playlists = await _db.getAllPlaylists();
    final position = <int, int>{};
    for (final playlist in playlists) {
      final at = file.positionOf(playlist);
      if (at != null) position[playlist.id] = at;
    }
    final result = [
      for (final pl in playlists)
        if (!placed.contains(pl.id)) pl.id,
    ];
    final moving =
        playlists
            .where((pl) => placed.contains(pl.id) && position[pl.id] != null)
            .toList()
          ..sort((a, b) => position[a.id]!.compareTo(position[b.id]!));
    for (final playlist in moving) {
      final at = position[playlist.id]!;
      // The nearest listed before it, else the nearest listed after it.
      int? after;
      int? before;
      for (var i = 0; i < result.length; i++) {
        final other = position[result[i]];
        if (other == null) continue;
        if (other < at && (after == null || other > position[result[after]]!)) {
          after = i;
        }
        if (other > at &&
            (before == null || other < position[result[before]]!)) {
          before = i;
        }
      }
      final insertAt = after != null ? after + 1 : (before ?? result.length);
      result.insert(insertAt, playlist.id);
    }
    for (final playlist in playlists) {
      if (placed.contains(playlist.id) && position[playlist.id] == null) {
        result.add(playlist.id);
      }
    }
    await _db.setPlaylistOrder(result);
    return moving.length;
  }

  /// Makes [file]'s "where I was" point the player's, when its playlist and
  /// track are in the library. Returns whether it did.
  Future<bool> restoreResumePoint(LibraryFileData file) async {
    final resume = file.resume;
    if (resume == null) return false;
    final playlists = await _db.getAllPlaylists();
    final candidates = playlists.where(resume.playlist.matches).toList();
    final playlist =
        candidates.where(resume.playlist.sameFolderAs).firstOrNull ??
        candidates.firstOrNull;
    if (playlist == null) return false;
    final tracks = [
      for (final track in await _db.getTracksForPlaylist(playlist.id))
        if (track.videoId == resume.videoId) track,
    ];
    final track =
        tracks.where((t) => t.index == resume.index).firstOrNull ??
        tracks.firstOrNull;
    if (track == null) return false;
    await _store.saveSession(
      PlaybackSession(
        playlistId: playlist.id,
        trackId: track.id,
        chapterId: resume.chapterId,
        positionMs: resume.positionMs,
        whole: resume.whole,
      ),
    );
    return true;
  }
}
