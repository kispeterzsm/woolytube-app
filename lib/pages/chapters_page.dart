import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/chapter_service.dart';
import '../services/chapters.dart';
import '../services/playback_service.dart';
import '../services/playlist_service.dart';
import '../services/recognition/song_recognition_service.dart';
import '../widgets/mobile_data_download_guard.dart';
import '../widgets/settings_section_header.dart';
import 'recognition_review_page.dart';

/// How one file plays: as the playlist says, as chapters or as one track.
enum _PlayAs { playlistDefault, chapters, wholeFile }

/// A video's chapters: how it plays, the chapter list, and editing (by
/// typing times or by marking them while listening).
class ChaptersPage extends ConsumerStatefulWidget {
  final Track track;
  const ChaptersPage({super.key, required this.track});
  @override
  ConsumerState<ChaptersPage> createState() => _ChaptersPageState();
}

class _ChaptersPageState extends ConsumerState<ChaptersPage> {
  late final Stream<Track?> _trackRow;
  late final Stream<Playlist?> _playlistRow;

  /// Set while the owner marks chapters on the full-file timeline.
  PlaybackService? _editingPlayer;
  int? _markStart;
  bool _busy = false;

  /// The last completed recognition scan for this file, if any.
  RecognitionRun? _recognitionRun;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    // Single rows: a write to any other track of a long playlist does not
    // rebuild this page.
    _trackRow =
        (db.select(db.tracks)
          ..where((t) => t.id.equals(widget.track.id))).watchSingleOrNull();
    _playlistRow =
        (db.select(db.playlists)..where(
          (p) => p.id.equals(widget.track.playlistId),
        )).watchSingleOrNull();
    unawaited(_loadRecognitionRun());
  }

  @override
  void dispose() {
    _editingPlayer?.endChapterEditing();
    super.dispose();
  }

  PlaybackService get _player => ref.read(playbackServiceProvider);
  ChapterService get _chapters => ref.read(chapterServiceProvider);

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _showMessage(
        error is FormatException
            ? error.message
            : error is StateError
            ? error.message
            : error.toString(),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  /// Lets a running queue pick up the edit (songs that have not started).
  Future<void> _afterEdit(Track track) async {
    try {
      await _player.trackChaptersChanged(track);
    } catch (_) {}
  }

  Future<void> _play(Track track, {MediaChapter? chapter}) async {
    _stopMarking();
    final tracks = await ref
        .read(databaseProvider)
        .getTracksForPlaylist(track.playlistId);
    await _player.playTrack(
      track,
      tracks,
      chapterId: chapter?.id,
      whole: chapter == null,
    );
  }

  /// A tap on a chapter. When this file is the one playing, the queue is
  /// kept: a chapter of it is played from the queue, or (when the whole
  /// file plays) the player jumps there. Otherwise the playlist starts from
  /// this chapter.
  Future<void> _playChapter(Track track, MediaChapter chapter) async {
    final player = _player;
    final current = player.currentItem;
    if (current != null && current.track.id == track.id) {
      if (current.chapter == null) {
        _stopMarking();
        await player.seekTo(Duration(milliseconds: chapter.startMs));
        if (!player.isPlaying) await player.resume();
        return;
      }
      if (await player.playChapterOfCurrentFile(track.id, chapter.id)) {
        _stopMarking();
        return;
      }
    }
    await _play(track, chapter: chapter);
  }

  Future<void> _startMarking(Track track) async {
    final player = _player;
    final tracks = await ref
        .read(databaseProvider)
        .getTracksForPlaylist(track.playlistId);
    // Keeps the queue: the file plays now and the queue goes on after it.
    await player.beginChapterEditing(track, tracks);
    if (!mounted) {
      player.endChapterEditing();
      return;
    }
    setState(() {
      _editingPlayer = player;
      _markStart = null;
    });
  }

  void _stopMarking() {
    _editingPlayer?.endChapterEditing();
    if (!mounted) return;
    setState(() {
      _editingPlayer = null;
      _markStart = null;
    });
  }

  /// The file's length if it is known without opening it.
  int? _durationOf(Track track) {
    final player = _player;
    final loaded =
        player.currentTrack?.id == track.id &&
        player.sourceDuration > Duration.zero;
    return ChapterService.knownDurationMs(
      track,
      durationMs: loaded ? player.sourceDuration.inMilliseconds : null,
    );
  }

  /// Opens the chapter dialog and saves the result. Returns the saved
  /// chapter, or null when cancelled or impossible. The page only shows
  /// itself busy while saving, not while the dialog is open.
  Future<MediaChapter?> _edit(
    Track track, {
    MediaChapter? chapter,
    int? startMs,
    int? endMs,
  }) async {
    if (_busy) return null;
    final durationMs = _durationOf(track);
    if (durationMs == null || durationMs <= 0) {
      _showMessage(
        'The length of this file is not known yet. Play it once, or use '
        'Mark while listening, then add chapters.',
      );
      return null;
    }
    final data = ChapterData.decode(track.chaptersJson);
    var start = startMs;
    var end = endMs;
    if (chapter == null && start == null) {
      // A new chapter starts where the last one ends.
      final lastEnd = data.active.fold<int>(
        0,
        (latest, c) => c.endMs > latest ? c.endMs : latest,
      );
      start = lastEnd < durationMs ? lastEnd : 0;
      end = durationMs;
    }
    final result = await showDialog<MediaChapter>(
      context: context,
      builder:
          (_) => ChapterEditDialog(
            chapter: chapter,
            startMs: start,
            endMs: end,
            durationMs: durationMs,
            chapters: data.active,
          ),
    );
    if (result == null || !mounted) return null;
    var saved = false;
    await _run(() async {
      await _chapters.save(track, result, durationMs: durationMs);
      await _afterEdit(track);
      saved = true;
    });
    return saved ? result : null;
  }

  Future<void> _delete(Track track, MediaChapter chapter) async {
    final wasYouTube = ChapterData.decode(track.chaptersJson).custom == null;
    // Read now: Undo can be pressed after the page is closed.
    final chapters = _chapters;
    final player = _player;
    final messenger = ScaffoldMessenger.of(context);
    final before = await chapters.delete(track, chapter.id);
    await _afterEdit(track);
    if (before == null) return;
    Future<void> undo() async {
      await chapters.replaceChapters(track, before);
      try {
        await player.trackChaptersChanged(track);
      } catch (_) {}
    }

    _showMessage(
      wasYouTube
          ? 'Removed "${chapter.title}". This video now uses your own '
              'chapter list.'
          : 'Removed "${chapter.title}".',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          if (mounted) {
            unawaited(_run(undo));
            return;
          }
          unawaited(
            undo().catchError((Object error) {
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    'Could not bring back "${chapter.title}": '
                    '${error is StateError ? error.message : error}',
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }

  Future<void> _revertToYouTube(Track track, ChapterData data) async {
    final count = data.custom?.length ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Use YouTube chapters again?'),
            content: Text(
              count == 1
                  ? 'Your own chapter is discarded.'
                  : 'Your $count own chapters are discarded.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Discard mine'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _chapters.restore(track);
      await _afterEdit(track);
    });
  }

  Future<void> _fetchFromYouTube(Track track) async {
    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      return;
    }
    await _run(() async {
      await _chapters.refresh(track);
      await _afterEdit(track);
      final fresh = await ref.read(databaseProvider).getTrack(track.id);
      final found = ChapterData.decode(fresh?.chaptersJson).downloaded.length;
      _showMessage(
        found == 0
            ? 'This video has no chapters on YouTube.'
            : 'Found $found chapters on YouTube.',
      );
    });
  }

  Future<void> _setPlayAs(Track track, _PlayAs mode) async {
    await _chapters.setOverride(track, switch (mode) {
      _PlayAs.playlistDefault => null,
      _PlayAs.chapters => true,
      _PlayAs.wholeFile => false,
    });
    await _afterEdit(track);
  }

  Future<void> _setShuffle(Track track, bool enabled) async {
    await _chapters.setShuffleChapters(track, enabled);
    await _afterEdit(track);
  }

  Future<void> _addToUpNext(Track track, MediaChapter chapter) async {
    final added = await _player.addToUpNextQueue(track, chapterId: chapter.id);
    if (added) await _player.startUpNextQueueIfIdle();
    _showMessage(
      added ? 'Added to Up next' : 'This chapter cannot be added to Up next',
    );
  }

  /// "Mark start", then "End chapter here": the dialog opens with both
  /// times, and after saving the next chapter starts where this one ended.
  Future<void> _mark(Track track) async {
    final player = _editingPlayer;
    if (player == null || _busy) return;
    final now = player.sourcePosition.inMilliseconds;
    final start = _markStart;
    if (start == null) {
      setState(() => _markStart = now);
      return;
    }
    final wasPlaying = player.isPlaying;
    await player.pause();
    if (!mounted) return;
    setState(() => _markStart = null);
    final saved = await _edit(track, startMs: start, endMs: now);
    if (!mounted) return;
    // Cancelled: the start mark stays, so the end can be marked again.
    setState(() => _markStart = saved?.endMs ?? start);
    if (wasPlaying && identical(_editingPlayer, player)) await player.resume();
  }

  void _showInfo() {
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('About chapters'),
            content: const SingleChildScrollView(
              child: Text(
                'Chapters split a long video into tracks with their own '
                'titles, so Next and Previous move between them. The file '
                'itself is never changed.\n\n'
                'With shuffle on, all chapters of a video play before the '
                'next video is picked. Shuffle chapters mixes their order '
                'too.\n\n'
                'Mark while listening plays the file: tap Mark start where '
                'a chapter begins and End chapter here where it ends.\n\n'
                'Changes reach songs that have not started yet. If this '
                'video is playing now, they apply the next time it starts.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
    );
  }

  Future<void> _loadRecognitionRun() async {
    try {
      final run = await ref
          .read(songRecognitionServiceProvider)
          .loadRun(widget.track);
      if (mounted) setState(() => _recognitionRun = run);
    } catch (_) {
      // No cached run is the same as none.
    }
  }

  Future<void> _recognizeSongs(Track track) async {
    if (ref.read(downloadServiceProvider).isDownloading) {
      throw StateError('Wait for the running download to finish first.');
    }
    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      return;
    }
    final service = ref.read(songRecognitionServiceProvider);
    // The scan outlives this page; results are picked up through the
    // progress stream and the cached run.
    unawaited(
      service
          .scan(track)
          .then((run) {
            if (!mounted) return;
            setState(() => _recognitionRun = run);
            _showMessage(
              'Recognized ${run.proposals.length} '
              'section${run.proposals.length == 1 ? '' : 's'} in '
              '"${track.title}".',
              action: SnackBarAction(
                label: 'Review',
                onPressed: () {
                  // The message can outlive the page.
                  if (mounted) _openReview(track, run);
                },
              ),
            );
          })
          .catchError((Object error) {
            if (error is RecognitionCancelled) return;
            _showMessage('Recognition failed: $error');
          }),
    );
  }

  Future<void> _openReview(Track track, RecognitionRun run) async {
    _stopMarking();
    final applied = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => RecognitionReviewPage(track: track, run: run),
      ),
    );
    if (applied == null || !mounted) return;
    await _afterEdit(track);
    _showMessage(
      'Applied $applied chapter${applied == 1 ? '' : 's'}. '
      'Undo last chapter change takes them back.',
    );
  }

  Future<void> _removeAutomatic(Track track) async {
    await _chapters.removeAutomatic(track);
    await _afterEdit(track);
  }

  /// Takes back the last stored chapter change (an edit, a removal,
  /// recognition results or going back to the YouTube chapters).
  Future<void> _undo(Track track) async {
    await _chapters.undo(track);
    await _afterEdit(track);
  }

  @override
  Widget build(BuildContext context) {
    final currentId = ref.watch(
      currentTrackProvider.select((value) => value.valueOrNull?.id),
    );
    final marking = _editingPlayer != null && currentId == widget.track.id;
    return StreamBuilder<Track?>(
      stream: _trackRow,
      builder: (context, trackSnapshot) {
        final track = trackSnapshot.data ?? widget.track;
        return StreamBuilder<Playlist?>(
          stream: _playlistRow,
          builder: (context, playlistSnapshot) {
            final playlistChapters =
                playlistSnapshot.data?.playChapters ?? true;
            return _buildPage(context, track, playlistChapters, marking);
          },
        );
      },
    );
  }

  Widget _buildPage(
    BuildContext context,
    Track track,
    bool playlistChapters,
    bool marking,
  ) {
    final data = ChapterData.decode(track.chaptersJson);
    final playable = track.status == 'complete' && track.filePath != null;
    final canFetch =
        !track.isLocalReplacement &&
        !PlaylistService.isForcedInsertVideoId(track.videoId);
    final canRevert = data.custom != null && data.valid;
    final mode = switch (track.chaptersEnabled) {
      null => _PlayAs.playlistDefault,
      true => _PlayAs.chapters,
      false => _PlayAs.wholeFile,
    };
    final chaptersOn = track.chaptersEnabled ?? playlistChapters;
    final durationMs = ChapterService.knownDurationMs(track);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chapters'),
        actions: [
          IconButton(
            tooltip: 'About chapters',
            icon: const Icon(Icons.info_outline),
            onPressed: _showInfo,
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
      bottomNavigationBar:
          marking
              ? _MarkingPanel(
                player: _editingPlayer!,
                markStart: _markStart,
                busy: _busy,
                onMark: () => _mark(track),
                onDiscard: () => setState(() => _markStart = null),
                onDone: _stopMarking,
              )
              : null,
      body: ValueListenableBuilder<double>(
        valueListenable: audioPlayerOverlayHeightNotifier,
        builder:
            (context, overlay, _) => ListView(
              padding: EdgeInsets.only(bottom: 24 + overlay),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    track.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          [
                            if (durationMs != null)
                              chapterTimestamp(durationMs),
                            data.active.isEmpty
                                ? 'No chapters'
                                : data.active.length == 1
                                ? '1 chapter'
                                : '${data.active.length} chapters',
                          ].join(' · '),
                          style: const TextStyle(color: Color(0xFF999999)),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        key: const ValueKey('chapters-play-whole'),
                        onPressed:
                            _busy || !playable
                                ? null
                                : () => _run(() => _play(track)),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play whole file'),
                      ),
                    ],
                  ),
                ),
                if (!data.valid)
                  const _Notice(
                    icon: Icons.info_outline,
                    text:
                        'This file was replaced, so its old chapters no longer '
                        'fit. Add or mark new chapters for it.',
                  ),
                const SettingsSectionHeader('Play as'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<_PlayAs>(
                      key: const ValueKey('chapters-play-as'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: _PlayAs.playlistDefault,
                          label: Text('Default'),
                        ),
                        ButtonSegment(
                          value: _PlayAs.chapters,
                          label: Text('Chapters'),
                        ),
                        ButtonSegment(
                          value: _PlayAs.wholeFile,
                          label: Text('Whole file'),
                        ),
                      ],
                      // Always the stored value: a failed save shows what
                      // really applies.
                      selected: {mode},
                      onSelectionChanged:
                          _busy
                              ? null
                              : (selection) => _run(
                                () => _setPlayAs(track, selection.first),
                              ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Text(
                    'Default follows the playlist setting "Play chapters as '
                    'tracks", which is ${playlistChapters ? 'on' : 'off'}.',
                    style: const TextStyle(
                      color: Color(0xFF999999),
                      fontSize: 13,
                    ),
                  ),
                ),
                if (data.active.isNotEmpty)
                  SwitchListTile(
                    key: const ValueKey('chapters-shuffle'),
                    title: const Text('Shuffle chapters'),
                    subtitle: const Text(
                      'When shuffle is on, play this video\'s chapters in '
                      'random order',
                    ),
                    value: data.shuffleChapters,
                    onChanged:
                        _busy
                            ? null
                            : (enabled) =>
                                _run(() => _setShuffle(track, enabled)),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 4, 0),
                  child: Row(
                    children: [
                      const Text(
                        'Chapters',
                        style: TextStyle(
                          color: Color(0xFF2196F3),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (data.active.isNotEmpty)
                        _SourceChip(custom: data.custom != null),
                      const Spacer(),
                      IconButton(
                        key: const ValueKey('chapters-add'),
                        tooltip: 'Add chapter',
                        onPressed:
                            _busy || !playable ? null : () => _edit(track),
                        icon: const Icon(Icons.add),
                      ),
                      PopupMenuButton<String>(
                        key: const ValueKey('chapters-more'),
                        tooltip: 'More',
                        enabled: !_busy,
                        onSelected: (value) {
                          switch (value) {
                            case 'mark':
                              _run(() => _startMarking(track));
                            case 'fetch':
                              _fetchFromYouTube(track);
                            case 'revert':
                              _revertToYouTube(track, data);
                          }
                        },
                        itemBuilder:
                            (_) => [
                              PopupMenuItem(
                                value: 'mark',
                                enabled: playable && !marking,
                                child: const Text('Mark while listening'),
                              ),
                              if (canFetch)
                                const PopupMenuItem(
                                  value: 'fetch',
                                  child: Text('Fetch from YouTube'),
                                ),
                              if (canRevert && canFetch)
                                const PopupMenuItem(
                                  value: 'revert',
                                  child: Text('Use YouTube chapters again'),
                                ),
                            ],
                      ),
                    ],
                  ),
                ),
                if (data.undoChapters != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const ValueKey('chapters-undo'),
                        onPressed:
                            _busy ? null : () => _run(() => _undo(track)),
                        icon: const Icon(Icons.undo),
                        label: const Text('Undo last chapter change'),
                      ),
                    ),
                  ),
                if (data.active.isNotEmpty && !chaptersOn)
                  const _Notice(
                    icon: Icons.block,
                    text:
                        'Chapters are off for this video: it plays as one '
                        'track.',
                  ),
                if (data.active.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      canFetch
                          ? 'No chapters yet. Fetch them from YouTube, or add '
                              'your own with + or Mark while listening.'
                          : 'No chapters yet. Add your own with + or Mark '
                              'while listening.',
                      style: const TextStyle(color: Color(0xFF999999)),
                    ),
                  ),
                Opacity(
                  opacity: chaptersOn ? 1 : 0.6,
                  child: Column(
                    children: [
                      for (final (i, chapter) in data.active.indexed)
                        _ChapterRow(
                          key: ValueKey('chapter-${chapter.id}'),
                          number: i + 1,
                          chapter: chapter,
                          enabled: !_busy && playable,
                          onTap:
                              () => _run(() async {
                                final player = _editingPlayer;
                                if (marking && player != null) {
                                  // Marking: jump there on the timeline.
                                  await player.seekTo(
                                    Duration(milliseconds: chapter.startMs),
                                  );
                                } else {
                                  await _playChapter(track, chapter);
                                }
                              }),
                          onEdit: () => _edit(track, chapter: chapter),
                          onAddToUpNext:
                              () => _run(() => _addToUpNext(track, chapter)),
                          onDelete: () => _run(() => _delete(track, chapter)),
                        ),
                    ],
                  ),
                ),
                // Below the list, so the page reads as before for files that
                // are never scanned.
                _RecognitionSection(
                  track: track,
                  data: data,
                  run: _recognitionRun,
                  enabled: !_busy && playable,
                  onRecognize: () => _run(() => _recognizeSongs(track)),
                  onReview: (run) => _openReview(track, run),
                  onRemoveAutomatic: () => _run(() => _removeAutomatic(track)),
                ),
              ],
            ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFFFFB74D)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(color: Color(0xFFDDDDDD))),
          ),
        ],
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.custom});

  final bool custom;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF333333),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        custom ? 'Your own' : 'From YouTube',
        style: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
      ),
    );
  }
}

/// Song recognition for long mixes. Only this section follows the scan's
/// progress, so the rest of the page does not rebuild with every sample.
class _RecognitionSection extends ConsumerWidget {
  const _RecognitionSection({
    required this.track,
    required this.data,
    required this.run,
    required this.enabled,
    required this.onRecognize,
    required this.onReview,
    required this.onRemoveAutomatic,
  });

  final Track track;
  final ChapterData data;

  /// The last completed scan of this file, if any.
  final RecognitionRun? run;

  /// False while the page is busy or the file cannot be played.
  final bool enabled;
  final VoidCallback onRecognize;
  final void Function(RecognitionRun run) onReview;
  final VoidCallback onRemoveAutomatic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(recognitionProgressProvider).valueOrNull;
    // The running scan of this file, if any.
    final scan =
        progress != null && progress.running && progress.trackId == track.id
            ? progress
            : null;
    final scanningOther = progress?.running == true && scan == null;
    final run = this.run;
    final hasAutomatic = data.active.any(
      (c) => c.origin == ChapterOrigin.auto && !c.manuallyEdited,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSectionHeader('Song recognition'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Identifies the songs in a long mix by fingerprinting short '
            'samples and proposes chapters for you to review. Only '
            'fingerprints are sent, never audio.',
            style: TextStyle(color: Color(0xFF999999), fontSize: 13),
          ),
        ),
        if (scan != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value:
                      scan.total > 0 && scan.phase == RecognitionPhase.sampling
                          ? scan.completed / scan.total
                          : null,
                ),
                const SizedBox(height: 4),
                Text(
                  switch (scan.phase) {
                    RecognitionPhase.sampling =>
                      'Recognizing samples ${scan.completed} of '
                          '${scan.total}…',
                    RecognitionPhase.silence => 'Finding quiet transitions…',
                    _ => 'Estimating chapters…',
                  },
                  style: const TextStyle(
                    color: Color(0xFF999999),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (scan != null)
                TextButton.icon(
                  key: const ValueKey('cancel-recognition'),
                  onPressed:
                      () => ref.read(songRecognitionServiceProvider).cancel(),
                  icon: const Icon(Icons.stop),
                  label: const Text('Cancel'),
                )
              else
                TextButton.icon(
                  key: const ValueKey('recognize-songs'),
                  onPressed: enabled && !scanningOther ? onRecognize : null,
                  icon: const Icon(Icons.graphic_eq),
                  label: Text(
                    run == null ? 'Recognize songs' : 'Recognize again',
                  ),
                ),
              if (run != null && scan == null)
                FilledButton.tonalIcon(
                  key: const ValueKey('review-proposals'),
                  onPressed: enabled ? () => onReview(run) : null,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: Text('Review ${run.proposals.length} proposals'),
                ),
              if (hasAutomatic)
                TextButton(
                  key: const ValueKey('remove-automatic'),
                  onPressed: enabled ? onRemoveAutomatic : null,
                  child: const Text('Remove automatic chapters'),
                ),
            ],
          ),
        ),
        if (scanningOther)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Another file is being scanned.',
              style: TextStyle(color: Color(0xFF999999), fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    super.key,
    required this.number,
    required this.chapter,
    required this.enabled,
    required this.onTap,
    required this.onEdit,
    required this.onAddToUpNext,
    required this.onDelete,
  });

  final int number;
  final MediaChapter chapter;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onAddToUpNext;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // Recognised chapters say so, and the first open question about them
    // (a doubtful name or timing) shows on a line of its own.
    final origin = switch (chapter.origin) {
      ChapterOrigin.auto when chapter.manuallyEdited => ' · Auto, edited',
      ChapterOrigin.auto => ' · Auto',
      _ => '',
    };
    final review = chapter.reviewReasons.firstOrNull;
    return ListTile(
      leading: SizedBox(
        width: 28,
        child: Text(
          '$number',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF999999)),
        ),
      ),
      title: Text(chapter.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${chapterTimestamp(chapter.startMs)} – '
        '${chapterTimestamp(chapter.endMs)} · '
        '${chapterTimestamp(chapter.duration.inMilliseconds)}'
        '$origin${review == null ? '' : '\n$review'}',
      ),
      isThreeLine: review != null,
      enabled: enabled,
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        tooltip: 'Chapter options',
        enabled: enabled,
        onSelected: (value) {
          switch (value) {
            case 'edit':
              onEdit();
            case 'queue':
              onAddToUpNext();
            case 'delete':
              onDelete();
          }
        },
        itemBuilder:
            (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'queue', child: Text('Add to Up next')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
      ),
    );
  }
}

/// The marking timeline. Only this panel follows the playing position, so
/// the rest of the page does not rebuild several times a second.
class _MarkingPanel extends ConsumerStatefulWidget {
  const _MarkingPanel({
    required this.player,
    required this.markStart,
    required this.busy,
    required this.onMark,
    required this.onDiscard,
    required this.onDone,
  });

  final PlaybackService player;
  final int? markStart;
  final bool busy;
  final VoidCallback onMark;
  final VoidCallback onDiscard;
  final VoidCallback onDone;

  @override
  ConsumerState<_MarkingPanel> createState() => _MarkingPanelState();
}

class _MarkingPanelState extends ConsumerState<_MarkingPanel> {
  /// While dragging, the slider shows the finger, not the player.
  double? _dragMs;

  /// After a seek, the target is shown until the player's position gets
  /// there, so the thumb does not jump back for a moment.
  double? _heldMs;
  DateTime? _heldAt;

  bool _holding(double positionMs) {
    final held = _heldMs, at = _heldAt;
    if (held == null || at == null) return false;
    if ((positionMs - held).abs() < 1500) return false;
    return DateTime.now().difference(at) < const Duration(seconds: 2);
  }

  @override
  Widget build(BuildContext context) {
    final position =
        ref.watch(positionProvider).valueOrNull ?? widget.player.sourcePosition;
    var duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    if (duration <= Duration.zero) duration = widget.player.sourceDuration;
    final playing = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final maxMs =
        duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
    final positionMs = position.inMilliseconds.toDouble();
    final shownMs = (_dragMs ?? (_holding(positionMs) ? _heldMs! : positionMs))
        .clamp(0.0, maxMs);
    final markStart = widget.markStart;

    return Material(
      color: const Color(0xFF2A2A2A),
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Mark while listening',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('chapters-marking-done'),
                    onPressed: widget.onDone,
                    child: const Text('Done'),
                  ),
                ],
              ),
              Slider(
                value: shownMs,
                max: maxMs,
                onChangeStart: (v) => setState(() => _dragMs = v),
                onChanged: (v) => setState(() => _dragMs = v),
                onChangeEnd: (v) {
                  setState(() {
                    _dragMs = null;
                    _heldMs = v;
                    _heldAt = DateTime.now();
                  });
                  unawaited(
                    widget.player.seekTo(Duration(milliseconds: v.round())),
                  );
                },
              ),
              // Times on their own line, so the buttons fit on narrow
              // phones and with large text.
              Row(
                children: [
                  IconButton(
                    tooltip: playing ? 'Pause' : 'Play',
                    onPressed: () => widget.player.togglePlayPause(),
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  ),
                  Expanded(
                    child: Text(
                      '${chapterTimestamp(shownMs.round())} / '
                      '${chapterTimestamp(duration.inMilliseconds)}'
                      '${markStart == null ? '' : ' · starts at ${chapterTimestamp(markStart)}'}',
                      style: const TextStyle(fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    if (markStart != null)
                      TextButton(
                        onPressed: widget.busy ? null : widget.onDiscard,
                        child: const Text('Discard'),
                      ),
                    FilledButton(
                      key: const ValueKey('chapters-mark'),
                      onPressed: widget.busy ? null : widget.onMark,
                      child: Text(
                        markStart == null ? 'Mark start' : 'End chapter here',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChapterEditDialog extends StatefulWidget {
  final MediaChapter? chapter;
  final int? startMs;
  final int? endMs;
  final int? durationMs;
  final List<MediaChapter> chapters;
  const ChapterEditDialog({
    super.key,
    this.chapter,
    this.startMs,
    this.endMs,
    this.durationMs,
    this.chapters = const [],
  });
  @override
  State<ChapterEditDialog> createState() => _ChapterEditDialogState();
}

class _ChapterEditDialogState extends State<ChapterEditDialog> {
  late final _title = TextEditingController(text: widget.chapter?.title ?? '');
  late final _start = TextEditingController(
    text: chapterTimestamp(widget.chapter?.startMs ?? widget.startMs ?? 0),
  );
  late final _end = TextEditingController(
    text: chapterTimestamp(
      widget.chapter?.endMs ?? widget.endMs ?? widget.durationMs ?? 0,
    ),
  );
  String? _error;
  @override
  void dispose() {
    _title.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final start = parseChapterTimestamp(_start.text),
          end = parseChapterTimestamp(_end.text);
      if (start == null || end == null) {
        throw const FormatException(
          'Use minutes:seconds or hours:minutes:seconds.',
        );
      }
      final chapter = MediaChapter(
        id:
            widget.chapter?.id ??
            'local-${DateTime.now().microsecondsSinceEpoch}',
        title: _title.text.trim(),
        startMs: start,
        endMs: end,
      );
      final entries = [
        ...widget.chapters.where((c) => c.id != chapter.id),
        chapter,
      ]..sort((a, b) => a.startMs.compareTo(b.startMs));
      validateChapters(entries, durationMs: widget.durationMs);
      Navigator.pop(context, chapter);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.chapter == null ? 'Add chapter' : 'Edit chapter'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('chapter-title'),
            controller: _title,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            key: const ValueKey('chapter-start'),
            controller: _start,
            keyboardType: TextInputType.datetime,
            decoration: const InputDecoration(
              labelText: 'Start (m:ss or h:mm:ss)',
            ),
          ),
          TextField(
            key: const ValueKey('chapter-end'),
            controller: _end,
            keyboardType: TextInputType.datetime,
            decoration: InputDecoration(
              labelText: 'End (m:ss or h:mm:ss)',
              helperText:
                  widget.durationMs == null
                      ? null
                      : 'The file is ${chapterTimestamp(widget.durationMs!)} '
                          'long',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
