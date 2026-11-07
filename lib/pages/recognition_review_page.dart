import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/chapter_service.dart';
import '../services/chapters.dart';
import '../services/playback_service.dart';
import '../services/recognition/chapter_estimator.dart';
import '../services/recognition/song_recognition_service.dart';

/// Lets the user check, fix and apply the chapters a recognition scan
/// proposed. Nothing touches the track's chapters until Apply.
class RecognitionReviewPage extends ConsumerStatefulWidget {
  final Track track;
  final RecognitionRun run;

  const RecognitionReviewPage({
    super.key,
    required this.track,
    required this.run,
  });

  @override
  ConsumerState<RecognitionReviewPage> createState() =>
      _RecognitionReviewPageState();
}

class _RecognitionReviewPageState extends ConsumerState<RecognitionReviewPage> {
  // Runs saved by older builds can hold empty proposals; they never apply.
  late final List<ChapterProposal> _proposals = [
    for (final p in widget.run.proposals)
      if (p.endMs > p.startMs) p,
  ];
  bool _busy = false;
  PlaybackService? _previewPlayer;
  Timer? _previewStop;

  @override
  void dispose() {
    _previewStop?.cancel();
    _previewPlayer?.endChapterEditing();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException ? error.message : error.toString(),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _persist() async {
    try {
      await ref
          .read(songRecognitionServiceProvider)
          .saveRun(widget.run.copyWith(proposals: _proposals), widget.track);
    } catch (_) {
      // Keeping edits across restarts is a convenience, not a requirement.
    }
  }

  Future<void> _preview(int startMs, {int? endMs}) async {
    final player = ref.read(playbackServiceProvider);
    if (_previewPlayer == null) {
      final tracks = await ref
          .read(databaseProvider)
          .getTracksForPlaylist(widget.track.playlistId);
      // Keeps the queue: the file plays now and the queue goes on after it.
      await player.beginChapterEditing(widget.track, tracks);
      if (!mounted) {
        player.endChapterEditing();
        return;
      }
      _previewPlayer = player;
    }
    await player.seekTo(Duration(milliseconds: startMs.clamp(0, 1 << 40)));
    await player.resume();
    _previewStop?.cancel();
    if (endMs != null && endMs > startMs) {
      _previewStop = Timer(Duration(milliseconds: endMs - startMs), () {
        _previewPlayer?.pause();
      });
    }
    if (mounted) setState(() {});
  }

  Future<void> _stopPreview() async {
    _previewStop?.cancel();
    final player = _previewPlayer;
    _previewPlayer = null;
    player?.endChapterEditing();
    if (mounted) setState(() {});
  }

  Future<void> _rename(int index) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: _proposals[index].title),
    );
    if (title == null || title.isEmpty) return;
    setState(() => _proposals[index] = _proposals[index].renamed(title));
    await _persist();
  }

  Future<void> _mergeWithNext(int index) async {
    final left = _proposals[index];
    final right = _proposals[index + 1];
    final merged = ChapterProposal(
      id: left.id,
      title: left.recognized || !right.recognized ? left.title : right.title,
      startMs: left.startMs,
      endMs: right.endMs,
      trackKey: left.trackKey ?? right.trackKey,
      referenceId: left.referenceId ?? right.referenceId,
      sampleCount: left.sampleCount + right.sampleCount,
      referenceSampleCount:
          left.referenceSampleCount + right.referenceSampleCount,
      referenceStartMs: left.referenceStartMs,
      referenceSpreadMs: left.referenceSpreadMs,
      boundaryMethod: left.boundaryMethod,
      selectedQuietIntervalMs: left.selectedQuietIntervalMs,
      nearestSilenceMs: left.nearestSilenceMs,
      distanceFromSilenceEndMs: left.distanceFromSilenceEndMs,
      consistentReference:
          left.consistentReference && right.consistentReference,
      notes: {...left.notes, ...right.notes}.toList(),
      firstSampleMs: left.firstSampleMs,
      lastSampleMs: right.lastSampleMs,
      // The user decided these belong together; later scans keep it.
      edited: true,
    );
    setState(() => _proposals.replaceRange(index, index + 2, [merged]));
    await _persist();
  }

  Future<void> _delete(int index) async {
    setState(() => _proposals.removeAt(index));
    await _persist();
  }

  Future<void> _apply() async {
    final db = ref.read(databaseProvider);
    final fresh = await db.getTrack(widget.track.id);
    if (fresh == null) throw StateError('The track no longer exists.');
    final run = widget.run;
    final current = ChapterData.decode(fresh.chaptersJson);
    if (current.lastRecognitionRunId == run.runId) {
      _showMessage('These proposals were already applied to this file.');
      return;
    }
    // Proposals are rebased onto edits made since the scan, but not onto an
    // undo, a reset or a replaced file: those bump the epoch, and a run
    // from another file content is refused by its key inside the apply.
    if (run.trackId != fresh.id || current.recognitionEpoch != run.epoch) {
      throw const StaleRecognitionRun();
    }
    final applied = await ref
        .read(chapterServiceProvider)
        .applyRecognition(
          fresh,
          runId: run.runId,
          epoch: run.epoch,
          fileKey: run.fileKey,
          durationMs: run.durationMs,
          proposals: _proposals.map((p) => p.toChapter()).toList(),
        );
    if (!mounted) return;
    if (!applied) {
      // Something changed between the check above and the apply.
      final after = ChapterData.decode(
        (await db.getTrack(fresh.id))?.chaptersJson,
      );
      if (after.lastRecognitionRunId == run.runId) {
        _showMessage('These proposals were already applied to this file.');
        return;
      }
      throw const StaleRecognitionRun();
    }
    await _stopPreview();
    if (mounted) Navigator.of(context).pop(_proposals.length);
  }

  @override
  Widget build(BuildContext context) {
    final playing = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final unrecognized = _proposals.where((p) => !p.recognized).length;
    final flagged = _proposals.where((p) => p.notes.isNotEmpty).length;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recognized songs'),
        actions: [
          TextButton(
            key: const ValueKey('apply-proposals'),
            onPressed: _busy || _proposals.isEmpty ? null : () => _run(_apply),
            child: Text('Apply (${_proposals.length})'),
          ),
        ],
        bottom:
            _busy
                ? const PreferredSize(
                  preferredSize: Size.fromHeight(2),
                  child: LinearProgressIndicator(minHeight: 2),
                )
                : null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.track.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '${widget.run.matchedSamples} of ${widget.run.sampleCount} samples '
            'recognized · ${_proposals.length} proposed chapters',
          ),
          const SizedBox(height: 8),
          const Text(
            'These are suggestions, not changes to your file. A consistent match '
            'supports a title but does not prove it; listen before you apply. '
            'Applying keeps chapters you made or edited and replaces earlier '
            'automatic ones.',
          ),
          if (unrecognized > 0 || flagged > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                [
                  if (unrecognized > 0)
                    '$unrecognized unrecognized section${unrecognized == 1 ? '' : 's'}',
                  if (flagged > 0) '$flagged with review notes',
                ].join(' · '),
                style: TextStyle(color: theme.colorScheme.tertiary),
              ),
            ),
          if (_previewPlayer != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: playing ? 'Pause' : 'Play',
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: () => _previewPlayer?.togglePlayPause(),
                    ),
                    Expanded(
                      child: Text(
                        'Preview · ${chapterTimestamp(position.inMilliseconds)}',
                      ),
                    ),
                    TextButton(
                      onPressed: _stopPreview,
                      child: const Text('Stop preview'),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (_proposals.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Nothing left to apply.'),
            ),
          for (var i = 0; i < _proposals.length; i++)
            _ProposalCard(
              key: ValueKey('proposal-$i-${_proposals[i].id}'),
              proposal: _proposals[i],
              busy: _busy,
              canMerge: i + 1 < _proposals.length,
              onPlay:
                  () => _run(
                    () => _preview(
                      _proposals[i].startMs,
                      endMs: _proposals[i].endMs,
                    ),
                  ),
              onBoundary:
                  () => _run(
                    () => _preview(
                      _proposals[i].startMs - 5000,
                      endMs: _proposals[i].startMs + 15000,
                    ),
                  ),
              onRename: () => _run(() => _rename(i)),
              onMerge: () => _run(() => _mergeWithNext(i)),
              onDelete: () => _run(() => _delete(i)),
            ),
        ],
      ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  final ChapterProposal proposal;
  final bool busy;
  final bool canMerge;
  final VoidCallback onPlay;
  final VoidCallback onBoundary;
  final VoidCallback onRename;
  final VoidCallback onMerge;
  final VoidCallback onDelete;

  const _ProposalCard({
    super.key,
    required this.proposal,
    required this.busy,
    required this.canMerge,
    required this.onPlay,
    required this.onBoundary,
    required this.onRename,
    required this.onMerge,
    required this.onDelete,
  });

  String get _method => switch (proposal.boundaryMethod) {
    'quiet-transition' => 'quiet transition',
    'reference-offset' => 'catalog offset',
    'sample-bracket' => 'between samples',
    _ => 'file start',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    proposal.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color:
                          proposal.recognized
                              ? null
                              : theme.colorScheme.tertiary,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Proposal actions',
                  enabled: !busy,
                  onSelected: (value) {
                    switch (value) {
                      case 'rename':
                        onRename();
                      case 'merge':
                        onMerge();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder:
                      (_) => [
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename'),
                        ),
                        if (canMerge)
                          const PopupMenuItem(
                            value: 'merge',
                            child: Text('Merge with next'),
                          ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Remove'),
                        ),
                      ],
                ),
              ],
            ),
            Text(
              '${chapterTimestamp(proposal.startMs)} – ${chapterTimestamp(proposal.endMs)}'
              ' · ${chapterTimestamp(proposal.endMs - proposal.startMs)}',
            ),
            Text(
              '${proposal.sampleCount} detection${proposal.sampleCount == 1 ? '' : 's'}'
              ' · start from $_method'
              '${proposal.referenceSpreadMs == null ? '' : ' · spread ${proposal.referenceSpreadMs} ms'}',
              style: theme.textTheme.bodySmall,
            ),
            for (final note in proposal.notes)
              Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: busy ? null : onPlay,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Play'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onBoundary,
                  icon: const Icon(Icons.skip_previous, size: 18),
                  label: const Text('Boundary'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename chapter'),
    content: TextField(
      key: const ValueKey('proposal-title'),
      controller: _controller,
      autofocus: true,
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
