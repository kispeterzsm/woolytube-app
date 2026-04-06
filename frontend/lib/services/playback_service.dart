import 'dart:io';
import 'dart:math';
import 'package:media_kit/media_kit.dart' hide Track, Playlist;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';

class PlaybackService {
  late final Player _player;

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

  // Streams
  Stream<Track?> get currentTrackStream => _currentTrack.stream;
  Stream<Playlist?> get currentPlaylistStream => _currentPlaylist.stream;
  Stream<List<Track>> get queueStream => _queue.stream;
  Stream<int> get queueIndexStream => _queueIndex.stream;
  Stream<bool> get shuffleEnabledStream => _shuffleEnabled.stream;
  Stream<bool> get autoplayEnabledStream => _autoplayEnabled.stream;
  Stream<bool> get audioOnlyModeStream => _audioOnlyMode.stream;
  Stream<Duration> get positionStream => _player.stream.position;
  Stream<Duration> get durationStream => _player.stream.duration;
  Stream<bool> get isPlayingStream => _player.stream.playing;
  Stream<bool> get isCompletedStream => _player.stream.completed;

  // Current values
  Track? get currentTrack => _currentTrack.value;
  Playlist? get currentPlaylist => _currentPlaylist.value;
  List<Track> get queue => _queue.value;
  int get queueIndex => _queueIndex.value;
  bool get shuffleEnabled => _shuffleEnabled.value;
  bool get autoplayEnabled => _autoplayEnabled.value;
  bool get audioOnlyMode => _audioOnlyMode.value;
  bool get isPlaying => _player.state.playing;
  Duration get position => _player.state.position;
  Duration get duration => _player.state.duration;

  // Shuffle state
  List<int> _shuffledIndices = [];

  PlaybackService() {
    _player = Player();

    // Auto-advance on track completion
    _player.stream.completed.listen((completed) {
      if (completed && _autoplayEnabled.value && _queue.value.isNotEmpty) {
        next();
      }
    });
  }

  /// Resolve stored file path (without extension) to actual file on disk
  String? resolveFilePath(String storedPath) {
    // First try the stored path directly (in case it already has extension)
    if (File(storedPath).existsSync()) return storedPath;

    // Scan directory for matching file
    final dir = Directory(p.dirname(storedPath));
    final baseName = p.basename(storedPath);
    if (!dir.existsSync()) return null;

    for (final entity in dir.listSync()) {
      if (entity is File &&
          p.basenameWithoutExtension(entity.path) == baseName) {
        return entity.path;
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
  Future<void> playTrack(Track track, List<Track> allTracks,
      {Playlist? playlist}) async {
    // Filter to only playable (downloaded) tracks
    final playable = allTracks
        .where((t) => t.status == 'complete' && t.filePath != null)
        .toList();
    if (playable.isEmpty) return;

    final index = playable.indexWhere((t) => t.id == track.id);
    if (index == -1) return;

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
    final filePath =
        track.filePath != null ? resolveFilePath(track.filePath!) : null;
    if (filePath == null) {
      // Skip to next if file not found
      next();
      return;
    }

    await _player.open(Media('file://$filePath'));
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
    indices.shuffle(Random());
    _shuffledIndices = [currentIndex, ...indices];
  }

  Future<void> stop() async {
    await _player.stop();
    _currentTrack.add(null);
    _currentPlaylist.add(null);
    _queue.add([]);
    _queueIndex.add(0);
    _shuffledIndices = [];
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
  }
}
