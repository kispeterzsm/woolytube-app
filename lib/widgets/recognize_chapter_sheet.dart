import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/providers.dart';
import '../services/chapters.dart';
import '../services/recognition/song_recognition_service.dart';

const _titleStyle = TextStyle(color: Colors.white);
const _subtitleStyle = TextStyle(color: Color(0xFF888888));
const _warningStyle = TextStyle(color: Color(0xFFFFB74D), fontSize: 13);

/// Looks up the song(s) in one chapter and lists them. Pops with the title
/// the user picked, or null. Closing the sheet cancels the lookup; the
/// chapter's start and end are never touched.
class RecognizeChapterSheet extends ConsumerStatefulWidget {
  const RecognizeChapterSheet({
    super.key,
    required this.track,
    required this.chapter,
  });

  final Track track;
  final MediaChapter chapter;

  @override
  ConsumerState<RecognizeChapterSheet> createState() =>
      _RecognizeChapterSheetState();
}

class _RecognizeChapterSheetState extends ConsumerState<RecognizeChapterSheet> {
  late final SongRecognitionService _service;

  /// This sheet's lookup holds the recognition lock.
  bool _owns = false;
  RecognitionProgress? _progress;
  RangeRecognition? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = ref.read(songRecognitionServiceProvider);
    if (_service.isScanning) {
      _error = 'Another file is being scanned. Try again when it is done.';
      return;
    }
    // Claims the lock before its first await, so a cancel from dispose
    // always reaches this lookup.
    final lookup = _service.recognizeRange(
      widget.track,
      startMs: widget.chapter.startMs,
      endMs: widget.chapter.endMs,
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );
    _owns = true;
    unawaited(
      lookup.then(
        (result) {
          _owns = false;
          if (mounted) setState(() => _result = result);
        },
        onError: (Object error) {
          _owns = false;
          if (error is RecognitionCancelled || !mounted) return;
          setState(
            () =>
                _error =
                    error is StateError
                        ? error.message
                        : 'Recognition failed: $error',
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    if (_owns) _service.cancel();
    super.dispose();
  }

  String _offsetText(List<int> matchedAtMs) {
    final start = widget.chapter.startMs;
    return matchedAtMs
        .map((ms) => chapterTimestamp((ms - start).clamp(0, 1 << 40)))
        .join(', ');
  }

  /// Where the song seems to start compared with the chapter, when the
  /// samples agree on it and it is a few seconds off.
  String? _startHint(RangeCandidate candidate) {
    final songStart = candidate.songStartMs;
    if (songStart == null || !candidate.consistent) return null;
    final delta = songStart - widget.chapter.startMs;
    if (delta.abs() < 3000) return null;
    return 'The song seems to start ${chapterTimestamp(delta.abs())} '
        '${delta < 0 ? 'before' : 'after'} this chapter.';
  }

  Widget _running() {
    final progress = _progress;
    final total = progress?.total ?? 0;
    final done = progress?.completed ?? 0;
    final waiting = progress?.phase == RecognitionPhase.waiting;
    final text =
        waiting
            ? '${progress!.waitReason == RecognitionWaitReason.network ? 'Connection problem.' : 'Shazam asked us to slow down.'} '
                'Waiting before sample ${done + 1} of $total…'
            : total == 0
            ? 'Preparing…'
            : 'Checking sample ${done < total ? done + 1 : total} of '
                '$total…';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: total > 0 ? done / total : null),
          const SizedBox(height: 8),
          Text(
            text,
            key: const ValueKey('recognize-chapter-progress'),
            style: _subtitleStyle,
          ),
        ],
      ),
    );
  }

  List<Widget> _results(RangeRecognition result) {
    final candidates = result.candidates;
    return [
      if (result.limited)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            'Shazam is limiting requests, so only ${result.checkedSamples} '
            'of ${result.sampleCount} samples were checked. Try again later '
            'for the rest.',
            key: const ValueKey('recognize-chapter-limited'),
            style: _warningStyle,
          ),
        ),
      if (result.mixed)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            'More than one song was heard in this chapter. It may run '
            'across a song change; check its boundaries.',
            key: ValueKey('recognize-chapter-mixed'),
            style: _warningStyle,
          ),
        ),
      if (candidates.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'No match in ${result.checkedSamples} '
            'sample${result.checkedSamples == 1 ? '' : 's'}. Shazam may not '
            'know this version of the song.',
            key: const ValueKey('recognize-chapter-none'),
            style: _subtitleStyle,
          ),
        ),
      for (final (i, candidate) in candidates.indexed)
        ListTile(
          key: ValueKey('recognize-chapter-candidate-$i'),
          title: Text(candidate.title, style: _titleStyle),
          subtitle: Text(
            [
              'Matched ${candidate.matchedAtMs.length} of '
                  '${result.checkedSamples} samples, at '
                  '${_offsetText(candidate.matchedAtMs)} into the chapter',
              if (candidate.consistent) 'timing agrees',
              if (_startHint(candidate) case final hint?) hint,
            ].join(' · '),
            style: _subtitleStyle,
          ),
          isThreeLine: true,
          trailing: TextButton(
            key: ValueKey('recognize-chapter-use-$i'),
            onPressed:
                candidate.title == widget.chapter.title
                    ? null
                    : () => Navigator.pop(context, candidate.title),
            child: Text(
              candidate.title == widget.chapter.title
                  ? 'Current title'
                  : 'Use as title',
            ),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.chapter;
    final result = _result;
    final error = _error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'Recognize song',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '${chapter.title} · ${chapterTimestamp(chapter.startMs)} – '
            '${chapterTimestamp(chapter.endMs)}\n'
            'Only this chapter is looked up. Its start and end stay as '
            'they are.',
            style: _subtitleStyle,
          ),
        ),
        const Divider(height: 1, color: Color(0xFF3A3A3A)),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            children: [
              if (error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    error,
                    key: const ValueKey('recognize-chapter-error'),
                    style: const TextStyle(color: Color(0xFFE57373)),
                  ),
                )
              else if (result == null)
                _running()
              else
                ..._results(result),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              key: const ValueKey('recognize-chapter-close'),
              onPressed: () => Navigator.pop(context),
              child: Text(result == null && error == null ? 'Cancel' : 'Close'),
            ),
          ),
        ),
      ],
    );
  }
}
