import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/playback_service.dart';

const _accent = Color(0xFF2196F3);
const _muted = Color(0xFF999999);

/// How long after a line starts people tap it: taken off a tap.
const lyricsTapReactionMs = 250;

/// One nudge of the fine-tune buttons.
const _nudgeMs = 500;

/// Opens the tap-to-sync sheet for the synced doc of [track] and
/// [chapterId] (null = the whole file). [playFrom] plays the track from a
/// file time, like a tap on a line of the lyrics page.
Future<void> showLyricsTimingSheet(
  BuildContext context, {
  required Track track,
  String? chapterId,
  required Future<void> Function(int fileMs) playFrom,
}) => showModalBottomSheet<void>(
  context: context,
  backgroundColor: const Color(0xFF2A2A2A),
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder:
      (_) => LyricsTimingSheet(
        track: track,
        chapterId: chapterId,
        playFrom: playFrom,
      ),
);

/// The new timing shift when the line starting at [lineStartMs] (doc time,
/// with the [currentShiftMs] already in it) is heard at [heardAtMs] (doc
/// time of the tap, reaction time taken off).
int lyricsShiftForTap({
  required int currentShiftMs,
  required int lineStartMs,
  required int heardAtMs,
}) => currentShiftMs + heardAtMs - lineStartMs;

/// Signed seconds, like "+1.5 s" or "−12.0 s".
String lyricsShiftLabel(int shiftMs) {
  final seconds = (shiftMs.abs() / 1000).toStringAsFixed(1);
  return '${shiftMs < 0 ? '−' : '+'}$seconds s';
}

/// Plays the track and lets the user tap the line being sung, which moves
/// every line by the same amount. Also: nudges, reset, and "use without
/// timing".
class LyricsTimingSheet extends ConsumerStatefulWidget {
  const LyricsTimingSheet({
    super.key,
    required this.track,
    this.chapterId,
    required this.playFrom,
  });

  final Track track;
  final String? chapterId;
  final Future<void> Function(int fileMs) playFrom;

  @override
  ConsumerState<LyricsTimingSheet> createState() => _LyricsTimingSheetState();
}

class _LyricsTimingSheetState extends ConsumerState<LyricsTimingSheet> {
  LyricsDoc? _doc;
  List<LyricsLine> _lines = const [];
  bool _loading = true;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final doc = await db.lyricsDocFor(widget.track.id, widget.chapterId);
    final lines =
        doc == null ? const <LyricsLine>[] : await db.lyricsLinesForDoc(doc.id);
    if (!mounted) return;
    setState(() {
      _doc = doc;
      _lines = lines;
      _loading = false;
    });
  }

  PlaybackService get _player => ref.read(playbackServiceProvider);

  /// Whether the player has this track's file (and the doc's chapter, or
  /// the whole file) loaded.
  bool _playingThis(PlaybackService player) {
    final item = player.currentItem;
    if (item == null || item.track.id != widget.track.id) return false;
    final chapterId = widget.chapterId;
    return chapterId == null || item.chapter == null
        ? true
        : item.chapter!.id == chapterId;
  }

  /// The doc time of the player's [position], or null when it plays
  /// something else.
  int? _docMs(PlaybackService player, Duration position) {
    final doc = _doc;
    if (doc == null || !_playingThis(player)) return null;
    final fileMs =
        (player.currentItem!.chapter?.startMs ?? 0) + position.inMilliseconds;
    return fileMs - doc.offsetMs;
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is StateError ? e.message : 'Could not: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playPause() => _act(() async {
    final player = _player;
    final doc = _doc;
    if (doc == null) return;
    if (!_playingThis(player)) {
      // From a few seconds before the first line.
      final first = _lines
          .map((l) => l.startMs)
          .whereType<int>()
          .fold<int?>(null, (a, b) => a == null ? b : min(a, b));
      await widget.playFrom(doc.offsetMs + max(0, (first ?? 0) - 5000));
      return;
    }
    if (player.isPlaying) {
      await player.pause();
    } else {
      await player.resume();
    }
  });

  Future<void> _setShift(int shiftMs) => _act(() async {
    await ref
        .read(lyricsServiceProvider)
        .setTimingShift(widget.track.id, widget.chapterId, shiftMs);
    await _load();
  });

  Future<void> _tapLine(LyricsLine line) async {
    final doc = _doc;
    final start = line.startMs;
    if (doc == null || start == null || _busy) return;
    final player = _player;
    final now = _docMs(player, player.position);
    if (now == null) {
      setState(
        () => _message = 'Press play first, then tap the line being sung.',
      );
      return;
    }
    await _setShift(
      lyricsShiftForTap(
        currentShiftMs: doc.shiftMs,
        lineStartMs: start,
        heardAtMs: now - lyricsTapReactionMs,
      ),
    );
  }

  Future<void> _withoutTiming() => _act(() async {
    await ref
        .read(lyricsServiceProvider)
        .useWithoutTiming(widget.track.id, widget.chapterId);
    if (mounted) Navigator.pop(context);
  });

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.85;
    final doc = _doc;
    final player = ref.watch(playbackServiceProvider);
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Fix the timing',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Play the song and tap the line being sung right now. Every '
              'line moves by the same amount.',
              style: TextStyle(color: Color(0xFFCCCCCC)),
            ),
          ),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (doc == null || !doc.synced)
            const Expanded(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'These lyrics have no times.',
                  key: ValueKey('lyrics-timing-untimed'),
                  style: TextStyle(color: _muted),
                ),
              ),
            )
          else ...[
            _controls(doc, player),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _message!,
                  key: const ValueKey('lyrics-timing-message'),
                  style: const TextStyle(color: Color(0xFFE57373)),
                ),
              ),
            const Divider(height: 1, color: Color(0xFF3A3A3A)),
            Expanded(child: _lineList(player)),
            const Divider(height: 1, color: Color(0xFF3A3A3A)),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  TextButton.icon(
                    key: const ValueKey('lyrics-timing-reset'),
                    onPressed:
                        _busy || doc.shiftMs == 0 ? null : () => _setShift(0),
                    icon: const Icon(Icons.restore),
                    label: const Text('Reset timing'),
                  ),
                  TextButton.icon(
                    key: const ValueKey('lyrics-timing-off'),
                    onPressed: _busy ? null : _withoutTiming,
                    icon: const Icon(Icons.timer_off_outlined),
                    label: const Text('Use without timing'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _controls(LyricsDoc doc, PlaybackService player) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          StreamBuilder<bool>(
            stream: player.isPlayingStream,
            initialData: player.isPlaying,
            builder: (context, snapshot) {
              final playing = _playingThis(player) && snapshot.data == true;
              return IconButton.filledTonal(
                key: const ValueKey('lyrics-timing-play'),
                tooltip: playing ? 'Pause' : 'Play',
                onPressed: _busy ? null : _playPause,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              );
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              doc.shiftMs == 0
                  ? 'Times as found'
                  : 'Moved ${lyricsShiftLabel(doc.shiftMs)}',
              key: const ValueKey('lyrics-timing-shift'),
              style: const TextStyle(color: Colors.white),
            ),
          ),
          TextButton(
            key: const ValueKey('lyrics-timing-earlier'),
            onPressed: _busy ? null : () => _setShift(doc.shiftMs - _nudgeMs),
            child: const Text('−0.5 s'),
          ),
          TextButton(
            key: const ValueKey('lyrics-timing-later'),
            onPressed: _busy ? null : () => _setShift(doc.shiftMs + _nudgeMs),
            child: const Text('+0.5 s'),
          ),
        ],
      ),
    );
  }

  Widget _lineList(PlaybackService player) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snapshot) {
        final now =
            snapshot.data == null ? null : _docMs(player, snapshot.data!);
        // The line being sung by the current times.
        LyricsLine? current;
        if (now != null) {
          for (final line in _lines) {
            final start = line.startMs;
            if (start != null && start <= now) current = line;
          }
        }
        return ListView.builder(
          key: const ValueKey('lyrics-timing-lines'),
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: _lines.length,
          itemBuilder: (context, i) {
            final line = _lines[i];
            final start = line.startMs;
            final isCurrent = identical(line, current);
            return InkWell(
              key: ValueKey('lyrics-timing-line-${line.lineNo}'),
              onTap: start == null || _busy ? null : () => _tapLine(line),
              child: Container(
                color: isCurrent ? const Color(0x332196F3) : null,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(
                        start == null ? '' : _timestamp(start),
                        style: const TextStyle(
                          color: _accent,
                          fontSize: 13,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        line.lineText,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

String _timestamp(int ms) {
  final d = Duration(milliseconds: max(0, ms));
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (d.inHours == 0) return '${d.inMinutes}:$s';
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  return '${d.inHours}:$m:$s';
}
