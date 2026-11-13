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
import '../services/youtube_links.dart';
import '../widgets/mobile_data_download_guard.dart';
import '../widgets/recognize_chapter_sheet.dart';
import '../widgets/settings_section_header.dart';
import 'chapter_editor_page.dart';
import 'lyrics_page.dart';
import 'recognition_review_page.dart';
import '../services/track_title.dart';

/// How one file plays: as the playlist says, as chapters or as one track.
enum _PlayAs { playlistDefault, chapters, wholeFile }

/// Whether one file's chapters shuffle (when shuffle is on): as the
/// playlist says, always or never.
enum _ShuffleChapters { playlistDefault, shuffle, noShuffle }

/// A video's chapters: how it plays, the chapter list, per-chapter queueing
/// and Always skip, and editing them in the chapter editor while listening.
class ChaptersPage extends ConsumerStatefulWidget {
  final Track track;
  const ChaptersPage({super.key, required this.track});
  @override
  ConsumerState<ChaptersPage> createState() => _ChaptersPageState();
}

class _ChaptersPageState extends ConsumerState<ChaptersPage> {
  late final Stream<Track?> _trackRow;
  late final Stream<Playlist?> _playlistRow;

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
        await player.seekTo(Duration(milliseconds: chapter.startMs));
        if (!player.isPlaying) await player.resume();
        return;
      }
      if (await player.playChapterOfCurrentFile(track.id, chapter.id)) {
        return;
      }
    }
    await _play(track, chapter: chapter);
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

  /// Opens the typed-times dialog for [chapter] and saves the result.
  Future<void> _editTimes(Track track, MediaChapter chapter) async {
    if (_busy) return;
    final durationMs = _durationOf(track);
    if (durationMs == null || durationMs <= 0) {
      _showMessage(
        'The length of this file is not known yet. Use Adjust boundaries '
        'instead: it opens the file.',
      );
      return;
    }
    final data = ChapterData.decode(track.chaptersJson);
    final result = await showDialog<MediaChapter>(
      context: context,
      builder:
          (_) => ChapterEditDialog(
            chapter: chapter,
            durationMs: durationMs,
            chapters: data.active,
          ),
    );
    if (result == null || !mounted) return;
    await _run(() async {
      await _chapters.save(track, result, durationMs: durationMs);
      await _afterEdit(track);
    });
  }

  /// Opens the chapter editor on the current list (from any source). Its
  /// saves (it stays open after each) are one change that Undo takes back:
  /// to the list from before the editor opened.
  Future<void> _openEditor(Track track, {String? focusChapterId}) async {
    if (_busy) return;
    final data = ChapterData.decode(track.chaptersJson);
    // Read now: the editor saves while this page is covered.
    final chapters = _chapters;
    final player = _player;
    // When this file is the one playing (or paused), the editor opens on
    // the chapter the player is in and shows where exactly it is.
    final item = player.currentItem;
    final playingAtMs =
        item != null && item.track.id == track.id
            ? item.startMs + player.position.inMilliseconds
            : null;
    // After the first save, Undo stays on the list from before the editor.
    var savedOnce = false;
    final saved = await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute(
        builder:
            (_) => ChapterEditorPage(
              track: track,
              initial: data.active,
              durationMs: _durationOf(track),
              focusChapterId: focusChapterId,
              playingAtMs: playingAtMs,
              title: data.active.isEmpty ? 'Create chapters' : 'Edit chapters',
              saveLabel: 'Save',
              notesById: {
                for (final c in data.active)
                  if (c.reviewReasons.isNotEmpty) c.id: c.reviewReasons,
              },
              onSave: (list, durationMs) async {
                final changed = await chapters.replaceActive(
                  track,
                  list,
                  durationMs: durationMs,
                  keepUndo: savedOnce,
                );
                savedOnce = savedOnce || changed;
                if (changed) {
                  try {
                    await player.trackChaptersChanged(track);
                  } catch (_) {}
                }
                return changed;
              },
            ),
      ),
    );
    if (saved == true) {
      _showMessage('Chapters saved. Undo last chapter change takes it back.');
    }
  }

  Future<void> _rename(Track track, MediaChapter chapter) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: chapter.title),
    );
    final trimmed = title?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == chapter.title || !mounted) return;
    await _run(() async {
      await _chapters.rename(track, chapter.id, trimmed);
      await _afterEdit(track);
    });
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
    final before = ChapterData.decode(track.chaptersJson);
    await _run(() async {
      await _chapters.refresh(track);
      await _afterEdit(track);
      final fresh = await ref.read(databaseProvider).getTrack(track.id);
      final after = ChapterData.decode(fresh?.chaptersJson);
      _showMessage(fetchedChaptersMessage(before, after));
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

  Future<void> _setShuffle(Track track, _ShuffleChapters mode) async {
    await _chapters.setShuffleChapters(track, switch (mode) {
      _ShuffleChapters.playlistDefault => null,
      _ShuffleChapters.shuffle => true,
      _ShuffleChapters.noShuffle => false,
    });
    await _afterEdit(track);
  }

  Future<void> _queue(
    Track track,
    MediaChapter chapter, {
    required bool next,
  }) async {
    final player = _player;
    final added =
        next
            ? await player.playNext(track, chapterId: chapter.id)
            : await player.addToUpNextQueue(track, chapterId: chapter.id);
    if (added) await player.startUpNextQueueIfIdle();
    _showMessage(
      !added
          ? 'This chapter cannot be queued'
          : next
          ? 'Plays next: "${chapter.title}"'
          : 'Added to queue: "${chapter.title}"',
    );
  }

  Future<void> _setSkip(Track track, MediaChapter chapter, bool skip) async {
    await _chapters.setChapterSkip(track, chapter.id, skip);
    await _afterEdit(track);
  }

  Future<void> _share(Track track, MediaChapter chapter) async {
    try {
      await shareYouTubeChapter(track, chapter);
    } catch (e) {
      _showMessage('Could not share: $e');
    }
  }

  /// The per-chapter options, laid out like the track options sheet.
  void _showChapterActions(
    Track track,
    MediaChapter chapter, {
    required bool playable,
    String? lyricsMode,
  }) {
    bool? skipOverride;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder:
          (sheetContext) => StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              final data = ChapterData.decode(track.chaptersJson);
              final skipped = skipOverride ?? data.isSkipped(chapter.id);
              void close() => Navigator.pop(sheetContext);
              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
                ),
                child: _ChapterActionsSheet(
                  chapter: chapter,
                  fileMs:
                      ChapterService.knownDurationMs(track) ??
                      data.active.lastOrNull?.endMs,
                  skipped: skipped,
                  playable: playable,
                  onPlay: () {
                    close();
                    _run(() => _playChapter(track, chapter));
                  },
                  onPlayNext: () {
                    close();
                    _run(() => _queue(track, chapter, next: true));
                  },
                  onAddToQueue: () {
                    close();
                    _run(() => _queue(track, chapter, next: false));
                  },
                  onSkipChanged: (value) async {
                    setSheetState(() => skipOverride = value);
                    try {
                      await _setSkip(track, chapter, value);
                    } catch (e) {
                      if (sheetContext.mounted) {
                        setSheetState(() => skipOverride = !value);
                      }
                      _showMessage('Could not save: $e');
                    }
                  },
                  onAdjust: () {
                    close();
                    _openEditor(track, focusChapterId: chapter.id);
                  },
                  onRename: () {
                    close();
                    _rename(track, chapter);
                  },
                  onRecognize:
                      playable
                          ? () {
                            close();
                            unawaited(_recognizeChapter(track, chapter));
                          }
                          : null,
                  onEditTimes: () {
                    close();
                    _editTimes(track, chapter);
                  },
                  onDelete: () {
                    close();
                    _run(() => _delete(track, chapter));
                  },
                  onShare:
                      hasYouTubeTimeline(track)
                          ? () {
                            close();
                            unawaited(_share(track, chapter));
                          }
                          : null,
                  lyricsTitle: lyricsMenuTitle(lyricsMode),
                  lyricsSubtitle: lyricsMenuSubtitle(lyricsMode),
                  onLyrics: () {
                    close();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder:
                            (_) =>
                                LyricsPage(track: track, chapterId: chapter.id),
                      ),
                    );
                  },
                ),
              );
            },
          ),
    );
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
                'too. Default follows the playlist\'s "Shuffle chapters" '
                'setting; Shuffle and Don\'t shuffle decide for this video '
                'alone.\n\n'
                'Edit chapters opens the editor: pick a boundary, listen on '
                'both sides of it and drag the waveform or nudge it until it '
                'sits exactly where the song changes. Split here adds a '
                'boundary where the file is playing.\n\n'
                'Each chapter\'s menu can play it next, add it to the queue '
                'or mark it Always skip, so autoplay and shuffle pass over '
                'it.\n\n'
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
              '"${track.displayTitle}".',
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
            _showMessage(
              error is RecognitionRateLimited
                  ? error.toString()
                  : 'Recognition failed: $error',
            );
          }),
    );
  }

  Future<void> _openReview(Track track, RecognitionRun run) async {
    final applied = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => RecognitionReviewPage(track: track, run: run),
      ),
    );
    if (applied == null || !mounted) return;
    await _afterEdit(track);
    _showMessage(
      'The file now has $applied chapter${applied == 1 ? '' : 's'}. '
      'Undo last chapter change brings back the ones from before.',
    );
  }

  /// Recognize from the ⋮ menu, for a file that already has chapters: the
  /// scan runs only after the user agreed that applying its results
  /// replaces their chapters, and even then nothing changes until Apply.
  Future<void> _confirmRecognize(Track track, ChapterData data) async {
    final count = data.active.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Replace your chapters?'),
            content: Text(
              'Recognition proposes a new set of chapters for this file. '
              'Applying it replaces the current '
              '${count == 1 ? 'chapter' : '$count chapters'}.\n\n'
              'The scan runs now, but your chapters stay exactly as they are '
              'until you review the new set and press Apply.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('confirm-recognize'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Recognize'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() => _recognizeSongs(track));
  }

  /// Looks up the song in one chapter and, when the user picks a match,
  /// renames the chapter (one undoable step; its times never change).
  Future<void> _recognizeChapter(Track track, MediaChapter chapter) async {
    if (ref.read(downloadServiceProvider).isDownloading) {
      _showMessage('Wait for the running download to finish first.');
      return;
    }
    if (ref.read(songRecognitionServiceProvider).isScanning) {
      _showMessage('Wait for the running scan to finish first.');
      return;
    }
    if (!await confirmManualDownload(
          context,
          ref.read(downloadNetworkPolicyProvider),
        ) ||
        !mounted) {
      return;
    }
    final title = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder:
          (sheetContext) => ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
            ),
            child: RecognizeChapterSheet(track: track, chapter: chapter),
          ),
    );
    if (title == null || title.trim().isEmpty || !mounted) return;
    await _run(() async {
      await _chapters.rename(track, chapter.id, title);
      await _afterEdit(track);
      _showMessage(
        'Renamed to "$title". Undo last chapter change takes it back.',
      );
    });
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
    return StreamBuilder<Track?>(
      stream: _trackRow,
      builder: (context, trackSnapshot) {
        final track = trackSnapshot.data ?? widget.track;
        return StreamBuilder<Playlist?>(
          stream: _playlistRow,
          builder: (context, playlistSnapshot) {
            final playlistChapters =
                playlistSnapshot.data?.playChapters ?? true;
            return _buildPage(
              context,
              track,
              playlistChapters,
              playlistSnapshot.data?.shuffleChapters ?? false,
              playlistSnapshot.data?.lyricsMode,
            );
          },
        );
      },
    );
  }

  Widget _buildPage(
    BuildContext context,
    Track track,
    bool playlistChapters,
    bool playlistShuffle,
    String? lyricsMode,
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
    final shuffleMode = switch (data.shuffleChapters) {
      null => _ShuffleChapters.playlistDefault,
      true => _ShuffleChapters.shuffle,
      false => _ShuffleChapters.noShuffle,
    };
    final durationMs = ChapterService.knownDurationMs(track);
    // Sets the clock format of the times listed (h:mm:ss for an hour or
    // more), so they all read alike.
    final fileMs = durationMs ?? data.active.lastOrNull?.endMs;

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
      body: ValueListenableBuilder<double>(
        valueListenable: audioPlayerOverlayHeightNotifier,
        builder:
            (context, overlay, _) => ListView(
              padding: EdgeInsets.only(bottom: 24 + overlay),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    track.displayTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          key: const ValueKey('chapters-summary'),
                          [
                            if (durationMs != null)
                              chapterTimestamp(durationMs, fileMs: fileMs),
                            _glued(
                              data.active.isEmpty
                                  ? 'No chapters'
                                  : data.active.length == 1
                                  ? '1 chapter'
                                  : '${data.active.length} chapters',
                            ),
                          ].join(_separator),
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
                        'fit. Tap Create chapters to make new ones.',
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
                if (data.active.isNotEmpty) ...[
                  const SettingsSectionHeader('Shuffle chapters'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<_ShuffleChapters>(
                        key: const ValueKey('chapters-shuffle'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: _ShuffleChapters.playlistDefault,
                            label: Text('Default'),
                          ),
                          ButtonSegment(
                            value: _ShuffleChapters.shuffle,
                            label: Text('Shuffle'),
                          ),
                          ButtonSegment(
                            value: _ShuffleChapters.noShuffle,
                            label: Text('Don\'t shuffle'),
                          ),
                        ],
                        selected: {shuffleMode},
                        // A file that plays whole has no chapters to mix.
                        onSelectionChanged:
                            _busy || !chaptersOn
                                ? null
                                : (selection) => _run(
                                  () => _setShuffle(track, selection.first),
                                ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                    child: Text(
                      chaptersOn
                          ? 'Applies when shuffle is on. Default follows the '
                              'playlist setting "Shuffle chapters", which is '
                              '${playlistShuffle ? 'on' : 'off'}.'
                          : 'This video plays as one whole file, so its '
                              'chapters can\'t be shuffled.',
                      style: const TextStyle(
                        color: Color(0xFF999999),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
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
                        Flexible(
                          child: _SourceChip(custom: data.custom != null),
                        ),
                      const Spacer(),
                      if (canFetch || data.active.isNotEmpty)
                        PopupMenuButton<String>(
                          key: const ValueKey('chapters-more'),
                          tooltip: 'More',
                          enabled: !_busy,
                          onSelected: (value) {
                            switch (value) {
                              case 'fetch':
                                _fetchFromYouTube(track);
                              case 'revert':
                                _revertToYouTube(track, data);
                              case 'recognize':
                                _confirmRecognize(track, data);
                            }
                          },
                          itemBuilder:
                              (_) => [
                                if (canFetch)
                                  const PopupMenuItem(
                                    value: 'fetch',
                                    child: Text('Fetch from YouTube'),
                                  ),
                                if (canFetch && canRevert)
                                  const PopupMenuItem(
                                    value: 'revert',
                                    child: Text('Use YouTube chapters again'),
                                  ),
                                // A file with chapters keeps its scan here,
                                // a deliberate step away from the list.
                                if (data.active.isNotEmpty)
                                  PopupMenuItem(
                                    key: const ValueKey('chapters-recognize'),
                                    value: 'recognize',
                                    enabled:
                                        playable &&
                                        !ref
                                            .read(
                                              songRecognitionServiceProvider,
                                            )
                                            .isScanning,
                                    child: Text(
                                      _recognitionRun == null
                                          ? 'Recognize songs…'
                                          : 'Recognize again…',
                                    ),
                                  ),
                              ],
                        )
                      else
                        const SizedBox(height: 48),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('chapters-edit'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed:
                          _busy || !playable ? null : () => _openEditor(track),
                      icon: Icon(data.active.isEmpty ? Icons.add : Icons.tune),
                      label: Text(
                        data.active.isEmpty
                            ? 'Create chapters'
                            : 'Edit chapters',
                      ),
                    ),
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
                          ? 'No chapters yet. Fetch them from YouTube, or tap '
                              'Create chapters to make your own while '
                              'listening.'
                          : 'No chapters yet. Tap Create chapters to make '
                              'your own while listening.',
                      style: const TextStyle(color: Color(0xFF999999)),
                    ),
                  ),
                Opacity(
                  opacity: chaptersOn ? 1 : 0.6,
                  // Only the list follows playback, and only when the
                  // playing chapter (or play/pause) changes.
                  child: Consumer(
                    builder: (context, ref, _) {
                      final current = _watchCurrentChapterIndex(
                        ref,
                        track.id,
                        data.active,
                      );
                      final isPlaying =
                          current != null &&
                          ref.watch(
                            isPlayingProvider.select(
                              (playing) => playing.valueOrNull ?? false,
                            ),
                          );
                      return Column(
                        children: [
                          for (final (i, chapter) in data.active.indexed)
                            _ChapterRow(
                              key: ValueKey('chapter-${chapter.id}'),
                              number: i + 1,
                              chapter: chapter,
                              fileMs: fileMs,
                              skipped: data.isSkipped(chapter.id),
                              playable: playable,
                              enabled: !_busy,
                              isCurrent: i == current,
                              isPlaying: i == current && isPlaying,
                              onTap:
                                  () =>
                                      _run(() => _playChapter(track, chapter)),
                              onMore:
                                  () => _showChapterActions(
                                    track,
                                    chapter,
                                    playable: playable,
                                    lyricsMode: lyricsMode,
                                  ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                // Below the list, so the page reads as before for files that
                // are never scanned.
                _RecognitionSection(
                  track: track,
                  data: data,
                  run: _recognitionRun,
                  enabled: !_busy && playable,
                  // With chapters, Recognize is in the ⋮ menu above.
                  showRecognizeButton: data.active.isEmpty,
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

/// What a "Fetch from YouTube" did, given the chapter info [before] and
/// [after] it: whether YouTube's chapters are now shown, and that the
/// user's own list (when there is one) is untouched and still in use.
@visibleForTesting
String fetchedChaptersMessage(ChapterData before, ChapterData after) {
  final found = after.downloaded.length;
  final foundText =
      found == 0
          ? 'This video has no chapters on YouTube.'
          : 'Found $found chapter${found == 1 ? '' : 's'} on YouTube.';
  if (after.custom != null) {
    return '$foundText Your own chapters are unchanged and still used'
        '${found == 0 ? '' : '; ⋮ > Use YouTube chapters again switches to '
                'YouTube\'s'}.';
  }
  if (before.valid &&
      before.active.isNotEmpty &&
      !ChapterService.sameChapters(before.active, after.active)) {
    final undo = after.undoChapters;
    // A fetch keeps an Undo step that held a list of its own (such as the
    // chapters "Use YouTube chapters again" set aside).
    if (undo != null && !ChapterService.sameChapters(undo, before.active)) {
      return '$foundText The list below was updated. Undo last chapter '
          'change still brings back your earlier chapters.';
    }
    return '$foundText The list below was updated. Undo last chapter change '
        'brings back the previous one.';
  }
  return found == 0 ? foundText : '$foundText They are shown below.';
}

/// The playing chapter's colour, as in the playlist's track list.
const _accent = Color(0xFF2196F3);

/// The index in [chapters] of the chapter playing now, or null when
/// [trackId] is not the file playing (or it plays in a gap). A chapter
/// played as its own track is found by id; while the whole file plays (or
/// that chapter was since edited away) it is the one at the position. Both
/// are watched through selects, so a position tick inside the same chapter
/// rebuilds nothing.
int? _watchCurrentChapterIndex(
  WidgetRef ref,
  int trackId,
  List<MediaChapter> chapters,
) {
  final item = ref.watch(
    currentPlaybackItemProvider.select((value) {
      final item = value.valueOrNull;
      return item == null || item.track.id != trackId
          ? null
          : (chapterId: item.chapter?.id, startMs: item.startMs);
    }),
  );
  if (item == null) return null;
  final chapterId = item.chapterId;
  if (chapterId != null) {
    final index = chapters.indexWhere((c) => c.id == chapterId);
    if (index >= 0) return index;
  }
  return ref.watch(
    positionProvider.select((value) {
      // The position is on the item's own timeline.
      final ms = item.startMs + (value.valueOrNull?.inMilliseconds ?? 0);
      final index = chapters.indexWhere((c) => ms >= c.startMs && ms < c.endMs);
      return index < 0 ? null : index;
    }),
  );
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
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
      ),
    );
  }
}

/// "Retrying in m:ss…" for a scan that waits before its next lookup,
/// ticking down once a second.
class _RetryCountdown extends StatefulWidget {
  const _RetryCountdown({required this.progress});

  final RecognitionProgress progress;

  @override
  State<_RetryCountdown> createState() => _RetryCountdownState();
}

class _RetryCountdownState extends State<_RetryCountdown> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resumeAt = widget.progress.resumeAt;
    var remaining =
        resumeAt == null ? Duration.zero : resumeAt.difference(DateTime.now());
    if (remaining.isNegative) remaining = Duration.zero;
    // Rounded up, so the countdown reaches 0:00 only when the retry is due.
    final seconds = (remaining.inMilliseconds + 999) ~/ 1000;
    final time =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final reason = switch (widget.progress.waitReason) {
      RecognitionWaitReason.network => 'Connection problem.',
      _ => 'Shazam asked us to slow down.',
    };
    return Text(
      '$reason Retrying in $time… '
      '(${widget.progress.completed} of ${widget.progress.total} done)',
      key: const ValueKey('recognition-waiting'),
      style: const TextStyle(color: Color(0xFF999999), fontSize: 12),
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
    required this.showRecognizeButton,
    required this.onRecognize,
    required this.onReview,
    required this.onRemoveAutomatic,
  });

  final Track track;
  final ChapterData data;

  /// Shows Recognize songs here (a file without chapters). Otherwise it is
  /// in the chapters' ⋮ menu, and this section only shows while there is a
  /// scan, a result or a failure to show.
  final bool showRecognizeButton;

  /// The last completed scan of this file, if any.
  final RecognitionRun? run;

  /// False while the page is busy or the file cannot be played.
  final bool enabled;
  final VoidCallback onRecognize;
  final void Function(RecognitionRun run) onReview;
  final VoidCallback onRemoveAutomatic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress =
        ref.watch(recognitionProgressProvider).valueOrNull ??
        ref.read(songRecognitionServiceProvider).currentProgress;
    // The running scan of this file, if any.
    final scan =
        progress != null && progress.running && progress.trackId == track.id
            ? progress
            : null;
    // Why the last scan of this file stopped, until the next one starts. A
    // scan runs unattended, so the message must outlast its snack bar.
    final failure =
        progress != null &&
                progress.phase == RecognitionPhase.failed &&
                progress.trackId == track.id
            ? progress.message
            : null;
    final scanningOther = progress?.running == true && scan == null;
    final run = this.run;
    // A run applies once per recognition epoch, which an undo, a reset or a
    // replaced file moves on. Recognize again rebuilds a fresh run from the
    // saved lookups, so only an appliable run is offered for review.
    final applied = run != null && data.lastRecognitionRunId == run.runId;
    final stale = run != null && data.recognitionEpoch != run.epoch;
    // Applying keeps each proposal's id as the prefix of the chapters made
    // from it, so this tells whether any of the run's chapters are listed.
    // A proposal applied over an identical chapter (same start and title)
    // keeps that chapter's id, so that counts too.
    final runShown =
        run != null &&
        data.active.any(
          (c) => run.proposals.any(
            (p) =>
                c.id.startsWith('${p.id}-') ||
                (c.startMs == p.startMs && c.title == p.title),
          ),
        );
    // A run an older decoder measured in the wrong place is never offered
    // for review, applied or not; chapters already applied from it stay.
    final runHint =
        run == null || scan != null
            ? null
            : run.decoderOutdated
            ? runShown
                ? 'The automatic chapters from the last scan were made with '
                    'an older, less accurate scan of MP3 files, so their '
                    'timings can be off by several seconds. Recognize again '
                    'for exact timings.'
                : RecognitionRun.decoderOutdatedMessage
            : stale
            ? applied && !runShown
                ? 'These results were taken back. Recognize again rebuilds '
                    'them from saved lookups.'
                : 'The chapters were undone or reset since this scan. '
                    'Recognize again rebuilds its proposals from saved '
                    'lookups.'
            : applied
            ? runShown
                ? 'The results of the last scan are applied.'
                : 'The results of the last scan were applied, then removed. '
                    'Recognize again rebuilds them from saved lookups.'
            : null;
    final hasAutomatic = data.active.any(
      (c) => c.origin == ChapterOrigin.auto && !c.manuallyEdited,
    );
    if (!showRecognizeButton &&
        scan == null &&
        failure == null &&
        run == null &&
        !hasAutomatic &&
        !scanningOther) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const ValueKey('recognition-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSectionHeader('Song recognition'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            showRecognizeButton
                ? 'Identifies the songs in a long mix by fingerprinting short '
                    'samples and proposes chapters for you to review. Only '
                    'fingerprints are sent, never audio.'
                : 'To scan this file again, use ⋮ next to Chapters. Your '
                    'chapters stay until you apply a new set.',
            style: const TextStyle(color: Color(0xFF999999), fontSize: 13),
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
                      scan.total > 0 &&
                              (scan.phase == RecognitionPhase.sampling ||
                                  scan.phase == RecognitionPhase.waiting)
                          ? scan.completed / scan.total
                          : null,
                ),
                const SizedBox(height: 4),
                if (scan.phase == RecognitionPhase.waiting)
                  _RetryCountdown(progress: scan)
                else
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
        if (failure != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              failure == RecognitionRateLimited.message
                  ? failure
                  : 'The last scan failed: $failure',
              key: const ValueKey('recognition-failed'),
              style: const TextStyle(color: Color(0xFFE57373), fontSize: 12),
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
              else if (showRecognizeButton)
                TextButton.icon(
                  key: const ValueKey('recognize-songs'),
                  onPressed: enabled && !scanningOther ? onRecognize : null,
                  icon: const Icon(Icons.graphic_eq),
                  label: Text(
                    run == null ? 'Recognize songs' : 'Recognize again',
                  ),
                ),
              if (run != null && scan == null && runHint == null)
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
        if (runHint != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              runHint,
              key: const ValueKey('recognition-run-hint'),
              style: const TextStyle(color: Color(0xFF999999), fontSize: 12),
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
    required this.fileMs,
    required this.skipped,
    required this.playable,
    required this.enabled,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
    required this.onMore,
  });

  final int number;
  final MediaChapter chapter;

  /// The file's length, for the clock format ([chapterClock]).
  final int? fileMs;

  /// Marked Always skip: autoplay passes over it.
  final bool skipped;
  final bool playable;
  final bool enabled;

  /// The chapter the player is on (playing or paused), marked like the
  /// current track of a playlist.
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback onMore;

  String _time(int ms) => chapterTimestamp(ms, fileMs: fileMs);

  @override
  Widget build(BuildContext context) {
    // Recognised chapters say so, and the first open question about them
    // (a doubtful name or timing) shows on a line of its own.
    final origin = switch (chapter.origin) {
      ChapterOrigin.auto when chapter.manuallyEdited =>
        '$_separator${_glued('Auto, edited')}',
      ChapterOrigin.auto => '${_separator}Auto',
      _ => '',
    };
    final times = _timeRange(_time(chapter.startMs), _time(chapter.endMs));
    final review = chapter.reviewReasons.firstOrNull;
    final weight = isCurrent ? FontWeight.w600 : FontWeight.normal;
    // A stand-in name stays red even while it plays, so it is never missed.
    final titleColor =
        isPlaceholderChapterTitle(chapter.title)
            ? Theme.of(context).colorScheme.error
            : isCurrent
            ? _accent
            : null;
    return ListTile(
      tileColor: isCurrent ? const Color(0xFF2A2A2A) : null,
      leading: SizedBox(
        width: 28,
        child: Text(
          '$number',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isCurrent ? _accent : const Color(0xFF999999),
            fontWeight: weight,
          ),
        ),
      ),
      title: Text(
        chapter.title,
        key: ValueKey('chapter-title-${chapter.id}'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: titleColor, fontWeight: weight),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text.rich(
                  key: ValueKey('chapter-times-${chapter.id}'),
                  TextSpan(
                    children: [
                      if (skipped)
                        TextSpan(
                          text: _glued('Always skip'),
                          style: const TextStyle(color: Color(0xFFE57373)),
                        ),
                      TextSpan(
                        text: '${skipped ? _separator : ''}$times$origin',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Right-aligned, so the lengths line up in a column.
              Text(
                _time(chapter.duration.inMilliseconds),
                key: ValueKey('chapter-length-${chapter.id}'),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (review != null) Text(review),
        ],
      ),
      isThreeLine: review != null,
      enabled: enabled && playable,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            child:
                isPlaying
                    ? Icon(
                      Icons.graphic_eq,
                      key: ValueKey('chapter-playing-${chapter.id}'),
                      color: _accent,
                      size: 20,
                    )
                    : null,
          ),
          IconButton(
            tooltip: 'Chapter options',
            onPressed: enabled ? onMore : null,
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
    );
  }
}

/// " · " between the parts of a grey line. The dot is kept with the part
/// after it (a no-break space), so a line that wraps never ends with a
/// dangling "·"; the next line starts with it instead.
const _separator = ' \u00B7\u00A0';

/// [text] with no-break spaces, so it stays on one line: "Always skip".
String _glued(String text) => text.replaceAll(' ', '\u00A0');

/// "1:02:33 – 1:05:00". When it wraps, the dash goes to the next line with
/// the end time (the word joiner and no-break space keep them together),
/// so no line ends with a dangling "–".
String _timeRange(String start, String end) => '$start \u2013\u2060\u00A0$end';

const _sheetTitleStyle = TextStyle(color: Colors.white);
const _sheetSubtitleStyle = TextStyle(color: Color(0xFF888888));

/// Play, queue, Always skip and editing for one chapter.
class _ChapterActionsSheet extends StatelessWidget {
  const _ChapterActionsSheet({
    required this.chapter,
    required this.fileMs,
    required this.skipped,
    required this.playable,
    required this.onPlay,
    required this.onPlayNext,
    required this.onAddToQueue,
    required this.onSkipChanged,
    required this.onAdjust,
    required this.onRename,
    required this.onRecognize,
    required this.onEditTimes,
    required this.onDelete,
    required this.onShare,
    required this.lyricsTitle,
    required this.lyricsSubtitle,
    required this.onLyrics,
  });

  final MediaChapter chapter;

  /// The file's length, for the clock format ([chapterClock]).
  final int? fileMs;
  final bool skipped;
  final bool playable;
  final VoidCallback onPlay;
  final VoidCallback onPlayNext;
  final VoidCallback onAddToQueue;
  final ValueChanged<bool> onSkipChanged;
  final VoidCallback onAdjust;
  final VoidCallback onRename;

  /// Null when the file cannot be played (so not decoded either).
  final VoidCallback? onRecognize;
  final VoidCallback onEditTimes;
  final VoidCallback onDelete;

  /// Null when the chapter has no YouTube moment to link to.
  final VoidCallback? onShare;
  final String lyricsTitle;
  final String lyricsSubtitle;
  final VoidCallback onLyrics;

  String _time(int ms) => chapterTimestamp(ms, fileMs: fileMs);

  @override
  Widget build(BuildContext context) {
    Widget tile({
      required Key key,
      required IconData icon,
      required String title,
      String? subtitle,
      Color iconColor = Colors.white70,
      VoidCallback? onTap,
    }) {
      return ListTile(
        key: key,
        leading: Icon(
          icon,
          color: onTap == null ? const Color(0xFF666666) : iconColor,
        ),
        title: Text(title, style: _sheetTitleStyle),
        subtitle:
            subtitle == null
                ? null
                : Text(subtitle, style: _sheetSubtitleStyle),
        enabled: onTap != null,
        onTap: onTap,
      );
    }

    const queueColor = Color(0xFF64B5F6);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              const Icon(Icons.bookmark_outline, color: Colors.white70),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chapter.title,
                      key: const ValueKey('chapter-actions-title'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_time(chapter.startMs)} – '
                      '${_time(chapter.endMs)} · '
                      '${_time(chapter.duration.inMilliseconds)}',
                      style: _sheetSubtitleStyle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF3A3A3A)),
        Flexible(
          child: ListView(
            key: const ValueKey('chapter-actions-list'),
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              tile(
                key: const ValueKey('chapter-actions-play'),
                icon: Icons.play_arrow,
                title: 'Play',
                subtitle:
                    skipped
                        ? 'Plays it even though it is skipped'
                        : 'Plays from this chapter on',
                onTap: playable ? onPlay : null,
              ),
              tile(
                key: const ValueKey('chapter-actions-play-next'),
                icon: Icons.playlist_play,
                iconColor: queueColor,
                title: 'Play next',
                subtitle:
                    skipped
                        ? 'Turn off Always skip to queue it'
                        : 'Plays right after the current song',
                onTap: playable && !skipped ? onPlayNext : null,
              ),
              tile(
                key: const ValueKey('chapter-actions-add-to-queue'),
                icon: Icons.queue_music,
                iconColor: queueColor,
                title: 'Add to queue',
                subtitle:
                    skipped
                        ? 'Turn off Always skip to queue it'
                        : 'Plays after everything in Up next',
                onTap: playable && !skipped ? onAddToQueue : null,
              ),
              SwitchListTile(
                key: const ValueKey('chapter-actions-always-skip'),
                secondary: Icon(
                  Icons.skip_next,
                  color: skipped ? const Color(0xFFE57373) : Colors.white70,
                ),
                title: const Text('Always skip', style: _sheetTitleStyle),
                subtitle: const Text(
                  'Autoplay and shuffle pass over it; tap it to play it '
                  'anyway',
                  style: _sheetSubtitleStyle,
                ),
                value: skipped,
                onChanged: onSkipChanged,
              ),
              tile(
                key: const ValueKey('chapter-actions-lyrics'),
                icon: Icons.lyrics_outlined,
                title: lyricsTitle,
                subtitle: lyricsSubtitle,
                onTap: onLyrics,
              ),
              if (onShare != null)
                tile(
                  key: const ValueKey('chapter-actions-share'),
                  icon: Icons.share,
                  title: 'Share link',
                  // The link is in whole seconds.
                  subtitle:
                      'Opens YouTube at '
                      '${chapterTimestamp(chapter.startMs ~/ 1000 * 1000)}',
                  onTap: onShare,
                ),
              const Divider(height: 1, color: Color(0xFF3A3A3A)),
              tile(
                key: const ValueKey('chapter-actions-adjust'),
                icon: Icons.tune,
                title: 'Adjust boundaries…',
                subtitle: 'Move its start and end while listening',
                onTap: playable ? onAdjust : null,
              ),
              tile(
                key: const ValueKey('chapter-actions-recognize'),
                icon: Icons.graphic_eq,
                title: 'Recognize song…',
                subtitle:
                    'Finds the song in this chapter only; its start and end '
                    'stay',
                onTap: onRecognize,
              ),
              tile(
                key: const ValueKey('chapter-actions-rename'),
                icon: Icons.edit,
                title: 'Rename…',
                onTap: onRename,
              ),
              tile(
                key: const ValueKey('chapter-actions-edit-times'),
                icon: Icons.schedule,
                title: 'Edit times…',
                subtitle: 'Type the exact start and end',
                onTap: onEditTimes,
              ),
              tile(
                key: const ValueKey('chapter-actions-delete'),
                icon: Icons.delete_outline,
                iconColor: const Color(0xFFE57373),
                title: 'Delete',
                subtitle: 'Leaves a gap; Undo brings it back',
                onTap: onDelete,
              ),
            ],
          ),
        ),
      ],
    );
  }
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
      key: const ValueKey('chapter-rename'),
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
    text: chapterTimestamp(
      widget.chapter?.startMs ?? widget.startMs ?? 0,
      fileMs: widget.durationMs,
    ),
  );
  late final _end = TextEditingController(
    text: chapterTimestamp(
      widget.chapter?.endMs ?? widget.endMs ?? widget.durationMs ?? 0,
      fileMs: widget.durationMs,
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
      validateChapters(entries);
      // Only the end typed here is checked against the length. The other
      // chapters were accepted before; one that ends a little past a later,
      // rounder length estimate must not block editing this one.
      final durationMs = widget.durationMs;
      if (durationMs != null &&
          durationMs > 0 &&
          chapter.endMs > durationMs &&
          chapter.endMs != widget.chapter?.endMs) {
        throw const FormatException(
          'Chapters must stay within the media duration.',
        );
      }
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
              helperMaxLines: 2,
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
