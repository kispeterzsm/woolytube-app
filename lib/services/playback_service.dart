import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:media_kit/media_kit.dart' hide Track, Playlist;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';
import 'audio_focus_controller.dart';
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
  final Random _random;
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
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<bool> get isPlayingStream => _player.stream.playing;
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
  Duration get position => _player.state.position;
  Duration get duration => _player.state.duration;
  Duration? get sleepTimerRemaining => _sleepTimer.remaining;

  // Shuffle state
  List<int> _shuffledIndices = [];

  Future<void> _videoTrackTransition = Future.value();
  List<_SkipSegment> _activeSegments = [];
  bool _isSeekingPastSegment = false;

  PlaybackService(this._db, {Random? random}) : _random = random ?? Random() {
    _player = Player();
    _sleepTimer = SleepTimerController(onElapsed: pause);

    // Auto-advance on track completion
    _player.stream.completed.listen((completed) {
      if (completed &&
          _autoplayEnabled.value &&
          (_queue.value.isNotEmpty || _upNextQueue.value.isNotEmpty)) {
        next();
      }
    });

    _player.stream.position.listen(_maybeSkipSponsorBlockSegment);
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

  /// Start playing a track from a list of tracks
  @override
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
  }) async {
    final playable = playableTracksForPlayback(
      allTracks,
      directlySelectedTrackId: track.id,
    );
    if (playable.isEmpty) return;

    final index = playable.indexWhere((t) => t.id == track.id);
    if (index == -1) return;

    await _playPlayableTrack(playable, index, playlist: playlist);
  }

  Future<void> playAll(List<Track> allTracks, {Playlist? playlist}) async {
    final playable = playableTracksForPlayback(allTracks);
    if (playable.isEmpty) return;

    final index =
        _shuffleEnabled.value && playable.length > 1
            ? 1 + _random.nextInt(playable.length - 1)
            : 0;

    await _playPlayableTrack(playable, index, playlist: playlist);
  }

  /// Adds exactly one track to the separate up-next queue. It intentionally
  /// does not replace or append the source playlist's playback list.
  Future<bool> addToUpNextQueue(Track track) async {
    final fresh = await _db.getTrack(track.id);
    if (fresh == null || !isTrackAutomaticallyPlayable(fresh)) return false;

    _upNextQueue.add([..._upNextQueue.value, fresh]);
    return true;
  }

  /// Starts the first queued item when nothing is currently playing. This
  /// makes “Add to queue” useful before a playlist has been started.
  Future<bool> startUpNextQueueIfIdle() async {
    if (_currentTrack.value != null) return false;
    return _playNextQueuedTrack();
  }

  void removeUpNextQueueAt(int index) {
    final entries = List<Track>.of(_upNextQueue.value);
    if (index < 0 || index >= entries.length) return;
    entries.removeAt(index);
    _upNextQueue.add(entries);
  }

  void clearUpNextQueue() => _upNextQueue.add([]);

  /// Persists the always-skip preference and refreshes in-memory references
  /// so a track already waiting in either queue is skipped immediately.
  Future<void> setAlwaysSkip(Track track, bool alwaysSkip) async {
    await _db.updateTrackAlwaysSkip(track.id, alwaysSkip);

    List<Track> updateReferences(List<Track> entries) =>
        entries
            .map(
              (entry) =>
                  entry.id == track.id
                      ? entry.copyWith(alwaysSkip: alwaysSkip)
                      : entry,
            )
            .toList();

    _queue.add(updateReferences(_queue.value));
    _upNextQueue.add(updateReferences(_upNextQueue.value));

    final current = _currentTrack.value;
    if (current?.id == track.id) {
      _currentTrack.add(current!.copyWith(alwaysSkip: alwaysSkip));
    }
  }

  /// Pulls and consumes the next manually queued track, ignoring stale,
  /// unavailable, deleted, or always-skipped entries along the way.
  Future<bool> _playNextQueuedTrack() async {
    final entries = List<Track>.of(_upNextQueue.value);
    while (entries.isNotEmpty) {
      final candidate = entries.removeAt(0);
      _upNextQueue.add(List<Track>.of(entries));

      final fresh = await _db.getTrack(candidate.id);
      if (fresh == null || !isTrackAutomaticallyPlayable(fresh)) continue;

      await _playlistForTrack(fresh);
      _currentTrack.add(fresh);
      await _loadAndPlay(fresh);
      return true;
    }
    return false;
  }

  Future<void> _playPlayableTrack(
    List<Track> playable,
    int index, {
    Playlist? playlist,
  }) async {
    _queue.add(playable);
    _queueIndex.add(index);
    _currentTrack.add(playable[index]);
    if (playlist != null) _currentPlaylist.add(playlist);

    if (_shuffleEnabled.value) {
      _generateShuffledIndices(index);
    }

    await _loadAndPlay(playable[index]);
  }

  Future<void> _loadAndPlay(Track track) async {
    await _loadActiveSegments(track);
    final filePath =
        track.filePath != null ? resolveFilePath(track.filePath!) : null;
    if (filePath == null) {
      // File not found — don't auto-advance, leave track selected so user
      // can see which track failed.
      return;
    }

    final hasFocus =
        _audioFocusController == null ||
        await _audioFocusController!.requestFocus();
    if (!hasFocus) return;
    try {
      await _player.open(Media('file://$filePath'));
    } catch (_) {
      await _audioFocusController?.abandonFocus();
      rethrow;
    }
  }

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

    _sponsorBlockSegments.add(visible);
    _activeSegments = _mergeSegments(
      visible
          .where((segment) => segment.shouldSkip)
          .map((segment) => _SkipSegment(segment.startMs, segment.endMs))
          .toList(),
    );
  }

  Future<Playlist?> _playlistForTrack(Track track) async {
    final current = _currentPlaylist.value;
    if (current != null && current.id == track.playlistId) {
      return current;
    }
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
    if (_isSeekingPastSegment || !_player.state.playing) return;
    if (_activeSegments.isEmpty) return;

    final durationMs = _player.state.duration.inMilliseconds;
    final positionMs = position.inMilliseconds;
    for (final segment in _activeSegments) {
      if (positionMs < segment.startMs || positionMs >= segment.endMs) {
        continue;
      }
      final targetMs = segment.endMs + 250;
      if (durationMs > 0 && targetMs >= durationMs - 500) {
        await next();
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
  Future<void> seekTo(Duration position) => _player.seek(position);

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
  Future<void> next() async {
    if (await _playNextQueuedTrack()) return;
    await _moveWithinPlaylistQueue(forward: true);
  }

  @override
  Future<void> previous() async {
    // If more than 3 seconds in, restart current track.
    if (_player.state.position.inSeconds > 3) {
      seekTo(Duration.zero);
      return;
    }
    await _moveWithinPlaylistQueue(forward: false);
  }

  /// Moves through the source playlist queue while bypassing any tracks that
  /// have become unplayable or are marked always-skip. This is intentionally
  /// checked at transition time so it applies to both ordered and shuffled
  /// playback, including preferences changed after playback began.
  Future<void> _moveWithinPlaylistQueue({required bool forward}) async {
    final q = _queue.value;
    if (q.isEmpty) return;

    final currentIndex = _queueIndex.value.clamp(0, q.length - 1).toInt();
    if (_shuffleEnabled.value && _shuffledIndices.isNotEmpty) {
      var currentShufflePos = _shuffledIndices.indexOf(currentIndex);
      if (currentShufflePos == -1) {
        _generateShuffledIndices(currentIndex);
        currentShufflePos = _shuffledIndices.indexOf(currentIndex);
      }

      var candidateShufflePos = currentShufflePos + (forward ? 1 : -1);
      while (candidateShufflePos >= 0 &&
          candidateShufflePos < _shuffledIndices.length) {
        final candidateIndex = _shuffledIndices[candidateShufflePos];
        if (await _playAutomaticQueueTrack(q[candidateIndex], candidateIndex)) {
          return;
        }
        candidateShufflePos += forward ? 1 : -1;
      }
      return;
    }

    var candidateIndex = currentIndex + (forward ? 1 : -1);
    while (candidateIndex >= 0 && candidateIndex < q.length) {
      if (await _playAutomaticQueueTrack(q[candidateIndex], candidateIndex)) {
        return;
      }
      candidateIndex += forward ? 1 : -1;
    }
  }

  Future<bool> _playAutomaticQueueTrack(Track candidate, int index) async {
    final fresh = await _db.getTrack(candidate.id);
    if (fresh == null || !isTrackAutomaticallyPlayable(fresh)) return false;

    _queueIndex.add(index);
    await _playlistForTrack(fresh);
    _currentTrack.add(fresh);
    await _loadAndPlay(fresh);
    return true;
  }

  void setShuffleEnabled(bool enabled) {
    _shuffleEnabled.add(enabled);
    if (enabled) {
      _generateShuffledIndices(_queueIndex.value);
    }
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

  void _generateShuffledIndices(int currentIndex) {
    final indices = List.generate(_queue.value.length, (i) => i);
    indices.remove(currentIndex);
    indices.shuffle(_random);
    _shuffledIndices = [currentIndex, ...indices];
  }

  @override
  Future<void> stop() async {
    _sleepTimer.cancel();
    await _player.stop();
    await _audioFocusController?.abandonFocus();
    _currentTrack.add(null);
    _currentPlaylist.add(null);
    _queue.add([]);
    _upNextQueue.add([]);
    _queueIndex.add(0);
    _shuffledIndices = [];
    _activeSegments = [];
    _sponsorBlockSegments.add([]);
    _pendingSegmentMarkStart.add(null);
  }

  void dispose() {
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
