import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:media_kit/media_kit.dart' hide Track, Playlist;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';
import 'audio_focus_controller.dart';
import 'chapter_playback.dart';
import 'chapters.dart';
import 'playback_notification_controller.dart';
import 'picture_in_picture_service.dart';
import 'sleep_timer_controller.dart';
import 'sponsorblock_service.dart';

class SegmentMarkResult {
  final bool started;
  final bool saved;
  final Duration? start;
  final Duration? end;
  final String? error;

  const SegmentMarkResult._({
    required this.started,
    required this.saved,
    this.start,
    this.end,
    this.error,
  });

  const SegmentMarkResult.started(Duration start)
    : this._(started: true, saved: false, start: start);

  const SegmentMarkResult.saved(Duration start, Duration end)
    : this._(started: false, saved: true, start: start, end: end);

  const SegmentMarkResult.error(String error)
    : this._(started: false, saved: false, error: error);
}

class _SkipSegment {
  final int startMs;
  final int endMs;

  const _SkipSegment(this.startMs, this.endMs);
}

class PlaybackSponsorBlockSegment {
  final int id;
  final String source;
  final String category;
  final String label;
  final int colorValue;
  final SponsorBlockCategoryAction action;
  final String actionType;
  final int startMs;
  final int endMs;

  const PlaybackSponsorBlockSegment({
    required this.id,
    required this.source,
    required this.category,
    required this.label,
    required this.colorValue,
    required this.action,
    required this.actionType,
    required this.startMs,
    required this.endMs,
  });

  bool get shouldSkip =>
      action == SponsorBlockCategoryAction.autoSkip && actionType == 'skip';
}

/// A track that has a completed local file and can be opened by the player.
bool isTrackPlayable(Track track) =>
    track.status == 'complete' && track.filePath != null;

/// Automatic playback honors the per-track always-skip preference. Explicit
/// selections can opt a single track back in through [playableTracksForPlayback].
bool isTrackAutomaticallyPlayable(Track track) =>
    isTrackPlayable(track) && !track.alwaysSkip;

/// Filters a playlist for playback. [directlySelectedTrackId] deliberately
/// keeps that one always-skipped track, because tapping a track is an explicit
/// request to play it.
List<Track> playableTracksForPlayback(
  List<Track> tracks, {
  int? directlySelectedTrackId,
}) =>
    tracks
        .where(
          (track) =>
              isTrackPlayable(track) &&
              (!track.alwaysSkip || track.id == directlySelectedTrackId),
        )
        .toList();

class PlaybackService
    implements
        PlaybackNotificationController,
        PictureInPicturePlaybackController {
  late final Player _player;
  late final SleepTimerController _sleepTimer;
  final AppDatabase _db;
  late final AlbumPlaybackQueue _albumQueue;
  final _currentItem = BehaviorSubject<PlaybackItem?>.seeded(null);
  final _position = BehaviorSubject<Duration>.seeded(Duration.zero);
  final _duration = BehaviorSubject<Duration>.seeded(Duration.zero);
  final _messages = StreamController<String>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _playbackTransition = Future.value();
  bool _loading = false;
  bool _completionHandled = false;
  bool _completionAdvancePending = false;
  bool _chapterEditing = false;
  int _generation = 0;
  int? _loadedTrackId;

  /// The on-disk file of the current item, resolved once per load so video
  /// detection does not rescan the directory on every emission.
  String? _currentFilePath;

  PlaybackItem? get currentItem => _currentItem.value;

  /// Short, user-facing notices about playback problems, such as a missing
  /// file or denied audio focus. The UI shows them as transient messages.
  Stream<String> get messages => _messages.stream;

  void reportMessage(String message) {
    if (!_messages.isClosed) _messages.add(message);
  }

  @override
  String? get currentMediaId => currentItem?.id;
  Stream<PlaybackItem?> get currentItemStream => _currentItem.stream;
  Duration get sourcePosition =>
      _loadedTrackId == null ? Duration.zero : _player.state.position;
  Duration get sourceDuration =>
      _loadedTrackId == null ? Duration.zero : _player.state.duration;
  AudioFocusController? _audioFocusController;

  // VideoController is lazy — only created when video playback is needed.
  // Attaching it eagerly causes Android to create a GL surface that gets
  // destroyed on background, which makes libmpv restart the file.
  VideoController? _videoController;
  VideoController get videoController {
    _videoController ??= VideoController(_player);
    return _videoController!;
  }

  bool get hasVideoController => _videoController != null;

  // State subjects
  final _currentTrack = BehaviorSubject<Track?>.seeded(null);
  final _currentPlaylist = BehaviorSubject<Playlist?>.seeded(null);
  final _queue = BehaviorSubject<List<Track>>.seeded([]);
  final _upNextQueue = BehaviorSubject<List<Track>>.seeded([]);
  final _queueIndex = BehaviorSubject<int>.seeded(0);
  final _shuffleEnabled = BehaviorSubject<bool>.seeded(false);
  final _autoplayEnabled = BehaviorSubject<bool>.seeded(true);
  final _audioOnlyMode = BehaviorSubject<bool>.seeded(false);
  final _pendingSegmentMarkStart = BehaviorSubject<Duration?>.seeded(null);
  final _sponsorBlockSegments =
      BehaviorSubject<List<PlaybackSponsorBlockSegment>>.seeded([]);

  // Streams
  @override
  Stream<Track?> get currentTrackStream => _currentTrack.stream;
  Stream<Playlist?> get currentPlaylistStream => _currentPlaylist.stream;
  Stream<List<Track>> get queueStream => _queue.stream;
  Stream<List<Track>> get upNextQueueStream => _upNextQueue.stream;
  Stream<int> get queueIndexStream => _queueIndex.stream;
  @override
  Stream<bool> get shuffleEnabledStream => _shuffleEnabled.stream;
  Stream<bool> get autoplayEnabledStream => _autoplayEnabled.stream;
  Stream<bool> get audioOnlyModeStream => _audioOnlyMode.stream;
  Stream<Duration?> get pendingSegmentMarkStartStream =>
      _pendingSegmentMarkStart.stream;
  Stream<List<PlaybackSponsorBlockSegment>> get sponsorBlockSegmentsStream =>
      _sponsorBlockSegments.stream;
  Stream<Duration?> get sleepTimerRemainingStream =>
      _sleepTimer.remainingStream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<bool> get isPlayingStream => _player.stream.playing;
  Stream<List<SubtitleTrack>> get subtitleTracksStream async* {
    yield _player.state.tracks.subtitle;
    yield* _player.stream.tracks.map((tracks) => tracks.subtitle);
  }

  Stream<SubtitleTrack> get selectedSubtitleTrackStream async* {
    yield _player.state.track.subtitle;
    yield* _player.stream.track.map((track) => track.subtitle);
  }

  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _player.setSubtitleTrack(track);

  Stream<bool> get isCompletedStream => _player.stream.completed;
  Stream<int?> get videoWidthStream => _player.stream.width;
  Stream<int?> get videoHeightStream => _player.stream.height;
  @override
  Stream<double?> get videoAspectStream => Rx.combineLatest2(
    _player.stream.width,
    _player.stream.height,
    (int? w, int? h) =>
        (w != null && h != null && w > 0 && h > 0) ? w / h : null,
  );

  // Current values
  @override
  Track? get currentTrack => _currentTrack.value;
  Playlist? get currentPlaylist => _currentPlaylist.value;
  List<Track> get queue => _queue.value;
  List<Track> get upNextQueue => _upNextQueue.value;
  int get queueIndex => _queueIndex.value;
  @override
  bool get shuffleEnabled => _shuffleEnabled.value;
  bool get autoplayEnabled => _autoplayEnabled.value;
  @override
  bool get audioOnlyMode => _audioOnlyMode.value;
  Duration? get pendingSegmentMarkStart => _pendingSegmentMarkStart.value;
  List<PlaybackSponsorBlockSegment> get sponsorBlockSegments =>
      _sponsorBlockSegments.value;
  @override
  bool get isPlaying => _player.state.playing;
  @override
  Duration get position => _position.value;
  Duration get duration => _duration.value;
  Duration? get sleepTimerRemaining => _sleepTimer.remaining;

  Future<void> _videoTrackTransition = Future.value();
  List<_SkipSegment> _activeSegments = [];
  bool _isSeekingPastSegment = false;

  PlaybackService(this._db, {Random? random, Player? player}) {
    _player = player ?? Player();
    _albumQueue = AlbumPlaybackQueue(random: random);
    // Route the sleep timer through the transition chain so a track change
    // that is in flight when the timer fires cannot swallow the pause.
    _sleepTimer = SleepTimerController(onElapsed: () => _transition(pause));
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed && !_loading && !_chapterEditing && !_completionHandled) {
          _completionHandled = true;
          final generation = _generation;
          final completedId = currentMediaId;
          _completionAdvancePending = true;
          unawaited(
            _transition(() async {
              _completionAdvancePending = false;
              if (generation != _generation || currentMediaId != completedId) {
                return;
              }
              if (autoplayEnabled) await _advance();
            }),
          );
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (_loading) return;
        _position.add(currentItem?.relativePosition(position) ?? position);
        unawaited(_maybeSkipSponsorBlockSegment(position));
      }),
    );
    _subscriptions.add(
      _player.stream.duration.listen((duration) {
        if (!_loading) {
          _duration.add(currentItem?.chapter?.duration ?? duration);
        }
      }),
    );
  }

  Future<void> _transition(Future<void> Function() action) {
    final next = _playbackTransition.then((_) => action());
    _playbackTransition = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  void _publishQueue() {
    _queue.add(_albumQueue.items.map((i) => i.displayTrack).toList());
    _queueIndex.add(_albumQueue.index);
    _upNextQueue.add(
      _albumQueue.queued
          .map(
            (g) =>
                g.items.length > 1
                    ? g.items.first.track
                    : g.items.first.displayTrack,
          )
          .toList(),
    );
  }

  Future<void> initializeAudioFocus({
    required bool pauseOnAudioInterruption,
    PlaybackAudioSession? audioSession,
  }) async {
    final controller = AudioFocusController(
      session: audioSession ?? await PlatformPlaybackAudioSession.create(),
      // The controller decides whether focus is kept (transient loss) or
      // abandoned, so it pauses the player directly instead of via pause().
      pausePlayback: () => _player.pause(),
      resumePlayback: resume,
      isPlaying: () => isPlaying,
    );
    await controller.initialize(enabled: pauseOnAudioInterruption);
    _audioFocusController = controller;
  }

  Future<void> setPauseOnAudioInterruption(bool enabled) async {
    await _audioFocusController?.setEnabled(enabled);
  }

  /// Resolve stored file path (without extension) to actual file on disk
  String? resolveFilePath(String storedPath) {
    // First try the stored path directly (in case it already has extension)
    if (File(storedPath).existsSync()) return storedPath;

    // Scan directory for matching file by full basename
    final dir = Directory(p.dirname(storedPath));
    final baseName = p.basename(storedPath);
    if (!dir.existsSync()) return null;

    for (final entity in dir.listSync()) {
      if (entity is File &&
          p.basenameWithoutExtension(entity.path) == baseName) {
        return entity.path;
      }
    }

    // Fallback: match by index prefix (handles title mismatch from yt-dlp)
    final indexPrefixMatch = RegExp(r'^\d{3}[_ -]').firstMatch(baseName);
    if (indexPrefixMatch != null) {
      final prefix = indexPrefixMatch.group(0)!;
      const mediaExtensions = {
        '.m4a',
        '.mp3',
        '.opus',
        '.ogg',
        '.flac',
        '.wav',
        '.mp4',
        '.mkv',
        '.webm',
        '.avi',
        '.mov',
      };
      for (final entity in dir.listSync()) {
        if (entity is File) {
          final fileName = p.basename(entity.path);
          final ext = p.extension(entity.path).toLowerCase();
          if (fileName.startsWith(prefix) && mediaExtensions.contains(ext)) {
            return entity.path;
          }
        }
      }
    }

    return null;
  }

  /// Whether the resolved file is a video format
  bool _isVideoFile(String? filePath) {
    if (filePath == null) return false;
    final ext = p.extension(filePath).toLowerCase();
    return ['.mp4', '.mkv', '.webm', '.avi', '.mov'].contains(ext);
  }

  String? _resolveTrackFile(Track track) =>
      track.filePath == null ? null : resolveFilePath(track.filePath!);

  bool _isVideoTrack(Track? track, bool audioOnly) {
    if (track == null || audioOnly) return false;
    return _isVideoFile(_currentFilePath ?? _resolveTrackFile(track));
  }

  /// Whether the current track is a video file (not audio-only)
  @override
  bool get isVideoContent =>
      _isVideoTrack(_currentTrack.value, _audioOnlyMode.value);

  @override
  Stream<bool> get isVideoContentStream => Rx.combineLatest2(
    _currentTrack.stream,
    _audioOnlyMode.stream,
    _isVideoTrack,
  );

  @override
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
    String? chapterId,
    bool whole = false,
  }) => _transition(() async {
    final playable = playableTracksForPlayback(
      allTracks,
      directlySelectedTrackId: track.id,
    );
    await _startQueue(
      playable,
      trackId: track.id,
      chapterId: chapterId,
      whole: whole,
    );
  });

  Future<void> playAll(List<Track> tracks, {Playlist? playlist}) =>
      _transition(() async {
        await _startQueue(playableTracksForPlayback(tracks));
      });

  Future<void> _startQueue(
    List<Track> tracks, {
    int? trackId,
    String? chapterId,
    bool whole = false,
  }) async {
    final groups = await _buildAlbums(
      tracks,
      trackId: trackId,
      chapterId: chapterId,
      whole: whole,
    );
    if (groups.isEmpty) {
      reportMessage('Nothing to play');
      return;
    }
    // Validate the explicitly selected file and take audio focus before the
    // live queue is replaced, so a failure leaves current playback untouched.
    PlaybackAlbum? selectedAlbum;
    String? selectedPath;
    if (trackId != null) {
      selectedAlbum = groups.where((g) => g.trackId == trackId).firstOrNull;
    }
    if (selectedAlbum != null) {
      final selectedTrack = selectedAlbum.items.first.track;
      selectedPath = _resolveTrackFile(selectedTrack);
      if (selectedPath == null) {
        reportMessage('File not found: ${selectedTrack.title}');
        return;
      }
    }
    if (!await _requestFocus()) return;
    final selected = _albumQueue.start(
      groups,
      trackId: trackId,
      chapterId: chapterId,
      shuffled: shuffleEnabled,
    );
    _publishQueue();
    if (selected == null) return;
    final filePath =
        selected.track.id == selectedAlbum?.trackId
            ? selectedPath
            : _resolveTrackFile(selected.track);
    if (filePath == null) {
      _reportSkippedFiles([selected.track.title]);
      await _advance();
      return;
    }
    await _loadAndPlay(selected, filePath: filePath);
  }

  /// Builds the playback groups for [tracks] from fresh database rows, reading
  /// each distinct playlist once instead of one query per track.
  Future<List<PlaybackAlbum>> _buildAlbums(
    List<Track> tracks, {
    int? trackId,
    String? chapterId,
    bool whole = false,
  }) async {
    final playlists = <int, Playlist>{};
    final freshTracks = <int, Track>{};
    for (final playlistId in tracks.map((t) => t.playlistId).toSet()) {
      try {
        playlists[playlistId] = await _db.getPlaylist(playlistId);
      } catch (_) {
        continue;
      }
      for (final fresh in await _db.getTracksForPlaylist(playlistId)) {
        freshTracks[fresh.id] = fresh;
      }
    }
    final groups = <PlaybackAlbum>[];
    for (final track in tracks) {
      final fresh = freshTracks[track.id];
      final playlist = playlists[track.playlistId];
      if (fresh == null || playlist == null || !isTrackPlayable(fresh)) {
        continue;
      }
      var items = chapterPlaybackItems(
        fresh,
        playlist,
        whole: whole && track.id == trackId,
      );
      if (chapterId != null && track.id == trackId) {
        items =
            ChapterData.decode(
              fresh.chaptersJson,
            ).active.map((c) => PlaybackItem(fresh, c)).toList();
        if (!items.any((i) => i.chapter?.id == chapterId)) return const [];
      }
      groups.add(PlaybackAlbum(items));
    }
    return groups;
  }

  Future<bool> _requestFocus() async {
    final controller = _audioFocusController;
    if (controller == null || await controller.requestFocus()) return true;
    reportMessage('Another app is using audio');
    return false;
  }

  void _reportSkippedFiles(List<String> titles) {
    if (titles.isEmpty) return;
    reportMessage(
      titles.length == 1
          ? 'Skipped "${titles.single}": file not found'
          : 'Skipped ${titles.length} tracks: files not found',
    );
  }

  Future<bool> addToUpNextQueue(Track track, {String? chapterId}) async {
    final fresh = await _db.getTrack(track.id);
    if (fresh == null || !isTrackAutomaticallyPlayable(fresh)) return false;
    final playlist = await _db.getPlaylist(fresh.playlistId);
    var items = chapterPlaybackItems(fresh, playlist);
    if (chapterId != null) {
      items =
          ChapterData.decode(fresh.chaptersJson).active
              .where((c) => c.id == chapterId)
              .map((c) => PlaybackItem(fresh, c))
              .toList();
    }
    if (items.isEmpty) return false;
    _albumQueue.enqueue(PlaybackAlbum(items));
    _publishQueue();
    return true;
  }

  Future<bool> startUpNextQueueIfIdle() async {
    if (currentTrack != null) return false;
    var started = false;
    await _transition(() async {
      if (currentTrack == null) started = await _advance();
    });
    return started;
  }

  void removeUpNextQueueAt(int index) {
    _albumQueue.removeQueued(index);
    _publishQueue();
  }

  void clearUpNextQueue() {
    _albumQueue.clearQueued();
    _publishQueue();
  }

  Future<void> setAlwaysSkip(Track track, bool alwaysSkip) async {
    await _db.updateTrackAlwaysSkip(track.id, alwaysSkip);
    if (currentTrack?.id == track.id) {
      _currentTrack.add(currentTrack!.copyWith(alwaysSkip: alwaysSkip));
    }
  }

  Future<bool> _advance({bool forward = true, bool skipFile = false}) async {
    var item =
        skipFile
            ? _albumQueue.nextFile()
            : forward
            ? _albumQueue.next()
            : _albumQueue.previous();
    final missingFiles = <String>[];
    while (item != null) {
      final candidate = await _freshPlaybackItem(item);
      if (candidate != null) {
        final filePath = _resolveTrackFile(candidate.track);
        if (filePath != null) {
          _publishQueue();
          _reportSkippedFiles(missingFiles);
          return await _loadAndPlay(candidate, filePath: filePath);
        }
        missingFiles.add(candidate.track.title);
      }
      item = forward ? _albumQueue.next() : _albumQueue.previous();
    }
    _publishQueue();
    _reportSkippedFiles(missingFiles);
    return false;
  }

  /// Re-reads a queued item from the database. Returns null when the track is
  /// no longer automatically playable, its file was replaced, or its chapter
  /// no longer exists; otherwise the item carries the chapter's current bounds
  /// rather than the ones captured when the queue was built.
  Future<PlaybackItem?> _freshPlaybackItem(PlaybackItem item) async {
    final fresh = await _db.getTrack(item.track.id);
    if (fresh == null ||
        !isTrackAutomaticallyPlayable(fresh) ||
        fresh.filePath != item.track.filePath ||
        fresh.downloadedAt != item.track.downloadedAt) {
      return null;
    }
    final queuedChapter = item.chapter;
    if (queuedChapter == null) return PlaybackItem(fresh);
    final chapter =
        ChapterData.decode(
          fresh.chaptersJson,
        ).active.where((c) => c.id == queuedChapter.id).firstOrNull;
    return chapter == null ? null : PlaybackItem(fresh, chapter);
  }

  /// Opens [item] from the already resolved [filePath]. Audio focus is taken
  /// before anything is published, so a denied request leaves the previous
  /// item and its media untouched. Returns whether the file was opened.
  Future<bool> _loadAndPlay(
    PlaybackItem item, {
    required String filePath,
  }) async {
    if (!await _requestFocus()) return false;
    _loading = true;
    _loadedTrackId = null;
    _currentFilePath = filePath;
    _generation++;
    _chapterEditing = false;
    _completionHandled = false;
    _isSeekingPastSegment = false;
    _currentItem.add(item);
    _currentTrack.add(item.displayTrack);
    _position.add(Duration.zero);
    _duration.add(item.duration ?? Duration.zero);
    try {
      await _player.pause();
      await _loadActiveSegments(item.track);
      await _player.open(
        Media(
          Uri.file(filePath).toString(),
          start:
              item.chapter == null
                  ? null
                  : Duration(milliseconds: item.startMs),
          end:
              item.chapter == null
                  ? null
                  : Duration(milliseconds: item.chapter!.endMs),
        ),
      );
      _loadedTrackId = item.track.id;
    } catch (_) {
      // The previous media must not stay resumable under this item's name.
      _currentFilePath = null;
      try {
        await _player.stop();
      } catch (_) {}
      await _audioFocusController?.abandonFocus();
      reportMessage('Could not open "${item.track.title}"');
    } finally {
      _loading = false;
      _duration.add(
        _loadedTrackId == null
            ? Duration.zero
            : item.chapter?.duration ?? _player.state.duration,
      );
      _position.add(item.relativePosition(sourcePosition));
    }
    return _loadedTrackId != null;
  }

  Future<void> beginChapterEditing(Track track) async {
    await playTrack(track, [track], whole: true);
    if (_loadedTrackId != track.id) {
      throw StateError('The local media file could not be opened.');
    }
    _chapterEditing = true;
  }

  void endChapterEditing() => _chapterEditing = false;

  Future<void> refreshCurrentSegments() async {
    final track = _currentTrack.value;
    if (track != null) {
      await _loadActiveSegments(track);
    }
  }

  Future<void> _loadActiveSegments(Track track) async {
    _pendingSegmentMarkStart.add(null);
    final playlist = await _playlistForTrack(track);
    if (playlist == null || !playlist.sponsorBlockEnabled) {
      _activeSegments = [];
      _sponsorBlockSegments.add([]);
      return;
    }

    final categoryActions = decodeSponsorBlockCategoryActions(
      playlist.sponsorBlockCategoryActions,
      legacyCategories: playlist.sponsorBlockCategories,
    );

    final segments = await _db.getSegmentsForTrack(track.id);
    final visible =
        segments
            .where((segment) {
              if (!isSponsorBlockCategory(segment.category)) return false;
              if (segment.source == 'hidden') return false;
              if (segment.source == 'sponsorblock' &&
                  track.isLocalReplacement) {
                return false;
              }
              final action =
                  categoryActions[segment.category] ??
                  SponsorBlockCategoryAction.disabled;
              if (action == SponsorBlockCategoryAction.disabled) return false;
              return segment.endMs > segment.startMs;
            })
            .map((segment) {
              final definition = sponsorBlockCategoryDefinition(
                segment.category,
              );
              return PlaybackSponsorBlockSegment(
                id: segment.id,
                source: segment.source,
                category: segment.category,
                label: definition.label,
                colorValue: definition.colorValue,
                action:
                    categoryActions[segment.category] ??
                    SponsorBlockCategoryAction.disabled,
                actionType: segment.actionType,
                startMs: segment.startMs,
                endMs: segment.endMs,
              );
            })
            .toList()
          ..sort((a, b) => a.startMs.compareTo(b.startMs));

    final chapter = currentItem?.chapter;
    _sponsorBlockSegments.add(
      chapter == null
          ? visible
          : visible
              .where(
                (s) => s.endMs > chapter.startMs && s.startMs < chapter.endMs,
              )
              .map(
                (s) => PlaybackSponsorBlockSegment(
                  id: s.id,
                  source: s.source,
                  category: s.category,
                  label: s.label,
                  colorValue: s.colorValue,
                  action: s.action,
                  actionType: s.actionType,
                  startMs: max(s.startMs, chapter.startMs) - chapter.startMs,
                  endMs: min(s.endMs, chapter.endMs) - chapter.startMs,
                ),
              )
              .toList(),
    );
    _activeSegments = _mergeSegments(
      visible
          .where((segment) => segment.shouldSkip)
          .map((segment) => _SkipSegment(segment.startMs, segment.endMs))
          .toList(),
    );
  }

  Future<Playlist?> _playlistForTrack(Track track) async {
    final current = _currentPlaylist.value;
    try {
      final playlist = await _db.getPlaylist(track.playlistId);
      _currentPlaylist.add(playlist);
      return playlist;
    } catch (_) {}
    return current;
  }

  List<_SkipSegment> _mergeSegments(List<_SkipSegment> segments) {
    if (segments.isEmpty) return const [];
    final merged = <_SkipSegment>[];
    var current = segments.first;
    for (final next in segments.skip(1)) {
      if (next.startMs <= current.endMs + 250) {
        current = _SkipSegment(current.startMs, max(current.endMs, next.endMs));
      } else {
        merged.add(current);
        current = next;
      }
    }
    merged.add(current);
    return merged;
  }

  Future<void> _maybeSkipSponsorBlockSegment(Duration position) async {
    if (_loading ||
        _chapterEditing ||
        _isSeekingPastSegment ||
        !_player.state.playing) {
      return;
    }
    if (_activeSegments.isEmpty) return;

    final durationMs =
        currentItem?.chapter?.endMs ?? _player.state.duration.inMilliseconds;
    final positionMs = position.inMilliseconds;
    for (final segment in _activeSegments) {
      if (positionMs < segment.startMs || positionMs >= segment.endMs) {
        continue;
      }
      final targetMs = segment.endMs + 250;
      if (durationMs > 0 && targetMs >= durationMs - 500) {
        _isSeekingPastSegment = true;
        try {
          await pause();
          if (autoplayEnabled && !_completionHandled) {
            _completionHandled = true;
            await next();
          }
        } finally {
          // Re-arm skipping so a later seek back into the item still works.
          _isSeekingPastSegment = false;
        }
        return;
      }
      _isSeekingPastSegment = true;
      try {
        await _player.seek(Duration(milliseconds: targetMs));
      } finally {
        Future.delayed(const Duration(milliseconds: 400), () {
          _isSeekingPastSegment = false;
        });
      }
      return;
    }
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    await _audioFocusController?.abandonFocus();
  }

  @override
  Future<void> resume() async {
    if (_loadedTrackId == null) {
      // Nothing is open (stopped, still loading, or the last open failed), so
      // there is nothing to take focus for. A play press while idle may still
      // start tracks that were queued up next.
      if (currentTrack == null) await startUpNextQueueIfIdle();
      return;
    }
    if (!await _requestFocus()) return;
    try {
      // Native playback restarts a completed range on Play. Allow that new
      // traversal to advance when it reaches the end again.
      _completionHandled = false;
      await _player.play();
    } catch (_) {
      await _audioFocusController?.abandonFocus();
      rethrow;
    }
  }

  @override
  Future<void> togglePlayPause() async {
    if (_player.state.playing) {
      await pause();
    } else {
      await resume();
    }
  }

  @override
  Future<void> seekTo(Duration position) async {
    final target = currentItem?.sourcePosition(position) ?? position;
    await _player.seek(target);
    _position.add(currentItem?.relativePosition(target) ?? target);
    _completionHandled = false;
  }

  Future<SegmentMarkResult> markLocalSegmentBoundary(String category) async {
    final track = _currentTrack.value;
    if (track == null) {
      return const SegmentMarkResult.error('Nothing playing');
    }
    if (!isSponsorBlockCategory(category)) {
      return const SegmentMarkResult.error('Unknown segment category');
    }

    final current = _player.state.position;
    final start = _pendingSegmentMarkStart.value;
    if (start == null) {
      _pendingSegmentMarkStart.add(current);
      return SegmentMarkResult.started(current);
    }

    final first = start < current ? start : current;
    final second = start < current ? current : start;
    if (second - first < const Duration(seconds: 1)) {
      _pendingSegmentMarkStart.add(null);
      return const SegmentMarkResult.error('Segment is too short');
    }

    await _db.insertLocalSegment(
      SponsorBlockSegmentsCompanion.insert(
        trackId: track.id,
        videoId: track.videoId,
        source: 'local',
        category: category,
        startMs: first.inMilliseconds,
        endMs: second.inMilliseconds,
        createdAt: DateTime.now(),
      ),
    );
    _pendingSegmentMarkStart.add(null);
    await _loadActiveSegments(track);
    return SegmentMarkResult.saved(first, second);
  }

  void cancelLocalSegmentMark() {
    _pendingSegmentMarkStart.add(null);
  }

  @override
  Future<void> next() {
    final completionPending = _completionAdvancePending;
    final fromId = currentMediaId;
    return _transition(() async {
      // A natural completion queued just before this press already moved on.
      if (completionPending && currentMediaId != fromId) return;
      await _advance();
    });
  }

  @override
  Future<void> nextFile() {
    final completionPending = _completionAdvancePending;
    final fromTrackId = currentTrack?.id;
    return _transition(() async {
      if (completionPending && currentTrack?.id != fromTrackId) return;
      if (!await _advance(skipFile: true)) {
        _completionHandled = true;
        await _player.pause();
      }
    });
  }

  @override
  Future<void> previous() => _transition(() async {
    if (position.inSeconds > 3) {
      await seekTo(Duration.zero);
      return;
    }
    if (!await _advance(forward: false) && _loadedTrackId != null) {
      await seekTo(Duration.zero);
    }
  });

  void setShuffleEnabled(bool enabled) {
    _shuffleEnabled.add(enabled);
    _albumQueue.setShuffle(enabled);
    _publishQueue();
  }

  @override
  void toggleShuffle() => setShuffleEnabled(!_shuffleEnabled.value);

  void setAutoplayEnabled(bool enabled) => _autoplayEnabled.add(enabled);
  void toggleAutoplay() => setAutoplayEnabled(!_autoplayEnabled.value);

  @override
  Future<void> setAudioOnlyMode(bool enabled) {
    final transition = _videoTrackTransition.then<void>((_) async {
      if (_audioOnlyMode.value == enabled) return;

      // Select the native video track before changing the Flutter surface.
      // Audio-only therefore stops video decoding instead of just hiding it.
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.setProperty('vid', enabled ? 'no' : 'auto');
      }
      _audioOnlyMode.add(enabled);
    });
    _videoTrackTransition = transition.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return transition;
  }

  Future<void> toggleAudioOnlyMode() => setAudioOnlyMode(!_audioOnlyMode.value);

  void startSleepTimer(Duration duration) => _sleepTimer.start(duration);

  void cancelSleepTimer() => _sleepTimer.cancel();

  @override
  Future<void> stop() => _transition(() async {
    _generation++;
    _loadedTrackId = null;
    _currentFilePath = null;
    _chapterEditing = false;
    _completionHandled = true;
    _sleepTimer.cancel();
    await _player.stop();
    await _audioFocusController?.abandonFocus();
    _currentTrack.add(null);
    _currentPlaylist.add(null);
    _queue.add([]);
    _upNextQueue.add([]);
    _queueIndex.add(0);
    _albumQueue.clear();
    _currentItem.add(null);
    _position.add(Duration.zero);
    _duration.add(Duration.zero);
    _activeSegments = [];
    _sponsorBlockSegments.add([]);
    _pendingSegmentMarkStart.add(null);
  });

  Future<void> dispose() async {
    // Stop every producer before closing the subjects they feed, otherwise a
    // late player event could add to a closed stream.
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _sleepTimer.dispose();
    await _audioFocusController?.dispose();
    await _player.dispose();
    await Future.wait([
      _currentItem.close(),
      _position.close(),
      _duration.close(),
      _currentTrack.close(),
      _currentPlaylist.close(),
      _queue.close(),
      _upNextQueue.close(),
      _queueIndex.close(),
      _shuffleEnabled.close(),
      _autoplayEnabled.close(),
      _audioOnlyMode.close(),
      _pendingSegmentMarkStart.close(),
      _sponsorBlockSegments.close(),
      _messages.close(),
    ]);
  }
}
