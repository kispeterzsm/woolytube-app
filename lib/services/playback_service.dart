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
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _playbackTransition = Future.value();
  bool _loading = false;
  bool _completionHandled = false;
  bool _chapterEditing = false;
  int _generation = 0;
  int? _loadedTrackId;

  PlaybackItem? get currentItem => _currentItem.value;
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
    _sleepTimer = SleepTimerController(onElapsed: pause);
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed && !_loading && !_chapterEditing && !_completionHandled) {
          _completionHandled = true;
          final generation = _generation;
          unawaited(
            _transition(() async {
              if (generation != _generation) return;
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
      pausePlayback: pause,
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

  /// Whether the current track is a video file (not audio-only)
  @override
  bool get isVideoContent {
    final track = _currentTrack.value;
    if (track == null || _audioOnlyMode.value) return false;
    final resolved =
        track.filePath != null ? resolveFilePath(track.filePath!) : null;
    return _isVideoFile(resolved);
  }

  @override
  Stream<bool> get isVideoContentStream => Rx.combineLatest2(
    _currentTrack.stream,
    _audioOnlyMode.stream,
    (Track? track, bool audioOnly) {
      if (track == null || audioOnly) return false;
      final resolved =
          track.filePath != null ? resolveFilePath(track.filePath!) : null;
      return _isVideoFile(resolved);
    },
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
    final groups = <PlaybackAlbum>[];
    for (final track in tracks) {
      final fresh = await _db.getTrack(track.id);
      if (fresh == null || !isTrackPlayable(fresh)) continue;
      final playlist = await _db.getPlaylist(fresh.playlistId);
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
        if (!items.any((i) => i.chapter?.id == chapterId)) return;
      }
      groups.add(PlaybackAlbum(items));
    }
    final selected = _albumQueue.start(
      groups,
      trackId: trackId,
      chapterId: chapterId,
      shuffled: shuffleEnabled,
    );
    _publishQueue();
    if (selected != null) await _loadAndPlay(selected);
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

  Future<bool> _advance({bool forward = true}) async {
    var item = forward ? _albumQueue.next() : _albumQueue.previous();
    while (item != null) {
      final fresh = await _db.getTrack(item.track.id);
      if (fresh != null &&
          isTrackAutomaticallyPlayable(fresh) &&
          fresh.filePath == item.track.filePath &&
          fresh.downloadedAt == item.track.downloadedAt &&
          (item.chapter == null ||
              ChapterData.decode(fresh.chaptersJson).valid) &&
          resolveFilePath(fresh.filePath!) != null) {
        _publishQueue();
        await _loadAndPlay(PlaybackItem(fresh, item.chapter));
        return true;
      }
      item = forward ? _albumQueue.next() : _albumQueue.previous();
    }
    _publishQueue();
    return false;
  }

  Future<void> _loadAndPlay(PlaybackItem item) async {
    _loading = true;
    _loadedTrackId = null;
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
      final filePath =
          item.track.filePath == null
              ? null
              : resolveFilePath(item.track.filePath!);
      if (filePath == null) return;
      final hasFocus =
          _audioFocusController == null ||
          await _audioFocusController!.requestFocus();
      if (!hasFocus) return;
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
      await _audioFocusController?.abandonFocus();
      rethrow;
    } finally {
      _loading = false;
      _duration.add(
        _loadedTrackId == null
            ? Duration.zero
            : item.chapter?.duration ?? _player.state.duration,
      );
      _position.add(item.relativePosition(sourcePosition));
    }
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
        await pause();
        if (autoplayEnabled && !_completionHandled) {
          _completionHandled = true;
          await next();
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
    final hasFocus =
        _audioFocusController == null ||
        await _audioFocusController!.requestFocus();
    if (!hasFocus) return;
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
  Future<void> next() => _transition(() async {
    await _advance();
  });

  @override
  Future<void> previous() => _transition(() async {
    if (position.inSeconds > 3) {
      await seekTo(Duration.zero);
      return;
    }
    await _advance(forward: false);
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

  void dispose() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _currentItem.close();
    _position.close();
    _duration.close();
    _sleepTimer.dispose();
    unawaited(_audioFocusController?.dispose());
    _player.dispose();
    _currentTrack.close();
    _currentPlaylist.close();
    _queue.close();
    _upNextQueue.close();
    _queueIndex.close();
    _shuffleEnabled.close();
    _autoplayEnabled.close();
    _audioOnlyMode.close();
    _pendingSegmentMarkStart.close();
    _sponsorBlockSegments.close();
  }
}
