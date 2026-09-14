import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/providers.dart';
import '../providers/playback_providers.dart';
import '../services/chapters.dart';
import '../services/playback_service.dart';
import '../services/playlist_service.dart';
import '../widgets/mobile_data_download_guard.dart';

class ChaptersPage extends ConsumerStatefulWidget {
  final Track track;
  const ChaptersPage({super.key, required this.track});
  @override
  ConsumerState<ChaptersPage> createState() => _ChaptersPageState();
}

class _ChaptersPageState extends ConsumerState<ChaptersPage> {
  late final Stream<List<Track>> _tracks;
  PlaybackService? _editingPlayer;
  int? _markStart;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tracks = ref
        .read(databaseProvider)
        .watchTracksForPlaylist(widget.track.playlistId);
  }

  @override
  void dispose() {
    _editingPlayer?.endChapterEditing();
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

  Future<void> _play(
    Track track, {
    MediaChapter? chapter,
    bool edit = false,
  }) async {
    final player = ref.read(playbackServiceProvider);
    _markStart = null;
    if (edit) {
      await player.beginChapterEditing(track);
      _editingPlayer = player;
    } else {
      _editingPlayer?.endChapterEditing();
      _editingPlayer = null;
      final tracks = await ref
          .read(databaseProvider)
          .getTracksForPlaylist(track.playlistId);
      await player.playTrack(
        track,
        tracks,
        chapterId: chapter?.id,
        whole: chapter == null,
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _edit(
    Track track, {
    MediaChapter? chapter,
    int? startMs,
    int? endMs,
  }) async {
    final player = ref.read(playbackServiceProvider);
    final data = ChapterData.decode(track.chaptersJson);
    final durationMs =
        player.currentTrack?.id == track.id &&
                player.sourceDuration > Duration.zero
            ? player.sourceDuration.inMilliseconds
            : data.valid
            ? data.durationMs ??
                (track.isLocalReplacement
                    ? null
                    : track.durationSeconds == null
                    ? null
                    : track.durationSeconds! * 1000)
            : null;
    final result = await showDialog<MediaChapter>(
      context: context,
      builder:
          (_) => ChapterEditDialog(
            chapter: chapter,
            startMs: startMs,
            endMs: endMs,
            durationMs: durationMs,
            chapters: data.active,
          ),
    );
    if (result == null) return;
    await ref
        .read(chapterServiceProvider)
        .save(track, result, durationMs: durationMs);
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(currentTrackProvider).valueOrNull;
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final playing = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final marking = _editingPlayer != null && current?.id == widget.track.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Chapters')),
      body: StreamBuilder<List<Track>>(
        stream: _tracks,
        builder: (context, snapshot) {
          final track =
              snapshot.data
                  ?.where((t) => t.id == widget.track.id)
                  .firstOrNull ??
              widget.track;
          final data = ChapterData.decode(track.chaptersJson);
          final service = ref.read(chapterServiceProvider);
          final playable = track.status == 'complete' && track.filePath != null;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(track.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value:
                    track.chaptersEnabled == null
                        ? 'inherit'
                        : track.chaptersEnabled!
                        ? 'chapters'
                        : 'whole',
                decoration: const InputDecoration(labelText: 'Album playback'),
                items: const [
                  DropdownMenuItem(
                    value: 'inherit',
                    child: Text('Use playlist setting'),
                  ),
                  DropdownMenuItem(value: 'whole', child: Text('Whole video')),
                  DropdownMenuItem(value: 'chapters', child: Text('Chapters')),
                ],
                onChanged:
                    _busy
                        ? null
                        : (v) => _run(
                          () => service.setOverride(
                            track,
                            v == 'inherit' ? null : v == 'chapters',
                          ),
                        ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Shuffle finishes this album’s chapters before choosing another playlist entry.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Chapter edits apply the next time you start playback. The complete media file stays unchanged.',
              ),
              if (!data.valid)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'The file was replaced. Mark new chapters for this file.',
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed:
                        _busy || !playable
                            ? null
                            : () => _run(() => _play(track)),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play whole file'),
                  ),
                  TextButton.icon(
                    onPressed:
                        _busy || !playable
                            ? null
                            : () => _run(() => _play(track, edit: true)),
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('Mark chapters'),
                  ),
                  if (!track.isLocalReplacement &&
                      !PlaylistService.isForcedInsertVideoId(track.videoId))
                    TextButton.icon(
                      onPressed:
                          _busy
                              ? null
                              : () => _run(() async {
                                if (!await confirmManualDownload(
                                  context,
                                  ref.read(downloadNetworkPolicyProvider),
                                )) {
                                  return;
                                }
                                await service.refresh(track);
                              }),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Fetch YouTube chapters'),
                    ),
                  if (data.custom != null && data.valid)
                    TextButton(
                      onPressed:
                          _busy
                              ? null
                              : () => _run(() => service.restore(track)),
                      child: const Text('Restore downloaded chapters'),
                    ),
                ],
              ),
              if (marking)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        const Text('Mark on the full-file timeline'),
                        Slider(
                          value: position.inMilliseconds.toDouble().clamp(
                            0,
                            duration.inMilliseconds.toDouble(),
                          ),
                          max:
                              duration.inMilliseconds > 0
                                  ? duration.inMilliseconds.toDouble()
                                  : 1,
                          onChanged:
                              (v) => _editingPlayer!.seekTo(
                                Duration(milliseconds: v.round()),
                              ),
                        ),
                        Text(
                          '${chapterTimestamp(position.inMilliseconds)} / ${chapterTimestamp(duration.inMilliseconds)}',
                        ),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          children: [
                            IconButton(
                              onPressed:
                                  () => _editingPlayer!.togglePlayPause(),
                              icon: Icon(
                                playing ? Icons.pause : Icons.play_arrow,
                              ),
                            ),
                            FilledButton(
                              onPressed:
                                  _busy
                                      ? null
                                      : () => _run(() async {
                                        final now =
                                            _editingPlayer!
                                                .sourcePosition
                                                .inMilliseconds;
                                        if (_markStart == null) {
                                          setState(() => _markStart = now);
                                          return;
                                        }
                                        final start = _markStart!;
                                        _markStart = null;
                                        await _editingPlayer!.pause();
                                        if (mounted) {
                                          await _edit(
                                            track,
                                            startMs: start,
                                            endMs: now,
                                          );
                                        }
                                      }),
                              child: Text(
                                _markStart == null
                                    ? 'Mark chapter start'
                                    : 'Finish chapter',
                              ),
                            ),
                            if (_markStart != null)
                              TextButton(
                                onPressed:
                                    () => setState(() => _markStart = null),
                                child: const Text('Discard'),
                              ),
                          ],
                        ),
                        if (_markStart != null)
                          Text('Start: ${chapterTimestamp(_markStart!)}'),
                      ],
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      data.custom != null
                          ? 'Custom chapters'
                          : 'Downloaded chapters',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add chapter',
                    onPressed:
                        _busy || !playable
                            ? null
                            : () => _run(() => _edit(track)),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              if (data.active.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No chapters. Fetch them from YouTube or mark your own. Whole-file playback is available.',
                  ),
                ),
              for (final chapter in data.active)
                Card(
                  child: ListTile(
                    title: Text(chapter.title),
                    subtitle: Text(
                      '${chapterTimestamp(chapter.startMs)} – ${chapterTimestamp(chapter.endMs)} · ${chapterTimestamp(chapter.duration.inMilliseconds)}',
                    ),
                    leading: IconButton(
                      tooltip: 'Play chapter',
                      icon: const Icon(Icons.play_arrow),
                      onPressed:
                          _busy || !playable
                              ? null
                              : () =>
                                  _run(() => _play(track, chapter: chapter)),
                    ),
                    onTap:
                        _busy
                            ? null
                            : () => _run(() => _edit(track, chapter: chapter)),
                    trailing: PopupMenuButton<String>(
                      onSelected:
                          (value) => _run(() async {
                            switch (value) {
                              case 'edit':
                                await _edit(track, chapter: chapter);
                              case 'delete':
                                await service.delete(track, chapter.id);
                              case 'queue':
                                final player = ref.read(
                                  playbackServiceProvider,
                                );
                                final added = await player.addToUpNextQueue(
                                  track,
                                  chapterId: chapter.id,
                                );
                                if (added) {
                                  await player.startUpNextQueueIfIdle();
                                }
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        added
                                            ? 'Queued after the current album'
                                            : 'This chapter cannot be queued',
                                      ),
                                    ),
                                  );
                                }
                            }
                          }),
                      itemBuilder:
                          (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(
                              value: 'queue',
                              child: Text('Add to queue'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                    ),
                  ),
                ),
              if (_busy) const LinearProgressIndicator(),
            ],
          );
        },
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
    text: chapterTimestamp(widget.chapter?.endMs ?? widget.endMs ?? 0),
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
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            key: const ValueKey('chapter-start'),
            controller: _start,
            decoration: const InputDecoration(
              labelText: 'Start (m:ss or h:mm:ss)',
            ),
          ),
          TextField(
            key: const ValueKey('chapter-end'),
            controller: _end,
            decoration: const InputDecoration(
              labelText: 'End (m:ss or h:mm:ss)',
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
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
