import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:media_kit/media_kit.dart' hide Track, Playlist, Tracks;
import 'package:media_kit/media_kit.dart' as media show Tracks;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart' as p;
import '../database/database.dart';
import 'audio_focus_controller.dart';
import 'audio_processing.dart';
import 'chapter_playback.dart';
import 'chapters.dart';
import 'loudness_service.dart';
import 'metadata_service.dart';
import 'playback_notification_controller.dart';
import 'playback_settings_store.dart';
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

enum _LoadResult { opened, openFailed, focusDenied }

enum _AdvanceResult { loaded, nothingLeft, focusDenied }

/// A queue item that was checked against the database and has a file.
class _Stepped {
  final PlaybackItem item;
  final String path;
  const _Stepped(this.item, this.path);
}

/// Plays local media and owns the play queue.
///
/// Every command that changes what is loaded runs through one serial chain
/// ([_transition]), so a tap, a natural track end, the sleep timer and a
/// notification button can never interleave half-way.
///
/// State for the UI is published on BehaviorSubjects that only emit real
/// changes. [positionStream] is rate-limited for widgets; [position] is
/// always the latest raw value.
class PlaybackService
    implements
        PlaybackNotificationController,
        PictureInPicturePlaybackController {
  /// How often [positionStream] emits while playing. Seeks and loads are
  /// published at once.
  static const uiPositionInterval = Duration(milliseconds: 200);

  /// A file that reports neither a length nor progress this long after it
  /// was opened is treated as unplayable.
  static const loadTimeout = Duration(seconds: 10);

  /// After a player error during a load, how long a file still has to show
  /// that it opened.
  static const loadErrorGrace = Duration(milliseconds: 1500);

  /// How often the position of the current song is remembered while playing.
  static const sessionSaveInterval = Duration(seconds: 15);

  static const _maxOpenAttempts = 5;

  late final Player _player;
  late final SleepTimerController _sleepTimer;
  final AppDatabase _db;
  final PlaybackSettingsStore? _settingsStore;
  late final AlbumPlaybackQueue _albumQueue;
  final _currentItem = BehaviorSubject<PlaybackItem?>.seeded(null);

  /// Latest raw position, relative to the current item.
  final _position = BehaviorSubject<Duration>.seeded(Duration.zero);

  /// [_position] at UI rate.
  final _uiPosition = BehaviorSubject<Duration>.seeded(Duration.zero);
  final _clock = Stopwatch()..start();
  Duration _lastUiPositionAt = const Duration(days: -1);
  Timer? _uiPositionTimer;

  final _duration = BehaviorSubject<Duration>.seeded(Duration.zero);

  /// Mirrors the player's playing flag, but holds still while a file is
  /// being opened so track changes do not flash a Play icon.
  final _playing = BehaviorSubject<bool>.seeded(false);
  final _messages = StreamController<String>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _playbackTransition = Future.value();
  int _transitionsInFlight = 0;
  bool _loading = false;
  bool _completionHandled = false;
  bool _completionAdvancePending = false;
  bool _chapterEditing = false;
  int _generation = 0;
  int? _loadedTrackId;

  /// The current item finished (or was cut at its end) and nothing new was
  /// loaded since. Play then restarts it.
  bool _itemEnded = false;

  /// Autoplay ran out of things to play.
  bool _queueEnded = false;

  /// The position listener already handled the end of the current chapter.
  bool _boundaryHandled = false;

  /// End of the range the player was opened with, on the file's timeline.
  /// A chapter followed by chapters that continue it is opened up to the end
  /// of that run, so moving from one to the next needs no reload.
  int? _openedEndMs;

  /// Pause requests that arrived while a file was being opened.
  bool _pauseAfterLoad = false;

  /// The next file is opened paused (after "stop after this song").
  bool _openNextPaused = false;
  bool _pauseAfterLoadKeepFocus = false;

  /// Coalescing of rapid Next/Previous presses.
  int _pendingNext = 0;
  int _pendingPrevious = 0;
  _Stepped? _pendingSkipTarget;
  PlaybackQueueSnapshot? _skipOrigin;

  /// Where a not-yet-opened current item (a restored session) starts.
  Duration? _resumeAtSource;

  /// The song that opening the chapter editor for another file interrupted:
  /// its queue id and where it was. The next step that reaches it continues
  /// there instead of at its start.
  ({String id, Duration at})? _resumeAfterEdit;

  /// The albums behind the published "Up next" list, so an index from the UI
  /// always means what the user saw, even while a step is in flight.
  List<PlaybackAlbum> _publishedUpNext = const [];

  /// Audio-only was switched on for the car or picture-in-picture, not by
  /// the user, and is undone when the app comes back to the foreground.
  bool _temporaryAudioOnly = false;

  Timer? _loadWatchTimer;
  int? _loadWatchGeneration;
  int? _errorDuringLoadGeneration;

  PlaybackSession? _lastSavedSession;
  Duration _lastSessionSaveAt = Duration.zero;

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

  /// Whether the current item is one chapter of a longer file. Only then
  /// does "skip to the next file" differ from Next.
  @override
  bool get currentItemIsChapter => currentItem?.chapter != null;
  Stream<bool> get currentItemIsChapterStream =>
      _currentItem.stream.map((item) => item?.chapter != null).distinct();

  Duration get sourcePosition =>
      _loadedTrackId == null ? Duration.zero : _player.state.position;
  Duration get sourceDuration =>
      _loadedTrackId == null ? Duration.zero : _player.state.duration;

  /// Whether the current item's media is open in the player. False for a
  /// session restored at start-up until Play is pressed.
  bool get hasLoadedMedia => _loadedTrackId != null;
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
  final _queue = BehaviorSubject<List<Track>>.seeded(const []);
  final _upNextQueue = BehaviorSubject<List<Track>>.seeded(const []);
  final _queueIndex = BehaviorSubject<int>.seeded(0);
  final _shuffleEnabled = BehaviorSubject<bool>.seeded(false);
  final _autoplayEnabled = BehaviorSubject<bool>.seeded(true);
  final _audioOnlyMode = BehaviorSubject<bool>.seeded(false);
  final _audioSettings = BehaviorSubject<AudioProcessingSettings>.seeded(
    const AudioProcessingSettings(),
  );
  final _stopAfterCurrent = BehaviorSubject<bool>.seeded(false);
  final _pendingSegmentMarkStart = BehaviorSubject<Duration?>.seeded(null);
  final _sponsorBlockSegments =
      BehaviorSubject<List<PlaybackSponsorBlockSegment>>.seeded(const []);

  /// What the decoded tracks say about the current file: true/false once
  /// known, null while only the file extension is known.
  final _detectedVideo = BehaviorSubject<bool?>.seeded(null);

  // Streams
  @override
  Stream<Track?> get currentTrackStream => _currentTrack.stream;
  Stream<Playlist?> get currentPlaylistStream => _currentPlaylist.stream;

  /// The whole play order, re-published only when its content changes.
  Stream<List<Track>> get queueStream => _queue.stream;
  Stream<List<Track>> get upNextQueueStream => _upNextQueue.stream;
  Stream<int> get queueIndexStream => _queueIndex.stream;
  Stream<int> get queueLengthStream =>
      _queue.stream.map((q) => q.length).distinct();
  Stream<int> get upNextCountStream =>
      _upNextQueue.stream.map((q) => q.length).distinct();
  @override
  Stream<bool> get shuffleEnabledStream => _shuffleEnabled.stream.distinct();
  Stream<bool> get autoplayEnabledStream => _autoplayEnabled.stream.distinct();
  Stream<bool> get audioOnlyModeStream => _audioOnlyMode.stream.distinct();

  /// Plane mode: songs are evened out and their quiet parts lifted, so they
  /// stay clear over engine noise at a lower volume.
  Stream<bool> get planeModeStream =>
      _audioSettings.stream.map((s) => s.planeMode).distinct();
  bool get planeMode => _audioSettings.value.planeMode;

  /// Plane mode, its strength and "Even out volume" together.
  Stream<AudioProcessingSettings> get audioProcessingSettingsStream =>
      _audioSettings.stream.distinct();
  AudioProcessingSettings get audioProcessingSettings => _audioSettings.value;

  /// "Stop after this song": playback pauses when the current item ends.
  Stream<bool> get stopAfterCurrentStream =>
      _stopAfterCurrent.stream.distinct();
  Stream<Duration?> get pendingSegmentMarkStartStream =>
      _pendingSegmentMarkStart.stream;
  Stream<List<PlaybackSponsorBlockSegment>> get sponsorBlockSegmentsStream =>
      _sponsorBlockSegments.stream;
  Stream<Duration?> get sleepTimerRemainingStream =>
      _sleepTimer.remainingStream;

  /// Position of the current item for widgets: at most every
  /// [uiPositionInterval] while playing, at once after a seek or a load.
  /// Replays the latest value to new listeners.
  @override
  Stream<Duration> get positionStream => _uiPosition.stream;

  /// Every position update from the player. Only for code that needs more
  /// precision than [positionStream] gives; widgets should not use it.
  Stream<Duration> get rawPositionStream => _position.stream;

  /// Whole seconds of the position, for time labels.
  Stream<Duration> get positionSecondsStream =>
      _uiPosition.stream.map((p) => Duration(seconds: p.inSeconds)).distinct();
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<bool> get isPlayingStream => _playing.stream;
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
  Stream<int?> get videoWidthStream =>
      _player.stream.width.startWith(_player.state.width);
  Stream<int?> get videoHeightStream =>
      _player.stream.height.startWith(_player.state.height);
  @override
  Stream<double?> get videoAspectStream =>
      Rx.combineLatest2(
        videoWidthStream,
        videoHeightStream,
        (int? w, int? h) =>
            (w != null && h != null && w > 0 && h > 0) ? w / h : null,
      ).distinct();

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
  bool get stopAfterCurrent => _stopAfterCurrent.value;
  Duration? get pendingSegmentMarkStart => _pendingSegmentMarkStart.value;
  List<PlaybackSponsorBlockSegment> get sponsorBlockSegments =>
      _sponsorBlockSegments.value;
  @override
  bool get isPlaying => _playing.value;
  @override
  Duration get position => _position.value;
  Duration get duration => _duration.value;
  Duration? get sleepTimerRemaining => _sleepTimer.remaining;

  Future<void> _videoTrackTransition = Future.value();

  final Future<void> Function(String name, String value)?
  _setMpvPropertyOverride;

  /// Where measured loudness comes from; see [attachLoudness].
  TrackLoudnessSource? _loudness;
  StreamSubscription<LoudnessJob>? _loudnessMeasured;

  /// A measurement of the playing song that arrives later than this into it
  /// waits for its next play: a level step late in a song is worse than
  /// one more play at the old level.
  static const _reapplyLoudnessWithin = Duration(seconds: 30);

  /// The filters and gain mpv has now. mpv keeps them across files.
  AudioProcessingPlan _appliedAudioPlan = AudioProcessingPlan.none;

  /// Keeps changes to mpv's filters in order.
  Future<void> _audioPlanTransition = Future.value();
  List<_SkipSegment> _activeSegments = [];

  /// Queue items the user picked although they are marked Always skip (a
  /// tapped chapter, or every chapter of a tapped file whose chapters are
  /// all skipped). Stepping to them again (Next, Previous, a gapless
  /// boundary) still plays them. Reset when a new queue starts.
  final Set<String> _chosenItemIds = {};

  /// One range per chapter of the current file marked Always skip.
  List<_SkipSegment> _skippedChapterRanges = const [];

  /// A skipped chapter range the user seeked into on purpose; it plays.
  _SkipSegment? _skipExemptChapterSegment;

  /// [_skippedChapterRanges] without the exempt one, adjacent ranges joined.
  /// Jumped over like SponsorBlock segments while the file plays whole.
  List<_SkipSegment> _skippedChapterSegments = const [];

  /// The playlist's visible segments on the file's timeline, kept so a
  /// chapter change can re-filter them without a database query.
  List<PlaybackSponsorBlockSegment> _visibleSegments = const [];
  bool _isSeekingPastSegment = false;

  /// [settingsStore] remembers shuffle, autoplay, audio-only and the last
  /// song across restarts. When it is omitted, the app's shared preferences
  /// are used for a real player and nothing is remembered when a test passes
  /// its own [player].
  ///
  /// [setMpvProperty] replaces setting an mpv option on the real player (for
  /// tests, whose players have no mpv behind them).
  PlaybackService(
    this._db, {
    Random? random,
    Player? player,
    PlaybackSettingsStore? settingsStore,
    Future<void> Function(String name, String value)? setMpvProperty,
  }) : _settingsStore =
           settingsStore ??
           (player == null ? SharedPreferencesPlaybackSettingsStore() : null),
       _setMpvPropertyOverride = setMpvProperty {
    _player = player ?? Player();
    _albumQueue = AlbumPlaybackQueue(random: random);
    // Route the sleep timer through the transition chain so a track change
    // that is in flight when the timer fires cannot swallow the pause.
    _sleepTimer = SleepTimerController(onElapsed: () => _transition(pause));
    _playing.add(_player.state.playing);
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed && !_loading && !_chapterEditing) _handleItemEnd();
      }),
    );
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (_loading) return;
        _syncPlaying(playing);
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (_loading) return;
        _setPosition(currentItem?.relativePosition(position) ?? position);
        _checkChapterBoundary(position);
        unawaited(_maybeSkipSponsorBlockSegment(position));
        _maybeSaveSessionPeriodically();
      }),
    );
    _subscriptions.add(
      _player.stream.duration.listen((duration) {
        if (duration > Duration.zero) _cancelLoadWatch();
        if (!_loading) {
          _setDuration(currentItem?.chapter?.duration ?? duration);
        }
      }),
    );
    _subscriptions.add(_player.stream.error.listen(_onPlayerError));
    _subscriptions.add(_player.stream.tracks.listen(_onTracks));
    if (_settingsStore != null) {
      unawaited(_transition(_restorePersistedState));
    }
  }

  Future<void> _transition(Future<void> Function() action) {
    _transitionsInFlight++;
    final next = _playbackTransition.then((_) => action());
    _playbackTransition = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next.whenComplete(() => _transitionsInFlight--);
  }

  void _setPosition(Duration value, {bool immediate = false}) {
    if (_position.isClosed) return;
    if (value != _position.value) _position.add(value);
    _publishUiPosition(immediate: immediate);
  }

  void _publishUiPosition({bool immediate = false}) {
    if (_uiPosition.isClosed) return;
    final value = _position.value;
    final shown = _uiPosition.value;
    final now = _clock.elapsed;
    final jumped =
        value < shown || value - shown > const Duration(milliseconds: 1000);
    if (immediate || jumped || now - _lastUiPositionAt >= uiPositionInterval) {
      _uiPositionTimer?.cancel();
      _uiPositionTimer = null;
      _lastUiPositionAt = now;
      if (value != shown) _uiPosition.add(value);
      return;
    }
    // Make sure the last value (for example where playback paused) lands.
    _uiPositionTimer ??= Timer(
      uiPositionInterval - (now - _lastUiPositionAt),
      () {
        _uiPositionTimer = null;
        _publishUiPosition(immediate: true);
      },
    );
  }

  void _setDuration(Duration value) {
    if (!_duration.isClosed && _duration.value != value) _duration.add(value);
  }

  void _syncPlaying([bool? value]) {
    final playing = value ?? _player.state.playing;
    if (!_playing.isClosed && _playing.value != playing) _playing.add(playing);
  }

  void _publishQueue() {
    if (_queue.isClosed) return;
    final items = [for (final i in _albumQueue.items) i.displayTrack];
    if (!listEquals(items, _queue.value)) _queue.add(items);
    final index = _albumQueue.index;
    if (_queueIndex.value != index) _queueIndex.add(index);
    _publishedUpNext = _albumQueue.queued;
    final upNext =
        _publishedUpNext
            .map(
              (g) =>
                  g.items.length > 1
                      ? g.items.first.track
                      : g.items.first.displayTrack,
            )
            .toList();
    if (!listEquals(upNext, _upNextQueue.value)) _upNextQueue.add(upNext);
  }

  Future<void> initializeAudioFocus({
    required bool pauseOnAudioInterruption,
    PlaybackAudioSession? audioSession,
  }) async {
    final controller = AudioFocusController(
      session: audioSession ?? await PlatformPlaybackAudioSession.create(),
      // The controller decides whether focus is kept (transient loss) or
      // abandoned, so it pauses the player directly instead of via pause().
      pausePlayback: _pauseForFocusLoss,
      resumePlayback: resume,
      // A file that is still opening is about to play, so an interruption
      // must pause it and resume it afterwards.
      isPlaying: () => isPlaying || _loading,
    );
    await controller.initialize(enabled: pauseOnAudioInterruption);
    _audioFocusController = controller;
  }

  Future<void> setPauseOnAudioInterruption(bool enabled) async {
    await _audioFocusController?.setEnabled(enabled);
  }

  Future<void> _pauseForFocusLoss() async {
    if (_loading) _pauseAfterLoadKeepFocus = true;
    await _player.pause();
    _saveSession();
  }

  Future<void> _abandonFocus() async {
    await _audioFocusController?.abandonFocus();
  }

  /// Resolve stored file path (without extension) to actual file on disk
  String? resolveFilePath(String storedPath) =>
      MetadataService.resolveStoredFilePath(storedPath);

  /// Whether the resolved file is a video format
  bool _isVideoFile(String? filePath) {
    if (filePath == null) return false;
    final ext = p.extension(filePath).toLowerCase();
    return ['.mp4', '.mkv', '.webm', '.avi', '.mov'].contains(ext);
  }

  String? _resolveTrackFile(Track track) =>
      track.filePath == null ? null : resolveFilePath(track.filePath!);

  bool _isVideoTrack(Track? track, bool audioOnly, bool? detected) {
    if (track == null || audioOnly) return false;
    // A video container may hold only audio; trust the decoded tracks once
    // the player reported them.
    if (detected == false) return false;
    return _isVideoFile(_currentFilePath ?? _resolveTrackFile(track));
  }

  /// Whether the current track is a video file (not audio-only)
  @override
  bool get isVideoContent => _isVideoTrack(
    _currentTrack.value,
    _audioOnlyMode.value,
    _detectedVideo.value,
  );

  @override
  Stream<bool> get isVideoContentStream =>
      Rx.combineLatest3(
        _currentTrack.stream,
        _audioOnlyMode.stream,
        _detectedVideo.stream,
        _isVideoTrack,
      ).distinct();

  void _onTracks(media.Tracks tracks) {
    if (_loading || _loadedTrackId == null || _detectedVideo.isClosed) return;
    bool real(String id) => id != 'auto' && id != 'no';
    final hasAudio = tracks.audio.any((t) => real(t.id));
    final hasVideo = tracks.video.any(
      (t) => real(t.id) && t.albumart != true && t.image != true,
    );
    // Only an audio-only result is acted on: it stops an audio file in a
    // video container from opening the video player.
    if (hasAudio && !hasVideo && _detectedVideo.value != false) {
      _detectedVideo.add(false);
    }
  }

  /// Plays [track] with [allTracks] as the queue. [startAt] is a time in
  /// the file: when the file plays as chapters and no [chapterId] is given,
  /// the chapter at that time is played, from that time.
  @override
  Future<void> playTrack(
    Track track,
    List<Track> allTracks, {
    Playlist? playlist,
    String? chapterId,
    bool whole = false,
    Duration? startAt,
  }) => _transition(() async {
    final playable = playableTracksForPlayback(
      allTracks,
      directlySelectedTrackId: track.id,
    );
    await _startQueue(
      playable,
      selected: track,
      chapterId: chapterId,
      whole: whole,
      startAt: startAt,
    );
  });

  Future<void> playAll(List<Track> tracks, {Playlist? playlist}) =>
      _transition(() async {
        await _startQueue(playableTracksForPlayback(tracks));
      });

  /// Replaces the queue with [entries] (such as search results) and plays
  /// it, in this order or shuffled; Up next is kept. Each file plays whole
  /// or as just its listed chapters. Files that are not downloaded or are
  /// marked Always skip are left out, and so are chapters marked Always
  /// skip.
  Future<void> playEntries(List<QueueEntry> entries) => _transition(() async {
    final (tracks, chapterSubsets) = _entryTracks(entries);
    await _startQueue(
      playableTracksForPlayback(tracks),
      chapterSubsets: chapterSubsets,
    );
  });

  /// Adds [entries] to Up next as one entry per file, in order ([first]
  /// puts them all before what is already waiting), skipping what
  /// [playEntries] leaves out. Returns how many files were added.
  Future<int> enqueueEntries(
    List<QueueEntry> entries, {
    bool first = false,
  }) async {
    final (tracks, chapterSubsets) = _entryTracks(entries);
    final groups = await _buildAlbums(
      playableTracksForPlayback(tracks),
      chapterSubsets: chapterSubsets,
    );
    for (final album in first ? groups.reversed : groups) {
      _albumQueue.enqueue(album, first: first);
    }
    if (groups.isNotEmpty) _publishQueue();
    return groups.length;
  }

  /// The distinct files of [entries] in order, and the chapters to play of
  /// those that play only some. A file listed whole anywhere plays whole.
  static (List<Track>, Map<int, Set<String>>) _entryTracks(
    List<QueueEntry> entries,
  ) {
    final tracks = <Track>[];
    final seen = <int>{};
    final whole = <int>{};
    final subsets = <int, Set<String>>{};
    for (final entry in entries) {
      final id = entry.track.id;
      if (seen.add(id)) tracks.add(entry.track);
      final chapterIds = entry.chapterIds;
      if (chapterIds == null) {
        whole.add(id);
        subsets.remove(id);
      } else if (!whole.contains(id)) {
        subsets.putIfAbsent(id, () => <String>{}).addAll(chapterIds);
      }
    }
    return (tracks, subsets);
  }

  Future<void> _startQueue(
    List<Track> tracks, {
    Track? selected,
    String? chapterId,
    bool whole = false,
    Duration? startAt,
    Map<int, Set<String>> chapterSubsets = const {},
  }) async {
    final trackId = selected?.id;
    final groups = await _buildAlbums(
      tracks,
      trackId: trackId,
      chapterId: chapterId,
      whole: whole,
      chapterSubsets: chapterSubsets,
    );
    if (groups.isEmpty) {
      reportMessage('Nothing to play');
      return;
    }
    if (startAt != null && chapterId == null && selected != null) {
      chapterId = _chapterAt(groups, selected.id, startAt);
    }
    // Validate the explicitly selected file and take audio focus before the
    // live queue is replaced, so a failure leaves current playback untouched.
    String? selectedPath;
    if (selected != null) {
      final selectedAlbum =
          groups.where((g) => g.trackId == selected.id).firstOrNull;
      if (selectedAlbum == null) {
        // It is no longer downloaded (or was reset since the list was shown).
        reportMessage('"${selected.title}" can\'t be played right now');
        return;
      }
      selectedPath = _resolveTrackFile(selectedAlbum.items.first.track);
      if (selectedPath == null) {
        reportMessage('File not found: ${selected.title}');
        return;
      }
    }
    if (!await _requestFocus()) return;
    _pendingSkipTarget = null;
    _skipOrigin = null;
    _resumeAfterEdit = null;
    _chosenItemIds
      ..clear()
      ..addAll(_skippedItemIdsOf(groups, selected));
    final first = _albumQueue.start(
      groups,
      trackId: trackId,
      chapterId: chapterId,
      shuffled: shuffleEnabled,
    );
    _publishQueue();
    if (first == null) return;
    final filePath =
        first.track.id == trackId
            ? selectedPath
            : _resolveTrackFile(first.track);
    if (filePath == null) {
      _reportSkippedFiles([first.track.title]);
      await _advance();
      return;
    }
    final result = await _loadAndPlay(
      first,
      filePath: filePath,
      startAt:
          first.track.id == trackId && startAt != null
              ? _startWithin(first, startAt)
              : null,
      reportFailure: false,
    );
    if (result == _LoadResult.openFailed) {
      reportMessage('Could not play "${first.track.title}"');
      await _advance();
    }
  }

  /// The id of the chapter of track [trackId] that holds file time [at],
  /// when that file plays as chapters.
  String? _chapterAt(List<PlaybackAlbum> groups, int trackId, Duration at) {
    final album = groups.where((g) => g.trackId == trackId).firstOrNull;
    if (album == null) return null;
    final ms = at.inMilliseconds;
    MediaChapter? found;
    for (final item in album.items) {
      final chapter = item.chapter;
      if (chapter == null) return null;
      if (chapter.startMs <= ms) found = chapter;
      if (ms < chapter.endMs && chapter.startMs <= ms) return chapter.id;
    }
    return found?.id;
  }

  /// File time [at] kept inside [item]: a time before a chapter starts at
  /// its start, one past its end is dropped.
  Duration? _startWithin(PlaybackItem item, Duration at) {
    final chapter = item.chapter;
    final ms = at.inMilliseconds;
    if (chapter == null) return ms <= 0 ? null : at;
    if (ms >= chapter.endMs) return null;
    return ms <= chapter.startMs ? null : at;
  }

  /// The items of [selected]'s album that are marked Always skip: they are in
  /// the queue only because the user picked them.
  Iterable<String> _skippedItemIdsOf(
    List<PlaybackAlbum> groups,
    Track? selected,
  ) {
    if (selected == null) return const [];
    final album = groups.where((g) => g.trackId == selected.id).firstOrNull;
    if (album == null) return const [];
    final data = ChapterData.decode(album.items.first.track.chaptersJson);
    return album.items
        .where((i) => i.chapter != null && data.isSkipped(i.chapter!.id))
        .map((i) => i.id);
  }

  /// Builds the playback groups for [tracks] from fresh database rows, reading
  /// each distinct playlist once instead of one query per track. A file in
  /// [chapterSubsets] plays only those of its active chapters that are not
  /// marked Always skip, and is left out when none is left.
  Future<List<PlaybackAlbum>> _buildAlbums(
    List<Track> tracks, {
    int? trackId,
    String? chapterId,
    bool whole = false,
    Map<int, Set<String>> chapterSubsets = const {},
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
      final selected = track.id == trackId;
      var items = chapterPlaybackItems(
        fresh,
        playlist,
        whole: whole && selected,
        selected: selected,
      );
      if (chapterId != null && selected) {
        // A tapped chapter plays even when it is marked Always skip; the
        // file's other skipped chapters are still passed over.
        final data = ChapterData.decode(fresh.chaptersJson);
        items =
            data.active
                .where((c) => c.id == chapterId || !data.isSkipped(c.id))
                .map((c) => PlaybackItem(fresh, c))
                .toList();
        if (!items.any((i) => i.chapter?.id == chapterId)) return const [];
      }
      final subset = chapterSubsets[track.id];
      if (subset != null) items = _subsetItems(fresh, subset);
      // Every chapter of it is marked Always skip.
      if (items.isEmpty) continue;
      groups.add(
        PlaybackAlbum(
          items,
          playlistShuffleChapters: playlist.shuffleChapters,
          chapterSubset: subset,
        ),
      );
    }
    return groups;
  }

  /// The active chapters of [track] in [subset] that are not marked Always
  /// skip, in timeline order.
  static List<PlaybackItem> _subsetItems(Track track, Set<String> subset) {
    final data = ChapterData.decode(track.chaptersJson);
    return [
      for (final chapter in data.active)
        if (subset.contains(chapter.id) && !data.isSkipped(chapter.id))
          PlaybackItem(track, chapter),
    ];
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

  void _reportFailedOpens(List<String> titles) {
    if (titles.isEmpty) return;
    reportMessage(
      titles.length == 1
          ? 'Could not play "${titles.single}"'
          : 'Could not play ${titles.length} files',
    );
  }

  /// Puts [track] at the front of Up next, so it plays after the current
  /// song (or file, with chapters).
  Future<bool> playNext(Track track, {String? chapterId}) =>
      addToUpNextQueue(track, chapterId: chapterId, first: true);

  Future<bool> addToUpNextQueue(
    Track track, {
    String? chapterId,
    bool first = false,
  }) async {
    final fresh = await _db.getTrack(track.id);
    if (fresh == null || !isTrackAutomaticallyPlayable(fresh)) return false;
    final playlist = await _db.getPlaylist(fresh.playlistId);
    var items = chapterPlaybackItems(fresh, playlist);
    if (chapterId != null) {
      // A chapter marked Always skip is refused like a skipped file.
      final data = ChapterData.decode(fresh.chaptersJson);
      items =
          data.active
              .where((c) => c.id == chapterId && !data.isSkipped(c.id))
              .map((c) => PlaybackItem(fresh, c))
              .toList();
    }
    if (items.isEmpty) return false;
    // A step that is rolled back meanwhile keeps this (see
    // [AlbumPlaybackQueue.restore]).
    _albumQueue.enqueue(
      PlaybackAlbum(items, playlistShuffleChapters: playlist.shuffleChapters),
      first: first,
    );
    _publishQueue();
    return true;
  }

  /// Nothing is playing, or autoplay already ran out of songs.
  bool get _idle => currentTrack == null || _queueEnded;

  Future<bool> startUpNextQueueIfIdle() async {
    if (!_idle) return false;
    var started = false;
    await _transition(() async {
      if (_idle) started = await _advance() == _AdvanceResult.loaded;
    });
    return started;
  }

  /// Removes the [index]th entry of the published [upNextQueue].
  void removeUpNextQueueAt(int index) {
    final shown = _publishedUpNext;
    if (index < 0 || index >= shown.length) return;
    _albumQueue.removeQueuedAlbum(shown[index]);
    _publishQueue();
  }

  /// Moves the [from]th entry of the published [upNextQueue] to [to]
  /// (an index in the list without the moved entry, as ReorderableListView
  /// reports it after adjusting).
  void moveUpNextQueue(int from, int to) {
    final shown = _publishedUpNext;
    if (from < 0 || from >= shown.length) return;
    _albumQueue.moveQueuedAlbum(shown[from], to);
    _publishQueue();
  }

  /// Plays the [index]th entry of the published [upNextQueue] now: it moves
  /// to the front and the rest of the current file is skipped.
  Future<void> playUpNextAt(int index) async {
    final shown = _publishedUpNext;
    if (index < 0 || index >= shown.length) return;
    _albumQueue.moveQueuedAlbum(shown[index], 0);
    _publishQueue();
    if (_idle) {
      await startUpNextQueueIfIdle();
    } else {
      await nextFile();
    }
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

  /// Moves the queue to the next item that is still playable and has a file,
  /// reporting files that are missing on the way. Null when there is none.
  Future<_Stepped?> _stepQueue({
    bool forward = true,
    bool skipFile = false,
  }) async {
    var item =
        skipFile
            ? _albumQueue.nextFile()
            : forward
            ? _albumQueue.next()
            : _albumQueue.previous();
    final missingFiles = <String>[];
    try {
      while (item != null) {
        final candidate = await _freshPlaybackItem(item);
        if (candidate != null) {
          final filePath = _resolveTrackFile(candidate.track);
          if (filePath != null) return _Stepped(candidate, filePath);
          missingFiles.add(candidate.track.title);
        }
        item = forward ? _albumQueue.next() : _albumQueue.previous();
      }
      return null;
    } finally {
      _reportSkippedFiles(missingFiles);
    }
  }

  /// [_stepQueue], but a step that finds nothing leaves the queue where it
  /// was, so the queue position keeps matching what is playing (also after
  /// walking over missing files at the end of the queue).
  Future<_Stepped?> _stepOrStay({
    bool forward = true,
    bool skipFile = false,
  }) async {
    final before = _albumQueue.snapshot();
    final stepped = await _stepQueue(forward: forward, skipFile: skipFile);
    if (stepped == null) {
      _restoreQueue(before);
      // "Next file" at the last file still skips the rest of this one.
      if (skipFile) _albumQueue.discardRestOfCurrentFile();
    }
    return stepped;
  }

  /// Rolls the queue back to [snapshot]. A shuffle switch made since then
  /// still applies; "Up next" changes are kept.
  void _restoreQueue(PlaybackQueueSnapshot snapshot) {
    _albumQueue.restore(snapshot);
    _albumQueue.setShuffle(shuffleEnabled);
  }

  /// One press of a burst of Next/Previous presses: moves the queue without
  /// opening anything. The last press of the burst loads the result.
  Future<void> _stepWithoutLoading({required bool forward}) async {
    final origin = _skipOrigin ?? _albumQueue.snapshot();
    final stepped = await _stepOrStay(forward: forward);
    if (stepped == null) return;
    _skipOrigin = origin;
    _pendingSkipTarget = stepped;
  }

  /// Steps the queue and opens the result. A file that cannot be opened is
  /// skipped (up to [_maxOpenAttempts] files) with a message. Denied audio
  /// focus leaves the queue where it was.
  Future<_AdvanceResult> _advance({
    bool forward = true,
    bool skipFile = false,
  }) async {
    final pending = _pendingSkipTarget;
    final origin = _skipOrigin ?? _albumQueue.snapshot();
    final resumeEdit = _resumeAfterEdit;
    _pendingSkipTarget = null;
    _skipOrigin = null;
    _resumeAfterEdit = null;
    final failedOpens = <String>[];
    // When the last press of a burst finds nothing, the queue is back at the
    // item the earlier presses reached, which is [pending].
    var target =
        await _stepOrStay(forward: forward, skipFile: skipFile) ?? pending;
    var attempts = 0;
    while (target != null) {
      _publishQueue();
      final result = await _loadAndPlay(
        target.item,
        filePath: target.path,
        startAt: _resumePositionFor(target.item, resumeEdit),
        reportFailure: false,
      );
      if (result == _LoadResult.opened) {
        _reportFailedOpens(failedOpens);
        return _AdvanceResult.loaded;
      }
      if (result == _LoadResult.focusDenied) {
        _restoreQueue(origin);
        _publishQueue();
        _reportFailedOpens(failedOpens);
        return _AdvanceResult.focusDenied;
      }
      failedOpens.add(target.item.track.title);
      if (++attempts >= _maxOpenAttempts) break;
      target = await _stepOrStay(forward: forward);
    }
    _publishQueue();
    _reportFailedOpens(failedOpens);
    if (_loadedTrackId == null) await _abandonFocus();
    return _AdvanceResult.nothingLeft;
  }

  /// Where [item] continues when it is the song the chapter editor
  /// interrupted; null (its start) otherwise.
  Duration? _resumePositionFor(
    PlaybackItem item,
    ({String id, Duration at})? resume,
  ) {
    if (resume == null || resume.id != item.id) return null;
    final at = resume.at.inMilliseconds;
    final chapter = item.chapter;
    if (chapter != null && (at < chapter.startMs || at >= chapter.endMs)) {
      return null;
    }
    return resume.at;
  }

  /// Re-reads a queued item from the database. Returns null when the track is
  /// no longer automatically playable, its file was replaced, or its chapter
  /// no longer exists or is marked Always skip (unless [chosen], or it is in
  /// [_chosenItemIds]: the user picked that chapter); otherwise the item
  /// carries the chapter's current bounds rather than the ones captured when
  /// the queue was built.
  Future<PlaybackItem?> _freshPlaybackItem(
    PlaybackItem item, {
    bool chosen = false,
  }) async {
    final fresh = await _db.getTrack(item.track.id);
    // A sync that places a new video above this one renames its file; that
    // is the same recording under a new name. Only a new download (a new
    // downloadedAt) means different media.
    if (fresh == null ||
        !isTrackAutomaticallyPlayable(fresh) ||
        fresh.downloadedAt != item.track.downloadedAt) {
      return null;
    }
    final queuedChapter = item.chapter;
    if (queuedChapter == null) return PlaybackItem(fresh);
    final data = ChapterData.decode(fresh.chaptersJson);
    if (!chosen &&
        !_chosenItemIds.contains(item.id) &&
        data.isSkipped(queuedChapter.id)) {
      return null;
    }
    final chapter =
        data.active.where((c) => c.id == queuedChapter.id).firstOrNull;
    return chapter == null ? null : PlaybackItem(fresh, chapter);
  }

  /// End of the range to open [item] with: a chapter that the next chapters
  /// of the same file continue without a gap is opened up to the end of that
  /// run, so the step to the next chapter needs no reload.
  Duration? _openEndFor(PlaybackItem item) {
    final chapter = item.chapter;
    if (chapter == null) return null;
    var endMs = chapter.endMs;
    if (autoplayEnabled && !_stopAfterCurrent.value) {
      var last = item;
      for (final following in _albumQueue.upcomingInAlbum()) {
        if (!last.continuesInto(following)) break;
        last = following;
        endMs = following.chapter!.endMs;
      }
    }
    return Duration(milliseconds: endMs);
  }

  /// Opens [item] from the already resolved [filePath]. Audio focus is taken
  /// before anything is published, so a denied request leaves the previous
  /// item and its media untouched. A file opened paused ([_openNextPaused])
  /// needs no focus until Play.
  Future<_LoadResult> _loadAndPlay(
    PlaybackItem item, {
    required String filePath,
    Duration? startAt,
    bool reportFailure = true,
  }) async {
    final focused = !_openNextPaused;
    if (focused && !await _requestFocus()) return _LoadResult.focusDenied;
    _loading = true;
    _pauseAfterLoad = _openNextPaused;
    _pauseAfterLoadKeepFocus = false;
    _loadedTrackId = null;
    _currentFilePath = filePath;
    _generation++;
    _cancelLoadWatch();
    _chapterEditing = false;
    _completionHandled = false;
    _itemEnded = false;
    _queueEnded = false;
    _boundaryHandled = false;
    _isSeekingPastSegment = false;
    _setSkipExemptChapter(null);
    _resumeAtSource = null;
    _pendingSkipTarget = null;
    _skipOrigin = null;
    _currentItem.add(item);
    _currentTrack.add(item.displayTrack);
    // After the track, so the previous track is never re-evaluated without
    // its detection result (which could flash "video" for it).
    if (_detectedVideo.value != null) _detectedVideo.add(null);
    _setPosition(
      startAt == null ? Duration.zero : item.relativePosition(startAt),
      immediate: true,
    );
    _setDuration(item.duration ?? Duration.zero);
    final end = _openEndFor(item);
    _openedEndMs = end?.inMilliseconds;
    var playOnOpen = true;
    try {
      await _player.pause();
      await _loadActiveSegments(item.track);
      // The new song's level and filters are in place before its first
      // sample is decoded.
      await _applyAudioProcessing(item.track.id, filePath);
      // A pause pressed until now (or "stop after this song") opens the file
      // paused, so not even a moment of it is heard.
      playOnOpen = !(_pauseAfterLoad || _pauseAfterLoadKeepFocus);
      // Play pressed during a paused open: it needs audio focus first.
      if (playOnOpen && !focused) playOnOpen = await _requestFocus();
      await _player.open(
        Media(
          Uri.file(filePath).toString(),
          start:
              startAt ??
              (item.chapter == null
                  ? null
                  : Duration(milliseconds: item.startMs)),
          end: end,
        ),
        play: playOnOpen,
      );
      _loadedTrackId = item.track.id;
    } catch (_) {
      // The previous media must not stay resumable under this item's name.
      _currentFilePath = null;
      try {
        await _player.stop();
      } catch (_) {}
      if (reportFailure) reportMessage('Could not open "${item.track.title}"');
    } finally {
      _loading = false;
      final playerDuration = _player.state.duration;
      _setDuration(
        _loadedTrackId == null
            ? Duration.zero
            : item.chapter?.duration ??
                (playerDuration > Duration.zero
                    ? playerDuration
                    : item.duration ?? Duration.zero),
      );
      _setPosition(item.relativePosition(sourcePosition), immediate: true);
    }
    if (_loadedTrackId == null) {
      _syncPlaying(false);
      return _LoadResult.openFailed;
    }
    if (_pauseAfterLoad || _pauseAfterLoadKeepFocus) {
      final abandon = _pauseAfterLoad;
      _pauseAfterLoad = false;
      _pauseAfterLoadKeepFocus = false;
      await _player.pause();
      if (abandon) await _abandonFocus();
    } else if (!playOnOpen) {
      // Play was pressed while the file was opening paused.
      if (await _requestFocus()) await _player.play();
    }
    _syncPlaying();
    _armLoadWatch();
    _saveSession(force: true);
    _prioritizeLoudness();
    return _LoadResult.opened;
  }

  // ---------------------------------------------------------------------
  // Files that open but never play.
  //
  // libmpv does not fail `open` for a corrupt or unsupported file: it goes
  // idle without a length or progress. Such a load is detected here and
  // treated like a failed open.

  void _armLoadWatch() {
    _cancelLoadWatch();
    if (_player.state.duration > Duration.zero) return;
    final generation = _generation;
    _loadWatchGeneration = generation;
    _loadWatchTimer = Timer(
      _errorDuringLoadGeneration == generation ? loadErrorGrace : loadTimeout,
      () => _onLoadFailed(generation),
    );
  }

  void _cancelLoadWatch() {
    _loadWatchTimer?.cancel();
    _loadWatchTimer = null;
    _loadWatchGeneration = null;
  }

  void _onPlayerError(String _) {
    if (_loading) {
      _errorDuringLoadGeneration = _generation;
      return;
    }
    final generation = _loadWatchGeneration;
    if (generation == null || generation != _generation) return;
    // Decode errors also happen in files that play on; give this one a
    // moment to report its length before giving up on it.
    _loadWatchTimer?.cancel();
    _loadWatchTimer = Timer(loadErrorGrace, () => _onLoadFailed(generation));
  }

  void _onLoadFailed(int generation) {
    _loadWatchTimer = null;
    _loadWatchGeneration = null;
    if (generation != _generation || _loading || _loadedTrackId == null) {
      return;
    }
    if (_player.state.duration > Duration.zero ||
        _player.state.position > Duration.zero) {
      return;
    }
    unawaited(
      _transition(() async {
        if (generation != _generation || _loadedTrackId == null) return;
        final item = currentItem;
        _loadedTrackId = null;
        _currentFilePath = null;
        _completionHandled = true;
        try {
          await _player.stop();
        } catch (_) {}
        _syncPlaying(false);
        if (item != null) _reportFailedOpens([item.track.title]);
        if (autoplayEnabled) {
          if (await _advance() == _AdvanceResult.loaded) return;
        }
        await _abandonFocus();
      }),
    );
  }

  // ---------------------------------------------------------------------
  // The end of an item.

  /// A natural end of the current item, or a cut at its end. Runs once per
  /// item: pauses for "stop after this song", otherwise continues with the
  /// next item when autoplay is on, and lets other apps have audio focus
  /// when nothing else plays.
  void _handleItemEnd() {
    if (_completionHandled || _chapterEditing) return;
    _completionHandled = true;
    _itemEnded = true;
    final generation = _generation;
    final endedId = currentMediaId;
    _completionAdvancePending = true;
    unawaited(
      _transition(() async {
        _completionAdvancePending = false;
        if (generation != _generation || currentMediaId != endedId) return;
        if (_stopAfterCurrent.value) {
          // "Stop after this song": get the next song ready, paused, so
          // Play continues the queue.
          _stopAfterCurrent.add(false);
          await _player.pause();
          if (autoplayEnabled) {
            _openNextPaused = true;
            try {
              final result = await _advance();
              if (result == _AdvanceResult.loaded) return;
              if (result == _AdvanceResult.nothingLeft) _queueEnded = true;
            } finally {
              _openNextPaused = false;
            }
          }
          await _abandonFocus();
          _saveSession(force: true);
          return;
        }
        if (autoplayEnabled) {
          final result = await _advance();
          if (result == _AdvanceResult.loaded) return;
          if (result == _AdvanceResult.nothingLeft) _queueEnded = true;
        }
        await _abandonFocus();
      }),
    );
  }

  /// A chapter opened together with the chapters that continue it reaches
  /// its end while the audio keeps running into the next one.
  void _checkChapterBoundary(Duration source) {
    final item = currentItem;
    final chapter = item?.chapter;
    final openedEnd = _openedEndMs;
    if (item == null ||
        chapter == null ||
        openedEnd == null ||
        openedEnd <= chapter.endMs ||
        _loadedTrackId == null ||
        _chapterEditing ||
        _completionHandled ||
        _boundaryHandled ||
        source.inMilliseconds < chapter.endMs) {
      return;
    }
    _boundaryHandled = true;
    final successor = _albumQueue.peekNext();
    if (autoplayEnabled &&
        !_stopAfterCurrent.value &&
        item.continuesInto(successor) &&
        successor!.chapter!.endMs <= openedEnd) {
      final generation = _generation;
      unawaited(_transition(() => _continueIntoNextChapter(generation)));
      return;
    }
    // Autoplay was switched off or the order changed since the file was
    // opened: stop here, as if the player had been opened for this chapter.
    _handleItemEnd();
    unawaited(_player.pause());
  }

  /// Makes the following chapter current while the audio keeps playing.
  Future<void> _continueIntoNextChapter(int generation) async {
    final current = currentItem;
    final chapter = current?.chapter;
    if (generation != _generation || current == null || chapter == null) {
      return;
    }
    if (_player.state.position.inMilliseconds < chapter.endMs - 500) {
      // The user seeked back into this chapter meanwhile.
      _boundaryHandled = false;
      return;
    }
    final snapshot = _albumQueue.snapshot();
    final queued = _albumQueue.next();
    final fresh = queued == null ? null : await _freshPlaybackItem(queued);
    if (generation != _generation) return;
    if (fresh == null ||
        !current.continuesInto(fresh) ||
        fresh.chapter!.endMs > (_openedEndMs ?? 0)) {
      // The chapters were edited meanwhile: open the next item normally.
      _restoreQueue(snapshot);
      _completionHandled = true;
      _itemEnded = true;
      await _player.pause();
      if (autoplayEnabled) {
        final result = await _advance();
        if (result == _AdvanceResult.loaded) return;
        if (result == _AdvanceResult.nothingLeft) _queueEnded = true;
      }
      await _abandonFocus();
      return;
    }
    _generation++;
    _completionHandled = false;
    _itemEnded = false;
    _boundaryHandled = false;
    _isSeekingPastSegment = false;
    _currentItem.add(fresh);
    _currentTrack.add(fresh.displayTrack);
    _setDuration(fresh.chapter!.duration);
    _setPosition(
      fresh.relativePosition(_player.state.position),
      immediate: true,
    );
    _publishSegmentsForCurrentItem();
    _publishQueue();
    _saveSession(force: true);
  }

  // ---------------------------------------------------------------------
  // Chapter editing.

  /// Opens [track] as one whole file for marking chapters, without throwing
  /// away the play queue:
  /// * already playing as a whole file: nothing is reloaded;
  /// * a chapter of it is current: the whole file takes that chapter's place
  ///   in the queue and continues from the same spot, playing or paused as
  ///   before (a song restored at start-up opens paused);
  /// * another file: it starts playing now. Once it ends (or on Next), the
  ///   song it interrupted continues where it was, then the rest of the
  ///   queue;
  /// * nothing at all is current: with [playlistTracks] the file starts as if
  ///   it had been tapped in that list, otherwise it plays alone.
  ///
  /// On failure nothing changes (or, when the player had to close the old
  /// song, that song stays current, ready to reopen with Play) and a
  /// [StateError] with a user-facing message is thrown. Call
  /// [endChapterEditing] when the editor closes.
  Future<void> beginChapterEditing(Track track, [List<Track>? playlistTracks]) {
    return _transition(() async {
      final item = currentItem;
      if (item != null && item.track.id == track.id) {
        await _editCurrentFile(item);
      } else if (item == null && playlistTracks != null) {
        await _editInPlaylist(track, playlistTracks);
      } else {
        await _editOtherFile(track, item);
      }
      _chapterEditing = true;
    });
  }

  Future<(Track, String)> _editableFile(int trackId) async {
    final fresh = await _db.getTrack(trackId);
    if (fresh == null || !isTrackPlayable(fresh)) {
      throw StateError('This file is not downloaded.');
    }
    final path = _resolveTrackFile(fresh);
    if (path == null) throw StateError('File not found.');
    return (fresh, path);
  }

  Never _editFailed(_LoadResult result) =>
      throw StateError(
        result == _LoadResult.focusDenied
            ? 'Another app is using audio.'
            : 'The local media file could not be opened.',
      );

  Future<void> _editCurrentFile(PlaybackItem item) async {
    final loaded = _loadedTrackId == item.track.id;
    if (loaded && item.chapter == null) return;
    final (fresh, path) = await _editableFile(item.track.id);
    final at =
        loaded
            ? _player.state.position
            : _resumeAtSource ?? Duration(milliseconds: item.startMs);
    final whole = PlaybackItem(fresh);
    final snapshot = _albumQueue.snapshot();
    _albumQueue.replaceCurrent(whole);
    _publishQueue();
    final result = await _loadKeepingPause(
      paused: !(loaded && isPlaying),
      () => _loadAndPlay(
        whole,
        filePath: path,
        startAt: at,
        reportFailure: false,
      ),
    );
    if (result == _LoadResult.opened) return;
    _restoreQueue(snapshot);
    _publishQueue();
    if (result == _LoadResult.openFailed) await _showUnopened(item, at);
    _editFailed(result);
  }

  Future<void> _editInPlaylist(Track track, List<Track> playlistTracks) async {
    final (fresh, path) = await _editableFile(track.id);
    final groups = await _buildAlbums(
      playableTracksForPlayback(
        playlistTracks,
        directlySelectedTrackId: fresh.id,
      ),
      trackId: fresh.id,
      whole: true,
    );
    if (!groups.any((g) => g.trackId == fresh.id)) {
      await _editOtherFile(fresh, null);
      return;
    }
    if (!await _requestFocus()) _editFailed(_LoadResult.focusDenied);
    _pendingSkipTarget = null;
    _skipOrigin = null;
    _resumeAfterEdit = null;
    final snapshot = _albumQueue.snapshot();
    final first = _albumQueue.start(
      groups,
      trackId: fresh.id,
      shuffled: shuffleEnabled,
    );
    _publishQueue();
    // Unlike a tap, a file that does not open must not start another song.
    final result =
        first == null || first.track.id != fresh.id
            ? _LoadResult.openFailed
            : await _loadAndPlay(first, filePath: path, reportFailure: false);
    if (result == _LoadResult.opened) return;
    _restoreQueue(snapshot);
    _publishQueue();
    if (result == _LoadResult.openFailed) await _showUnopened(null, null);
    _editFailed(result);
  }

  Future<void> _editOtherFile(Track track, PlaybackItem? interrupted) async {
    final (fresh, path) = await _editableFile(track.id);
    final whole = PlaybackItem(fresh);
    final snapshot = _albumQueue.snapshot();
    final interruptedAt =
        _loadedTrackId != null ? _player.state.position : _resumeAtSource;
    // Pick the interrupted song up again afterwards, where it was.
    final resume =
        interrupted != null && !_itemEnded && !_queueEnded
            ? PlaybackItem(interrupted.track, interrupted.chapter)
            : null;
    _albumQueue.playNow(whole, thenResume: resume);
    _publishQueue();
    final result = await _loadAndPlay(
      whole,
      filePath: path,
      reportFailure: false,
    );
    if (result == _LoadResult.opened) {
      if (resume != null && interruptedAt != null) {
        _resumeAfterEdit = (id: resume.id, at: interruptedAt);
      }
      return;
    }
    _restoreQueue(snapshot);
    _publishQueue();
    if (result == _LoadResult.openFailed) {
      await _showUnopened(interrupted, interruptedAt);
    }
    _editFailed(result);
  }

  /// Runs [load] with the file opening paused when [paused] is true.
  Future<_LoadResult> _loadKeepingPause(
    Future<_LoadResult> Function() load, {
    required bool paused,
  }) async {
    if (!paused) return load();
    final before = _openNextPaused;
    _openNextPaused = true;
    try {
      return await load();
    } finally {
      _openNextPaused = before;
    }
  }

  /// After a failed open closed the player: shows [item] again, not opened,
  /// at [at] (Play reopens it there), or nothing at all when [item] is null.
  Future<void> _showUnopened(PlaybackItem? item, Duration? at) async {
    _loadedTrackId = null;
    _currentFilePath = null;
    _completionHandled = true;
    _cancelLoadWatch();
    _syncPlaying(false);
    _resumeAtSource = item == null ? null : at;
    _currentItem.add(item);
    _currentTrack.add(item?.displayTrack);
    if (item == null) {
      _currentPlaylist.add(null);
      _activeSegments = const [];
      _clearSkippedChapterSegments();
      _visibleSegments = const [];
      _sponsorBlockSegments.add(const []);
      if (_detectedVideo.value != null) _detectedVideo.add(null);
      _setPosition(Duration.zero, immediate: true);
      _setDuration(Duration.zero);
    } else {
      _setDuration(item.duration ?? Duration.zero);
      _setPosition(
        item.relativePosition(at ?? Duration(milliseconds: item.startMs)),
        immediate: true,
      );
      await _loadActiveSegments(item.track, clearPendingMark: false);
    }
    await _abandonFocus();
  }

  void endChapterEditing() => _chapterEditing = false;

  /// Jumps to chapter [chapterId] of the file that is playing now (track
  /// [trackId], played as chapters), keeping the queue: its order, history
  /// and "Up next" stay. Returns false, changing nothing, when the current
  /// item is not a chapter of that file or the chapter is not in the queue.
  Future<bool> playChapterOfCurrentFile(int trackId, String chapterId) async {
    var played = false;
    await _transition(() async {
      final item = currentItem;
      if (item == null || item.track.id != trackId || item.chapter == null) {
        return;
      }
      final snapshot = _albumQueue.snapshot();
      final target = _albumQueue.jumpToChapter(trackId, chapterId);
      final fresh =
          target == null
              ? null
              : await _freshPlaybackItem(target, chosen: true);
      final path = fresh == null ? null : _resolveTrackFile(fresh.track);
      if (fresh == null || path == null) {
        _restoreQueue(snapshot);
        return;
      }
      _publishQueue();
      final result = await _loadAndPlay(fresh, filePath: path);
      if (result == _LoadResult.focusDenied) {
        _restoreQueue(snapshot);
        _publishQueue();
        return;
      }
      played = result == _LoadResult.opened;
      if (played) _chosenItemIds.add(fresh.id);
    });
    return played;
  }

  // ---------------------------------------------------------------------
  // Live settings changes.

  Future<void> refreshCurrentSegments() async {
    final track = _currentTrack.value;
    if (track != null) {
      await _loadActiveSegments(track, clearPendingMark: false);
    }
  }

  /// Call after a playlist's settings (SponsorBlock, chapters as tracks) or
  /// a track's chapters were saved. The song that is playing gets the new
  /// skip segments and progress-bar markers right away; songs that have not
  /// started yet are rebuilt with the new chapter setting. The current song
  /// itself keeps playing as it is.
  Future<void> playlistSettingsChanged(int playlistId) => _transition(() async {
    final current = currentTrack;
    if (current != null && current.playlistId == playlistId) {
      await _loadActiveSegments(current, clearPendingMark: false);
    }
    final Playlist playlist;
    try {
      playlist = await _db.getPlaylist(playlistId);
    } catch (_) {
      return;
    }
    final fresh = {
      for (final t in await _db.getTracksForPlaylist(playlistId)) t.id: t,
    };
    _albumQueue.rebuildPendingAlbums((album) {
      final track = album.items.first.track;
      if (track.playlistId != playlistId) return null;
      final row = fresh[track.id];
      if (row == null) return null;
      // An album limited to some chapters (search results) keeps to them.
      final subset = album.chapterSubset;
      return PlaybackAlbum(
        subset == null
            ? chapterPlaybackItems(row, playlist)
            : _subsetItems(row, subset),
        playlistShuffleChapters: playlist.shuffleChapters,
        chapterSubset: subset,
      );
    });
    _publishQueue();
  });

  /// Same as [playlistSettingsChanged] for the playlist of [track]; call it
  /// after the track's chapters or chapter options were edited.
  Future<void> trackChaptersChanged(Track track) =>
      playlistSettingsChanged(track.playlistId);

  // ---------------------------------------------------------------------
  // SponsorBlock.

  Future<void> _loadActiveSegments(
    Track track, {
    bool clearPendingMark = true,
  }) async {
    if (clearPendingMark) _pendingSegmentMarkStart.add(null);
    await _loadSkippedChapterSegments(track);
    final playlist = await _playlistForTrack(track);
    if (playlist == null || !playlist.sponsorBlockEnabled) {
      _activeSegments = const [];
      _visibleSegments = const [];
      _sponsorBlockSegments.add(const []);
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

    _visibleSegments = visible;
    _publishSegmentsForCurrentItem();
    _activeSegments = _mergeSegments(
      visible
          .where((segment) => segment.shouldSkip)
          .map((segment) => _SkipSegment(segment.startMs, segment.endMs))
          .toList(),
    );
  }

  /// Reads the chapters of [track] marked Always skip from the database (the
  /// given row may be older than the last skip change).
  Future<void> _loadSkippedChapterSegments(Track track) async {
    final row = await _db.getTrack(track.id);
    final data = ChapterData.decode((row ?? track).chaptersJson);
    final ranges = [
      for (final c in data.active)
        if (data.isSkipped(c.id)) _SkipSegment(c.startMs, c.endMs),
    ];
    final exempt = _skipExemptChapterSegment;
    _skippedChapterRanges = ranges;
    // Keep playing a skipped chapter the user chose while its range stays.
    _setSkipExemptChapter(
      exempt == null
          ? null
          : ranges
              .where(
                (s) => s.startMs <= exempt.startMs && s.endMs >= exempt.endMs,
              )
              .firstOrNull,
    );
  }

  void _clearSkippedChapterSegments() {
    _skippedChapterRanges = const [];
    _setSkipExemptChapter(null);
  }

  /// Exempts [range] (one of [_skippedChapterRanges], or none) and rebuilds
  /// the ranges that are jumped over. Only that chapter plays: a skipped
  /// chapter right after it is still jumped over.
  void _setSkipExemptChapter(_SkipSegment? range) {
    _skipExemptChapterSegment = range;
    _skippedChapterSegments = _mergeSegments([
      for (final r in _skippedChapterRanges)
        if (!identical(r, range)) r,
    ]);
  }

  /// Publishes the visible segments on the current item's own timeline.
  void _publishSegmentsForCurrentItem() {
    final chapter = currentItem?.chapter;
    final visible = _visibleSegments;
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
  }

  Future<Playlist?> _playlistForTrack(Track track) async {
    final current = _currentPlaylist.value;
    try {
      final playlist = await _db.getPlaylist(track.playlistId);
      if (playlist != current) _currentPlaylist.add(playlist);
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
        _completionHandled ||
        !_player.state.playing) {
      return;
    }
    // Skipped chapters only matter while the file plays whole; as chapters
    // they are left out of the queue, and one that plays was chosen.
    final skippedChapters =
        currentItem?.chapter == null
            ? _skippedChapterSegments
            : const <_SkipSegment>[];
    if (_activeSegments.isEmpty && skippedChapters.isEmpty) return;

    final durationMs =
        currentItem?.chapter?.endMs ?? _player.state.duration.inMilliseconds;
    final positionMs = position.inMilliseconds;
    for (final segment in [..._activeSegments, ...skippedChapters]) {
      if (positionMs < segment.startMs || positionMs >= segment.endMs) {
        continue;
      }
      final targetMs = segment.endMs + 250;
      if (durationMs > 0 && targetMs >= durationMs - 500) {
        // The segment runs to the end of the item. A command that is
        // already changing the item (such as a Next press) wins.
        if (_transitionsInFlight > 0) return;
        // End it exactly like a natural end: keep audio focus, advance once,
        // and let Play restart it instead of pausing in the segment again.
        _handleItemEnd();
        await _player.pause();
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

  // ---------------------------------------------------------------------
  // Transport.

  @override
  Future<void> pause() async {
    if (_loading) _pauseAfterLoad = true;
    await _player.pause();
    await _abandonFocus();
    _saveSession(force: true);
  }

  @override
  Future<void> resume() async {
    if (_loading) {
      // The file being opened plays when it is ready.
      _pauseAfterLoad = false;
      _pauseAfterLoadKeepFocus = false;
      return;
    }
    if (_loadedTrackId == null) {
      // Decided inside the command queue: the session restored at start-up
      // may still be loading, and a Play sent right then (headset, car,
      // notification) must open it rather than be dropped.
      await _transition(_resumeUnopened);
      return;
    }
    await _resumeOpened();
  }

  /// Play with nothing open: opens the current item (a restored session, or
  /// one whose open failed), or starts "Up next" when nothing is current.
  Future<void> _resumeUnopened() async {
    if (_loadedTrackId != null) {
      await _resumeOpened(inTransition: true);
      return;
    }
    final item = currentItem;
    if (item == null) {
      if (_idle) await _advance();
      return;
    }
    // Its file may have been renamed since.
    final current = await _db.getTrack(item.track.id);
    final filePath = _resolveTrackFile(current ?? item.track);
    if (filePath == null) {
      reportMessage('File not found: ${item.track.title}');
      return;
    }
    final result = await _loadAndPlay(
      item,
      filePath: filePath,
      startAt: _resumeAtSource,
    );
    if (result == _LoadResult.openFailed) await _abandonFocus();
  }

  Future<void> _resumeOpened({bool inTransition = false}) async {
    if (_queueEnded && _albumQueue.queued.isNotEmpty) {
      // Songs were queued after the end: play them, not the last song again.
      Future<void> playQueued() async {
        if (_queueEnded && _albumQueue.queued.isNotEmpty) await _advance();
      }

      await (inTransition ? playQueued() : _transition(playQueued));
      return;
    }
    if (!await _requestFocus()) return;
    try {
      // Play after the end restarts the item (and lets it advance again).
      if (_itemEnded) await _seek(Duration.zero, chosen: false);
      _completionHandled = false;
      await _player.play();
    } catch (_) {
      await _abandonFocus();
      rethrow;
    }
  }

  @override
  Future<void> togglePlayPause() async {
    final playing =
        _loading ? !(_pauseAfterLoad || _pauseAfterLoadKeepFocus) : isPlaying;
    if (playing) {
      await pause();
    } else {
      await resume();
    }
  }

  /// A seek by the user: one into a chapter marked Always skip plays it.
  @override
  Future<void> seekTo(Duration position) => _seek(position, chosen: true);

  /// Seeks the current item. [chosen] says the user picked [position]; an
  /// internal restart ([chosen] false) jumps over skipped chapters again.
  Future<void> _seek(Duration position, {required bool chosen}) async {
    final item = currentItem;
    final target = _seekTarget(item, position);
    final relative = item?.relativePosition(target) ?? target;
    _completionHandled = false;
    _itemEnded = false;
    _queueEnded = false;
    _boundaryHandled = false;
    if (_loadedTrackId == null && !_loading) {
      // Not opened yet (a restored session): start there on Play.
      if (item != null) {
        _resumeAtSource = target;
        _setPosition(relative, immediate: true);
      }
      return;
    }
    // Show the target at once; the player confirms it afterwards.
    _setPosition(relative, immediate: true);
    if (item?.chapter == null) {
      if (chosen) {
        _exemptSkippedChapterAt(target);
      } else {
        _setSkipExemptChapter(null);
      }
    }
    if (!await _waitUntilSeekable()) return;
    await _player.seek(target);
    _setPosition(relative, immediate: true);
  }

  /// Where [position] (on [item]'s own timeline) is in the file. A whole
  /// file is clamped to the length the player reports, never to the stored
  /// length, which can be missing or wrong (0 for some local files).
  Duration _seekTarget(PlaybackItem? item, Duration position) {
    if (item == null) return position;
    if (item.chapter != null) return item.sourcePosition(position);
    final ms = max(0, position.inMilliseconds);
    final real =
        _loadedTrackId != null && !_loading
            ? _player.state.duration.inMilliseconds
            : 0;
    return Duration(milliseconds: real > 0 ? min(ms, real) : ms);
  }

  /// A seek right after a file was opened is dropped by the player while it
  /// still loads it (it has no length yet). Waits briefly for the length.
  /// False when another file was opened meanwhile.
  Future<bool> _waitUntilSeekable() async {
    if (_player.state.duration > Duration.zero) return true;
    final generation = _generation;
    try {
      await _player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Seek anyway: some media never report a length.
    }
    return generation == _generation;
  }

  /// A seek into a chapter marked Always skip while the file plays whole is
  /// a choice to hear it, so that chapter is not jumped over this time.
  void _exemptSkippedChapterAt(Duration target) {
    final ms = target.inMilliseconds;
    _setSkipExemptChapter(
      _skippedChapterRanges
          .where((s) => ms >= s.startMs && ms < s.endMs)
          .firstOrNull,
    );
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

  /// Next item. Rapid presses are coalesced: every press moves one item, but
  /// only the item reached by the last press is opened.
  @override
  Future<void> next() {
    final completionPending = _completionAdvancePending;
    final fromId = currentMediaId;
    _pendingNext++;
    return _transition(() async {
      _pendingNext--;
      // A natural completion queued just before this press already moved on.
      if (completionPending && currentMediaId != fromId) return;
      if (_pendingNext > 0) {
        await _stepWithoutLoading(forward: true);
        return;
      }
      if (await _advance() == _AdvanceResult.nothingLeft &&
          _loadedTrackId != null) {
        reportMessage('End of the queue');
      }
    });
  }

  @override
  Future<void> nextFile() {
    final completionPending = _completionAdvancePending;
    final fromTrackId = currentTrack?.id;
    return _transition(() async {
      if (completionPending && currentTrack?.id != fromTrackId) return;
      if (await _advance(skipFile: true) == _AdvanceResult.nothingLeft) {
        _completionHandled = true;
        _itemEnded = true;
        await _player.pause();
      }
    });
  }

  /// Restarts the item when more than 3 seconds have played, otherwise goes
  /// to the previous item. Rapid presses are coalesced like [next].
  @override
  Future<void> previous() {
    _pendingPrevious++;
    return _transition(() async {
      _pendingPrevious--;
      if (_pendingSkipTarget == null && position.inSeconds > 3) {
        await _seek(Duration.zero, chosen: false);
        return;
      }
      if (_pendingPrevious > 0) {
        await _stepWithoutLoading(forward: false);
        return;
      }
      if (await _advance(forward: false) == _AdvanceResult.nothingLeft &&
          _loadedTrackId != null) {
        await _seek(Duration.zero, chosen: false);
      }
    });
  }

  // ---------------------------------------------------------------------
  // Modes.

  /// Shuffle on mixes every song not played yet (also those above the
  /// current one); shuffle off continues in playlist order after the
  /// current song. The current song keeps playing either way.
  void setShuffleEnabled(bool enabled) {
    if (_shuffleEnabled.value != enabled) {
      _shuffleEnabled.add(enabled);
      _remember((store) => store.saveShuffle(enabled));
    }
    unawaited(
      _transition(() async {
        _albumQueue.setShuffle(shuffleEnabled);
        _publishQueue();
      }),
    );
  }

  @override
  void toggleShuffle() => setShuffleEnabled(!_shuffleEnabled.value);

  void setAutoplayEnabled(bool enabled) {
    if (_autoplayEnabled.value == enabled) return;
    _autoplayEnabled.add(enabled);
    _remember((store) => store.saveAutoplay(enabled));
  }

  void toggleAutoplay() => setAutoplayEnabled(!_autoplayEnabled.value);

  /// Pause when the current song (or chapter) ends.
  void setStopAfterCurrent(bool enabled) {
    if (_stopAfterCurrent.value != enabled) _stopAfterCurrent.add(enabled);
  }

  /// Switches video decoding off or on without remembering the choice; for
  /// temporary changes. User choices go through [setAudioOnlyPreference].
  @override
  Future<void> setAudioOnlyMode(bool enabled) {
    final transition = _videoTrackTransition.then<void>((_) async {
      if (_audioOnlyMode.value == enabled) return;

      // Select the native video track before changing the Flutter surface.
      // Audio-only therefore stops video decoding instead of just hiding it.
      final native = _nativePlayer;
      if (native != null) {
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

  NativePlayer? get _nativePlayer {
    try {
      final platform = _player.platform;
      return platform is NativePlayer ? platform : null;
    } catch (_) {
      return null;
    }
  }

  /// The user's own audio-only choice: applied and remembered across
  /// restarts. It also cancels a temporary audio-only mode.
  Future<void> setAudioOnlyPreference(bool enabled) {
    _temporaryAudioOnly = false;
    _remember((store) => store.saveAudioOnly(enabled));
    return setAudioOnlyMode(enabled);
  }

  Future<void> toggleAudioOnlyMode() =>
      setAudioOnlyPreference(!_audioOnlyMode.value);

  /// Switches plane mode on or off for the song that is playing and the
  /// ones after it, without remembering the choice.
  Future<void> setPlaneMode(bool enabled) =>
      _updateAudioSettings(_audioSettings.value.copyWith(planeMode: enabled));

  /// The user's own plane mode choice: applied and remembered across
  /// restarts.
  Future<void> setPlaneModePreference(bool enabled) {
    _remember((store) => store.savePlaneMode(enabled));
    return setPlaneMode(enabled);
  }

  Future<void> togglePlaneMode() =>
      setPlaneModePreference(!_audioSettings.value.planeMode);

  /// How hard plane mode works. Remembered by the app settings.
  Future<void> setPlaneModeStrength(PlaneModeStrength strength) =>
      _updateAudioSettings(_audioSettings.value.copyWith(strength: strength));

  /// "Even out volume": every song at a similar loudness. Remembered by the
  /// app settings.
  Future<void> setEvenOutVolume(bool enabled) => _updateAudioSettings(
    _audioSettings.value.copyWith(evenOutVolume: enabled),
  );

  /// How "Even out volume" levels songs. Remembered by the app settings.
  Future<void> setEvenOutMode(EvenOutMode mode) =>
      _updateAudioSettings(_audioSettings.value.copyWith(evenOutMode: mode));

  /// Lets the player use measured loudness, and asks for the songs it
  /// plays to be measured first.
  void attachLoudness(TrackLoudnessSource source) {
    unawaited(_loudnessMeasured?.cancel());
    _loudness = source;
    _loudnessMeasured = source.measuredFiles.listen(_onLoudnessMeasured);
    final needed = _audioSettings.value.needsLoudness;
    source.setEnabled(needed);
    if (needed) _prioritizeLoudness();
  }

  /// The playing song was measured only after it started (it was tapped
  /// before measuring got to it): it gets its level now, unless it has
  /// played for a while already.
  void _onLoudnessMeasured(LoudnessJob job) {
    if (!_audioSettings.value.needsLoudness) return;
    if (job.trackId != _loadedTrackId || job.path != _currentFilePath) return;
    if (currentItem?.track.id != job.trackId) return;
    if (_position.value > _reapplyLoudnessWithin) return;
    unawaited(_applyAudioProcessing(job.trackId, job.path));
  }

  Future<void> _updateAudioSettings(AudioProcessingSettings settings) async {
    if (_audioSettings.isClosed || _audioSettings.value == settings) return;
    _audioSettings.add(settings);
    // Measuring is switched before the request, which it would drop while
    // off.
    _loudness?.setEnabled(settings.needsLoudness);
    if (settings.needsLoudness) _prioritizeLoudness();
    // The song that is playing (or opening) changes at once.
    final trackId = currentItem?.track.id;
    final path = _currentFilePath;
    if (trackId == null || path == null) return;
    await _applyAudioProcessing(trackId, path);
  }

  /// Gives mpv the filters and gain for [trackId]'s file at [path]. Never
  /// throws: playback goes on unprocessed rather than not at all.
  Future<void> _applyAudioProcessing(int trackId, String path) {
    final next = _audioPlanTransition.then((_) async {
      try {
        final settings = _audioSettings.value;
        MeasuredLoudness? loudness;
        if (settings.needsLoudness) {
          try {
            loudness = await _loudness?.loudnessFor(trackId, path);
          } catch (_) {}
        }
        await _setAudioPlan(planAudioProcessing(settings, loudness));
      } catch (e) {
        debugPrint('Could not apply audio processing: $e');
      }
    });
    _audioPlanTransition = next;
    return next;
  }

  Future<void> _setAudioPlan(AudioProcessingPlan plan) async {
    final applied = _appliedAudioPlan;
    if (plan.filters != applied.filters) {
      if (!await _setMpvProperty('af', plan.filters)) return;
      _appliedAudioPlan = AudioProcessingPlan(
        filters: plan.filters,
        gainDb: applied.gainDb,
      );
    }
    if (plan.gainDb != _appliedAudioPlan.gainDb) {
      if (!await _setMpvProperty('replaygain-fallback', plan.gainText)) return;
      _appliedAudioPlan = plan;
    }
  }

  /// Sets an mpv option on the main player. False when there is no mpv
  /// (tests and platforms without libmpv).
  Future<bool> _setMpvProperty(String name, String value) async {
    final override = _setMpvPropertyOverride;
    if (override != null) {
      await override(name, value);
      return true;
    }
    final native = _nativePlayer;
    if (native == null) return false;
    await native.setProperty(name, value);
    return true;
  }

  /// Asks for the current song and the next few to be measured first.
  void _prioritizeLoudness() {
    final loudness = _loudness;
    if (loudness == null || !_audioSettings.value.needsLoudness) return;
    final items = _albumQueue.items;
    final start = _albumQueue.current == null ? 0 : _albumQueue.index;
    final jobs = <LoudnessJob>[];
    final seen = <int>{};
    for (var i = start; i < items.length && jobs.length < 4; i++) {
      final track = items[i].track;
      if (!seen.add(track.id) || !isTrackPlayable(track)) continue;
      final path =
          track.id == _loadedTrackId && _currentFilePath != null
              ? _currentFilePath
              : _resolveTrackFile(track);
      if (path != null) jobs.add(LoudnessJob(track.id, path));
    }
    if (jobs.isNotEmpty) loudness.prioritize(jobs);
  }

  /// Audio-only for a situation without a screen (car, picture-in-picture
  /// headphone button). [restoreTemporaryAudioOnly] undoes it, unless the
  /// user changed the mode in between. Does nothing when audio-only is on
  /// already.
  @override
  Future<void> enableTemporaryAudioOnly() async {
    if (_audioOnlyMode.value) return;
    _temporaryAudioOnly = true;
    await setAudioOnlyMode(true);
  }

  /// Switches video back on if [enableTemporaryAudioOnly] switched it off.
  @override
  Future<void> restoreTemporaryAudioOnly() async {
    if (!_temporaryAudioOnly) return;
    _temporaryAudioOnly = false;
    try {
      await setAudioOnlyMode(false);
    } catch (_) {
      _temporaryAudioOnly = true;
      rethrow;
    }
  }

  void startSleepTimer(Duration duration) => _sleepTimer.start(duration);

  void cancelSleepTimer() => _sleepTimer.cancel();

  @override
  Future<void> stop() => _transition(_stopNow);

  Future<void> _stopNow() async {
    _generation++;
    _loadedTrackId = null;
    _currentFilePath = null;
    _chapterEditing = false;
    _completionHandled = true;
    _itemEnded = false;
    _queueEnded = false;
    _boundaryHandled = false;
    _openedEndMs = null;
    _resumeAtSource = null;
    _resumeAfterEdit = null;
    _pendingSkipTarget = null;
    _skipOrigin = null;
    _cancelLoadWatch();
    _sleepTimer.cancel();
    if (_stopAfterCurrent.value) _stopAfterCurrent.add(false);
    await _player.stop();
    _syncPlaying(false);
    await _abandonFocus();
    _currentTrack.add(null);
    _currentPlaylist.add(null);
    _albumQueue.clear();
    _publishQueue();
    _currentItem.add(null);
    _setPosition(Duration.zero, immediate: true);
    _setDuration(Duration.zero);
    _activeSegments = const [];
    _clearSkippedChapterSegments();
    _visibleSegments = const [];
    _sponsorBlockSegments.add(const []);
    _pendingSegmentMarkStart.add(null);
    if (_detectedVideo.value != null) _detectedVideo.add(null);
    _lastSavedSession = null;
    _remember((store) => store.saveSession(null));
  }

  /// Call before playlist [playlistId] is deleted: its songs leave the
  /// queue and "Up next", and when one of them is the current song,
  /// playback stops (its file may be deleted with it).
  Future<void> playlistRemoved(int playlistId) =>
      _removeTracksWhere((track) => track.playlistId == playlistId);

  /// Call before the tracks [trackIds] are deleted: they leave the queue
  /// and "Up next", and when one of them is the current song, playback
  /// stops (its file is deleted with it).
  Future<void> tracksRemoved(Set<int> trackIds) =>
      _removeTracksWhere((track) => trackIds.contains(track.id));

  Future<void> _removeTracksWhere(bool Function(Track track) removed) =>
      _transition(() async {
        final item = currentItem;
        if (item != null && removed(item.track)) {
          await _stopNow();
          return;
        }
        _albumQueue.removeTracksWhere(removed);
        final pending = _pendingSkipTarget;
        if (pending != null && removed(pending.item.track)) {
          _pendingSkipTarget = null;
        }
        _publishQueue();
      });

  // ---------------------------------------------------------------------
  // Remembering settings and the last song.

  void _remember(Future<void> Function(PlaybackSettingsStore store) save) {
    final store = _settingsStore;
    if (store == null) return;
    unawaited(Future<void>.sync(() => save(store)).catchError((Object _) {}));
  }

  void _saveSession({bool force = false}) {
    if (_settingsStore == null) return;
    final item = currentItem;
    if (item == null) return;
    final position =
        _loadedTrackId == null
            ? (_resumeAtSource ?? Duration(milliseconds: item.startMs))
            : _player.state.position;
    final session = PlaybackSession(
      playlistId: item.track.playlistId,
      trackId: item.track.id,
      chapterId: item.chapter?.id,
      positionMs: position.inMilliseconds,
      whole: item.chapter == null,
    );
    if (!force && session == _lastSavedSession) return;
    _lastSavedSession = session;
    _lastSessionSaveAt = _clock.elapsed;
    _remember((store) => store.saveSession(session));
  }

  void _maybeSaveSessionPeriodically() {
    if (_settingsStore == null) return;
    if (_clock.elapsed - _lastSessionSaveAt < sessionSaveInterval) return;
    _saveSession();
  }

  Future<void> _restorePersistedState() async {
    final PlaybackPreferences preferences;
    try {
      preferences = await _settingsStore!.load();
    } catch (_) {
      return;
    }
    final shuffle = preferences.shuffle;
    if (shuffle != null && shuffle != _shuffleEnabled.value) {
      _shuffleEnabled.add(shuffle);
    }
    final autoplay = preferences.autoplay;
    if (autoplay != null && autoplay != _autoplayEnabled.value) {
      _autoplayEnabled.add(autoplay);
    }
    final audioOnly = preferences.audioOnly ?? false;
    if (audioOnly) {
      unawaited(setAudioOnlyMode(true).catchError((Object _) {}));
    }
    if (preferences.planeMode == true) {
      unawaited(setPlaneMode(true).catchError((Object _) {}));
    }
    final session = preferences.session;
    if (session != null && currentItem == null) {
      try {
        await _restoreSession(session, audioOnly: audioOnly);
      } catch (_) {}
    }
  }

  /// Shows the last song again, paused and not yet opened, in its playlist
  /// queue. Play opens it at the remembered position. Video files are not
  /// restored, so start-up never opens the video player by itself.
  Future<void> _restoreSession(
    PlaybackSession session, {
    required bool audioOnly,
  }) async {
    final tracks = await _db.getTracksForPlaylist(session.playlistId);
    final track = tracks.where((t) => t.id == session.trackId).firstOrNull;
    if (track == null || !isTrackPlayable(track)) return;
    final path = _resolveTrackFile(track);
    if (path == null || (!audioOnly && _isVideoFile(path))) return;
    final groups = await _buildAlbums(
      playableTracksForPlayback(tracks, directlySelectedTrackId: track.id),
      trackId: track.id,
      chapterId: session.chapterId,
      whole: session.whole,
    );
    if (!groups.any((g) => g.trackId == track.id)) return;
    final item = _albumQueue.start(
      groups,
      trackId: track.id,
      chapterId: session.chapterId,
      shuffled: shuffleEnabled,
    );
    if (item == null || item.track.id != track.id) {
      _albumQueue.clear();
      return;
    }
    var at = Duration(milliseconds: session.positionMs);
    final chapter = item.chapter;
    if (chapter != null &&
        (at.inMilliseconds < chapter.startMs ||
            at.inMilliseconds >= chapter.endMs)) {
      at = Duration(milliseconds: chapter.startMs);
    }
    _currentFilePath = path;
    _resumeAtSource = at;
    _completionHandled = true;
    _currentItem.add(item);
    _currentTrack.add(item.displayTrack);
    _setDuration(item.duration ?? Duration.zero);
    _setPosition(item.relativePosition(at), immediate: true);
    _publishQueue();
    _lastSavedSession = session;
    await _loadActiveSegments(item.track);
  }

  Future<void> dispose() async {
    // Stop every producer before closing the subjects they feed, otherwise a
    // late player event could add to a closed stream.
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _loudnessMeasured?.cancel();
    _loudnessMeasured = null;
    _uiPositionTimer?.cancel();
    _cancelLoadWatch();
    _sleepTimer.dispose();
    await _audioFocusController?.dispose();
    await _player.dispose();
    await Future.wait([
      _currentItem.close(),
      _position.close(),
      _uiPosition.close(),
      _duration.close(),
      _playing.close(),
      _currentTrack.close(),
      _currentPlaylist.close(),
      _queue.close(),
      _upNextQueue.close(),
      _queueIndex.close(),
      _shuffleEnabled.close(),
      _autoplayEnabled.close(),
      _audioOnlyMode.close(),
      _audioSettings.close(),
      _stopAfterCurrent.close(),
      _pendingSegmentMarkStart.close(),
      _sponsorBlockSegments.close(),
      _detectedVideo.close(),
      _messages.close(),
    ]);
  }
}
