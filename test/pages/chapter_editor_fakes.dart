import 'dart:async';
import 'dart:typed_data';

import 'package:woolytube/services/chapter_preview_player.dart';
import 'package:woolytube/services/recognition/audio_window_decoder.dart';
import 'package:woolytube/services/waveform_service.dart';

/// A preview player that records what it was asked to play and changes
/// state at once, with no timers, so widget tests stay deterministic.
class FakePreviewPlayer implements ChapterPreviewPlayer {
  FakePreviewPlayer(this.filePath, {this.durationMs = 180000});

  @override
  final String filePath;
  int durationMs;

  /// Makes [ensureOpen] fail like a file the player cannot open.
  bool failOpen = false;

  final ranges = <PreviewRange>[];

  /// The rest position asked for with each of [ranges].
  final rests = <int?>[];
  final seeks = <int>[];

  /// The seeks that parked the playhead.
  final parkedSeeks = <int>[];
  int plays = 0;
  int pauses = 0;
  int opens = 0;
  bool disposed = false;

  bool _opened = false;
  int _position = 0;
  bool _playing = false;
  bool _parked = false;
  int? _rest;
  PreviewRange? _range;
  final _durations = StreamController<Duration>.broadcast(sync: true);
  final _positions = StreamController<int>.broadcast(sync: true);
  final _playingChanges = StreamController<bool>.broadcast(sync: true);
  final _rangeChanges = StreamController<PreviewRange?>.broadcast(sync: true);

  @override
  Duration get duration =>
      _opened ? Duration(milliseconds: durationMs) : Duration.zero;
  @override
  Stream<Duration> get durationStream => _durations.stream;
  @override
  int get positionMs => _position;
  @override
  Stream<int> get positionMsStream => _positions.stream;
  @override
  bool get isPlaying => _playing;
  @override
  Stream<bool> get playingStream => _playingChanges.stream;
  @override
  bool get parked => _parked;
  @override
  int? get restMs => _range == null ? null : _rest;
  @override
  PreviewRange? get activeRange => _range;
  @override
  Stream<PreviewRange?> get activeRangeStream => _rangeChanges.stream;

  /// Moves the playhead as playback would.
  set position(int ms) {
    _position = ms;
    _positions.add(ms);
  }

  void _setPlaying(bool playing) {
    if (_playing == playing) return;
    _playing = playing;
    _playingChanges.add(playing);
  }

  void _setRange(PreviewRange? range) {
    _range = range;
    _rangeChanges.add(range);
  }

  /// The range reached its end: paused and resting where the range said
  /// (its rest position, else its end), as the real player does.
  void finish() {
    final range = _range;
    final rest = range == null ? null : (_rest ?? range.endMs ?? durationMs);
    _setRange(null);
    if (range != null) _parked = true;
    _setPlaying(false);
    if (rest != null) position = rest;
  }

  /// A command that ends any range and the parked state.
  void _command() {
    _parked = false;
    _rest = null;
    _setRange(null);
  }

  @override
  Future<void> ensureOpen() async {
    opens++;
    if (failOpen) throw StateError('Could not open the file');
    if (_opened) return;
    _opened = true;
    _durations.add(duration);
  }

  @override
  Future<void> playRange(
    int startMs, {
    int? endMs,
    bool loop = false,
    int? restMs,
  }) async {
    _command();
    await ensureOpen();
    final range = (startMs: startMs, endMs: endMs, loop: loop);
    ranges.add(range);
    rests.add(restMs);
    _rest = restMs;
    position = startMs;
    _setRange(range);
    _setPlaying(true);
  }

  @override
  Future<void> play() async {
    _command();
    await ensureOpen();
    plays++;
    _setPlaying(true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    _command();
    _setPlaying(false);
  }

  @override
  Future<void> seek(int ms, {bool park = false}) async {
    _command();
    _parked = park;
    await ensureOpen();
    seeks.add(ms);
    if (park) parkedSeeks.add(ms);
    position = ms;
  }

  @override
  void moveRest(int ms) {
    if (_range != null) _rest = ms;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _setPlaying(false);
  }
}

/// Makes a preview player per file and keeps the last one.
class FakePreviewFactory {
  FakePreviewFactory({this.durationMs = 180000});

  final int durationMs;
  final made = <FakePreviewPlayer>[];
  bool failOpen = false;

  FakePreviewPlayer get last => made.last;

  ChapterPreviewPlayer call(String path) {
    final player = FakePreviewPlayer(path, durationMs: durationMs)
      ..failOpen = failOpen;
    made.add(player);
    return player;
  }
}

/// Loud audio everywhere except a silent stretch at [quietFromMs] to
/// [quietToMs].
class ToneDecoder implements AudioWindowDecoder {
  ToneDecoder({this.quietFromMs = -1, this.quietToMs = -1});

  final int quietFromMs;
  final int quietToMs;
  int requests = 0;

  @override
  Future<Int16List> decode(
    String path, {
    required Duration start,
    required Duration duration,
  }) async {
    requests++;
    final from = start.inMilliseconds;
    final count = duration.inMilliseconds * 16;
    final out = Int16List(count);
    for (var i = 0; i < count; i++) {
      final ms = from + i ~/ 16;
      final quiet = ms >= quietFromMs && ms < quietToMs;
      final level = quiet ? 0 : 12000;
      out[i] = i.isEven ? level : -level;
    }
    return out;
  }

  @override
  Future<Duration?> probeDuration(String path) async => null;
}

WaveformService fakeWaveforms({int quietFromMs = -1, int quietToMs = -1}) =>
    WaveformService(
      ToneDecoder(quietFromMs: quietFromMs, quietToMs: quietToMs),
    );
