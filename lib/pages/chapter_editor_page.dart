import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/chapter_editor_providers.dart';
import '../services/chapter_draft.dart';
import '../services/chapter_preview_player.dart';
import '../services/chapters.dart';
import '../services/waveform_service.dart';
import '../widgets/chapter_editor/editor_style.dart';
import '../widgets/chapter_editor/overview_strip.dart';
import '../widgets/chapter_editor/waveform_lens.dart';

/// What the listen buttons play around a boundary.
enum _Listen { end, across, start }

/// The playhead and the player's state at one moment.
typedef _TapState = ({int ms, bool playing, bool parked, bool known});

/// Edits one file's chapter list while listening: pick a boundary, hear
/// the audio on either side of it, and move it by dragging the waveform,
/// nudging or tapping "Set here" while it plays. Works the same for YouTube
/// chapters, recognised ones and a file with no chapters yet.
///
/// Nothing is stored until [onSave]. Saving keeps the editor open (unless
/// [closeOnSave]); leaving pops the page with whether anything was saved.
class ChapterEditorPage extends ConsumerStatefulWidget {
  const ChapterEditorPage({
    super.key,
    required this.track,
    required this.initial,
    this.durationMs,
    this.focusChapterId,
    required this.saveLabel,
    required this.onSave,
    this.title = 'Edit chapters',
    this.notesById = const {},
    this.closeOnSave = false,
    this.playingAtMs,
    this.playerPositionMs,
  });

  final Track track;
  final List<MediaChapter> initial;

  /// The file length when known; the preview player's real length is used
  /// once the file is open.
  final int? durationMs;

  /// The chapter whose start is selected when the editor opens.
  final String? focusChapterId;
  final String saveLabel;

  /// Stores the result. Returns whether anything changed; throws (with a
  /// message for the user) when it cannot be saved.
  final Future<bool> Function(List<MediaChapter> result, int durationMs) onSave;
  final String title;

  /// Review notes shown under chapters.
  final Map<String, List<String>> notesById;

  /// Leaves the editor after a successful save, for a save that hands the
  /// result back ("Done") rather than storing it.
  final bool closeOnSave;

  /// Where the app's player is in this file when the editor opens, when it
  /// plays (or paused on) this file. Without [focusChapterId] the editor
  /// then opens on the start of the chapter there, with the preview
  /// playhead on that exact spot.
  final int? playingAtMs;

  /// Where the app's player is in this file as it moves, or null once it
  /// is on another file. Shown in the top bar.
  final Stream<int?>? playerPositionMs;

  /// Forgets the choices kept for the session (zoom, lead time, replay).
  @visibleForTesting
  static void resetSessionChoices() {
    _ChapterEditorPageState._dragHintSeen = false;
    _ChapterEditorPageState._autoReplay = true;
    _ChapterEditorPageState._leadMs = 4000;
    _ChapterEditorPageState._spanMs = 8000;
  }

  @override
  ConsumerState<ChapterEditorPage> createState() => _ChapterEditorPageState();
}

class _ChapterEditorPageState extends ConsumerState<ChapterEditorPage>
    with SingleTickerProviderStateMixin {
  // Kept for the app session, like a tool's settings.
  static bool _dragHintSeen = false;
  static bool _autoReplay = true;
  static int _leadMs = 4000;
  static int _spanMs = 8000;

  static const _leads = [2000, 4000, 8000];
  static const _zooms = [2000, 8000, 30000];
  static const _nudges = [-1000, -100, -10, 10, 100, 1000];

  /// A "Set here" this soon after playback started on the boundary ("Hear
  /// start", "Play" from a resting playhead, "Play its start") is a
  /// reaction to the music starting, not to the change.
  static const _reactionGuardMs = 600;

  /// How long after a preview stopped by itself a tap still gets told it
  /// came too late, instead of being ignored.
  static const _lateTapMs = 700;

  late ChapterDraft _draft;
  late List<DraftEdge> _edges;

  /// The chapters as they were when the editor opened or was last saved.
  late Map<String, MediaChapter> _initialById;

  /// The selected boundary, by [DraftEdge.key]; [_selectedHint] finds the
  /// closest one when the key no longer exists.
  String? _selectedKey;
  int _selectedHint = 0;

  /// Where the selected boundary is while a drag or a held nudge moves it.
  /// Committed (one undo step) when the finger lifts.
  int? _pendingMs;

  String? _path;
  ChapterPreviewPlayer? _preview;
  WaveformService? _waveforms;
  String? _playerError;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// The preview playhead, smooth while playing. Only the widgets that draw
  /// it listen, so the page does not rebuild every frame.
  final _playhead = ValueNotifier<int>(0);
  late final Ticker _ticker;
  bool _playing = false;
  bool _playheadKnown = false;

  /// Where the playhead was put (the app player's spot on opening, or a
  /// seek) while the preview is not there yet: until its file is open,
  /// which can take seconds, the preview's position reads 0.
  int? _seekPendingMs;

  /// The playhead, and the player's state, when a finger went down on Set
  /// here or Split here. A tap counts when the finger lifts, 60–120 ms after
  /// it touched, by when a preview may already have stopped.
  _TapState? _down;
  int _downAt = 0;
  final _clock = Stopwatch()..start();

  /// Where playback last started: a preview's start, a resume or a seek.
  int? _playFromMs;

  /// A preview stopped by itself less than [_lateTapMs] ago.
  bool _endedRecently = false;
  Timer? _endedTimer;

  _Listen _lastMode = _Listen.start;
  _Listen? _requestedMode;
  _Listen? _activeMode;
  int _rangeRequests = 0;
  bool _loop = false;
  Timer? _replayTimer;

  int? _quietMs;
  int? _quietFor;
  bool _quietLoading = false;
  int _quietRequest = 0;

  /// Whether the file's length is known (given, or reported by the preview
  /// player). Otherwise the draft's length is only the last chapter's end
  /// and is not saved as the file's length.
  bool _durationKnown = false;

  bool _saving = false;

  /// Something was saved since the editor opened: leaving pops with true.
  bool _savedAny = false;

  /// Where the app's player is in this file, for the top bar.
  late final ValueNotifier<int?> _playerAt;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _draft = ChapterDraft.fromChapters(
      widget.initial,
      durationMs: widget.durationMs ?? 0,
      notesById: widget.notesById,
    );
    _edges = _draft.edges;
    _durationKnown = (widget.durationMs ?? 0) > 0;
    _initialById = {for (final c in widget.initial) c.id: c};
    _selectInitial();
    _ticker = createTicker((_) => _setPlayhead(_preview?.positionMs ?? 0));
    _playerAt = ValueNotifier(widget.playingAtMs);
    final positions = widget.playerPositionMs;
    if (positions != null) {
      _subscriptions.add(
        positions.listen((ms) {
          if (mounted) _playerAt.value = ms;
        }),
      );
    }
    _waveforms = ref.read(waveformServiceProvider);
    final path = _path = resolveTrackMediaPath(widget.track);
    if (path == null) {
      _playerError = 'The file is missing, so it cannot be played here.';
    } else {
      final preview =
          _preview = ref.read(chapterPreviewPlayerFactoryProvider)(path);
      _listenTo(preview);
      unawaited(_open());
      final playingAt = widget.playingAtMs;
      if (playingAt != null) {
        // The playhead starts where the app's player is: Play goes on from
        // there, and Set here moves the boundary there. A failed open is
        // shown by _open.
        _setPlayhead(playingAt);
        _playheadKnown = true;
        _seekPendingMs = playingAt;
        unawaited(_seekToPending());
      }
    }
    _refreshQuiet();
  }

  @override
  void dispose() {
    _replayTimer?.cancel();
    _endedTimer?.cancel();
    _ticker.dispose();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    final preview = _preview;
    _preview = null;
    if (preview != null) unawaited(preview.dispose());
    _playhead.dispose();
    _playerAt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- player

  void _listenTo(ChapterPreviewPlayer preview) {
    _subscriptions.addAll([
      preview.playingStream.listen((playing) {
        if (!mounted) return;
        _endedTimer?.cancel();
        _endedRecently = false;
        if (playing) {
          _playheadKnown = true;
          // Playing, the preview is open and where it plays from.
          _seekPendingMs = null;
          if (!_ticker.isActive) unawaited(_ticker.start());
        } else {
          _ticker.stop();
          _setPlayhead(preview.positionMs);
          if (preview.parked) {
            // A preview stopped by itself. Keep Set here lit a moment so a
            // tap that just missed it is told so, then rebuild without it.
            _endedRecently = true;
            _endedTimer = Timer(const Duration(milliseconds: _lateTapMs), () {
              if (mounted) setState(() => _endedRecently = false);
            });
          }
        }
        setState(() => _playing = playing);
      }),
      preview.positionMsStream.listen((_) {
        if (!_playing && mounted) {
          _setPlayhead(_seekPendingMs ?? preview.positionMs);
        }
      }),
      preview.durationStream.listen(_useDuration),
      preview.activeRangeStream.listen((range) {
        if (!mounted) return;
        // A new preview first clears the old range; keep the button lit.
        if (range == null && _rangeRequests > 0) return;
        setState(() => _activeMode = range == null ? null : _requestedMode);
      }),
    ]);
  }

  Future<void> _open() async {
    final preview = _preview;
    if (preview == null) return;
    try {
      await preview.ensureOpen();
    } on StateError catch (e) {
      if (!mounted) return;
      setState(
        () =>
            _playerError =
                e.message == 'Could not open the file'
                    ? 'Could not open the file, so listening is not '
                        'available.'
                    : e.message,
      );
      return;
    }
    if (!mounted) return;
    _useDuration(preview.duration);
  }

  Future<void> _retryOpen() async {
    setState(() => _playerError = null);
    await _open();
    if (mounted && _playerError == null) await _seekToPending();
  }

  /// Moves the preview to [_seekPendingMs]. A failed open is shown by
  /// [_open], and Retry seeks again.
  Future<void> _seekToPending() async {
    final preview = _preview;
    final at = _seekPendingMs;
    if (preview == null || at == null) return;
    try {
      await preview.seek(at);
    } catch (_) {
      return;
    }
    if (mounted) _seekLanded(preview);
  }

  /// Forgets [_seekPendingMs] once the preview is there. It stays when the
  /// seek failed or another command overtook it before the file opened.
  void _seekLanded(ChapterPreviewPlayer preview) {
    final at = _seekPendingMs;
    if (at == null) return;
    final length = preview.duration.inMilliseconds;
    final target = length > 0 ? min(at, length) : at;
    if ((preview.positionMs - target).abs() <= 5) _seekPendingMs = null;
  }

  void _useDuration(Duration duration) {
    final ms = duration.inMilliseconds;
    if (!mounted || ms <= 0) return;
    if (ms == _draft.durationMs) {
      if (!_durationKnown) setState(() => _durationKnown = true);
      return;
    }
    setState(() {
      _durationKnown = true;
      _draft = _draft.withDuration(ms);
    });
  }

  void _setPlayhead(int ms) => _playhead.value = ms;

  int get _playheadMs =>
      _seekPendingMs ?? _preview?.positionMs ?? _playhead.value;

  _TapState get _tapStateNow => (
    ms: _playheadMs,
    playing: _playing,
    parked: _preview?.parked ?? false,
    known: _playheadKnown,
  );

  void _captureDown() {
    _down = _tapStateNow;
    _downAt = _clock.elapsedMilliseconds;
  }

  /// The finger lifted or left without a tap: forget it once the tap (if
  /// any) has been handled, so Set here does not stay lit for it.
  void _releaseDown() {
    scheduleMicrotask(() {
      if (mounted && _down != null) setState(() => _down = null);
    });
  }

  bool get _downFresh => _clock.elapsedMilliseconds - _downAt < 1000;

  /// The playhead and the player's state when the finger touched, if that
  /// was just now; else as they are now.
  _TapState _tapped() {
    final down = _down;
    _down = null;
    return down != null && _downFresh ? down : _tapStateNow;
  }

  /// Whether the playhead was somewhere the user put it: playing, or paused
  /// by them, by a seek or a scrub. Not after a preview ended, when it
  /// rests on the boundary.
  static bool _chosen(_TapState tap) =>
      tap.playing || (tap.known && !tap.parked);

  bool get _playheadChosen => _chosen(_tapStateNow);

  /// A finger is on Set here since a moment when the playhead was chosen;
  /// the button stays lit for it even if the preview stops before it lifts.
  bool get _downPending {
    final down = _down;
    return down != null && _chosen(down) && _downFresh;
  }

  /// A preview stopped by itself just now.
  bool get _justEnded => _endedRecently && (_preview?.parked ?? false);

  static const _lateTapMessage =
      'Too late – the preview had already stopped. Tap while it plays; Play '
      'across plays on past the boundary.';

  /// Whether a tap at [at] during playback came too soon after playback
  /// started on the boundary [edge] to be a reaction to the change.
  bool _reactsToStart(DraftEdge edge, int at) {
    final from = _playFromMs;
    return from != null &&
        (edge.ms - from).abs() <= 50 &&
        at >= from &&
        at - from < _reactionGuardMs;
  }

  /// Runs a preview command, showing why it failed.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on StateError catch (e) {
      _message(
        e.message == 'Could not open the file'
            ? 'Could not open the file to play it.'
            : e.message,
      );
    }
  }

  Future<void> _playRange(
    int startMs,
    int endMs, {
    _Listen? mode,
    int? restMs,
  }) async {
    final preview = _preview;
    if (preview == null) return;
    _replayTimer?.cancel();
    _requestedMode = mode;
    if (mode != null) _lastMode = mode;
    _playheadKnown = true;
    _playFromMs = max(0, startMs);
    _seekPendingMs = null;
    setState(() => _activeMode = mode);
    _rangeRequests++;
    try {
      await _guard(
        () => preview.playRange(
          max(0, startMs),
          endMs: endMs,
          loop: mode != null && _loop,
          restMs: restMs,
        ),
      );
    } finally {
      _rangeRequests--;
    }
    if (mounted && preview.activeRange == null && !_playing) {
      setState(() => _activeMode = null);
    }
  }

  /// Plays around the selected boundary. Tapping the button that is
  /// playing stops it, unless [restart].
  Future<void> _listen(_Listen mode, {bool restart = false}) async {
    final preview = _preview;
    final edge = _edge;
    if (preview == null || edge == null) return;
    if (!restart && _activeMode == mode && _playing) {
      _replayTimer?.cancel();
      await preview.pause();
      return;
    }
    final at = edge.ms;
    final lead = _leadMs;
    final (start, end) = switch (mode) {
      _Listen.end => (at - lead, at),
      _Listen.across => (at - lead, at + lead),
      _Listen.start => (at, at + lead),
    };
    // Rests on the boundary afterwards, not where the preview stopped.
    await _playRange(start, end, mode: mode, restMs: at);
  }

  /// After a change, plays the last listen mode again so the new position
  /// can be heard right away.
  void _scheduleReplay() {
    if (!_autoReplay || _preview == null || _playerError != null) return;
    _replayTimer?.cancel();
    _replayTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) unawaited(_listen(_lastMode, restart: true));
    });
  }

  Future<void> _togglePlay() async {
    final preview = _preview;
    if (preview == null) return;
    _replayTimer?.cancel();
    if (_playing) {
      await preview.pause();
      return;
    }
    _requestedMode = null;
    _playheadKnown = true;
    final pending = _seekPendingMs;
    if (pending != null) {
      // The preview is not where the playhead is yet (its file is still
      // opening): Play goes on from the playhead, not from 0.
      await _guard(() => preview.seek(pending));
      if (!mounted) return;
      _seekLanded(preview);
      if (_seekPendingMs != null) return;
    }
    _playFromMs = preview.positionMs;
    await _guard(preview.play);
  }

  Future<void> _seek(int ms) async {
    final preview = _preview;
    if (preview == null) return;
    _replayTimer?.cancel();
    _requestedMode = null;
    final target = max(0, min(ms, _draft.durationMs));
    _playFromMs = target;
    _seekPendingMs = target;
    setState(() => _playheadKnown = true);
    _setPlayhead(target);
    await _guard(() => preview.seek(target));
    if (mounted) _seekLanded(preview);
  }

  // ------------------------------------------------------------ selection

  DraftEdge? get _edge {
    final key = _selectedKey;
    if (key != null) {
      final edge = _draft.edgeByKey(key);
      if (edge != null) return edge;
    }
    return _draft.nearestEdge(_selectedHint);
  }

  void _selectInitial() {
    final focus = widget.focusChapterId;
    DraftEdge? pick;
    if (focus != null) {
      pick =
          _edges.where((e) => e.rightId == focus).firstOrNull ??
          _edges.where((e) => e.leftId == focus).firstOrNull;
    }
    // The chapter the app's player is in: its start, so the playing part
    // can be fixed. In a gap, the chapter before it.
    final playingAt = widget.playingAtMs;
    if (pick == null && playingAt != null) {
      final playing =
          _draft.chapters.where((c) => c.startMs <= playingAt).lastOrNull;
      if (playing != null) {
        pick = _edges.where((e) => e.rightId == playing.id).firstOrNull;
      }
    }
    // The start of the file is rarely the boundary to fix.
    pick ??= _edges.where((e) => e.shared).firstOrNull ?? _edges.firstOrNull;
    _selectedKey = pick?.key;
    _selectedHint = pick?.ms ?? 0;
  }

  void _select(DraftEdge edge, {bool scrollUp = false}) {
    _replayTimer?.cancel();
    setState(() {
      _selectedKey = edge.key;
      _selectedHint = edge.ms;
      _pendingMs = null;
    });
    _refreshQuiet();
    if (scrollUp && _scroll.hasClients && _scroll.offset > 0) {
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  void _selectChapter(DraftChapter chapter) {
    final edge =
        _edges.where((e) => e.rightId == chapter.id).firstOrNull ??
        _edges.where((e) => e.leftId == chapter.id).firstOrNull;
    if (edge != null) _select(edge, scrollUp: true);
  }

  void _step(int by) {
    final edge = _edge;
    if (edge == null) return;
    final i = _edges.indexOf(edge) + by;
    if (i >= 0 && i < _edges.length) _select(_edges[i]);
  }

  // -------------------------------------------------------------- editing

  void _setDraft(ChapterDraft next, {DraftEdge? select, int? selectNear}) {
    setState(() {
      _draft = next;
      _edges = next.edges;
      _pendingMs = null;
      final edge =
          select ?? (selectNear == null ? null : next.nearestEdge(selectNear));
      if (edge != null) {
        _selectedKey = edge.key;
        _selectedHint = edge.ms;
      } else {
        final current = _edge;
        if (current != null) {
          _selectedKey = current.key;
          _selectedHint = current.ms;
        }
      }
    });
    _refreshQuiet();
  }

  /// Moves the selected boundary as close to [ms] as it can go. Returns
  /// false when it could not move at all.
  ///
  /// A paused playhead moves along onto the new spot unless [parkPlayhead]
  /// is false, and a preview of the boundary comes to rest there.
  bool _moveTo(int ms, {bool replay = true, bool parkPlayhead = true}) {
    final edge = _edge;
    if (edge == null) return false;
    final from = edge.ms;
    final target = _draft.clampEdge(edge, ms);
    final next = _draft.moveEdge(edge, target);
    if (identical(next, _draft)) {
      if (_pendingMs != null) setState(() => _pendingMs = null);
      return false;
    }
    _setDraft(
      next,
      select: next.edgeByKey(edge.key) ?? next.nearestEdge(target),
    );
    _followBoundary(from, target, park: parkPlayhead);
    if (replay) _scheduleReplay();
    return true;
  }

  /// Keeps the playhead with a boundary that moved from [from] to [to]: a
  /// preview resting on [from] rests on [to] instead, and with [park] a
  /// paused playhead moves there (so a later Set here cannot undo the
  /// move).
  void _followBoundary(int from, int to, {required bool park}) {
    final preview = _preview;
    if (preview == null || _playerError != null) return;
    if (preview.activeRange != null) {
      if (preview.restMs == from) preview.moveRest(to);
      return;
    }
    if (!park || _playing || _rangeRequests > 0) return;
    _setPlayhead(to);
    _seekPendingMs = to;
    unawaited(
      _guard(() => preview.seek(to, park: true)).then((_) {
        if (mounted) _seekLanded(preview);
      }),
    );
  }

  void _nudge(int deltaMs) {
    final edge = _edge;
    if (edge == null) return;
    if (!_moveTo(edge.ms + deltaMs)) {
      _message('This boundary cannot move further that way.');
    }
  }

  void _holdStart() {
    final edge = _edge;
    if (edge == null) return;
    _replayTimer?.cancel();
    setState(() => _pendingMs = edge.ms);
  }

  void _holdStep(int deltaMs) {
    final edge = _edge;
    final pending = _pendingMs;
    if (edge == null || pending == null) return;
    final next = _draft.clampEdge(edge, pending + deltaMs);
    if (next != pending) setState(() => _pendingMs = next);
  }

  void _commitPending() {
    final pending = _pendingMs;
    if (pending == null) return;
    _moveTo(pending);
  }

  int _dragTo(int ms) {
    final edge = _edge;
    if (edge == null) return ms;
    final clamped = _draft.clampEdge(edge, ms);
    if (clamped != _pendingMs) setState(() => _pendingMs = clamped);
    return clamped;
  }

  void _dragStart() {
    _replayTimer?.cancel();
    final edge = _edge;
    setState(() {
      _dragHintSeen = true;
      _pendingMs = edge?.ms;
    });
  }

  void _setHere() {
    final edge = _edge;
    final preview = _preview;
    if (edge == null || preview == null) return;
    final tap = _tapped();
    final at = tap.ms;
    if (!_chosen(tap)) {
      // Lit only for a tap that just missed a preview, or a stale finger.
      setState(() {});
      if (_justEnded) _message(_lateTapMessage);
      return;
    }
    if (tap.playing && _reactsToStart(edge, at)) {
      _message(
        'Tap when you hear the change – use Play across to start a little '
        'before it.',
      );
      return;
    }
    final target = _draft.clampEdge(edge, at);
    HapticFeedback.selectionClick();
    // Never replays: this is "I just heard it". Playing goes on, and a
    // preview comes to rest on the new spot.
    final moved = _moveTo(target, replay: false, parkPlayhead: false);
    // The button may have stayed lit only for this finger.
    if (!moved) setState(() {});
    if ((target - at).abs() > 50) {
      _message(
        'Moved as far as it can go: chapters are at least 1 second long '
        'and cannot overlap.',
      );
    } else if (!moved) {
      _message('The boundary is already here.');
    }
  }

  void _split() {
    final tap = _tapped();
    final at = tap.ms;
    // After a preview the playhead rests on a boundary: nothing to split.
    // A finger that went down while it played still counts.
    if (!tap.playing && tap.parked) {
      _message(
        _justEnded
            ? _lateTapMessage
            : 'Play, then tap Split here where a new chapter starts.',
      );
      return;
    }
    final next = _draft.splitAt(at);
    if (identical(next, _draft)) {
      _message(
        at >= _draft.durationMs
            ? 'This is the end of the file.'
            : 'Too close to a boundary: every chapter is at least 1 second '
                'long.',
      );
      return;
    }
    HapticFeedback.selectionClick();
    final added = next.chapters.where((c) => c.startMs == at).firstOrNull;
    _setDraft(next, selectNear: at);
    _offerUndo(
      next,
      added == null
          ? 'Added a boundary at ${preciseTime(at)}.'
          : 'Added "${added.title}" at ${preciseTime(at)}.',
    );
  }

  void _undo() => _setDraft(_draft.undo());
  void _redo() => _setDraft(_draft.redo());

  /// A message with Undo, which only applies while [after] is still the
  /// latest change.
  void _offerUndo(ChapterDraft after, String text) {
    _message(
      text,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          if (mounted && identical(_draft, after)) _undo();
        },
      ),
    );
  }

  Future<void> _typeTime() async {
    final edge = _edge;
    if (edge == null) return;
    final ms = await showDialog<int>(
      context: context,
      builder: (_) => _TimeDialog(initialMs: edge.ms),
    );
    if (ms == null || !mounted) return;
    final now = _edge;
    if (now == null) return;
    final target = _draft.clampEdge(now, ms);
    _moveTo(target);
    if (target != ms) {
      _message(
        'Moved to ${preciseTime(target)}, as close as it can go: chapters '
        'are at least 1 second long and cannot overlap.',
      );
    }
  }

  Future<void> _removeBoundary(DraftEdge edge) async {
    final left = _draft.chapterById(edge.leftId ?? '');
    final right = _draft.chapterById(edge.rightId ?? '');
    if (left == null || right == null) return;
    final keepLeft = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => SimpleDialog(
            title: const Text('Remove this boundary?'),
            contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'The two chapters become one. Which title should it keep?',
                ),
              ),
              for (final (value, title) in [
                (true, left.title),
                (false, right.title),
              ])
                SimpleDialogOption(
                  key: ValueKey('editor-keep-${value ? 'left' : 'right'}'),
                  onPressed: () => Navigator.pop(ctx, value),
                  child: Text('Keep "$title"'),
                ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
            ],
          ),
    );
    if (keepLeft == null || !mounted) return;
    final next = _draft.removeEdge(edge, keepLeftTitle: keepLeft);
    if (identical(next, _draft)) return;
    _setDraft(next, selectNear: edge.ms);
    _offerUndo(next, 'Boundary removed.');
  }

  Future<void> _rename(DraftChapter chapter) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: chapter.title),
    );
    if (title == null || title.trim().isEmpty || !mounted) return;
    _setDraft(_draft.rename(chapter.id, title));
  }

  void _delete(DraftChapter chapter) {
    final next = _draft.delete(chapter.id);
    if (identical(next, _draft)) return;
    _setDraft(next, selectNear: chapter.startMs);
    _offerUndo(next, 'Removed "${chapter.title}".');
  }

  void _mergeWithNext(DraftChapter chapter) {
    final next = _draft.mergeWithNext(chapter.id);
    if (identical(next, _draft)) return;
    _setDraft(next, selectNear: chapter.startMs);
    _offerUndo(next, 'Merged into "${chapter.title}".');
  }

  void _fillGap(int startMs) {
    final next = _draft.splitAt(startMs);
    if (identical(next, _draft)) return;
    _setDraft(next, selectNear: startMs);
  }

  void _startFromScratch() {
    final next = _draft.createFromScratch('Chapter 1');
    if (identical(next, _draft)) return;
    _setDraft(next, selectNear: 0);
  }

  // ---------------------------------------------------------------- quiet

  /// Looks for the quietest spot near the selected boundary, for "Snap to
  /// quiet".
  void _refreshQuiet() {
    final edge = _edge;
    final path = _path;
    final service = _waveforms;
    if (edge == null || path == null || service == null) {
      _quietMs = _quietFor = null;
      _quietLoading = false;
      return;
    }
    if (_quietFor == edge.ms) return;
    _quietFor = edge.ms;
    _quietMs = null;
    _quietLoading = true;
    final request = ++_quietRequest;
    service.quietestPoint(path, edge.ms).then((ms) {
      if (!mounted || request != _quietRequest) return;
      setState(() {
        _quietMs = ms;
        _quietLoading = false;
      });
    });
  }

  // ----------------------------------------------------------------- save

  Future<void> _save() async {
    if (_saving) return;
    _replayTimer?.cancel();
    setState(() => _saving = true);
    try {
      unawaited(_preview?.pause());
      // Editing goes on while saving; only this list counts as saved.
      final saving = _draft.chapters;
      final result = _draft.toChapters();
      // 0 when the length is unknown: the stored length is kept then.
      final saved = await widget.onSave(
        result,
        _durationKnown ? _draft.durationMs : 0,
      );
      _savedAny = _savedAny || saved;
      if (!mounted) return;
      if (widget.closeOnSave) {
        Navigator.of(context).pop(saved);
        return;
      }
      // Stays open: what was saved is the new starting point, so back
      // leaves without asking until the next change. A change made while
      // saving is not in it and stays unsaved.
      setState(() {
        _draft = _draft.markSaved(saving);
        _initialById = {for (final c in result) c.id: c};
      });
      _message(saved ? 'Chapters saved.' : 'Already saved: nothing changed.');
    } catch (error) {
      _message(
        error is FormatException
            ? error.message
            : error is StateError
            ? error.message
            : '$error',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text('Your changes to the chapters are not saved.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                key: const ValueKey('editor-discard'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Discard'),
              ),
            ],
          ),
    );
    if (discard == true && mounted) Navigator.of(context).pop(_savedAny);
  }

  void _message(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: action,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  // ---------------------------------------------------------------- build

  /// Where [edge] was when the editor opened; null for a boundary that did
  /// not exist then (such as one made by Split here).
  int? _originalOf(DraftEdge edge) {
    final left = edge.leftId == null ? null : _initialById[edge.leftId];
    final right = edge.rightId == null ? null : _initialById[edge.rightId];
    if (edge.shared) {
      // Both chapters existed and already met there.
      if (left == null || right == null || left.endMs != right.startMs) {
        return null;
      }
      return right.startMs;
    }
    return right?.startMs ?? left?.endMs;
  }

  /// The chapters as drawn: with the boundary where the finger has it.
  List<DraftChapter> _shownChapters(DraftEdge? edge) {
    final pending = _pendingMs;
    if (pending == null || edge == null) return _draft.chapters;
    return [
      for (final c in _draft.chapters)
        if (c.id == edge.leftId)
          c.copyWith(endMs: pending)
        else if (c.id == edge.rightId)
          c.copyWith(startMs: pending)
        else
          c,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final edge = _edge;
    final edgeIndex = edge == null ? null : _edges.indexOf(edge);
    final liveMs = _pendingMs ?? edge?.ms;
    final shown = _shownChapters(edge);
    final edgesMs = [
      for (final (i, e) in _edges.indexed)
        i == edgeIndex && liveMs != null ? liveMs : e.ms,
    ];
    final dirty = _draft.dirty;
    final canListen = _preview != null && _playerError == null;

    return PopScope(
      // Back is ignored while saving. After a save, the page pops itself
      // so the result says that something was saved.
      canPop: !dirty && !_saving && !_savedAny,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _saving) return;
        if (dirty) {
          unawaited(_confirmDiscard());
        } else {
          Navigator.of(context).pop(_savedAny);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              // Where the app's player is in this file, to the millisecond,
              // while it is on this file.
              ValueListenableBuilder<int?>(
                valueListenable: _playerAt,
                builder:
                    (context, ms, _) => Text.rich(
                      TextSpan(
                        children: [
                          if (ms != null) ...[
                            const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: EdgeInsets.only(right: 3),
                                child: Icon(
                                  Icons.graphic_eq,
                                  size: 12,
                                  color: EditorColors.playhead,
                                ),
                              ),
                            ),
                            TextSpan(
                              text: preciseTime(ms),
                              style: const TextStyle(
                                color: EditorColors.playhead,
                                fontFeatures: tabularFigures,
                              ),
                            ),
                            const TextSpan(text: ' · '),
                          ],
                          TextSpan(text: widget.track.title),
                        ],
                      ),
                      key: const ValueKey('editor-player-position'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: EditorColors.muted,
                      ),
                    ),
              ),
            ],
          ),
          actions: [
            IconButton(
              key: const ValueKey('editor-undo'),
              tooltip: 'Undo',
              onPressed: _draft.canUndo && !_saving ? _undo : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              key: const ValueKey('editor-redo'),
              tooltip: 'Redo',
              onPressed: _draft.canRedo && !_saving ? _redo : null,
              icon: const Icon(Icons.redo),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, left: 4),
              child: FilledButton(
                key: const ValueKey('editor-save'),
                onPressed: dirty && !_saving ? _save : null,
                child: Text(widget.saveLabel),
              ),
            ),
          ],
          bottom:
              _saving
                  ? const PreferredSize(
                    preferredSize: Size.fromHeight(2),
                    child: LinearProgressIndicator(minHeight: 2),
                  )
                  : null,
        ),
        bottomNavigationBar: _transportBar(canListen),
        body: Column(
          children: [
            if (_playerError != null)
              _Banner(
                text: _playerError!,
                onRetry: _preview == null ? null : _retryOpen,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: ChapterOverviewStrip(
                chapters: shown,
                edgesMs: edgesMs,
                durationMs: _draft.durationMs,
                selectedIndex: edgeIndex,
                playhead: _playhead,
                lensSpanMs: _spanMs,
                onSelectEdge: (i) => _select(_edges[i]),
                onSeek: _seek,
              ),
            ),
            _Legend(chapters: _draft.chapters),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (_draft.chapters.isEmpty)
                    _EmptyState(
                      durationKnown: _draft.durationMs >= 1000,
                      openFailed: _playerError != null,
                      onStart: _startFromScratch,
                    )
                  else if (edge != null && liveMs != null)
                    _focusCard(edge, edgeIndex!, liveMs, shown, canListen),
                  ..._chapterList(edge),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _focusCard(
    DraftEdge edge,
    int index,
    int liveMs,
    List<DraftChapter> shown,
    bool canListen,
  ) {
    final left = _draft.chapterById(edge.leftId ?? '');
    final right = _draft.chapterById(edge.rightId ?? '');
    final original = _originalOf(edge);
    final quiet = _quietMs;
    final snapTo = quiet == null ? null : _draft.clampEdge(edge, quiet);
    final snapDelta = snapTo == null ? null : snapTo - edge.ms;
    final theme = Theme.of(context);
    final chosen = _playheadChosen;
    final canSetHere = canListen && (chosen || _downPending || _justEnded);

    return Card(
      key: const ValueKey('editor-focus'),
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  key: const ValueKey('editor-prev-edge'),
                  tooltip: 'Previous boundary',
                  onPressed: index > 0 ? () => _step(-1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    'Boundary ${index + 1} of ${_edges.length}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const ValueKey('editor-next-edge'),
                  tooltip: 'Next boundary',
                  onPressed: index + 1 < _edges.length ? () => _step(1) : null,
                  icon: const Icon(Icons.chevron_right),
                ),
                PopupMenuButton<String>(
                  key: const ValueKey('editor-edge-menu'),
                  tooltip: 'Boundary options',
                  onSelected: (value) {
                    switch (value) {
                      case 'remove':
                        unawaited(_removeBoundary(edge));
                      case 'reset':
                        if (original != null) _moveTo(original);
                      case 'time':
                        unawaited(_typeTime());
                    }
                  },
                  itemBuilder:
                      (_) => [
                        PopupMenuItem(
                          value: 'remove',
                          enabled: edge.shared,
                          child: const Text('Remove this boundary'),
                        ),
                        PopupMenuItem(
                          value: 'reset',
                          enabled: original != null && original != edge.ms,
                          child: const Text('Reset to original position'),
                        ),
                        const PopupMenuItem(
                          value: 'time',
                          child: Text('Type an exact time…'),
                        ),
                      ],
                ),
              ],
            ),
            _EdgeLabels(
              left:
                  left?.title ??
                  (edge.ms <= 0 ? 'Start of the file' : 'No chapter'),
              right:
                  right?.title ??
                  (edge.ms >= _draft.durationMs
                      ? 'End of the file'
                      : 'No chapter'),
              leftIsChapter: left != null,
              rightIsChapter: right != null,
            ),
            const SizedBox(height: 8),
            WaveformLens(
              waveforms: _waveforms,
              path: _path,
              centerMs: liveMs,
              spanMs: _spanMs,
              durationMs: _draft.durationMs,
              chapters: shown,
              otherEdgesMs: [
                for (final e in _edges)
                  if (e != edge) e.ms,
              ],
              originalMs: original,
              playhead: _playhead,
              showHint: !_dragHintSeen,
              onDragStart: _dragStart,
              onDrag: _dragTo,
              onDragEnd: _commitPending,
              onSpanChanged: (span) => setState(() => _spanMs = span),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    key: const ValueKey('editor-time'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: _typeTime,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  preciseTime(liveMs),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w600,
                                    color: EditorColors.boundary,
                                    fontFeatures: tabularFigures,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.edit,
                                  size: 16,
                                  color: EditorColors.muted,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            original == null
                                ? 'New boundary'
                                : liveMs == original
                                ? 'Where it was'
                                : '${signedSeconds(liveMs - original)} from '
                                    'where it was',
                            key: const ValueKey('editor-moved-by'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: EditorColors.muted,
                              fontFeatures: tabularFigures,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SegmentedButton<int>(
                  key: const ValueKey('editor-zoom'),
                  showSelectedIcon: false,
                  emptySelectionAllowed: true,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 6),
                    ),
                  ),
                  segments: [
                    for (final span in _zooms)
                      ButtonSegment(
                        value: span,
                        label: Text('${span ~/ 1000} s'),
                        tooltip: 'Show ${span ~/ 1000} seconds',
                      ),
                  ],
                  selected: {if (_zooms.contains(_spanMs)) _spanMs},
                  onSelectionChanged: (selection) {
                    if (selection.isEmpty) return;
                    setState(() => _spanMs = selection.first);
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final (mode, key, icon, label) in [
                  (
                    _Listen.end,
                    'editor-hear-end',
                    Icons.keyboard_tab,
                    'Hear end',
                  ),
                  (
                    _Listen.across,
                    'editor-play-across',
                    Icons.compare_arrows,
                    'Play across',
                  ),
                  (
                    _Listen.start,
                    'editor-hear-start',
                    Icons.start,
                    'Hear start',
                  ),
                ]) ...[
                  if (mode != _Listen.end) const SizedBox(width: 6),
                  Expanded(
                    child: _ListenButton(
                      key: ValueKey(key),
                      icon: icon,
                      label: label,
                      active: _activeMode == mode,
                      playing: _activeMode == mode && _playing,
                      onTap: canListen ? () => _listen(mode) : null,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Lead',
                  style: TextStyle(color: EditorColors.muted, fontSize: 13),
                ),
                for (final lead in _leads)
                  ChoiceChip(
                    key: ValueKey('editor-lead-$lead'),
                    label: Text('${lead ~/ 1000} s'),
                    visualDensity: VisualDensity.compact,
                    selected: _leadMs == lead,
                    onSelected: (_) => setState(() => _leadMs = lead),
                  ),
                FilterChip(
                  key: const ValueKey('editor-loop'),
                  label: const Text('Loop'),
                  visualDensity: VisualDensity.compact,
                  selected: _loop,
                  onSelected: (value) => setState(() => _loop = value),
                ),
                FilterChip(
                  key: const ValueKey('editor-auto-replay'),
                  label: const Text('Replay after change'),
                  tooltip: 'Plays the last listen button again after a move',
                  visualDensity: VisualDensity.compact,
                  selected: _autoReplay,
                  onSelected: (value) => setState(() => _autoReplay = value),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final (i, delta) in _nudges.indexed) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: _NudgeButton(
                      key: ValueKey('editor-nudge-$delta'),
                      label: _nudgeLabel(delta),
                      tooltip:
                          '${delta < 0 ? 'Earlier' : 'Later'} by '
                          '${_nudgeLabel(delta.abs())}; hold to repeat',
                      onTap: () => _nudge(delta),
                      onHoldStart: _holdStart,
                      onHoldStep: () => _holdStep(delta),
                      onHoldEnd: _commitPending,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Listener(
                    onPointerDown: (_) => _captureDown(),
                    onPointerUp: (_) => _releaseDown(),
                    onPointerCancel: (_) => _releaseDown(),
                    child: OutlinedButton.icon(
                      key: const ValueKey('editor-set-here'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 52),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                      ),
                      onPressed: canSetHere ? _setHere : null,
                      icon: const Icon(Icons.my_location, size: 20),
                      label: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('Set here'),
                          ),
                          Text(
                            !canListen
                                ? 'Needs the file to play'
                                : !chosen
                                ? 'Play, then tap when you hear the change'
                                : _playing
                                ? 'Tap when you hear the change'
                                : 'Moves it to the playhead',
                            key: const ValueKey('editor-set-here-hint'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('editor-snap-quiet'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed:
                        snapTo != null && snapDelta!.abs() >= 5
                            ? () => _moveTo(snapTo)
                            : null,
                    icon: const Icon(Icons.volume_down, size: 20),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Snap to quiet'),
                          Text(
                            snapDelta == null
                                ? (quiet == null && _quietLoading
                                    ? 'Looking…'
                                    : 'Nothing nearby')
                                : snapDelta.abs() < 5
                                ? 'Already there'
                                : signedSeconds(snapDelta, decimals: 2),
                            style: const TextStyle(
                              fontSize: 11,
                              fontFeatures: tabularFigures,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _nudgeLabel(int ms) {
    final sign = ms < 0 ? '−' : '+';
    final abs = ms.abs();
    return abs >= 1000
        ? '$sign${abs ~/ 1000} s'
        : abs >= 100
        ? '$sign${abs / 1000} s'
        : '$sign$abs ms';
  }

  List<Widget> _chapterList(DraftEdge? edge) {
    final chapters = _draft.chapters;
    if (chapters.isEmpty) return const [];
    final rows = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(
          children: [
            Text(
              'Chapters (${chapters.length})',
              style: const TextStyle(
                color: Color(0xFF2196F3),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Tap one to adjust its start',
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: EditorColors.muted, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    ];
    final duration = _draft.durationMs;
    var previousEnd = 0;
    for (final (i, c) in chapters.indexed) {
      if (c.startMs - previousEnd >= ChapterDraft.minChapterMs) {
        rows.add(_gapRow(previousEnd, c.startMs));
      }
      rows.add(_chapterRow(i, c, edge, isLast: i == chapters.length - 1));
      previousEnd = c.endMs;
    }
    if (duration - previousEnd >= ChapterDraft.minChapterMs) {
      rows.add(_gapRow(previousEnd, duration));
    }
    return rows;
  }

  Widget _gapRow(int startMs, int endMs) {
    return Padding(
      key: ValueKey('editor-gap-$startMs'),
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          const Icon(Icons.more_vert, size: 18, color: Color(0xFF666666)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No chapter for ${chapterTimestamp(endMs - startMs)}',
              style: const TextStyle(color: EditorColors.muted, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () => _fillGap(startMs),
            child: const Text('Make a chapter'),
          ),
        ],
      ),
    );
  }

  Widget _chapterRow(
    int index,
    DraftChapter c,
    DraftEdge? edge, {
    required bool isLast,
  }) {
    final selected =
        edge != null && (edge.leftId == c.id || edge.rightId == c.id);
    final color = EditorColors.chapter(c.origin, index);
    final theme = Theme.of(context);
    return Material(
      color: selected ? const Color(0xFF2A2A2A) : Colors.transparent,
      child: InkWell(
        key: ValueKey('editor-chapter-${c.id}'),
        onTap: () => _selectChapter(c),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(
                width: 30,
                child: ValueListenableBuilder<int>(
                  valueListenable: _playhead,
                  builder: (context, ms, _) {
                    final here = _playing && ms >= c.startMs && ms < c.endMs;
                    return here
                        ? const Icon(
                          Icons.graphic_eq,
                          size: 16,
                          color: EditorColors.playhead,
                        )
                        : Text(
                          '${index + 1}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: EditorColors.muted),
                        );
                  },
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.title,
                      key: ValueKey('editor-chapter-title-${c.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: selected ? FontWeight.w600 : null,
                        // Stand-in names stand out, so unknown parts are
                        // easy to find.
                        color:
                            isPlaceholderChapterTitle(c.title)
                                ? theme.colorScheme.error
                                : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${chapterTimestamp(c.startMs)} – '
                      '${chapterTimestamp(c.endMs)} · '
                      '${chapterTimestamp(c.lengthMs)}',
                      style: const TextStyle(
                        color: EditorColors.muted,
                        fontSize: 13,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _Badge(text: originName(c.origin), color: color),
                        if (c.edited)
                          const _Badge(
                            text: 'edited',
                            color: Color(0xFF9E9E9E),
                          ),
                      ],
                    ),
                    for (final note in c.notes)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          note,
                          style: TextStyle(
                            color: theme.colorScheme.tertiary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('editor-row-play-${c.id}'),
                tooltip: 'Play its start',
                onPressed:
                    _preview != null && _playerError == null
                        ? () => _playRange(
                          c.startMs,
                          c.startMs + _leadMs * 2,
                          restMs: c.startMs,
                        )
                        : null,
                icon: const Icon(Icons.play_circle_outline),
              ),
              PopupMenuButton<String>(
                key: ValueKey('editor-row-menu-${c.id}'),
                tooltip: 'Chapter actions',
                onSelected: (value) {
                  switch (value) {
                    case 'rename':
                      unawaited(_rename(c));
                    case 'delete':
                      _delete(c);
                    case 'merge':
                      _mergeWithNext(c);
                  }
                },
                itemBuilder:
                    (_) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Rename'),
                      ),
                      if (!isLast)
                        const PopupMenuItem(
                          value: 'merge',
                          child: Text('Merge with next'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete (leaves a gap)'),
                      ),
                    ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _transportBar(bool canListen) {
    return Material(
      color: EditorColors.panel,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('editor-back-5'),
                tooltip: 'Back 5 seconds',
                onPressed: canListen ? () => _seek(_playheadMs - 5000) : null,
                icon: const Icon(Icons.replay_5),
              ),
              IconButton.filled(
                key: const ValueKey('editor-play-pause'),
                tooltip: _playing ? 'Pause' : 'Play from here',
                iconSize: 30,
                onPressed: canListen ? _togglePlay : null,
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                key: const ValueKey('editor-forward-5'),
                tooltip: 'Forward 5 seconds',
                onPressed: canListen ? () => _seek(_playheadMs + 5000) : null,
                icon: const Icon(Icons.forward_5),
              ),
              const SizedBox(width: 4),
              Expanded(
                flex: 2,
                child: ValueListenableBuilder<int>(
                  valueListenable: _playhead,
                  builder:
                      (context, ms, _) => Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              preciseTime(ms),
                              key: const ValueKey('editor-position'),
                              style: const TextStyle(
                                fontSize: 15,
                                fontFeatures: tabularFigures,
                              ),
                            ),
                          ),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _draft.durationMs > 0
                                  ? 'of ${chapterTimestamp(_draft.durationMs)}'
                                  : 'Loading…',
                              style: const TextStyle(
                                fontSize: 11,
                                color: EditorColors.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                ),
              ),
              // Shrinks its label on narrow phones instead of overflowing.
              Flexible(
                flex: 3,
                child: Listener(
                  onPointerDown: (_) => _captureDown(),
                  onPointerUp: (_) => _releaseDown(),
                  onPointerCancel: (_) => _releaseDown(),
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('editor-split'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: _draft.durationMs >= 2000 ? _split : null,
                    icon: const Icon(Icons.content_cut, size: 20),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Split here'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF3A2E1E),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: Color(0xFFFFB74D)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFFDDDDDD), fontSize: 13),
            ),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// Which colour means which source, for the sources in the list.
class _Legend extends StatelessWidget {
  const _Legend({required this.chapters});

  final List<DraftChapter> chapters;

  @override
  Widget build(BuildContext context) {
    final origins = {for (final c in chapters) c.origin};
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 22),
        child: Row(
          children: [
            for (final origin in ChapterOrigin.values)
              if (origins.contains(origin)) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: EditorColors.chapter(origin, 0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  originName(origin),
                  style: const TextStyle(
                    color: EditorColors.muted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 12),
              ],
            // The hint takes all the room the legend leaves, and wraps
            // rather than being cut.
            const Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.touch_app,
                          size: 14,
                          color: Color(0xFF777777),
                        ),
                      ),
                    ),
                    TextSpan(text: 'Tap a boundary · drag to scrub'),
                  ],
                ),
                key: ValueKey('editor-legend-hint'),
                textAlign: TextAlign.end,
                style: TextStyle(color: Color(0xFF777777), fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EdgeLabels extends StatelessWidget {
  const _EdgeLabels({
    required this.left,
    required this.right,
    required this.leftIsChapter,
    required this.rightIsChapter,
  });

  final String left;
  final String right;
  final bool leftIsChapter;
  final bool rightIsChapter;

  @override
  Widget build(BuildContext context) {
    Widget side(String caption, String title, bool chapter, TextAlign align) =>
        Column(
          crossAxisAlignment:
              align == TextAlign.end
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
          children: [
            Text(
              caption,
              style: const TextStyle(color: EditorColors.muted, fontSize: 11),
            ),
            Text(
              title,
              textAlign: align,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: chapter ? FontWeight.w500 : null,
                color: chapter ? Colors.white : EditorColors.muted,
                fontStyle: chapter ? null : FontStyle.italic,
              ),
            ),
          ],
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: side(
              leftIsChapter ? 'Ends' : 'Before',
              left,
              leftIsChapter,
              TextAlign.end,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Icon(
              Icons.vertical_align_center,
              size: 20,
              color: EditorColors.boundary,
            ),
          ),
          Expanded(
            child: side(
              rightIsChapter ? 'Starts' : 'After',
              right,
              rightIsChapter,
              TextAlign.start,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.durationKnown,
    required this.openFailed,
    required this.onStart,
  });

  final bool durationKnown;

  /// The file could not be opened (see the banner above).
  final bool openFailed;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.queue_music, size: 40, color: EditorColors.muted),
            const SizedBox(height: 8),
            Text(
              'No chapters yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'Play the file and tap Split here wherever a new song starts.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFFCCCCCC)),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('editor-start-scratch'),
              onPressed: durationKnown ? onStart : null,
              icon: const Icon(Icons.add),
              label: const Text('Start with one chapter'),
            ),
            if (!durationKnown)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  openFailed
                      ? 'The file could not be opened, so its length is '
                          'unknown.'
                      : 'Opening the file…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: EditorColors.muted,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Color.lerp(color, Colors.white, 0.4),
          fontSize: 11,
        ),
      ),
    );
  }
}

/// A big listen button: icon over label, lit while it plays.
class _ListenButton extends StatelessWidget {
  const _ListenButton({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.playing,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool playing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final foreground =
        !enabled
            ? const Color(0xFF666666)
            : active
            ? EditorColors.boundary
            : Colors.white;
    return Material(
      color:
          active
              ? EditorColors.boundary.withValues(alpha: 0.16)
              : EditorColors.track,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: active ? EditorColors.boundary : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 62,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(playing ? Icons.stop : icon, color: foreground),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: TextStyle(color: foreground, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A nudge button: a tap moves once, holding it keeps moving.
class _NudgeButton extends StatefulWidget {
  const _NudgeButton({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldStep,
    required this.onHoldEnd,
  });

  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldStep;
  final VoidCallback onHoldEnd;

  @override
  State<_NudgeButton> createState() => _NudgeButtonState();
}

class _NudgeButtonState extends State<_NudgeButton> {
  Timer? _repeat;

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  void _start() {
    widget.onHoldStart();
    widget.onHoldStep();
    _repeat = Timer.periodic(
      const Duration(milliseconds: 90),
      (_) => widget.onHoldStep(),
    );
  }

  void _stop() {
    if (_repeat == null) return;
    _repeat?.cancel();
    _repeat = null;
    widget.onHoldEnd();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      excludeFromSemantics: true,
      child: GestureDetector(
        onLongPressStart: (_) => _start(),
        onLongPressEnd: (_) => _stop(),
        onLongPressCancel: _stop,
        child: Material(
          color: EditorColors.track,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: SizedBox(
              height: 46,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      widget.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimeDialog extends StatefulWidget {
  const _TimeDialog({required this.initialMs});

  final int initialMs;

  @override
  State<_TimeDialog> createState() => _TimeDialogState();
}

class _TimeDialogState extends State<_TimeDialog> {
  late final _controller = TextEditingController(
    text: preciseTime(widget.initialMs),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final ms = parseChapterTimestamp(_controller.text);
    if (ms == null) {
      setState(() => _error = 'Use minutes:seconds, like 3:25.250');
      return;
    }
    Navigator.pop(context, ms);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Boundary time'),
    content: TextField(
      key: const ValueKey('editor-time-field'),
      controller: _controller,
      autofocus: true,
      keyboardType: TextInputType.datetime,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: 'Time (m:ss.mmm or h:mm:ss.mmm)',
        errorText: _error,
        errorMaxLines: 2,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Move')),
    ],
  );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename chapter'),
    content: TextField(
      key: const ValueKey('editor-rename-field'),
      controller: _controller,
      autofocus: true,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(labelText: 'Title'),
      onSubmitted: (value) => Navigator.pop(context, value.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}
