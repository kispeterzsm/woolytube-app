import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/chapter_editor_providers.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/chapter_preview_player.dart';
import '../services/chapter_service.dart';
import '../services/chapters.dart';
import '../services/lyrics/lyrics_models.dart';
import '../services/recognition/chapter_estimator.dart';
import '../services/recognition/song_recognition_service.dart';
import 'chapter_editor_page.dart';

/// Lets the user check, fix and apply the chapters a recognition scan
/// proposed. Nothing touches the track's chapters until Apply, which
/// replaces them with the reviewed set after showing what goes (one step
/// that Undo last chapter change takes back). Pops with the number of
/// chapters the file has afterwards.
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

  /// Plays stretches of the file on its own, away from the main queue.
  /// Made on first use and kept until the page closes.
  ChapterPreviewPlayer? _preview;

  /// The preview card shows from the first preview until Stop.
  bool _previewShown = false;

  @override
  void dispose() {
    final preview = _preview;
    _preview = null;
    if (preview != null) unawaited(preview.dispose());
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

  ChapterPreviewPlayer? _previewPlayer() {
    final existing = _preview;
    if (existing != null) return existing;
    final path = resolveTrackMediaPath(widget.track);
    if (path == null) {
      _showMessage('The file is missing, so it cannot be played.');
      return null;
    }
    return _preview = ref.read(chapterPreviewPlayerFactoryProvider)(path);
  }

  /// Plays [startMs] to [endMs] of the file and stops there. The main
  /// player is paused, its queue untouched.
  Future<void> _playPreview(int startMs, {int? endMs}) async {
    final preview = _previewPlayer();
    if (preview == null) return;
    setState(() => _previewShown = true);
    try {
      await preview.playRange(max(0, startMs), endMs: endMs);
    } on StateError catch (e) {
      _showMessage(
        e.message == 'Could not open the file'
            ? 'Could not open the file to play it.'
            : e.message,
      );
    }
  }

  Future<void> _togglePreview() async {
    final preview = _preview;
    if (preview == null) return;
    try {
      await (preview.isPlaying ? preview.pause() : preview.play());
    } on StateError catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _stopPreview() async {
    final preview = _preview;
    if (mounted) setState(() => _previewShown = false);
    await preview?.pause();
  }

  /// Opens the chapter editor on the proposals. Its result replaces them
  /// here; nothing reaches the file until Apply.
  Future<void> _openEditor({String? focusId}) async {
    await _stopPreview();
    if (!mounted) return;
    final run = widget.run;
    final saved = await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute(
        builder:
            (_) => ChapterEditorPage(
              track: widget.track,
              initial: [for (final p in _proposals) p.toChapter()],
              durationMs: run.durationMs > 0 ? run.durationMs : null,
              focusChapterId: focusId,
              title: 'Adjust proposals',
              saveLabel: 'Done',
              // Hands the proposals back here; nothing is stored yet.
              closeOnSave: true,
              notesById: {
                for (final p in _proposals)
                  if (p.notes.isNotEmpty) p.id: p.notes,
              },
              onSave: (chapters, _) async {
                await _takeEditorResult(chapters);
                return true;
              },
            ),
      ),
    );
    if (saved == true) {
      _showMessage(
        'Proposals updated. Nothing changes on the file until you apply.',
      );
    }
  }

  /// Proposals kept by id take the new title and times; new ids are
  /// chapters the user added; missing ids were removed.
  Future<void> _takeEditorResult(List<MediaChapter> chapters) async {
    final byId = {for (final p in _proposals) p.id: p};
    final next = [
      for (final c in chapters)
        byId[c.id]?.adjusted(
              title: c.title,
              startMs: c.startMs,
              endMs: c.endMs,
            ) ??
            ChapterProposal.manual(
              id: c.id,
              title: c.title,
              startMs: c.startMs,
              endMs: c.endMs,
            ),
    ];
    if (mounted) {
      setState(
        () =>
            _proposals
              ..clear()
              ..addAll(next),
      );
    } else {
      _proposals
        ..clear()
        ..addAll(next);
    }
    await _persist();
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
    // Proposals are rebased onto edits made since the scan, but not onto an
    // undo, a reset or a replaced file: those bump the epoch, and a run
    // from another file content is refused by its key inside the apply.
    // Checked before "already applied": after an undo of this very run its
    // id is still the last one applied, but the way on is Recognize again.
    if (run.trackId != fresh.id || current.recognitionEpoch != run.epoch) {
      throw await _staleReason(fresh);
    }
    // Its timings came from a decoder that misplaced this file's audio.
    if (run.decoderOutdated) {
      throw StateError(RecognitionRun.decoderOutdatedMessage);
    }
    if (current.lastRecognitionRunId == run.runId) {
      _showMessage('These proposals were already applied to this file.');
      return;
    }
    // Checked again inside the apply; here so a stale run never asks first.
    if (await SongRecognitionService.currentFileKey(fresh) != run.fileKey) {
      throw const StaleRecognitionRun.fileChanged();
    }
    if (!mounted) return;
    final proposals = _proposals.map((p) => p.toChapter()).toList();
    final plan = ChapterService.planRecognition(
      current,
      proposals,
      durationMs: run.durationMs,
      replaceAll: true,
    );
    if (plan.removed.isNotEmpty && !await _confirmReplace(fresh, plan)) {
      return;
    }
    final applied = await ref
        .read(chapterServiceProvider)
        .applyRecognition(
          fresh,
          runId: run.runId,
          epoch: run.epoch,
          fileKey: run.fileKey,
          durationMs: run.durationMs,
          proposals: proposals,
          replaceAll: true,
        );
    if (!mounted) return;
    if (!applied) {
      // Something changed between the check above and the apply.
      final afterTrack = await db.getTrack(fresh.id);
      if (afterTrack == null) throw StateError('The track no longer exists.');
      final after = ChapterData.decode(afterTrack.chaptersJson);
      if (after.recognitionEpoch == run.epoch &&
          after.lastRecognitionRunId == run.runId) {
        _showMessage('These proposals were already applied to this file.');
        return;
      }
      throw await _staleReason(afterTrack);
    }
    unawaited(_fetchLyricsOfNewChapters(fresh.id));
    await _stopPreview();
    if (mounted) Navigator.of(context).pop(plan.chapters.length);
  }

  /// Shows which current chapters applying replaces, and asks.
  Future<bool> _confirmReplace(Track track, RecognitionPlan plan) async {
    final removedIds = {for (final c in plan.removed) c.id};
    final lyrics = [
      for (final doc in await ref
          .read(databaseProvider)
          .lyricsDocsForTrack(track.id))
        if (removedIds.contains(doc.chapterId) &&
            doc.status == LyricsStatus.found)
          doc,
    ];
    final pinned = lyrics.where((d) => d.pinned).length;
    if (!mounted) return false;
    const shown = 6;
    final removed = plan.removed;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Replace your chapters?'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    key: const ValueKey('replace-summary'),
                    [
                      '${removed.length} current '
                          'chapter${removed.length == 1 ? '' : 's'} '
                          '${removed.length == 1 ? 'is' : 'are'} replaced by '
                          '${plan.added.length} new '
                          'one${plan.added.length == 1 ? '' : 's'}.',
                      if (plan.kept > 0)
                        '${plan.kept} identical '
                            'chapter${plan.kept == 1 ? '' : 's'} '
                            '${plan.kept == 1 ? 'stays' : 'stay'}.',
                    ].join(' '),
                  ),
                  const SizedBox(height: 8),
                  for (final c in removed.take(shown))
                    Text(
                      '• ${c.title} (${chapterTimestamp(c.startMs)})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (removed.length > shown)
                    Text('…and ${removed.length - shown} more'),
                  if (lyrics.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      key: const ValueKey('replace-lyrics'),
                      '${lyrics.length} of them '
                      '${lyrics.length == 1 ? 'has' : 'have'} lyrics, which '
                      'are removed with them'
                      '${pinned == 0 ? '' : ', including $pinned you picked or fixed by hand, which are not looked up again'}'
                      '.',
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'Undo last chapter change brings your chapters back, '
                    'until you make another chapter change.',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('confirm-replace'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Replace'),
              ),
            ],
          ),
    );
    return confirmed == true;
  }

  /// Drops lyrics of chapters that are gone and, when the playlist has
  /// lyrics on and the network may be used without asking, fetches the new
  /// ones now; otherwise (or when this fails) the next update fetches them.
  Future<void> _fetchLyricsOfNewChapters(int trackId) async {
    // Read before the page closes.
    final lyrics = ref.read(lyricsServiceProvider);
    final policy = ref.read(downloadNetworkPolicyProvider);
    try {
      // Saving the chapters already dropped the docs of chapters that are
      // gone.
      if (!await policy.allowsAutomaticNetworkUse()) return;
      await lyrics.onChaptersChanged(trackId);
    } catch (_) {}
  }

  /// Why the run no longer fits [track]: a replaced file needs a new scan,
  /// undone or reset chapters only need the proposals rebuilt.
  Future<StaleRecognitionRun> _staleReason(Track track) async {
    if (widget.run.trackId != track.id ||
        track.filePath != widget.track.filePath ||
        await SongRecognitionService.currentFileKey(track) !=
            widget.run.fileKey) {
      return const StaleRecognitionRun.fileChanged();
    }
    return const StaleRecognitionRun();
  }

  @override
  Widget build(BuildContext context) {
    final unrecognized =
        _proposals.where((p) => !p.recognized && !p.addedByUser).length;
    final flagged = _proposals.where((p) => p.notes.isNotEmpty).length;
    final theme = Theme.of(context);
    final outdated = widget.run.decoderOutdated;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recognized songs'),
        actions: [
          TextButton(
            key: const ValueKey('apply-proposals'),
            onPressed:
                _busy || _proposals.isEmpty || outdated
                    ? null
                    : () => _run(_apply),
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
      body: ValueListenableBuilder<double>(
        valueListenable: audioPlayerOverlayHeightNotifier,
        builder: (context, overlay, _) {
          final previewing = _previewShown && _preview != null;
          // The preview controls stay pinned under the list, so they are
          // reachable while scrolling through the proposals.
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    16,
                    16,
                    16 + (previewing ? 0 : overlay),
                  ),
                  children: [
                    Text(widget.track.title, style: theme.textTheme.titleLarge),
                    if (outdated)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          RecognitionRun.decoderOutdatedMessage,
                          key: const ValueKey('review-decoder-outdated'),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      '${widget.run.matchedSamples} of ${widget.run.sampleCount} samples '
                      'recognized · ${_proposals.length} proposed chapters',
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'These are suggestions, not changes to your file. A consistent match '
                      'supports a title but does not prove it; listen before you apply. '
                      'Applying replaces the file\'s current chapters with this set; '
                      'you see what goes first, and Undo last chapter change takes it '
                      'back.',
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
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('review-open-editor'),
                          onPressed:
                              _busy || _proposals.isEmpty
                                  ? null
                                  : () => _openEditor(),
                          icon: const Icon(Icons.tune),
                          label: const Text('Fine-tune in editor'),
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
                            () => _playPreview(
                              _proposals[i].startMs,
                              endMs: _proposals[i].endMs,
                            ),
                        // Across the start: the end of the song before, then this one.
                        onBoundary:
                            () => _playPreview(
                              _proposals[i].startMs - 4000,
                              endMs: _proposals[i].startMs + 6000,
                            ),
                        onAdjust: () => _openEditor(focusId: _proposals[i].id),
                        onRename: () => _run(() => _rename(i)),
                        onMerge: () => _run(() => _mergeWithNext(i)),
                        onDelete: () => _run(() => _delete(i)),
                      ),
                  ],
                ),
              ),
              if (previewing)
                Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 8 + overlay),
                  child: _PreviewCard(
                    preview: _preview!,
                    onToggle: _togglePreview,
                    onStop: _stopPreview,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// What the page's preview player is doing, with play/pause and Stop.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.preview,
    required this.onToggle,
    required this.onStop,
  });

  final ChapterPreviewPlayer preview;
  final VoidCallback onToggle;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const ValueKey('review-preview'),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            StreamBuilder<bool>(
              stream: preview.playingStream,
              initialData: preview.isPlaying,
              builder: (context, snapshot) {
                final playing = snapshot.data ?? false;
                return IconButton(
                  tooltip: playing ? 'Pause' : 'Play',
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  onPressed: onToggle,
                );
              },
            ),
            Expanded(
              child: StreamBuilder<int>(
                stream: preview.positionMsStream,
                initialData: preview.positionMs,
                builder:
                    (context, _) => StreamBuilder<PreviewRange?>(
                      stream: preview.activeRangeStream,
                      initialData: preview.activeRange,
                      builder: (context, range) {
                        final r = range.data;
                        final end = r?.endMs;
                        return Text(
                          [
                            'Preview · ${chapterTimestamp(preview.positionMs ~/ 100 * 100)}',
                            if (r != null && end != null)
                              'until ${chapterTimestamp(end)}',
                          ].join(' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        );
                      },
                    ),
              ),
            ),
            TextButton(
              key: const ValueKey('review-preview-stop'),
              onPressed: onStop,
              child: const Text('Stop preview'),
            ),
          ],
        ),
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
  final VoidCallback onAdjust;
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
    required this.onAdjust,
    required this.onRename,
    required this.onMerge,
    required this.onDelete,
  });

  String get _method => switch (proposal.boundaryMethod) {
    'quiet-transition' => 'quiet transition',
    'reference-offset' => 'catalog offset',
    'sample-bracket' => 'between samples',
    ChapterProposal.manualBoundary => 'set by you',
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
                          proposal.recognized || proposal.addedByUser
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
              proposal.addedByUser
                  ? 'Added by you'
                  : '${proposal.sampleCount} detection${proposal.sampleCount == 1 ? '' : 's'}'
                      ' · ${proposal.boundaryMethod == ChapterProposal.manualBoundary ? 'start set by you' : 'start from $_method'}'
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
            Wrap(
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
                TextButton.icon(
                  key: ValueKey('proposal-adjust-${proposal.id}'),
                  onPressed: busy ? null : onAdjust,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Adjust'),
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
