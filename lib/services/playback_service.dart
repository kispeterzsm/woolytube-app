import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:media_kit/media_kit.dart' hide Track, Playlist;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';
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

class PlaybackService {
  late final Player _player;
  final AppDatabase _db;
  final Random _random;

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
  final _queueIndex = BehaviorSubject<int>.seeded(0);
  final _shuffleEnabled = BehaviorSubject<bool>.seeded(false);
  final _autoplayEnabled = BehaviorSubject<bool>.seeded(true);
  final _audioOnlyMode = BehaviorSubject<bool>.seeded(false);
  final _pendingSegmentMarkStart = BehaviorSubject<Duration?>.seeded(null);

  // Streams
  Stream<Track?> get currentTrackStream => _currentTrack.stream;
  Stream<Playlist?> get currentPlaylistStream => _currentPlaylist.stream;
  Stream<List<Track>> get queueStream => _queue.stream;
  Stream<int> get queueIndexStream => _queueIndex.stream;
  Stream<bool> get shuffleEnabledStream => _shuffleEnabled.stream;
  Stream<bool> get autoplayEnabledStream => _autoplayEnabled.stream;
  Stream<bool> get audioOnlyModeStream => _audioOnlyMode.stream;
  Stream<Duration?> get pendingSegmentMarkStartStream =>
      _pendingSegmentMarkStart.stream;
  Stream<Duration> get positionStream => _player.stream.position;
  Stream<Duration> get durationStream => _player.stream.duration;
  Stream<bool> get isPlayingStream => _player.stream.playing;
  Stream<bool> get isCompletedStream => _player.stream.completed;
  Stream<int?> get videoWidthStream => _player.stream.width;
  Stream<int?> get videoHeightStream => _player.stream.height;
  Stream<double?> get videoAspectStream => Rx.combineLatest2(
    _player.stream.width,
    _player.stream.height,
    (int? w, int? h) =>
        (w != null && h != null && w > 0 && h > 0) ? w / h : null,
  );

  // Current values
  Track? get currentTrack => _currentTrack.value;
  Playlist? get currentPlaylist => _currentPlaylist.value;
  List<Track> get queue => _queue.value;
  int get queueIndex => _queueIndex.value;
  bool get shuffleEnabled => _shuffleEnabled.value;
  bool get autoplayEnabled => _autoplayEnabled.value;
  bool get audioOnlyMode => _audioOnlyMode.value;
  Duration? get pendingSegmentMarkStart => _pendingSegmentMarkStart.value;
  bool get isPlaying => _player.state.playing;
  Duration get position => _player.state.position;
  Duration get duration => _player.state.duration;

  // Shuffle state
  List<int> _shuffledIndices = [];

  // Background/foreground transition safety net
  Duration _lastKnownPosition = Duration.zero;
  bool _wasPlayingBeforeBackground = false;
  List<_SkipSegment> _activeSegments = [];
  bool _isSeekingPastSegment = false;

  PlaybackService(this._db, {Random? random}) : _random = random ?? Random() {
    _player = Player();

    // Auto-advance on track completion
    _player.stream.completed.listen((completed) {
      if (completed && _autoplayEnabled.value && _queue.value.isNotEmpty) {
        next();
      }
    });

    _player.stream.position.listen(_maybeSkipSponsorBlockSegment);
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
  bool get isVideoContent {
    final track = _currentTrack.value;
    if (track == null || _audioOnlyMode.value) return false;
    final resolved =
        track.filePath != null ? resolveFilePath(track.filePath!) : null;
    return _isVideoFile(resolved);
  }

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
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
  }) async {
    final playable = _playableTracks(allTracks);
    if (playable.isEmpty) return;

    final index = playable.indexWhere((t) => t.id == track.id);
    if (index == -1) return;

    await _playPlayableTrack(playable, index, playlist: playlist);
  }

  Future<void> playAll(List<Track> allTracks, {Playlist? playlist}) async {
    final playable = _playableTracks(allTracks);
    if (playable.isEmpty) return;

    final index =
        _shuffleEnabled.value && playable.length > 1
            ? 1 + _random.nextInt(playable.length - 1)
            : 0;

    await _playPlayableTrack(playable, index, playlist: playlist);
  }

  List<Track> _playableTracks(List<Track> tracks) =>
      tracks
          .where((t) => t.status == 'complete' && t.filePath != null)
          .toList();

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

    await _player.open(Media('file://$filePath'));
  }

  Future<void> _loadActiveSegments(Track track) async {
    _pendingSegmentMarkStart.add(null);
    final playlist = _currentPlaylist.value;
    if (playlist == null || !playlist.sponsorBlockEnabled) {
      _activeSegments = [];
      return;
    }

    final enabledCategories = _decodeCategories(
      playlist.sponsorBlockCategories,
    );
    if (enabledCategories.isEmpty) {
      _activeSegments = [];
      return;
    }

    final segments = await _db.getSegmentsForTrack(track.id);
    final filtered =
        segments
            .where((segment) {
              if (!enabledCategories.contains(segment.category)) return false;
              if (segment.source == 'sponsorblock' &&
                  track.isLocalReplacement) {
                return false;
              }
              return segment.endMs > segment.startMs;
            })
            .map((segment) => _SkipSegment(segment.startMs, segment.endMs))
            .toList()
          ..sort((a, b) => a.startMs.compareTo(b.startMs));

    _activeSegments = _mergeSegments(filtered);
  }

  Set<String> _decodeCategories(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<String>()
            .where(sponsorBlockCategories.contains)
            .toSet();
      }
    } catch (_) {}
    return defaultSponsorBlockCategories.toSet();
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

  /// Disable libmpv's video track before the Android GL surface is destroyed.
  /// Without this, surface destruction makes libmpv pause and reset the file
  /// on the next play action. Audio keeps decoding normally.
  Future<void> handleAppInactive() async {
    _lastKnownPosition = _player.state.position;
    _wasPlayingBeforeBackground = _player.state.playing;
    final native = _player.platform;
    if (native is NativePlayer) {
      await native.setProperty('vid', 'no');
    }
  }

  /// Re-enable video decoding when the app returns to foreground so the
  /// Video widget can render again. If libmpv reset position during the
  /// surface teardown, seek back to where we were.
  Future<void> handleAppResumed() async {
    final native = _player.platform;
    if (native is NativePlayer) {
      await native.setProperty('vid', 'auto');
    }
    final current = _player.state.position;
    if (_lastKnownPosition > Duration.zero &&
        (current - _lastKnownPosition).abs() > const Duration(seconds: 2)) {
      await _player.seek(_lastKnownPosition);
    }
    if (_wasPlayingBeforeBackground && !_player.state.playing) {
      await _player.play();
    }
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();

  Future<void> togglePlayPause() async {
    if (_player.state.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> seekTo(Duration position) => _player.seek(position);

  Future<SegmentMarkResult> markLocalSegmentBoundary(String category) async {
    final track = _currentTrack.value;
    if (track == null) {
      return const SegmentMarkResult.error('Nothing playing');
    }
    if (!sponsorBlockCategories.contains(category)) {
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

  Future<void> next() async {
    final q = _queue.value;
    if (q.isEmpty) return;

    int nextIndex;
    if (_shuffleEnabled.value && _shuffledIndices.isNotEmpty) {
      final currentShufflePos = _shuffledIndices.indexOf(_queueIndex.value);
      final nextShufflePos = currentShufflePos + 1;
      if (nextShufflePos >= _shuffledIndices.length) return;
      nextIndex = _shuffledIndices[nextShufflePos];
    } else {
      nextIndex = _queueIndex.value + 1;
      if (nextIndex >= q.length) return;
    }

    _queueIndex.add(nextIndex);
    _currentTrack.add(q[nextIndex]);
    await _loadAndPlay(q[nextIndex]);
  }

  Future<void> previous() async {
    final q = _queue.value;
    if (q.isEmpty) return;

    // If more than 3 seconds in, restart current track
    if (_player.state.position.inSeconds > 3) {
      seekTo(Duration.zero);
      return;
    }

    int prevIndex;
    if (_shuffleEnabled.value && _shuffledIndices.isNotEmpty) {
      final currentShufflePos = _shuffledIndices.indexOf(_queueIndex.value);
      final prevShufflePos = currentShufflePos - 1;
      if (prevShufflePos < 0) {
        seekTo(Duration.zero);
        return;
      }
      prevIndex = _shuffledIndices[prevShufflePos];
    } else {
      prevIndex = _queueIndex.value - 1;
      if (prevIndex < 0) {
        seekTo(Duration.zero);
        return;
      }
    }

    _queueIndex.add(prevIndex);
    _currentTrack.add(q[prevIndex]);
    await _loadAndPlay(q[prevIndex]);
  }

  void setShuffleEnabled(bool enabled) {
    _shuffleEnabled.add(enabled);
    if (enabled) {
      _generateShuffledIndices(_queueIndex.value);
    }
  }

  void toggleShuffle() => setShuffleEnabled(!_shuffleEnabled.value);

  void setAutoplayEnabled(bool enabled) => _autoplayEnabled.add(enabled);
  void toggleAutoplay() => setAutoplayEnabled(!_autoplayEnabled.value);

  void setAudioOnlyMode(bool enabled) => _audioOnlyMode.add(enabled);
  void toggleAudioOnlyMode() => setAudioOnlyMode(!_audioOnlyMode.value);

  void _generateShuffledIndices(int currentIndex) {
    final indices = List.generate(_queue.value.length, (i) => i);
    indices.remove(currentIndex);
    indices.shuffle(_random);
    _shuffledIndices = [currentIndex, ...indices];
  }

  Future<void> stop() async {
    await _player.stop();
    _currentTrack.add(null);
    _currentPlaylist.add(null);
    _queue.add([]);
    _queueIndex.add(0);
    _shuffledIndices = [];
    _activeSegments = [];
    _pendingSegmentMarkStart.add(null);
  }

  void dispose() {
    _player.dispose();
    _currentTrack.close();
    _currentPlaylist.close();
    _queue.close();
    _queueIndex.close();
    _shuffleEnabled.close();
    _autoplayEnabled.close();
    _audioOnlyMode.close();
    _pendingSegmentMarkStart.close();
  }
}
