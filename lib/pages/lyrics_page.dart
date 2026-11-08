import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/chapters.dart';
import '../services/lyrics/lyrics_models.dart';
import '../services/lyrics/lyrics_service.dart' show LyricsService;
import '../widgets/lyrics_picker_sheet.dart';
import '../widgets/lyrics_timing_sheet.dart';
import '../widgets/mobile_data_download_guard.dart';

const _accent = Color(0xFF2196F3);
const _muted = Color(0xFF999999);

/// One part of a file that has its own lyrics: the whole file, or a
/// chapter of a mix.
class _Unit {
  const _Unit({this.chapter});

  final MediaChapter? chapter;
  String? get chapterId => chapter?.id;
  String get key => chapter?.id ?? 'whole';
}

/// A track's lyrics or transcript: what was found, where from, the lines
/// (tap a timed one to play from there), and ways to correct it.
class LyricsPage extends ConsumerStatefulWidget {
  const LyricsPage({super.key, required this.track, this.chapterId});

  final Track track;

  /// The chapter to show first; null = the whole file or the first chapter.
  final String? chapterId;

  @override
  ConsumerState<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends ConsumerState<LyricsPage> {
  late final Stream<Track?> _trackRow;
  late final Stream<Playlist?> _playlistRow;
  late final Stream<List<LyricsDoc>> _docs;

  /// The unit the owner chose in the selector (its [_Unit.key]).
  String? _selectedKey;
  bool _busy = false;

  /// The lines of the doc shown, reloaded when the doc row changes.
  LyricsDoc? _linesDoc;
  Future<List<LyricsLine>>? _lines;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseProvider);
    _trackRow =
        (db.select(db.tracks)
          ..where((t) => t.id.equals(widget.track.id))).watchSingleOrNull();
    _playlistRow =
        (db.select(db.playlists)..where(
          (p) => p.id.equals(widget.track.playlistId),
        )).watchSingleOrNull();
    _docs = db.watchLyricsDocsForTrack(widget.track.id);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _showMessage(
        error is StateError
            ? error.message
            : error is FormatException
            ? error.message
            : 'Something went wrong: $error',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _networkOk() =>
      confirmManualDownload(context, ref.read(downloadNetworkPolicyProvider));

  Future<void> _fetchNow(Track track) async {
    if (_busy || !await _networkOk() || !mounted) return;
    await _run(() => ref.read(lyricsServiceProvider).fetchTrack(track));
  }

  Future<void> _refetch(Track track, _Unit unit) async {
    if (_busy || !await _networkOk() || !mounted) return;
    await _run(
      () => ref.read(lyricsServiceProvider).refetch(track.id, unit.chapterId),
    );
  }

  Future<void> _markNone(Track track, _Unit unit) => _run(() async {
    await ref
        .read(lyricsServiceProvider)
        .applyPick(track.id, unit.chapterId, const LyricsPick.none());
    _showMessage('Saved: no lyrics here. Updates leave it alone.');
  });

  Future<void> _pick(Track track, _Unit unit, LyricsMode mode) async {
    if (_busy) return;
    final saved = await showLyricsPicker(
      context,
      trackId: track.id,
      chapterId: unit.chapterId,
      mode: mode,
      fallbackQuery: unit.chapter?.title ?? track.title,
    );
    if (saved) {
      _showMessage(
        mode == LyricsMode.transcript ? 'Transcript saved' : 'Lyrics saved',
      );
    }
  }

  Future<void> _fixTiming(
    Track track,
    Playlist? playlist,
    _Unit unit,
    String? Function(int fileMs) chapterAt,
  ) async {
    if (_busy) return;
    await showLyricsTimingSheet(
      context,
      track: track,
      chapterId: unit.chapterId,
      playFrom:
          (fileMs) => _playAt(
            track,
            playlist,
            fileMs,
            unit.chapterId ?? chapterAt(fileMs),
          ),
    );
  }

  /// Plays [track] from [fileMs] (file time). Keeps the queue when this
  /// file is the one playing; otherwise starts its playlist there.
  Future<void> _playAt(
    Track track,
    Playlist? playlist,
    int fileMs,
    String? chapterId,
  ) async {
    final player = ref.read(playbackServiceProvider);
    var current = player.currentItem;
    var moved = false;
    if (current != null && current.track.id == track.id) {
      if (current.chapter == null) {
        moved = true;
      } else if (chapterId != null &&
          (current.chapter!.id == chapterId ||
              await player.playChapterOfCurrentFile(track.id, chapterId))) {
        moved = true;
      }
    }
    if (!moved) {
      final tracks = await ref
          .read(databaseProvider)
          .getTracksForPlaylist(track.playlistId);
      await player.playTrack(
        track,
        tracks,
        playlist: playlist,
        chapterId: chapterId,
        whole: chapterId == null,
        startAt: Duration(milliseconds: fileMs),
      );
      return;
    }
    current = player.currentItem;
    if (current == null || current.track.id != track.id) return;
    final start = current.chapter?.startMs ?? 0;
    await player.seekTo(Duration(milliseconds: max(0, fileMs - start)));
    if (!player.isPlaying) await player.resume();
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
            return StreamBuilder<List<LyricsDoc>>(
              stream: _docs,
              builder: (context, docsSnapshot) {
                return _buildPage(
                  context,
                  track,
                  playlistSnapshot.data,
                  docsSnapshot.data,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildPage(
    BuildContext context,
    Track track,
    Playlist? playlist,
    List<LyricsDoc>? docs,
  ) {
    final mode = LyricsMode.fromDb(playlist?.lyricsMode);
    final chapters = ChapterData.decode(track.chaptersJson).active;
    final playsAsChapters =
        chapters.isNotEmpty &&
        (track.chaptersEnabled ?? playlist?.playChapters ?? true);
    final byKey = {
      for (final doc in docs ?? <LyricsDoc>[]) doc.chapterId ?? 'whole': doc,
    };

    // Chapters have their own lyrics only in lyrics mode, and only when the
    // file plays as chapters; a transcript always covers the whole file.
    final units = <_Unit>[
      if (mode != LyricsMode.lyrics ||
          !playsAsChapters ||
          byKey.containsKey('whole'))
        const _Unit(),
      if (mode == LyricsMode.lyrics && playsAsChapters)
        for (final chapter in chapters) _Unit(chapter: chapter),
    ];
    final wanted = _selectedKey ?? widget.chapterId ?? 'whole';
    final unit =
        units.where((u) => u.key == wanted).firstOrNull ??
        (widget.chapterId == null
            ? units.first
            : units.where((u) => u.key == widget.chapterId).firstOrNull ??
                units.first);
    final doc = byKey[unit.key];
    final playable = track.status == 'complete' && track.filePath != null;
    final blocked =
        mode == null ? null : LyricsService.fetchBlockedReason(track, mode);
    final transcript =
        mode == LyricsMode.transcript ||
        (mode == null && doc?.kind == LyricsMode.transcript.dbValue);

    return Scaffold(
      appBar: AppBar(
        title: Text(transcript ? 'Transcript' : 'Lyrics'),
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
          final header = <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                track.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (mode == null)
              const _Notice(
                key: ValueKey('lyrics-off-notice'),
                text:
                    'Lyrics are off for this playlist. Turn them on in '
                    'Playlist settings under Playback.',
              ),
            if (units.length > 1)
              _UnitSelector(
                units: units,
                selected: unit,
                docs: byKey,
                enabled: !_busy,
                onSelected:
                    (picked) => setState(() => _selectedKey = picked.key),
              ),
            _StatusHeader(doc: doc, mode: mode),
            if (blocked != null)
              _Notice(
                key: const ValueKey('lyrics-blocked-notice'),
                text: blocked,
              ),
            if (mode != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 0,
                  children: [
                    if (doc == null && blocked == null)
                      FilledButton.tonalIcon(
                        key: const ValueKey('lyrics-fetch-now'),
                        onPressed: _busy ? null : () => _fetchNow(track),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('Fetch now'),
                      ),
                    TextButton.icon(
                      key: const ValueKey('lyrics-wrong-song'),
                      onPressed: _busy ? null : () => _pick(track, unit, mode),
                      icon: const Icon(Icons.search),
                      label: Text(
                        mode == LyricsMode.transcript
                            ? 'Use other captions…'
                            : doc?.status == LyricsStatus.found
                            ? 'Wrong song?'
                            : 'Choose the song…',
                      ),
                    ),
                    if (!(doc?.status == LyricsStatus.none && doc!.pinned))
                      TextButton.icon(
                        key: const ValueKey('lyrics-mark-none'),
                        onPressed: _busy ? null : () => _markNone(track, unit),
                        icon: const Icon(Icons.block),
                        label: Text(
                          mode == LyricsMode.transcript
                              ? 'No transcript here'
                              : 'No lyrics here',
                        ),
                      ),
                    if (doc != null &&
                        doc.status == LyricsStatus.found &&
                        doc.synced &&
                        playable)
                      TextButton.icon(
                        key: const ValueKey('lyrics-timing'),
                        onPressed:
                            _busy
                                ? null
                                : () => _fixTiming(
                                  track,
                                  playlist,
                                  unit,
                                  (fileMs) =>
                                      playsAsChapters
                                          ? _chapterAt(chapters, fileMs)
                                          : null,
                                ),
                        icon: const Icon(Icons.timer_outlined),
                        label: const Text('Timing off?'),
                      ),
                    if (doc != null && blocked == null)
                      TextButton.icon(
                        key: const ValueKey('lyrics-refetch'),
                        onPressed: _busy ? null : () => _refetch(track, unit),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refetch automatically'),
                      ),
                  ],
                ),
              ),
            const Divider(height: 1, color: Color(0xFF3A3A3A)),
          ];
          final padding = EdgeInsets.only(bottom: 24 + overlay);
          if (doc == null || doc.status != LyricsStatus.found) {
            return ListView(padding: padding, children: header);
          }
          if (_linesDoc != doc) {
            _linesDoc = doc;
            _lines = ref.read(databaseProvider).lyricsLinesForDoc(doc.id);
          }
          return FutureBuilder<List<LyricsLine>>(
            future: _lines,
            builder: (context, snapshot) {
              final lines = snapshot.data;
              if (lines == null) {
                return ListView(
                  padding: padding,
                  children: [
                    ...header,
                    if (snapshot.hasError)
                      const _Notice(text: 'Could not read the lines.')
                    else
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                  ],
                );
              }
              return ListView.builder(
                key: const ValueKey('lyrics-lines'),
                padding: padding,
                itemCount: header.length + lines.length,
                itemBuilder: (context, i) {
                  if (i < header.length) return header[i];
                  final line = lines[i - header.length];
                  final startMs = line.startMs;
                  // A timing shift can move a line before the doc's start.
                  final fileMs =
                      startMs == null
                          ? null
                          : doc.offsetMs + max<int>(0, startMs);
                  return _LineRow(
                    line: line,
                    onTap:
                        fileMs == null || !playable || _busy
                            ? null
                            : () => _run(
                              () => _playAt(
                                track,
                                playlist,
                                fileMs,
                                doc.chapterId ??
                                    (playsAsChapters
                                        ? _chapterAt(chapters, fileMs)
                                        : null),
                              ),
                            ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// The menu entry that opens [LyricsPage], by the playlist's stored mode.
String lyricsMenuTitle(String? lyricsMode) =>
    LyricsMode.fromDb(lyricsMode) == LyricsMode.transcript
        ? 'Transcript…'
        : 'Lyrics…';

String lyricsMenuSubtitle(String? lyricsMode) => switch (LyricsMode.fromDb(
  lyricsMode,
)) {
  null => 'Turn on Lyrics in playlist settings to fetch them',
  LyricsMode.lyrics => 'See the lyrics, or pick the right song',
  LyricsMode.transcript => 'See the transcript, or pick other captions',
};

/// The chapter playing at [ms], or null in a gap.
String? _chapterAt(List<MediaChapter> chapters, int ms) {
  for (final chapter in chapters) {
    if (chapter.startMs <= ms && ms < chapter.endMs) return chapter.id;
  }
  return null;
}

/// m:ss, or h:mm:ss from an hour on.
String lyricsTimestamp(int ms) {
  final d = Duration(milliseconds: max(0, ms));
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (d.inHours == 0) return '${d.inMinutes}:$s';
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  return '${d.inHours}:$m:$s';
}

/// Where the text came from, as shown.
String lyricsSourceLabel(String? source) => switch (source) {
  LyricsSource.lrclib => 'LRCLIB',
  LyricsSource.ytmusic => 'YouTube Music',
  LyricsSource.ytSubs => 'YouTube captions',
  LyricsSource.ytAuto => 'YouTube automatic captions',
  _ => 'Unknown source',
};

/// A short status of a doc, for the chapter selector.
String lyricsStatusLabel(LyricsDoc? doc) {
  if (doc == null) return 'Not fetched yet';
  return switch (doc.status) {
    LyricsStatus.found =>
      doc.kind == LyricsMode.transcript.dbValue
          ? 'Transcript'
          : doc.synced
          ? 'Synced lyrics'
          : 'Lyrics',
    LyricsStatus.none => doc.pinned ? 'No lyrics (your choice)' : 'Not found',
    LyricsStatus.instrumental => 'Instrumental',
    _ => 'Could not fetch',
  };
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.doc, required this.mode});

  final LyricsDoc? doc;
  final LyricsMode? mode;

  @override
  Widget build(BuildContext context) {
    final doc = this.doc;
    final transcript =
        doc?.kind == LyricsMode.transcript.dbValue ||
        (doc == null && mode == LyricsMode.transcript);
    final what = transcript ? 'transcript' : 'lyrics';
    final String title;
    final String detail;
    IconData icon = Icons.lyrics_outlined;
    if (doc == null) {
      icon = Icons.hourglass_empty;
      title = 'Not fetched yet';
      detail =
          mode == null
              ? 'Nothing is fetched while lyrics are off.'
              : 'The next update looks for the $what, or fetch them now.';
    } else {
      final how = doc.pinned ? 'Chosen by you' : 'Found automatically';
      switch (doc.status) {
        case LyricsStatus.found:
          final names = [
            if ((doc.matchedArtist ?? '').isNotEmpty) doc.matchedArtist!,
            if ((doc.matchedTitle ?? '').isNotEmpty) doc.matchedTitle!,
          ];
          title =
              names.isNotEmpty
                  ? names.join(' – ')
                  : transcript
                  ? 'Transcript'
                  : 'Lyrics';
          detail = [
            lyricsSourceLabel(doc.source),
            if (doc.lang != null && doc.lang!.isNotEmpty) doc.lang!,
            doc.synced
                ? doc.shiftMs == 0
                    ? 'timed'
                    : 'timed, moved ${lyricsShiftLabel(doc.shiftMs)}'
                : 'not timed',
            how,
          ].join(' · ');
        case LyricsStatus.none:
          icon = Icons.block;
          title = doc.pinned ? 'No $what here' : 'No $what found';
          detail =
              doc.pinned
                  ? 'You said this has none. Updates leave it alone.'
                  : 'Checked ${_date(doc.checkedAt)}. Updates try again '
                      'now and then.';
        case LyricsStatus.instrumental:
          icon = Icons.music_note;
          title = 'Instrumental';
          detail = '${lyricsSourceLabel(doc.source)} · $how';
        default:
          icon = Icons.error_outline;
          title = 'Could not fetch the $what';
          detail = 'Tried ${_date(doc.checkedAt)}. Updates try again later.';
      }
    }
    return ListTile(
      key: const ValueKey('lyrics-status'),
      leading: Icon(icon, color: _accent),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle: Text(detail, style: const TextStyle(color: _muted)),
    );
  }

  static String _date(DateTime time) {
    final local = time.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return 'on ${local.year}-$m-$d';
  }
}

class _UnitSelector extends StatelessWidget {
  const _UnitSelector({
    required this.units,
    required this.selected,
    required this.docs,
    required this.enabled,
    required this.onSelected,
  });

  final List<_Unit> units;
  final _Unit selected;
  final Map<String, LyricsDoc> docs;
  final bool enabled;
  final ValueChanged<_Unit> onSelected;

  String _title(_Unit unit) {
    final chapter = unit.chapter;
    if (chapter == null) return 'Whole file';
    final number = units.where((u) => u.chapter != null).toList().indexOf(unit);
    return '${number + 1}. ${chapter.title}';
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<_Unit>(
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
            child: ListView(
              key: const ValueKey('lyrics-unit-list'),
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                for (final unit in units)
                  ListTile(
                    key: ValueKey('lyrics-unit-${unit.key}'),
                    selected: unit.key == selected.key,
                    title: Text(
                      _title(unit),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        if (unit.chapter != null)
                          lyricsTimestamp(unit.chapter!.startMs),
                        lyricsStatusLabel(docs[unit.key]),
                      ].join(' · '),
                      style: const TextStyle(color: _muted),
                    ),
                    onTap: () => Navigator.pop(sheetContext, unit),
                  ),
              ],
            ),
          ),
    );
    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const ValueKey('lyrics-chapter-selector'),
      leading: const Icon(Icons.list_alt),
      title: Text(
        _title(selected),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        selected.chapter == null
            ? 'Tap to pick a chapter'
            : 'Chapter ${units.where((u) => u.chapter != null).toList().indexOf(selected) + 1} '
                'of ${units.where((u) => u.chapter != null).length} · '
                'tap to pick another',
        style: const TextStyle(color: _muted),
      ),
      trailing: const Icon(Icons.expand_more),
      enabled: enabled,
      onTap: () => _open(context),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.onTap});

  final LyricsLine line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final startMs = line.startMs;
    return InkWell(
      key: ValueKey('lyrics-line-${line.lineNo}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (startMs != null)
              SizedBox(
                width: 56,
                child: Text(
                  lyricsTimestamp(startMs),
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
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: _muted, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(color: _muted))),
        ],
      ),
    );
  }
}
