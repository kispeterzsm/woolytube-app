import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart'
    hide DownloadProgress;
import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../database/database.dart';
import '../providers/chapter_fetch_jobs.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/chapters.dart';
import '../services/download_errors.dart';
import '../services/download_service.dart';
import '../services/library_gate.dart';
import '../services/lyrics/lyrics_models.dart';
import '../services/media_thumbnail_service.dart';
import '../services/playlist_service.dart';
import '../services/sponsorblock_service.dart';
import '../services/track_search.dart';
import '../services/video_quality.dart';
import '../widgets/lyrics_line_text.dart';
import '../widgets/mobile_data_download_guard.dart';
import '../widgets/tap_to_place_cursor_text_field.dart';
import '../widgets/video_quality_picker.dart';
import 'chapters_page.dart';
import 'playlist_settings_page.dart';

part 'playlist_detail/track_row.dart';
part 'playlist_detail/track_actions.dart';
part 'playlist_detail/track_dialogs.dart';

const _accent = Color(0xFF2196F3);
const _muted = Color(0xFF888888);

/// When the open-time folder check and cover backfill last ran, per
/// playlist. Reopening a playlist within [_openChecksInterval] skips them, so
/// going back and forth between pages never repeats the disk scan.
final _openChecksRanAt = <int, DateTime>{};
const _openChecksInterval = Duration(minutes: 5);

/// Forgets when the open-time checks ran, so the next open runs them.
@visibleForTesting
void resetPlaylistOpenChecks() => _openChecksRanAt.clear();

class PlaylistDetailPage extends ConsumerStatefulWidget {
  final int playlistId;

  /// Name shown in the app bar until the playlist row has loaded.
  final String? initialName;

  const PlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.initialName,
  });

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

/// Everything the page derives from one tracks list and one search query.
/// Rebuilt only when either changes, never on playback or download ticks.
/// A track whose download failed or that cannot be downloaded.
bool _isProblemTrack(Track track) =>
    track.status == 'error' || track.status == 'unavailable';

class _TrackListView {
  _TrackListView(this.tracks, this.query, [this.lyricMatches = const {}]) {
    final matches = <int, MediaChapter>{};
    if (query.isEmpty) {
      visible = tracks;
    } else {
      visible = [
        for (final track in tracks)
          if (matchesNormalizedTrackSearch(track, query) ||
              lyricMatches.containsKey(track.id))
            track,
      ];
      for (final track in visible) {
        if (track.chaptersJson == null) continue;
        final chapter = matchingChapterForSearch(track, query);
        if (chapter != null) matches[track.id] = chapter;
      }
    }
    chapterMatches = matches;
    rowOf = {for (var i = 0; i < visible.length; i++) visible[i].id: i};
    problemRows = [
      for (var i = 0; i < visible.length; i++)
        if (_isProblemTrack(visible[i])) i,
    ];

    var downloaded = 0;
    var unavailable = 0;
    var removed = 0;
    var seconds = 0;
    var maxIndex = 0;
    var playable = false;
    for (final track in tracks) {
      if (track.status == 'complete') downloaded++;
      if (track.status == 'unavailable') unavailable++;
      if (track.unavailableReason == removedFromYouTubeReason) removed++;
      seconds += track.durationSeconds ?? 0;
      if (track.index > maxIndex) maxIndex = track.index;
      if (!playable && track.status == 'complete' && !track.alwaysSkip) {
        playable = true;
      }
    }
    this.maxIndex = maxIndex;
    removedFromYouTube = removed;
    hasPlayable = playable;
    visibleHasPlayable =
        identical(visible, tracks)
            ? playable
            : visible.any((t) => t.status == 'complete' && !t.alwaysSkip);
    summary = _summaryText(tracks.length, downloaded, unavailable, seconds);
  }

  final List<Track> tracks;
  final String query;

  /// The best lyric line of each track whose lyrics match [query].
  final Map<int, LyricsHit> lyricMatches;
  late final List<Track> visible;
  late final Map<int, int> rowOf;

  /// Rows (in [visible]) whose download failed or that are unavailable.
  late final List<int> problemRows;
  late final Map<int, MediaChapter> chapterMatches;
  late final int maxIndex;

  /// Tracks a download found removed from YouTube (with or without a file).
  late final int removedFromYouTube;
  late final bool hasPlayable;
  late final bool visibleHasPlayable;
  late final String summary;

  static String _summaryText(
    int total,
    int downloaded,
    int unavailable,
    int seconds,
  ) {
    if (total == 0) return 'No tracks';
    final parts = <String>[
      total == 1 ? '1 track' : '$total tracks',
      downloaded == total ? 'all downloaded' : '$downloaded downloaded',
      if (unavailable > 0) '$unavailable unavailable',
    ];
    if (seconds > 0) parts.add(_formatTotalDuration(seconds));
    return parts.join(' · ');
  }
}

String _formatTotalDuration(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours == 0) return minutes == 0 ? '$seconds s' : '$minutes min';
  return minutes == 0 ? '$hours h' : '$hours h $minutes min';
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage>
    with _TrackActions {
  static const _followAnimation = Duration(milliseconds: 250);

  /// After the user scrolls the list, a track change does not move it for
  /// this long.
  static const _userScrollGrace = Duration(seconds: 4);

  /// How long after Play the next track change always brings the list along.
  static const _forceFollowWindow = Duration(seconds: 5);

  late final Future<Playlist?> _playlistLoad;
  Playlist? _fetchedPlaylist;
  bool _handledRemoval = false;

  final TextEditingController _searchController = TextEditingController();

  /// The normalized (trimmed, lower-case) query; empty when not filtering.
  String _searchQuery = '';

  // Lyric lines matching the query, searched after a short pause in typing.
  static const _lyricsDebounce = Duration(milliseconds: 200);
  Timer? _lyricsTimer;
  int _lyricsGeneration = 0;
  Map<int, LyricsHit> _lyricMatches = const {};
  String _lyricMatchesQuery = '';
  bool _showSearch = false;
  double? _offsetBeforeSearch;
  bool _isUpdating = false;

  /// Bumped by every Update and by Stop, so an update that was stopped
  /// while YouTube was still answering cannot touch the page when it
  /// finally returns.
  int _updateGeneration = 0;

  _TrackListView? _view;
  ScrollController? _listController;
  double _rowExtent = 0;

  /// True once the list was put on the playing track (or there was none).
  bool _initialFollowDone = false;

  /// Until then, the next track change always scrolls (set by Play, so a
  /// Play that changes nothing cannot make a much later change yank the
  /// list).
  DateTime? _forceFollowUntil;
  DateTime? _lastUserScroll;
  int? _lastProblemRow;
  final ValueNotifier<bool> _showJumpToPlaying = ValueNotifier(false);

  @override
  Playlist? get _playlist {
    final playlists = ref.read(playlistsProvider).valueOrNull;
    return playlists?.where((p) => p.id == widget.playlistId).firstOrNull ??
        _fetchedPlaylist;
  }

  @override
  void initState() {
    super.initState();
    _playlistLoad = _loadPlaylist();
    ref.listenManual<AsyncValue<Track?>>(
      currentTrackProvider,
      (previous, next) =>
          _onCurrentTrackChanged(previous?.valueOrNull, next.valueOrNull),
    );
    _lastOverlay = _overlayHeight;
    audioPlayerOverlayHeightNotifier.addListener(_onOverlayChanged);
  }

  Future<Playlist?> _loadPlaylist() async {
    try {
      final playlist = await ref
          .read(databaseProvider)
          .getPlaylist(widget.playlistId);
      if (mounted) setState(() => _fetchedPlaylist = playlist);
      return playlist;
    } catch (_) {
      // Deleted meanwhile: the live playlist row handles that case.
      return null;
    }
  }

  /// The folder check and the cover backfill read the disk and may write
  /// rows. They start once the page is on screen and its route has settled
  /// (the list is already on the playing track by then), and at most once
  /// every few minutes per playlist.
  Future<void> _startBackgroundChecks() async {
    final playlist = _playlist ?? await _playlistLoad;
    if (playlist == null || !mounted) return;
    final now = DateTime.now();
    final last = _openChecksRanAt[playlist.id];
    if (last != null && now.difference(last) < _openChecksInterval) return;
    _openChecksRanAt[playlist.id] = now;
    unawaited(_linkFiles(playlist));
    unawaited(_backfillThumbnails(playlist));
  }

  /// Links tracks to files that appeared on disk (copied back, restored).
  /// Only while nothing else is changing files: a sync that is renumbering
  /// them, or a download, keeps the rows right by itself.
  Future<void> _linkFiles(Playlist playlist) async {
    try {
      final gate = ref.read(libraryGateProvider);
      final metadata = ref.read(metadataServiceProvider);
      if (await gate.tryEnter('playlist check') != null) return;
      try {
        await metadata.reconcilePlaylist(playlist);
      } finally {
        await gate.exit();
      }
    } catch (_) {
      // The list still shows; the next update links the files.
    }
  }

  /// Saves a cover file for every downloaded track that has none yet (from
  /// the art inside the file, or the image cache), so covers show offline.
  Future<void> _backfillThumbnails(Playlist playlist) async {
    try {
      final backfill = ref.read(thumbnailBackfillServiceProvider);
      await backfill.ensureTrackThumbnails(playlist);
      await backfill.ensurePlaylistCover(playlist);
    } catch (_) {
      // Artwork is optional and should never block the playlist UI.
    }
  }

  @override
  void dispose() {
    audioPlayerOverlayHeightNotifier.removeListener(_onOverlayChanged);
    _lyricsTimer?.cancel();
    _searchController.dispose();
    _listController?.dispose();
    _showJumpToPlaying.dispose();
    super.dispose();
  }

  _TrackListView _viewFor(List<Track> tracks) {
    final cached = _view;
    final lyrics =
        _lyricMatchesQuery == _searchQuery
            ? _lyricMatches
            : const <int, LyricsHit>{};
    if (cached != null &&
        identical(cached.tracks, tracks) &&
        cached.query == _searchQuery &&
        identical(cached.lyricMatches, lyrics)) {
      return cached;
    }
    return _view = _TrackListView(tracks, _searchQuery, lyrics);
  }

  // ---------------------------------------------------------------------
  // Following the playing track
  // ---------------------------------------------------------------------

  double get _overlayHeight => audioPlayerOverlayHeightNotifier.value;
  double _lastOverlay = 0;

  /// The expanded player opened over the list: if it now covers the playing
  /// row the list was showing, bring the row into the part left free.
  void _onOverlayChanged() {
    final before = _lastOverlay;
    _lastOverlay = _overlayHeight;
    if (_overlayHeight <= before) return;
    final row = _rowOfCurrentTrack();
    final position = _position;
    if (row == null || position == null || _rowExtent <= 0) return;
    final top = row * _rowExtent;
    final oldBottom = position.pixels + position.viewportDimension - before;
    final wasShown =
        top + _rowExtent > position.pixels + 1 && top < oldBottom - 1;
    final lastScroll = _lastUserScroll;
    final browsing =
        lastScroll != null &&
        DateTime.now().difference(lastScroll) < _userScrollGrace;
    if (!wasShown || browsing) return;
    // After the list has been laid out with the new bottom padding.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = _rowOfCurrentTrack();
      if (current != null && !_rowFullyVisible(current)) {
        _scrollToRow(current, animate: true);
      }
      _updateJumpToPlaying();
    });
  }

  /// The offset that puts row [row] at 40 % of the part of the list that
  /// the expanded player does not cover.
  double _offsetForRow(
    int row, {
    required int rowCount,
    required double extent,
    required double viewport,
    required double overlay,
  }) {
    final visibleHeight = math.max(extent, viewport - overlay);
    final maxOffset = math.max(0.0, rowCount * extent + overlay - viewport);
    final target = row * extent - (visibleHeight * 0.4 - extent / 2);
    return target.clamp(0.0, maxOffset).toDouble();
  }

  ScrollController _ensureListController(
    _TrackListView view,
    double extent,
    double viewport,
    double overlay,
  ) {
    final existing = _listController;
    if (existing != null) return existing;
    var initialOffset = 0.0;
    final current = ref.read(currentTrackProvider);
    if (current.hasValue) {
      // Known on the first build when the page is reopened: the list is
      // created already on the playing row, so nothing scrolls or jumps.
      _initialFollowDone = true;
      final track = current.valueOrNull;
      final row = track == null ? null : view.rowOf[track.id];
      if (row != null) {
        initialOffset = _offsetForRow(
          row,
          rowCount: view.visible.length,
          extent: extent,
          viewport: viewport,
          overlay: overlay,
        );
      }
    }
    return _listController = ScrollController(
      initialScrollOffset: initialOffset,
    );
  }

  ScrollPosition? get _position {
    final controller = _listController;
    if (controller == null || !controller.hasClients) return null;
    return controller.position;
  }

  (double top, double bottom)? _visibleBand() {
    final position = _position;
    if (position == null || !position.hasContentDimensions) return null;
    final top = position.pixels;
    return (top, top + position.viewportDimension - _overlayHeight);
  }

  bool _rowFullyVisible(int row) {
    final band = _visibleBand();
    if (band == null) return false;
    final top = row * _rowExtent;
    return top >= band.$1 - 0.5 && top + _rowExtent <= band.$2 + 0.5;
  }

  bool _rowPartlyVisible(int row) {
    final band = _visibleBand();
    if (band == null) return false;
    final top = row * _rowExtent;
    return top + _rowExtent > band.$1 + 1 && top < band.$2 - 1;
  }

  void _scrollToRow(int row, {required bool animate}) {
    final position = _position;
    final view = _view;
    if (position == null || view == null || _rowExtent <= 0) return;
    final target = _offsetForRow(
      row,
      rowCount: view.visible.length,
      extent: _rowExtent,
      viewport: position.viewportDimension,
      overlay: _overlayHeight,
    ).clamp(position.minScrollExtent, position.maxScrollExtent);
    final distance = (target - position.pixels).abs();
    if (distance < 1) return;
    if (!animate || distance > 2 * position.viewportDimension) {
      // Far away: animating would build every row in between.
      _listController!.jumpTo(target);
    } else {
      unawaited(
        _listController!.animateTo(
          target,
          duration: _followAnimation,
          curve: Curves.easeOut,
        ),
      );
    }
  }

  int? _rowOfCurrentTrack() {
    final current = ref.read(currentTrackProvider).valueOrNull;
    if (current == null || current.playlistId != widget.playlistId) {
      return null;
    }
    return _view?.rowOf[current.id];
  }

  void _onCurrentTrackChanged(Track? previous, Track? next) {
    if (!mounted) return;
    final view = _view;
    if (view == null || _position == null) {
      // Not laid out yet: the list is created on the playing row instead.
      _updateJumpToPlaying();
      return;
    }
    if (next == null || next.playlistId != widget.playlistId) {
      // Known now, and not in this list: nothing to put on screen first.
      _initialFollowDone = true;
      _updateJumpToPlaying();
      return;
    }
    final row = view.rowOf[next.id];
    if (row == null) {
      // Hidden by the search filter.
      _initialFollowDone = true;
      _updateJumpToPlaying();
      return;
    }
    if (!_initialFollowDone) {
      // The playing track became known after the list was built.
      _initialFollowDone = true;
      _scrollToRow(row, animate: false);
      _updateJumpToPlaying();
      return;
    }
    final force = _takeForceFollow();
    if (previous?.id == next.id) {
      // Play restarted the track already playing: still show it.
      if (force && !_rowFullyVisible(row)) _scrollToRow(row, animate: true);
      _updateJumpToPlaying();
      return;
    }
    if (_rowFullyVisible(row)) {
      _updateJumpToPlaying();
      return;
    }
    if (!force) {
      final lastScroll = _lastUserScroll;
      final scrolledRecently =
          lastScroll != null &&
          DateTime.now().difference(lastScroll) < _userScrollGrace;
      final previousRow = previous == null ? null : view.rowOf[previous.id];
      final wasFollowing =
          previousRow != null && _rowPartlyVisible(previousRow);
      if (scrolledRecently || !wasFollowing) {
        // The user is looking at another part of the list: leave it there
        // and offer the "Now playing" button instead.
        _updateJumpToPlaying();
        return;
      }
    }
    _scrollToRow(row, animate: true);
    _updateJumpToPlaying();
  }

  bool _takeForceFollow() {
    final until = _forceFollowUntil;
    _forceFollowUntil = null;
    return until != null && DateTime.now().isBefore(until);
  }

  void _updateJumpToPlaying() {
    if (!mounted) return;
    final row = _rowOfCurrentTrack();
    final show = row != null && _position != null && !_rowPartlyVisible(row);
    if (_showJumpToPlaying.value != show) _showJumpToPlaying.value = show;
  }

  void _jumpToPlaying() {
    final row = _rowOfCurrentTrack();
    if (row == null) return;
    _lastUserScroll = null;
    _scrollToRow(row, animate: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateJumpToPlaying());
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if ((notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle) ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null)) {
      _lastUserScroll = DateTime.now();
    }
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _updateJumpToPlaying();
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------

  void _openSearch() {
    _offsetBeforeSearch = _position?.pixels;
    setState(() => _showSearch = true);
  }

  void _closeSearch() {
    _searchController.clear();
    _scheduleLyricsSearch('');
    final restore = _offsetBeforeSearch;
    setState(() {
      _showSearch = false;
      _searchQuery = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final row = _rowOfCurrentTrack();
      final position = _position;
      if (position == null) return;
      if (row != null) {
        _scrollToRow(row, animate: false);
      } else if (restore != null) {
        _listController!.jumpTo(
          restore.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
      _updateJumpToPlaying();
    });
  }

  void _onSearchChanged(String raw) {
    final query = normalizeTrackSearchQuery(raw);
    if (query == _searchQuery) {
      // Keeps the clear button in sync with the text.
      setState(() {});
      return;
    }
    setState(() => _searchQuery = query);
    _scheduleLyricsSearch(query);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final position = _position;
      if (position != null && position.pixels != 0) {
        _listController!.jumpTo(0);
      }
      _updateJumpToPlaying();
    });
  }

  /// Searches this playlist's lyrics for [query] once typing pauses, when
  /// the playlist has lyrics on.
  void _scheduleLyricsSearch(String query) {
    _lyricsTimer?.cancel();
    final generation = ++_lyricsGeneration;
    if (query.length < 2 || _playlist?.lyricsMode == null) {
      _lyricMatches = const {};
      _lyricMatchesQuery = '';
      return;
    }
    _lyricsTimer = Timer(_lyricsDebounce, () async {
      List<LyricsHit> hits;
      try {
        hits = await ref
            .read(lyricsSearchProvider)
            .search(query, playlistId: widget.playlistId);
      } catch (_) {
        hits = const [];
      }
      if (!mounted || generation != _lyricsGeneration) return;
      final matches = <int, LyricsHit>{};
      for (final hit in hits) {
        matches.putIfAbsent(hit.trackId, () => hit);
      }
      setState(() {
        _lyricMatches = matches;
        _lyricMatchesQuery = query;
      });
    });
  }

  // ---------------------------------------------------------------------
  // Playback actions
  // ---------------------------------------------------------------------

  void _onTrackTap(
    Track track,
    bool isCurrent,
    MediaChapter? chapter,
    LyricsHit? lyricMatch,
  ) {
    if (track.status != 'complete') {
      _showTrackActions(track);
      return;
    }
    final playback = ref.read(playbackServiceProvider);
    final allTracks = _view?.tracks ?? [track];
    if (chapter == null && lyricMatch != null) {
      // Plays from just before the matched line.
      final target = lyricsHitTarget(track, lyricMatch);
      unawaited(
        playback.playTrack(
          track,
          allTracks,
          playlist: _playlist,
          chapterId: target.chapter?.id,
          startAt: target.startAt,
        ),
      );
      return;
    }
    if (isCurrent && chapter == null) {
      // Tapping the playing row never reloads the file.
      unawaited(playback.togglePlayPause());
      return;
    }
    unawaited(
      playback.playTrack(
        track,
        allTracks,
        playlist: _playlist,
        chapterId: chapter?.id,
      ),
    );
  }

  void _playAll(List<Track> tracks) {
    _forceFollowUntil = DateTime.now().add(_forceFollowWindow);
    _lastUserScroll = null;
    unawaited(
      ref.read(playbackServiceProvider).playAll(tracks, playlist: _playlist),
    );
  }

  /// Scrolls to the first failed or unavailable track below the one in the
  /// middle of the list, wrapping around to the top after the last one.
  void _jumpToNextProblem() {
    final view = _view;
    final position = _position;
    if (view == null || view.problemRows.isEmpty) return;
    var anchor = -1;
    if (position != null && _rowExtent > 0) {
      final visibleHeight = math.max(
        _rowExtent,
        position.viewportDimension - _overlayHeight,
      );
      anchor =
          ((position.pixels + visibleHeight * 0.4 - _rowExtent / 2) /
                  _rowExtent)
              .round();
      // At either end the list cannot centre the row; use the last jump.
      final last = _lastProblemRow;
      if (last != null && _rowFullyVisible(last)) {
        anchor = math.max(anchor, last);
      }
    }
    final rows = view.problemRows;
    var index = rows.indexWhere((row) => row > anchor);
    final wrapped = index == -1;
    if (wrapped) index = 0;
    final row = rows[index];
    _lastProblemRow = row;
    // A jump the user asked for counts as browsing: auto-follow waits.
    _lastUserScroll = DateTime.now();
    _scrollToRow(row, animate: true);
    final track = view.visible[row];
    _showModeFeedback(
      '${wrapped && rows.length > 1 ? 'Back to the first · ' : ''}'
      '${index + 1} of ${rows.length}: #${track.index} '
      '${track.status == 'unavailable' ? 'unavailable' : 'download failed'}',
    );
  }

  void _showModeFeedback(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _openPlaylistSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistSettingsPage(playlistId: widget.playlistId),
      ),
    );
  }

  void _handlePlaylistRemoved() {
    if (_handledRemoval) return;
    _handledRemoval = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Only this route's "current" flag is looked up, and only now, so the
      // page does not rebuild on every route change above it.
      if (ModalRoute.isCurrentOf(context) ?? false) {
        Navigator.of(context).maybePop();
      }
    });
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tracksAsync = ref.watch(tracksProvider(widget.playlistId));
    final (playlistsLoaded, livePlaylist) = ref.watch(
      playlistsProvider.select(
        (playlists) => (
          playlists.hasValue,
          playlists.valueOrNull
              ?.where((p) => p.id == widget.playlistId)
              .firstOrNull,
        ),
      ),
    );
    final playlist = livePlaylist ?? _fetchedPlaylist;
    final removed =
        playlistsLoaded && livePlaylist == null && _fetchedPlaylist != null;
    if (removed) _handlePlaylistRemoved();
    final loadedTracks = tracksAsync.valueOrNull;
    final view = loadedTracks == null ? null : _viewFor(loadedTracks);

    return _AfterRouteSettles(
      onSettled: _startBackgroundChecks,
      child: PopScope(
        canPop: !_showSearch,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _showSearch) _closeSearch();
        },
        child: Scaffold(
          appBar: _buildAppBar(playlist, view),
          body:
              removed
                  ? const Center(
                    child: Text(
                      'This playlist was deleted.',
                      style: TextStyle(color: _muted),
                    ),
                  )
                  : tracksAsync.when(
                    loading:
                        () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('Error: $e')),
                    data:
                        (tracks) => Column(
                          children: [
                            _buildHeader(_viewFor(tracks), playlist),
                            _RunStatus(playlistId: widget.playlistId),
                            Expanded(child: _buildTrackList(_viewFor(tracks))),
                          ],
                        ),
                  ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(Playlist? playlist, _TrackListView? view) {
    final name = playlist?.name ?? widget.initialName ?? '';
    return AppBar(
      titleSpacing: _showSearch ? 0 : null,
      title:
          _showSearch
              ? TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search title, number or chapter',
                  hintStyle: const TextStyle(color: _muted),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  suffixIcon:
                      _searchController.text.isEmpty
                          ? null
                          : IconButton(
                            key: const ValueKey('playlist-search-clear'),
                            icon: const Icon(Icons.clear, color: _muted),
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
                            },
                          ),
                ),
                onChanged: _onSearchChanged,
              )
              : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (view != null)
                    Text(
                      view.summary,
                      key: const ValueKey('playlist-detail-summary'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                ],
              ),
      actions: [
        IconButton(
          icon: Icon(
            _showSearch ? Icons.search_off : Icons.search,
            color: _showSearch ? _accent : Colors.white,
          ),
          tooltip: _showSearch ? 'Close search' : 'Search tracks',
          onPressed: _showSearch ? _closeSearch : _openSearch,
        ),
        const _UpNextButton(),
        PopupMenuButton<String>(
          key: const ValueKey('playlist-detail-menu'),
          tooltip: 'More options',
          color: const Color(0xFF2A2A2A),
          onSelected: (value) {
            switch (value) {
              case 'settings':
                _openPlaylistSettings();
              case 'next-problem':
                _jumpToNextProblem();
              case 'retry-removed':
                unawaited(_retryRemovedTracks());
              case 'clear':
                unawaited(_confirmClearTemporary());
              case 'youtube':
                final url = playlist?.url;
                if (url != null) launchUrl(Uri.parse(url));
            }
          },
          itemBuilder:
              (_) => [
                const PopupMenuItem(
                  key: ValueKey('playlist-detail-settings'),
                  value: 'settings',
                  child: ListTile(
                    leading: Icon(Icons.settings_outlined),
                    title: Text('Playlist settings'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (view != null && view.problemRows.isNotEmpty)
                  PopupMenuItem(
                    key: const ValueKey('playlist-detail-next-problem'),
                    value: 'next-problem',
                    child: ListTile(
                      leading: const Icon(
                        Icons.error_outline,
                        color: Color(0xFFE57373),
                      ),
                      title: Text(
                        'Jump to next failed (${view.problemRows.length})',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (view != null && view.removedFromYouTube > 0)
                  PopupMenuItem(
                    key: const ValueKey('playlist-detail-retry-removed'),
                    value: 'retry-removed',
                    child: ListTile(
                      leading: const Icon(Icons.refresh),
                      title: Text(
                        'Try removed videos again (${view.removedFromYouTube})',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (playlist != null &&
                    playlist.isTemporary &&
                    view != null &&
                    view.tracks.isNotEmpty)
                  const PopupMenuItem(
                    key: ValueKey('playlist-detail-clear-temporary'),
                    value: 'clear',
                    child: ListTile(
                      leading: Icon(Icons.delete_sweep_outlined),
                      title: Text('Clear all'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (playlist != null && !playlist.isTemporary)
                  const PopupMenuItem(
                    value: 'youtube',
                    child: ListTile(
                      leading: Icon(Icons.open_in_new),
                      title: Text('Open on YouTube'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
        ),
      ],
    );
  }

  Widget _buildHeader(_TrackListView view, Playlist? playlist) {
    final filtering = _searchQuery.isNotEmpty;
    final playTracks = filtering ? view.visible : view.tracks;
    final canPlay = filtering ? view.visibleHasPlayable : view.hasPlayable;
    final isVideoPlaylist = playlist?.audioOnly == false;
    final playback = ref.read(playbackServiceProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Row(
        children: [
          // Play and Update on the left, the toggles pinned to the right.
          Expanded(
            child: Row(
              children: [
                // Shrinks with very large text instead of pushing the toggles off.
                Flexible(
                  flex: 3,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: FilledButton.icon(
                      key: const ValueKey('playlist-detail-play'),
                      onPressed: canPlay ? () => _playAll(playTracks) : null,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(filtering ? 'Play results' : 'Play'),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  flex: 2,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _UpdateControl(
                      playlistId: widget.playlistId,
                      starting: _isUpdating,
                      onUpdate: _startUpdate,
                      onStopCheck: _stopCheck,
                      onStopDownload: _confirmCancelDownload,
                      onLeaveQueue: _leaveQueue,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _ModeChip(
            key: const ValueKey('playlist-mode-shuffle'),
            provider: shuffleEnabledProvider,
            defaultValue: false,
            label: 'Shuffle',
            icon: Icons.shuffle,
            tooltip: (on) => on ? 'Shuffle is on' : 'Shuffle is off',
            onToggle: (on) {
              playback.toggleShuffle();
              _showModeFeedback(
                on
                    ? 'Shuffle off: tracks play in playlist order'
                    : 'Shuffle on: tracks play in random order',
              );
            },
          ),
          _ModeChip(
            key: const ValueKey('playlist-mode-autoplay'),
            provider: autoplayEnabledProvider,
            defaultValue: true,
            label: 'Autoplay',
            icon: Icons.playlist_play,
            tooltip:
                (on) =>
                    on
                        ? 'Autoplay is on: the next track starts by itself'
                        : 'Autoplay is off: playback stops after each track',
            onToggle: (on) {
              playback.toggleAutoplay();
              _showModeFeedback(
                on
                    ? 'Autoplay off: playback stops after each track'
                    : 'Autoplay on: the next track starts by itself',
              );
            },
          ),
          if (isVideoPlaylist)
            _ModeChip(
              key: const ValueKey('playlist-mode-audio-only'),
              provider: audioOnlyModeProvider,
              defaultValue: false,
              label: 'Audio only',
              icon: Icons.videocam_off_outlined,
              tooltip:
                  (on) =>
                      on
                          ? 'Audio only is on: videos play as sound only'
                          : 'Audio only is off: videos play with picture',
              onToggle: (on) {
                unawaited(playback.toggleAudioOnlyMode());
                _showModeFeedback(
                  on
                      ? 'Video on: videos play with picture'
                      : 'Audio only: videos play without picture',
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildTrackList(_TrackListView view) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = _TrackRowMetrics.of(context, maxIndex: view.maxIndex);
        return ValueListenableBuilder<double>(
          valueListenable: audioPlayerOverlayHeightNotifier,
          builder: (context, overlay, _) {
            _rowExtent = metrics.extent;
            final controller = _ensureListController(
              view,
              metrics.extent,
              constraints.maxHeight,
              overlay,
            );
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _updateJumpToPlaying(),
            );
            return Stack(
              children: [
                MediaQuery.withClampedTextScaling(
                  maxScaleFactor: _TrackRowMetrics.maxTextScale,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScrollNotification,
                    child: RawScrollbar(
                      controller: controller,
                      interactive: true,
                      thickness: 6,
                      radius: const Radius.circular(3),
                      minThumbLength: 48,
                      thumbColor: const Color(0x99FFFFFF),
                      padding: EdgeInsets.only(bottom: overlay),
                      child: ListView.builder(
                        key: const ValueKey('playlist-track-list'),
                        controller: controller,
                        itemExtent: metrics.extent,
                        padding: EdgeInsets.only(bottom: overlay),
                        itemCount: view.visible.length,
                        itemBuilder: (context, index) {
                          final track = view.visible[index];
                          return _TrackRow(
                            key: ValueKey('track-row-${track.id}'),
                            track: track,
                            metrics: metrics,
                            chapterMatch: view.chapterMatches[track.id],
                            lyricMatch: view.lyricMatches[track.id],
                            onTap: _onTrackTap,
                            onActions: _showTrackActions,
                          );
                        },
                      ),
                    ),
                  ),
                ),
                if (view.tracks.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No tracks yet. Tap Update to fetch them.',
                        style: TextStyle(color: _muted),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else if (view.visible.isEmpty)
                  const Center(
                    child: Text(
                      'No matching tracks',
                      style: TextStyle(color: _muted),
                    ),
                  ),
                Positioned(
                  right: 16,
                  bottom: overlay + 16,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _showJumpToPlaying,
                    builder:
                        (context, show, _) =>
                            show
                                ? FilledButton.tonalIcon(
                                  key: const ValueKey(
                                    'playlist-jump-to-playing',
                                  ),
                                  onPressed: _jumpToPlaying,
                                  icon: const Icon(Icons.graphic_eq),
                                  label: const Text('Now playing'),
                                )
                                : const SizedBox.shrink(),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmCancelDownload() async {
    final downloads = ref.read(downloadServiceProvider);
    final othersWaiting = downloads.queuedPlaylistIds.isNotEmpty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text(
              'Stop downloading?',
              style: TextStyle(color: Colors.white),
            ),
            content: Text(
              'Finished tracks are kept; the rest stay queued for the next '
              'update.${othersWaiting ? ' Playlists waiting to download are '
                      'not started either.' : ''}',
              style: const TextStyle(color: Color(0xFFCCCCCC)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep downloading'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Stop', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    await downloads.cancelActiveDownloads();
  }

  /// Stops the update while YouTube is still being asked; nothing changes.
  void _stopCheck() {
    final stopped = ref
        .read(playlistServiceProvider)
        .cancelSync(widget.playlistId);
    if (stopped) {
      setState(() {
        _isUpdating = false;
        _updateGeneration++;
      });
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Too late to stop: the changes are being saved'),
      ),
    );
  }

  void _leaveQueue() {
    if (!ref.read(downloadServiceProvider).removeFromQueue(widget.playlistId)) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Taken out of the download queue')),
    );
  }

  /// Empties the temporary playlist: every video and its files go.
  Future<void> _confirmClearTemporary() async {
    final count =
        ref.read(tracksProvider(widget.playlistId)).valueOrNull?.length ?? 0;
    final downloads = ref.read(downloadServiceProvider);
    final downloading =
        downloads.isDownloading &&
        downloads.activePlaylistId == widget.playlistId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text(
              'Clear Temporary?',
              style: TextStyle(color: Colors.white),
            ),
            content: Text(
              'Removes ${count == 1 ? 'the video' : 'all $count videos'} and '
              'deletes ${count == 1 ? 'its file' : 'their files'}.'
              '${downloading ? ' Its running download will be stopped.' : ''}',
              style: const TextStyle(color: Color(0xFFCCCCCC)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('clear-temporary-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'Clear all',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final error = await removeTemporaryVideos(ref, widget.playlistId);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Temporary playlist cleared')),
    );
    // The empty temporary playlist is not shown on the home page.
    if (mounted) navigator.popUntil((route) => route.isFirst);
  }

  Future<void> _retryRemovedTracks() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await ref
          .read(playlistServiceProvider)
          .retryRemovedTracks(widget.playlistId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            count == 0
                ? 'No removed videos to try again'
                : count == 1
                ? 'The next update tries 1 removed video again'
                : 'The next update tries $count removed videos again',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save: ${_errorText(e)}')),
      );
    }
  }

  Future<void> _startUpdate() async {
    final playlist = _playlist;
    if (playlist == null || _isUpdating) return;

    // Read every provider before the first await: `ref` is unusable once the
    // page is disposed, and the download must start even then.
    final downloadService = ref.read(downloadServiceProvider);
    final playlistService = ref.read(playlistServiceProvider);
    final db = ref.read(databaseProvider);
    // The temporary playlist asks YouTube nothing, so its download can wait
    // in the queue.
    if (downloadService.isDownloading && !playlist.isTemporary) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A download is already in progress')),
      );
      return;
    }
    if (explainDownloadsUnavailable(context, ref)) return;

    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      return;
    }
    if (!mounted) return;

    final generation = ++_updateGeneration;
    setState(() => _isUpdating = true);
    bool current() => mounted && generation == _updateGeneration;

    try {
      final freshPlaylist = await syncAndDownloadPlaylist(
        context: context,
        playlist: playlist,
        playlists: playlistService,
        downloads: downloadService,
        db: db,
      );
      if (freshPlaylist != null && mounted) {
        setState(() => _fetchedPlaylist = freshPlaylist);
      }
    } catch (e) {
      if (!mounted || !current()) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Update failed: ${friendlyDownloadError(_errorText(e))}',
          ),
        ),
      );
    } finally {
      if (current()) setState(() => _isUpdating = false);
    }
  }
}

/// Runs [onSettled] once, after the first frame and once the route's
/// entrance animation has finished. The route is looked up here, in a
/// widget whose rebuild costs nothing, so route changes do not rebuild the
/// page.
class _AfterRouteSettles extends StatefulWidget {
  const _AfterRouteSettles({required this.onSettled, required this.child});

  final VoidCallback onSettled;
  final Widget child;

  @override
  State<_AfterRouteSettles> createState() => _AfterRouteSettlesState();
}

class _AfterRouteSettlesState extends State<_AfterRouteSettles> {
  bool _done = false;
  Animation<double>? _animation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (_done || !mounted) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      _finish();
      return;
    }
    if (identical(animation, _animation)) return;
    _animation?.removeStatusListener(_onStatus);
    _animation = animation..addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _finish();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _animation?.removeStatusListener(_onStatus);
    _animation = null;
    if (mounted) widget.onSettled();
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_onStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// What this playlist's update or download is doing.
enum _Run { idle, checking, queued, preparing, downloading, finishing }

_Run _watchRun(WidgetRef ref, int playlistId) {
  final (status, activePlaylist, phase) = ref.watch(
    downloadProgressProvider.select((progress) {
      final value = progress.valueOrNull;
      return (value?.status, value?.playlistId, value?.phase);
    }),
  );
  if (status == 'downloading' && activePlaylist == playlistId) {
    return switch (phase) {
      DownloadPhase.preparing => _Run.preparing,
      DownloadPhase.finishing => _Run.finishing,
      _ => _Run.downloading,
    };
  }
  final checking = ref.watch(
    syncingPlaylistsProvider.select(
      (ids) => ids.valueOrNull?.contains(playlistId) ?? false,
    ),
  );
  if (checking) return _Run.checking;
  final queued = ref.watch(
    downloadQueueProvider.select(
      (ids) => ids.valueOrNull?.contains(playlistId) ?? false,
    ),
  );
  return queued ? _Run.queued : _Run.idle;
}

/// The button next to Play: Update, or the way to stop what is running.
/// Watches only the run state, never the per-percent progress.
class _UpdateControl extends ConsumerWidget {
  const _UpdateControl({
    required this.playlistId,
    required this.starting,
    required this.onUpdate,
    required this.onStopCheck,
    required this.onStopDownload,
    required this.onLeaveQueue,
  });

  final int playlistId;

  /// This page started an update that has not reached YouTube or the
  /// downloader yet (or is between the two).
  final bool starting;
  final VoidCallback onUpdate;
  final VoidCallback onStopCheck;
  final VoidCallback onStopDownload;
  final VoidCallback onLeaveQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = _watchRun(ref, playlistId);
    Widget button({
      required Key key,
      required Widget icon,
      required String label,
      required VoidCallback? onPressed,
      Color color = _accent,
    }) {
      return TextButton.icon(
        key: key,
        onPressed: onPressed,
        icon: icon,
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: TextButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: _muted,
          minimumSize: const Size(48, 48),
        ),
      );
    }

    switch (run) {
      case _Run.preparing || _Run.downloading || _Run.finishing:
        return button(
          key: const ValueKey('playlist-detail-cancel'),
          icon: const Icon(Icons.stop_circle_outlined),
          label: 'Stop download',
          onPressed: onStopDownload,
          color: const Color(0xFFE57373),
        );
      case _Run.checking:
        return button(
          key: const ValueKey('playlist-detail-stop-check'),
          icon: const Icon(Icons.stop_circle_outlined),
          label: 'Stop update',
          onPressed: onStopCheck,
          color: const Color(0xFFE57373),
        );
      case _Run.queued:
        return button(
          key: const ValueKey('playlist-detail-leave-queue'),
          icon: const Icon(Icons.remove_circle_outline),
          label: 'Remove from queue',
          onPressed: onLeaveQueue,
        );
      case _Run.idle:
        return button(
          key: const ValueKey('playlist-detail-update'),
          icon:
              starting
                  ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _muted,
                    ),
                  )
                  : const Icon(Icons.sync),
          label: starting ? 'Updating…' : 'Update',
          onPressed: starting ? null : onUpdate,
        );
    }
  }
}

/// The line under the header: a divider when nothing runs, otherwise what
/// the update is doing and a thin progress bar.
class _RunStatus extends ConsumerWidget {
  const _RunStatus({required this.playlistId});

  final int playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = _watchRun(ref, playlistId);
    if (run == _Run.idle) {
      return const SizedBox(
        height: 2,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Divider(height: 1, color: Color(0xFF333333)),
        ),
      );
    }
    final Widget label = switch (run) {
      _Run.checking => const _RunText('Checking for new videos…'),
      _Run.queued => const _RunText(
        'Queued — starts after the current download',
      ),
      _Run.preparing => const _RunText('Getting ready to download…'),
      _Run.finishing => const _RunText('Finishing up…'),
      _ => _DownloadingText(playlistId: playlistId),
    };
    return Column(
      key: const ValueKey('playlist-run-status'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 2, 16, 6), child: label),
        SizedBox(
          height: 2,
          child:
              run == _Run.downloading
                  ? _DownloadProgressBar(playlistId: playlistId)
                  : run == _Run.queued
                  ? const ColoredBox(color: Color(0xFF333333))
                  : const LinearProgressIndicator(
                    backgroundColor: Color(0xFF333333),
                    valueColor: AlwaysStoppedAnimation<Color>(_accent),
                    minHeight: 2,
                  ),
        ),
      ],
    );
  }
}

class _RunText extends StatelessWidget {
  const _RunText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        key: const ValueKey('playlist-run-text'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 13),
      ),
    );
  }
}

/// "Downloading 2 of 5 · Title"; rebuilds only when the track changes.
class _DownloadingText extends ConsumerWidget {
  const _DownloadingText({required this.playlistId});

  final int playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (index, total, title) = ref.watch(
      downloadProgressProvider.select((progress) {
        final value = progress.valueOrNull;
        if (value == null || value.playlistId != playlistId) {
          return (0, 0, null);
        }
        return (value.currentTrackIndex, value.totalTracks, value.currentTitle);
      }),
    );
    final parts = [
      total > 0 ? 'Downloading $index of $total' : 'Downloading',
      if (title != null && title.isNotEmpty) title,
    ];
    return _RunText(parts.join(' · '));
  }
}

/// The thin bar under the run status; the only widget that rebuilds on
/// every download progress event.
class _DownloadProgressBar extends ConsumerWidget {
  const _DownloadProgressBar({required this.playlistId});

  final int playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fraction = ref.watch(
      downloadProgressProvider.select((progress) {
        final value = progress.valueOrNull;
        return value != null && value.playlistId == playlistId
            ? value.overallFraction
            : 0.0;
      }),
    );
    return LinearProgressIndicator(
      key: const ValueKey('playlist-download-progress'),
      value: fraction,
      backgroundColor: const Color(0xFF333333),
      valueColor: const AlwaysStoppedAnimation<Color>(_accent),
      minHeight: 2,
    );
  }
}

/// A labelled on/off chip for one of the player-wide modes.
class _ModeChip extends ConsumerWidget {
  const _ModeChip({
    super.key,
    required this.provider,
    required this.defaultValue,
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.onToggle,
  });

  final ProviderListenable<AsyncValue<bool>> provider;
  final bool defaultValue;
  final String label;
  final IconData icon;
  final String Function(bool on) tooltip;

  /// Called with the value before the tap.
  final void Function(bool on) onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(provider).valueOrNull ?? defaultValue;
    // Compact round toggle: filled when on, so the state reads at a glance;
    // the label goes to screen readers and the tooltip.
    return Semantics(
      label: label,
      toggled: on,
      child: IconButton(
        icon: Icon(icon, size: 22),
        tooltip: tooltip(on),
        isSelected: on,
        onPressed: () => onToggle(on),
        style: IconButton.styleFrom(
          foregroundColor: const Color(0xFF9E9E9E),
          backgroundColor: Colors.transparent,
        ).copyWith(
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected)
                    ? Colors.white
                    : const Color(0xFF9E9E9E),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected)
                    ? _accent.withValues(alpha: 0.35)
                    : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

/// App-bar button for the Up next sheet, with a count badge. Only the
/// count is watched, so queue publishes do not rebuild the page.
class _UpNextButton extends ConsumerWidget {
  const _UpNextButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      upNextQueueProvider.select((queue) => queue.valueOrNull?.length ?? 0),
    );
    return IconButton(
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.queue_music),
          if (count > 0)
            Positioned(
              top: -5,
              right: -7,
              child: Container(
                constraints: const BoxConstraints(minWidth: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  count > 99 ? '99+' : count.toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
      tooltip: count == 0 ? 'Up next' : 'Up next ($count)',
      onPressed: () => showUpNextSheet(context),
    );
  }
}

/// Shows the tracks queued to play after the current song. Tap an entry
/// to play it now, drag the handle to reorder.
Future<void> showUpNextSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF2A2A2A),
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const _UpNextSheet(),
  );
}

class _UpNextSheet extends ConsumerStatefulWidget {
  const _UpNextSheet();

  @override
  ConsumerState<_UpNextSheet> createState() => _UpNextSheetState();
}

class _UpNextSheetState extends ConsumerState<_UpNextSheet> {
  /// The order just dropped, shown until the service publishes it, so a
  /// dragged entry never jumps back for a frame.
  List<Track>? _pendingOrder;
  List<Track>? _orderBeforeDrop;

  @override
  Widget build(BuildContext context) {
    final published =
        ref.watch(upNextQueueProvider).valueOrNull ?? const <Track>[];
    if (_pendingOrder != null && !identical(published, _orderBeforeDrop)) {
      _pendingOrder = null;
      _orderBeforeDrop = null;
    }
    final queue = _pendingOrder ?? published;
    final playlistNames = ref.watch(
      playlistsProvider.select(
        (playlists) => {
          for (final playlist in playlists.valueOrNull ?? const <Playlist>[])
            playlist.id: playlist.name,
        },
      ),
    );
    final playback = ref.read(playbackServiceProvider);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Up next',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        queue.isEmpty
                            ? 'These play after the current song'
                            : 'Tap to play now · drag ≡ to reorder',
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: queue.isEmpty ? null : playback.clearUpNextQueue,
                  child: const Text('Clear all'),
                ),
              ],
            ),
          ),
          if (queue.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 16, 24, 28),
              child: Text(
                'Nothing queued. Open a downloaded track’s ⋮ menu and '
                'choose Play next or Add to queue.',
                style: TextStyle(color: _muted),
                textAlign: TextAlign.center,
              ),
            )
          else
            Flexible(
              child: ReorderableListView.builder(
                key: const ValueKey('up-next-list'),
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: queue.length,
                onReorder: (from, to) {
                  // ReorderableListView reports the slot before removal.
                  if (to > from) to -= 1;
                  if (to == from) return;
                  final reordered = [...queue];
                  reordered.insert(to, reordered.removeAt(from));
                  setState(() {
                    _orderBeforeDrop = published;
                    _pendingOrder = reordered;
                  });
                  playback.moveUpNextQueue(from, to);
                },
                itemBuilder: (context, index) {
                  final track = queue[index];
                  final playlistName =
                      playlistNames[track.playlistId] ??
                      'Playlist #${track.playlistId}';
                  return Material(
                    key: ValueKey('up-next-$index-${track.id}'),
                    color: Colors.transparent,
                    child: ListTile(
                      contentPadding: const EdgeInsets.only(left: 4, right: 4),
                      leading: ReorderableDragStartListener(
                        index: index,
                        child: const SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(Icons.drag_handle, color: _muted),
                        ),
                      ),
                      title: Text(
                        track.title,
                        style: const TextStyle(color: Colors.white),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${index + 1}. $playlistName · #${track.index}',
                        style: const TextStyle(color: _muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(playback.playUpNextAt(index));
                      },
                      trailing: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        tooltip: 'Remove from Up next',
                        onPressed: () => playback.removeUpNextQueueAt(index),
                      ),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// The message of an error meant for the owner, without Dart's "Bad state:"
/// prefix.
String _errorText(Object error) =>
    error is StateError ? error.message : '$error';

/// Saves the video described by [entry] (`id`, `title`, and optionally
/// `thumbnail` and `duration`) to the temporary playlist and starts its
/// download, asking first on mobile data. Returns the message to show.
/// Providers are read before the first wait, so the download still starts
/// when the page that asked is gone.
Future<String> saveVideoToTemporary(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> entry,
) async {
  final playlists = ref.read(playlistServiceProvider);
  final downloads = ref.read(downloadServiceProvider);
  final policy = ref.read(downloadNetworkPolicyProvider);
  final settings = ref.read(appSettingsServiceProvider);
  final unavailable = ref.read(ytDlpInitErrorProvider);
  // Saving a video already downloaded as video would only make a copy.
  final copy = await ref
      .read(databaseProvider)
      .playlistWithVideoCopy(entry['id'] as String? ?? '');
  if (copy != null) {
    final title = entry['title'] as String? ?? 'This video';
    return '"$title" is already downloaded in ${copy.name}';
  }
  final saved = await playlists.addToTemporary(entry);
  final title = saved.track.title;
  if (!saved.added && saved.track.status == 'complete') {
    return '"$title" is already in Temporary';
  }
  final what =
      saved.added
          ? 'Saved "$title" to Temporary.'
          : '"$title" is in Temporary.';
  if (unavailable != null) {
    return '$what Downloads are unavailable: $unavailable';
  }
  DownloadNowChoice choice;
  try {
    choice =
        context.mounted
            ? await decideDownloadNow(
              context,
              policy,
              settings: settings,
              message: "You're on mobile data. Download it now?",
            )
            : await decideDownloadNowWithoutAsking(policy);
  } catch (_) {
    choice = DownloadNowChoice.later;
  }
  switch (choice) {
    case DownloadNowChoice.now:
      final waits =
          downloads.isDownloading &&
          downloads.activePlaylistId != saved.playlist.id;
      // A run of Temporary itself picks the new video up right after.
      unawaited(
        downloads
            .downloadPlaylist(saved.playlist, sourceChecked: false)
            .catchError((Object _) => DownloadStart.started),
      );
      return waits ? '$what It downloads after the current download.' : what;
    case DownloadNowChoice.later:
      return '$what Tap Update on it to download.';
    case DownloadNowChoice.offline:
      return "$what You're offline; tap Update on it later.";
  }
}

/// Removes the videos [trackIds] (all of them when null) of the temporary
/// playlist [playlistId] and deletes their files. What would keep writing to
/// them stops first: its chapter lookups and its download (a running one is
/// stopped and resumed afterwards for the videos left, see
/// [DownloadService.runWithDownloadStopped]). The player is told only once
/// the library is free, right before the files go. While another playlist
/// downloads nothing is touched. Returns an error message, or null when
/// they are gone.
Future<String?> removeTemporaryVideos(
  WidgetRef ref,
  int playlistId, [
  Set<int>? trackIds,
]) async {
  final downloads = ref.read(downloadServiceProvider);
  final playlists = ref.read(playlistServiceProvider);
  final playback = ref.read(playbackServiceProvider);
  final chapterJobs = ref.read(chapterFetchJobsProvider.notifier);
  Future<void> tellPlayer() async {
    try {
      if (trackIds == null) {
        await playback.playlistRemoved(playlistId);
      } else {
        await playback.tracksRemoved(trackIds);
      }
    } catch (_) {}
  }

  try {
    await downloads.runWithDownloadStopped(playlistId, () async {
      await chapterJobs.stop(playlistId);
      if (trackIds == null) {
        await playlists.clearPlaylist(playlistId, beforeDelete: tellPlayer);
      } else {
        await playlists.removeTracks(
          playlistId,
          trackIds,
          beforeDelete: tellPlayer,
        );
      }
    }, resume: trackIds != null);
  } on LibraryBusyException catch (e) {
    return e.message;
  } catch (e) {
    return 'Could not remove: ${_errorText(e)}';
  }
  return null;
}

/// Shows why nothing can be downloaded when yt-dlp failed to start, and
/// returns whether that is the case.
bool explainDownloadsUnavailable(BuildContext context, WidgetRef ref) {
  final reason = ref.read(ytDlpInitErrorProvider);
  if (reason == null) return false;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('Downloads are unavailable: $reason')));
  return true;
}

/// Refreshes [playlist] from YouTube, then starts downloading its new and
/// failed tracks and the replacements asked for.
///
/// When the refresh fails (no network, or the playlist was made private,
/// deleted or emptied on YouTube) the tracks already known are downloaded
/// anyway. Nothing starts while another library change is running. Returns
/// the playlist as the download got it, or null when nothing was started.
/// Shared by the home and playlist pages.
Future<Playlist?> syncAndDownloadPlaylist({
  required BuildContext context,
  required Playlist playlist,
  required PlaylistService playlists,
  required DownloadService downloads,
  required AppDatabase db,
}) async {
  void show(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // The caller's row may predate a rename or a format switch, and the sync
  // renames files inside the playlist's current folder.
  final current = await db.getPlaylist(playlist.id);
  SyncResult? result;
  try {
    // The temporary playlist has no YouTube playlist: its update only
    // downloads what is missing.
    if (!current.isTemporary) result = await playlists.syncPlaylist(current);
  } on SyncCancelledException {
    // The owner pressed Stop while YouTube was being asked: nothing changed
    // and nothing is downloaded.
    return null;
  } on LibraryBusyException catch (e) {
    show(e.message);
    return null;
  } catch (e) {
    show(
      "Couldn't refresh the playlist from YouTube; downloading the tracks "
      'already known.\n${friendlyDownloadError(_errorText(e))}',
    );
  }

  if (result != null && result.hasChanges) {
    final parts = <String>[];
    if (result.added > 0) parts.add('${result.added} new');
    if (result.markedUnavailable > 0) {
      parts.add('${result.markedUnavailable} unavailable');
    }
    if (result.removed > 0) parts.add('${result.removed} removed');
    if (result.markedAvailable > 0) {
      parts.add('${result.markedAvailable} restored');
    }
    show('Synced: ${parts.join(', ')}');
  }
  if (result != null && result.hasConflicts && context.mounted) {
    // Asked before the download starts, so the originals requested here
    // are downloaded by this same run.
    await _resolveReplacementConflicts(
      context,
      playlists,
      result.replacementConflicts,
    );
  }

  final fresh = await db.getPlaylist(playlist.id);
  // A service-level operation: it runs on even if the page was closed. A
  // playlist that has to wait for another download is queued at once.
  final start = downloads.downloadPlaylist(
    fresh,
    sourceChecked: result != null,
  );
  unawaited(
    start.then(
      (_) {},
      onError: (Object e, StackTrace _) {
        show('Download failed: ${friendlyDownloadError(_errorText(e))}');
      },
    ),
  );
  if (downloads.activePlaylistId != fresh.id &&
      downloads.queuedPlaylistIds.contains(fresh.id)) {
    show('Queued — starts after the current download');
  }
  return fresh;
}

/// Asks, for each local file whose YouTube video is back, whether to keep it
/// or get the original. A requested original is downloaded by the next
/// download run of the playlist.
Future<void> _resolveReplacementConflicts(
  BuildContext context,
  PlaylistService playlists,
  List<Track> conflicts,
) async {
  for (final track in conflicts) {
    if (!context.mounted) return;
    final decision = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text(
              'Video Available Again',
              style: TextStyle(color: Colors.white),
            ),
            content: Text(
              '"${track.title}" is available on YouTube again. You are using '
              'a local file for it.\n\n'
              'Download Original: the YouTube version downloads with this '
              'update and replaces your file only once it has finished. Your '
              "file is kept in the playlist's replaced-files folder "
              "(.woolytube_replaced). If YouTube can't provide the original, "
              'your file stays.',
              style: const TextStyle(color: Color(0xFFCCCCCC)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'keep'),
                child: const Text('Keep Replacement'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'download'),
                child: const Text('Download Original'),
              ),
            ],
          ),
    );
    if (decision != 'download') continue;
    try {
      await playlists.requestOriginalDownload(track);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not ask for the original of "${track.title}": '
            '${_errorText(e)}',
          ),
        ),
      );
    }
  }
}
