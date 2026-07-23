import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart'
    hide DownloadProgress;
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../database/database.dart';
import '../providers/providers.dart';
import '../providers/playback_providers.dart';
import '../services/download_service.dart';
import '../services/metadata_service.dart';
import '../services/media_thumbnail_service.dart';
import '../services/sponsorblock_service.dart';
import '../widgets/tap_to_place_cursor_text_field.dart';

enum _TrackActionGroup { youtube, storage, playback }

class PlaylistDetailPage extends ConsumerStatefulWidget {
  final int playlistId;

  const PlaylistDetailPage({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  static const _followScrollDuration = Duration(milliseconds: 250);

  Playlist? _playlist;
  String _searchQuery = '';
  bool _showSearch = false;
  bool _isUpdating = false;
  final ScrollController _trackListController = ScrollController();
  final Map<int, GlobalKey> _trackTileKeys = {};
  int? _lastFollowedTrackId;
  int _followRequest = 0;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
  }

  Future<void> _loadPlaylist() async {
    final db = ref.read(databaseProvider);
    final playlist = await db.getPlaylist(widget.playlistId);
    await ref.read(metadataServiceProvider).reconcilePlaylist(playlist);
    if (mounted) setState(() => _playlist = playlist);
    unawaited(_backfillLocalThumbnails(playlist.id));
  }

  Future<void> _backfillLocalThumbnails(int playlistId) async {
    try {
      await ref
          .read(playlistServiceProvider)
          .backfillLocalThumbnails(playlistId);
    } catch (_) {
      // Embedded artwork is optional and should never block the playlist UI.
    }
  }

  @override
  void dispose() {
    _trackListController.dispose();
    super.dispose();
  }

  GlobalKey _trackTileKey(int trackId) {
    return _trackTileKeys.putIfAbsent(
      trackId,
      () => GlobalKey(debugLabel: 'playlist-track-$trackId'),
    );
  }

  /// Keeps the currently playing item visible when playback advances while
  /// this playlist is open behind the audio controls.
  void _followCurrentTrack(Track? track, List<Track> visibleTracks) {
    if (track == null || track.playlistId != widget.playlistId) return;

    final targetIndex = visibleTracks.indexWhere((item) => item.id == track.id);
    if (targetIndex == -1 || _lastFollowedTrackId == track.id) return;

    _lastFollowedTrackId = track.id;
    final request = ++_followRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _scrollToTrack(track.id, targetIndex, visibleTracks.length, request),
      );
    });
  }

  Future<void> _scrollToTrack(
    int trackId,
    int targetIndex,
    int trackCount,
    int request,
  ) async {
    if (!mounted ||
        request != _followRequest ||
        !_trackListController.hasClients) {
      return;
    }

    final key = _trackTileKeys[trackId];
    final targetContext = key?.currentContext;
    if (targetContext != null) {
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0.4,
        duration: _followScrollDuration,
        curve: Curves.easeOut,
      );
      return;
    }

    final position = _trackListController.position;
    final averageTrackExtent =
        (position.maxScrollExtent + position.viewportDimension) / trackCount;
    final targetOffset =
        ((targetIndex + 0.5) * averageTrackExtent -
                (position.viewportDimension * 0.4))
            .clamp(0.0, position.maxScrollExtent)
            .toDouble();

    await _trackListController.animateTo(
      targetOffset,
      duration: _followScrollDuration,
      curve: Curves.easeOut,
    );

    if (!mounted || request != _followRequest) return;
    final refinedTargetContext = key?.currentContext;
    if (refinedTargetContext == null || !refinedTargetContext.mounted) return;
    await Scrollable.ensureVisible(
      refinedTargetContext,
      alignment: 0.4,
      duration: _followScrollDuration,
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tracksAsync = ref.watch(tracksProvider(widget.playlistId));
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;
    final isPlaying = ref.watch(isPlayingProvider).valueOrNull ?? false;
    final shuffleEnabled =
        ref.watch(shuffleEnabledProvider).valueOrNull ?? false;
    final autoplayEnabled =
        ref.watch(autoplayEnabledProvider).valueOrNull ?? true;
    final audioOnlyMode = ref.watch(audioOnlyModeProvider).valueOrNull ?? false;
    final isVideoPlaylist = _playlist?.audioOnly == false;
    final playbackService = ref.watch(playbackServiceProvider);
    final upNextQueue = ref.watch(upNextQueueProvider).valueOrNull ?? const [];
    final downloadProgress =
        ref.watch(downloadProgressProvider).valueOrNull ??
        DownloadProgress.idle;
    final isDownloadingThis =
        downloadProgress.status == 'downloading' &&
        downloadProgress.playlistId == widget.playlistId;

    return Scaffold(
      appBar: AppBar(
        title: Text(_playlist?.name ?? 'Playlist'),
        actions: [
          IconButton(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.queue_music),
                if (upNextQueue.isNotEmpty)
                  Positioned(
                    top: -5,
                    right: -7,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2196F3),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        upNextQueue.length > 99
                            ? '99+'
                            : upNextQueue.length.toString(),
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
            tooltip:
                upNextQueue.isEmpty
                    ? 'Up next queue'
                    : 'Up next queue (${upNextQueue.length})',
            onPressed: _showUpNextQueue,
          ),
          IconButton(
            icon: Icon(
              _showSearch ? Icons.search_off : Icons.search,
              color: _showSearch ? const Color(0xFF2196F3) : Colors.white,
            ),
            onPressed: () {
              setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) _searchQuery = '';
              });
            },
          ),
        ],
      ),
      body: tracksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (tracks) {
          if (tracks.isEmpty) {
            return const Center(
              child: Text(
                'No tracks yet. Tap sync on the home page to fetch them.',
                style: TextStyle(color: Color(0xFF888888)),
                textAlign: TextAlign.center,
              ),
            );
          }

          final normalizedSearchQuery = _searchQuery.trim().toLowerCase();
          final filteredTracks =
              normalizedSearchQuery.isEmpty
                  ? tracks
                  : tracks
                      .where(
                        (t) => _matchesTrackSearch(t, normalizedSearchQuery),
                      )
                      .toList();

          final playableTracks =
              tracks
                  .where(
                    (track) => track.status == 'complete' && !track.alwaysSkip,
                  )
                  .toList();

          _followCurrentTrack(currentTrack, filteredTracks);

          return Column(
            children: [
              // Search bar
              if (_showSearch)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search tracks...',
                      prefixIcon: Icon(Icons.search, color: Color(0xFF888888)),
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                    style: const TextStyle(color: Colors.white),
                    onChanged: (q) => setState(() => _searchQuery = q),
                  ),
                ),
              // Download progress
              if (isDownloadingThis)
                LinearProgressIndicator(
                  value: downloadProgress.trackProgress / 100,
                  backgroundColor: const Color(0xFF333333),
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFF2196F3),
                  ),
                  minHeight: 2,
                ),
              // Controls row
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    // Play all
                    if (playableTracks.isNotEmpty)
                      TextButton.icon(
                        onPressed: () {
                          playbackService.playAll(tracks, playlist: _playlist);
                        },
                        icon: const Icon(Icons.play_arrow, size: 20),
                        label: const Text('Play all'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF2196F3),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    // Sync & download
                    TextButton.icon(
                      onPressed:
                          (_isUpdating || isDownloadingThis)
                              ? null
                              : _startUpdate,
                      icon: Icon(
                        _isUpdating ? Icons.hourglass_top : Icons.sync,
                        size: 20,
                      ),
                      label: Text(
                        isDownloadingThis
                            ? '${downloadProgress.currentTrackIndex}/${downloadProgress.totalTracks}'
                            : 'Update',
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor:
                            (_isUpdating || isDownloadingThis)
                                ? const Color(0xFF888888)
                                : const Color(0xFF2196F3),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                    const Spacer(),
                    // Audio-only toggle (video playlists only)
                    if (isVideoPlaylist) ...[
                      IconButton(
                        icon: Icon(
                          audioOnlyMode ? Icons.videocam_off : Icons.videocam,
                          color:
                              audioOnlyMode
                                  ? const Color(0xFF2196F3)
                                  : const Color(0xFF888888),
                          size: 22,
                        ),
                        onPressed: playbackService.toggleAudioOnlyMode,
                        tooltip: audioOnlyMode ? 'Audio only' : 'Play video',
                        constraints: const BoxConstraints(minWidth: 36),
                        padding: EdgeInsets.zero,
                      ),
                      const SizedBox(width: 4),
                    ],
                    // Shuffle toggle
                    IconButton(
                      icon: Icon(
                        Icons.shuffle,
                        color:
                            shuffleEnabled
                                ? const Color(0xFF2196F3)
                                : const Color(0xFF888888),
                        size: 20,
                      ),
                      onPressed: playbackService.toggleShuffle,
                      tooltip: 'Shuffle',
                      constraints: const BoxConstraints(minWidth: 36),
                      padding: EdgeInsets.zero,
                    ),
                    const SizedBox(width: 4),
                    // Autoplay toggle
                    IconButton(
                      icon: Icon(
                        Icons.playlist_play,
                        color:
                            autoplayEnabled
                                ? const Color(0xFF2196F3)
                                : const Color(0xFF888888),
                        size: 24,
                      ),
                      onPressed: playbackService.toggleAutoplay,
                      tooltip: autoplayEnabled ? 'Autoplay on' : 'Autoplay off',
                      constraints: const BoxConstraints(minWidth: 36),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFF333333)),
              // Track list
              Expanded(
                child: ValueListenableBuilder<double>(
                  valueListenable: audioPlayerOverlayHeightNotifier,
                  builder:
                      (context, overlayHeight, _) => ListView.builder(
                        controller: _trackListController,
                        padding: EdgeInsets.only(bottom: overlayHeight),
                        itemCount: filteredTracks.length,
                        itemBuilder: (context, index) {
                          final track = filteredTracks[index];
                          final isCurrentTrack = currentTrack?.id == track.id;
                          return KeyedSubtree(
                            key: _trackTileKey(track.id),
                            child: _buildTrackTile(
                              track,
                              isCurrentTrack: isCurrentTrack,
                              isCurrentlyPlaying: isCurrentTrack && isPlaying,
                              allTracks: tracks,
                            ),
                          );
                        },
                      ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTrackTile(
    Track track, {
    required bool isCurrentTrack,
    required bool isCurrentlyPlaying,
    required List<Track> allTracks,
  }) {
    final isPlayable = track.status == 'complete';
    final playbackService = ref.watch(playbackServiceProvider);

    final isUnavailable = track.status == 'unavailable';
    final hasLocalFile =
        track.status == 'complete' && track.unavailableReason != null;
    final hasError = track.status == 'error' && track.lastError != null;
    final trackSubtitle = _trackSubtitle(
      track,
      hasError: hasError,
      isUnavailable: isUnavailable,
      hasLocalFile: hasLocalFile,
    );
    final subtitle =
        track.alwaysSkip
            ? trackSubtitle.isEmpty
                ? 'Always skip'
                : 'Always skip · $trackSubtitle'
            : trackSubtitle;
    final thumbnailWidth =
        MediaQuery.sizeOf(context).width < 360 ? 96.0 : 112.0;

    return Material(
      color: isCurrentTrack ? const Color(0xFF2A2A2A) : Colors.transparent,
      child: InkWell(
        onTap:
            isPlayable
                ? () {
                  playbackService.playTrack(
                    track,
                    allTracks,
                    playlist: _playlist,
                  );
                }
                : null,
        onLongPress: () => _showTrackActions(track),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 32,
                child: Text(
                  track.index.toString(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color:
                        isCurrentTrack
                            ? const Color(0xFF2196F3)
                            : const Color(0xFF888888),
                    fontSize: 13,
                    fontWeight:
                        isCurrentTrack ? FontWeight.w600 : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: thumbnailWidth,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildTrackThumbnail(track),
                        if (isCurrentlyPlaying)
                          Container(
                            color: Colors.black38,
                            child: const Center(
                              child: Icon(
                                Icons.equalizer,
                                color: Color(0xFF2196F3),
                                size: 24,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      track.title,
                      style: TextStyle(
                        color:
                            isCurrentTrack
                                ? const Color(0xFF2196F3)
                                : Colors.white,
                        fontSize: 14,
                        fontWeight:
                            isCurrentTrack
                                ? FontWeight.w600
                                : FontWeight.normal,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color:
                              track.alwaysSkip
                                  ? const Color(0xFFE57373)
                                  : hasError
                                  ? const Color(0xFFAA6666)
                                  : isUnavailable
                                  ? const Color(0xFFAA6666)
                                  : hasLocalFile
                                  ? const Color(0xFFAAAA66)
                                  : const Color(0xFF888888),
                          fontSize: 12,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 24,
                child: Center(
                  child:
                      isCurrentTrack
                          ? Icon(
                            isCurrentlyPlaying ? Icons.pause : Icons.play_arrow,
                            color: const Color(0xFF2196F3),
                            size: 20,
                          )
                          : _statusIcon(
                            track.status,
                            hasLocalFile: hasLocalFile,
                          ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrackThumbnail(Track track) {
    final url = resolveRemoteThumbnailUrl(
      thumbnailUrl: track.thumbnailUrl,
      youtubeVideoId: track.videoId,
    );
    final fallback =
        url != null
            ? CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: const Color(0xFF333333)),
              errorWidget: (_, __, ___) => _thumbnailPlaceholder(),
            )
            : _thumbnailPlaceholder();
    final localPath = existingThumbnailPath(track.thumbnailPath);
    if (localPath != null) {
      return Image.file(
        File(localPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      );
    }
    return fallback;
  }

  Widget _thumbnailPlaceholder() {
    return Container(
      color: const Color(0xFF333333),
      child: const Icon(Icons.music_note, color: Color(0xFF555555), size: 24),
    );
  }

  String _videoUrl(Track track) =>
      'https://www.youtube.com/watch?v=${track.videoId}';

  Future<void> _shareTrack(Track track) async {
    try {
      await SharePlus.instance.share(
        ShareParams(uri: Uri.parse(_videoUrl(track)), title: track.title),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    }
  }

  Widget _statusIcon(String status, {bool hasLocalFile = false}) {
    switch (status) {
      case 'complete':
        return Icon(
          hasLocalFile ? Icons.check_circle_outline : Icons.check_circle,
          color: hasLocalFile ? const Color(0xFFAAAA66) : Colors.green,
          size: 20,
        );
      case 'downloading':
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case 'error':
        return const Icon(Icons.error, color: Colors.red, size: 20);
      case 'unavailable':
        return const Icon(Icons.block, color: Color(0xFF888888), size: 20);
      default:
        return const Icon(Icons.download, color: Color(0xFF555555), size: 20);
    }
  }

  bool _matchesTrackSearch(Track track, String query) {
    final index = track.index.toString();
    return track.title.toLowerCase().contains(query) ||
        index.contains(query) ||
        '#$index'.contains(query);
  }

  String _trackSubtitle(
    Track track, {
    required bool hasError,
    required bool isUnavailable,
    required bool hasLocalFile,
  }) {
    if (hasError) {
      return 'Download failed · ${_friendlyError(track.lastError!)}';
    }
    if (isUnavailable) {
      return '${_unavailableLabel(track.unavailableReason)} · ${track.videoId}';
    }
    if (hasLocalFile) {
      final duration = _formatDuration(track.durationSeconds);
      final localLabel =
          '${_unavailableLabel(track.unavailableReason)} (local file)';
      return duration.isEmpty ? localLabel : '$duration · $localLabel';
    }
    return _formatDuration(track.durationSeconds);
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds == 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _friendlyError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('confirm your age') ||
        lower.contains('sign in to confirm') ||
        lower.contains('age-restricted')) {
      return 'Age-restricted — needs sign-in';
    }
    if (lower.contains('private video')) return 'Private video';
    if (lower.contains('members-only') || lower.contains('members only')) {
      return 'Members-only video';
    }
    if (lower.contains('premium')) return 'YouTube Premium only';
    if (lower.contains('http error 403') ||
        lower.contains('rate-limit') ||
        lower.contains(' 429')) {
      return 'Blocked by YouTube (rate-limited)';
    }
    if (lower.contains('geo') && lower.contains('restrict')) {
      return 'Geo-restricted';
    }
    if (lower.contains('live event')) return 'Live event, not downloadable';
    if (lower.contains('video unavailable') ||
        lower.contains('this video is not available')) {
      return 'Video unavailable';
    }
    if (lower.contains('network') || lower.contains('connection')) {
      return 'Network error';
    }
    // Fallback: first line, truncated.
    final firstLine = raw.split('\n').first.trim();
    if (firstLine.length > 120) {
      return '${firstLine.substring(0, 120)}...';
    }
    return firstLine;
  }

  bool _isAgeGateError(String raw) {
    final lower = raw.toLowerCase();
    return lower.contains('confirm your age') ||
        lower.contains('sign in to confirm') ||
        lower.contains('age-restricted');
  }

  String _unavailableLabel(String? reason) {
    switch (reason) {
      case 'private':
        return 'Private video';
      case 'deleted':
        return 'Deleted video';
      case 'removed':
        return 'Removed from playlist';
      case 'needs_auth':
        return 'Requires authentication';
      case 'premium_only':
        return 'Premium only';
      default:
        return 'Unavailable';
    }
  }

  Future<void> _startUpdate() async {
    if (_playlist == null) return;

    final downloadService = ref.read(downloadServiceProvider);
    if (downloadService.isDownloading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A download is already in progress')),
      );
      return;
    }

    setState(() => _isUpdating = true);

    try {
      final playlistService = ref.read(playlistServiceProvider);
      final result = await playlistService.syncPlaylist(_playlist!);

      if (result.hasChanges && mounted) {
        final parts = <String>[];
        if (result.added > 0) parts.add('${result.added} new');
        if (result.markedUnavailable > 0) {
          parts.add('${result.markedUnavailable} unavailable');
        }
        if (result.removed > 0) parts.add('${result.removed} removed');
        if (result.markedAvailable > 0) {
          parts.add('${result.markedAvailable} restored');
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Synced: ${parts.join(', ')}')));
      }

      if (result.hasConflicts && mounted) {
        await _showReplacementConflicts(result.replacementConflicts);
      }

      final freshPlaylist = await ref
          .read(databaseProvider)
          .getPlaylist(widget.playlistId);
      setState(() => _playlist = freshPlaylist);
      downloadService.downloadPlaylist(freshPlaylist);
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _showReplacementConflicts(List<Track> conflicts) async {
    final db = ref.read(databaseProvider);
    for (final track in conflicts) {
      if (!mounted) return;
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
                '"${track.title}" is available on YouTube again.\n\n'
                'You have a local replacement file. '
                'Would you like to keep it or download the original?',
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
      if (decision == 'download') {
        await db.resetTrackForRedownload(track.id);
      }
    }
  }

  Future<void> _showUpNextQueue() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      builder:
          (sheetContext) => Consumer(
            builder: (context, ref, _) {
              final queue =
                  ref.watch(upNextQueueProvider).valueOrNull ?? const <Track>[];
              final playlists =
                  ref.watch(playlistsProvider).valueOrNull ??
                  const <Playlist>[];
              final playlistNames = {
                for (final playlist in playlists) playlist.id: playlist.name,
              };
              final playbackService = ref.read(playbackServiceProvider);

              return SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Up next',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed:
                                queue.isEmpty
                                    ? null
                                    : playbackService.clearUpNextQueue,
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    ),
                    if (queue.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(24, 16, 24, 28),
                        child: Text(
                          'Long-press a downloaded track and choose Add to queue.',
                          style: TextStyle(color: Color(0xFF888888)),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.65,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: queue.length,
                          separatorBuilder:
                              (_, __) => const Divider(
                                height: 1,
                                color: Color(0xFF383838),
                              ),
                          itemBuilder: (context, index) {
                            final track = queue[index];
                            final playlistName =
                                playlistNames[track.playlistId] ??
                                'Playlist #${track.playlistId}';
                            return ListTile(
                              key: ValueKey('up-next-$index-${track.id}'),
                              leading: const Icon(
                                Icons.queue_music,
                                color: Color(0xFF64B5F6),
                              ),
                              title: Text(
                                track.title,
                                style: const TextStyle(color: Colors.white),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '$playlistName · #${track.index}',
                                style: const TextStyle(
                                  color: Color(0xFF888888),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white70,
                                ),
                                tooltip: 'Remove from queue',
                                onPressed:
                                    () => playbackService.removeUpNextQueueAt(
                                      index,
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
            },
          ),
    );
  }

  void _showTrackActions(Track track) {
    final canAddToQueue =
        track.status == 'complete' &&
        track.filePath != null &&
        !track.alwaysSkip;
    _TrackActionGroup? selectedGroup;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      isScrollControlled: true,
      builder:
          (sheetContext) => StatefulBuilder(
            builder:
                (sheetContext, setSheetState) => SafeArea(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            track.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        ListTile(
                          leading: const Icon(
                            Icons.queue_music,
                            color: Color(0xFF64B5F6),
                          ),
                          title: const Text(
                            'Add to queue',
                            style: TextStyle(color: Colors.white),
                          ),
                          subtitle: Text(
                            track.alwaysSkip
                                ? 'Turn off Always skip before queueing this track'
                                : canAddToQueue
                                ? 'Play only this track after the current one'
                                : 'Download this track before adding it to the queue',
                            style: const TextStyle(color: Color(0xFF888888)),
                          ),
                          enabled: canAddToQueue,
                          onTap:
                              canAddToQueue
                                  ? () async {
                                    Navigator.pop(sheetContext);
                                    final playbackService = ref.read(
                                      playbackServiceProvider,
                                    );
                                    final added = await playbackService
                                        .addToUpNextQueue(track);
                                    if (!mounted) return;
                                    if (!added) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'That track cannot be added to the queue',
                                          ),
                                        ),
                                      );
                                      return;
                                    }
                                    final started =
                                        await playbackService
                                            .startUpNextQueueIfIdle();
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          started
                                              ? 'Added to queue and started playback'
                                              : 'Added to queue',
                                        ),
                                      ),
                                    );
                                  }
                                  : null,
                        ),
                        const Divider(height: 1, color: Color(0xFF3A3A3A)),
                        if (selectedGroup == null) ...[
                          ListTile(
                            key: const ValueKey('track-actions-group-youtube'),
                            leading: const Icon(
                              Icons.smart_display,
                              color: Color(0xFFE57373),
                            ),
                            title: const Text(
                              'YouTube',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Links, video ID, sharing, and archives',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.white70,
                            ),
                            onTap:
                                () => setSheetState(
                                  () =>
                                      selectedGroup = _TrackActionGroup.youtube,
                                ),
                          ),
                          ListTile(
                            key: const ValueKey('track-actions-group-storage'),
                            leading: const Icon(
                              Icons.folder,
                              color: Color(0xFFFFB74D),
                            ),
                            title: const Text(
                              'Storage',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Local files, naming, and downloads',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.white70,
                            ),
                            onTap:
                                () => setSheetState(
                                  () =>
                                      selectedGroup = _TrackActionGroup.storage,
                                ),
                          ),
                          ListTile(
                            key: const ValueKey('track-actions-group-playback'),
                            leading: const Icon(
                              Icons.tune,
                              color: Color(0xFF64B5F6),
                            ),
                            title: const Text(
                              'Playback settings',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Skip segments and automatic skipping',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.white70,
                            ),
                            onTap:
                                () => setSheetState(
                                  () =>
                                      selectedGroup =
                                          _TrackActionGroup.playback,
                                ),
                          ),
                        ] else
                          ListTile(
                            key: const ValueKey('track-actions-groups-back'),
                            leading: const Icon(
                              Icons.arrow_back,
                              color: Colors.white70,
                            ),
                            title: Text(
                              selectedGroup == _TrackActionGroup.youtube
                                  ? 'YouTube'
                                  : selectedGroup == _TrackActionGroup.storage
                                  ? 'Storage'
                                  : 'Playback settings',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: const Text(
                              'Back to action groups',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            onTap:
                                () => setSheetState(() => selectedGroup = null),
                          ),
                        if (selectedGroup == _TrackActionGroup.playback)
                          ListTile(
                            leading: Icon(
                              track.alwaysSkip
                                  ? Icons.play_arrow
                                  : Icons.skip_next,
                              color:
                                  track.alwaysSkip
                                      ? const Color(0xFF64B5F6)
                                      : const Color(0xFFE57373),
                            ),
                            title: Text(
                              track.alwaysSkip
                                  ? 'Stop always skipping'
                                  : 'Always skip',
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              track.alwaysSkip
                                  ? 'Allow this track during automatic playback again'
                                  : 'Skip it during autoplay and shuffle; tap it directly to play',
                              style: const TextStyle(color: Color(0xFF888888)),
                            ),
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await ref
                                  .read(playbackServiceProvider)
                                  .setAlwaysSkip(track, !track.alwaysSkip);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    track.alwaysSkip
                                        ? 'Always skip turned off'
                                        : 'This track will be skipped automatically',
                                  ),
                                ),
                              );
                            },
                          ),
                        if (selectedGroup == _TrackActionGroup.youtube)
                          ListTile(
                            leading: const Icon(
                              Icons.open_in_new,
                              color: Colors.white70,
                            ),
                            title: const Text(
                              'Open on YouTube',
                              style: TextStyle(color: Colors.white),
                            ),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              launchUrl(Uri.parse(_videoUrl(track)));
                            },
                          ),
                        if (selectedGroup == _TrackActionGroup.youtube)
                          ListTile(
                            leading: const Icon(
                              Icons.copy,
                              color: Colors.white70,
                            ),
                            title: const Text(
                              'Copy ID',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              track.videoId,
                              style: const TextStyle(color: Color(0xFF888888)),
                            ),
                            onTap: () {
                              Clipboard.setData(
                                ClipboardData(text: track.videoId),
                              );
                              Navigator.pop(sheetContext);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Video ID copied'),
                                ),
                              );
                            },
                          ),
                        if (selectedGroup == _TrackActionGroup.youtube)
                          ListTile(
                            leading: const Icon(
                              Icons.share,
                              color: Colors.white70,
                            ),
                            title: const Text(
                              'Share',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Share original YouTube link',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await _shareTrack(track);
                            },
                          ),
                        if (selectedGroup == _TrackActionGroup.youtube)
                          ListTile(
                            key: const ValueKey(
                              'track-actions-find-quietaplaylist',
                            ),
                            leading: const Icon(
                              Icons.travel_explore,
                              color: Colors.white70,
                            ),
                            title: const Text(
                              'Find on quiteaplaylist',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Find this video in web archives',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              launchUrl(
                                Uri.https('quiteaplaylist.com', '/search', {
                                  'url': _videoUrl(track),
                                }),
                              );
                            },
                          ),
                        if (selectedGroup == _TrackActionGroup.storage)
                          ListTile(
                            leading: const Icon(
                              Icons.file_upload,
                              color: Colors.white70,
                            ),
                            title: const Text(
                              'Pick local replacement',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Choose a video/audio file from your device',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await _pickLocalReplacement(track);
                            },
                          ),
                        if (selectedGroup == _TrackActionGroup.playback)
                          ListTile(
                            leading: const Icon(
                              Icons.bookmarks,
                              color: Colors.white70,
                            ),
                            title: const Text(
                              'Skip segments',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'View, edit, hide, or delete skip segments',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await _showSkipSegments(track);
                            },
                          ),
                        if (selectedGroup == _TrackActionGroup.storage)
                          ListTile(
                            leading: const Icon(
                              Icons.edit,
                              color: Colors.white70,
                            ),
                            title: const Text(
                              'Override title / filename',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Edit the stored title or on-disk name',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await _showOverrideDialog(track);
                            },
                          ),
                        if (selectedGroup == _TrackActionGroup.storage)
                          ListTile(
                            leading: const Icon(
                              Icons.refresh,
                              color: Colors.white70,
                            ),
                            title: const Text(
                              'Redownload',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Clear local state and download from YouTube',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await _redownloadTrack(track);
                            },
                          ),
                        if (selectedGroup == _TrackActionGroup.storage &&
                            track.status == 'error' &&
                            track.lastError != null)
                          ListTile(
                            leading: const Icon(
                              Icons.error_outline,
                              color: Colors.white70,
                            ),
                            title: const Text(
                              'Show error details',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              _friendlyError(track.lastError!),
                              style: const TextStyle(color: Color(0xFFAA6666)),
                            ),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _showErrorDetails(track);
                            },
                          ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
          ),
    );
  }

  Future<void> _pickLocalReplacement(Track track) async {
    if (_playlist == null) return;

    final dir = Directory(_playlist!.outputPath);
    if (!dir.existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Playlist folder not found')),
        );
      }
      return;
    }

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'm4a',
          'mp3',
          'opus',
          'ogg',
          'flac',
          'wav',
          'mp4',
          'mkv',
          'webm',
          'avi',
          'mov',
        ],
        withData: false,
      );
    } catch (_) {
      // Some platforms reject FileType.custom — fall back to any file.
      result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
      );
    }
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    final sourcePath = picked.path;
    if (sourcePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not access picked file')),
        );
      }
      return;
    }

    try {
      final updated = await ref
          .read(playlistServiceProvider)
          .replaceWithLocalFile(
            trackId: track.id,
            sourcePath: sourcePath,
            sourceFileName: picked.name,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Replaced with ${p.basename(updated.filePath!)}'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Copy failed: $e')));
      }
    }
  }

  Future<void> _showSkipSegments(Track track) async {
    final db = ref.read(databaseProvider);
    var segments = await db.getSegmentsForTrack(track.id);

    Future<void> reload(StateSetter setSheetState) async {
      final updated = await db.getSegmentsForTrack(track.id);
      setSheetState(() => segments = updated);
      await ref.read(playbackServiceProvider).refreshCurrentSegments();
    }

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      isScrollControlled: true,
      builder:
          (sheetContext) => StatefulBuilder(
            builder:
                (context, setSheetState) => SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Skip segments',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (segments.isEmpty)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
                            child: Text(
                              'No skip segments cached for this track.',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                          )
                        else
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.of(context).size.height * 0.65,
                            ),
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                for (final segment in segments)
                                  ListTile(
                                    leading: _segmentColorSwatch(segment),
                                    title: Text(
                                      sponsorBlockCategoryLabels[segment
                                              .category] ??
                                          segment.category,
                                      style: TextStyle(
                                        color:
                                            segment.source == 'hidden'
                                                ? const Color(0xFF888888)
                                                : Colors.white,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${_sourceLabel(segment.source)} - ${_formatMs(segment.startMs)} - ${_formatMs(segment.endMs)}',
                                      style: const TextStyle(
                                        color: Color(0xFF888888),
                                      ),
                                    ),
                                    trailing: Wrap(
                                      spacing: 4,
                                      children: [
                                        IconButton(
                                          icon: const Icon(
                                            Icons.edit,
                                            color: Colors.white70,
                                          ),
                                          tooltip: 'Edit segment',
                                          onPressed: () async {
                                            final changed =
                                                await _showSegmentEditDialog(
                                                  track,
                                                  segment,
                                                );
                                            if (changed && mounted) {
                                              await reload(setSheetState);
                                            }
                                          },
                                        ),
                                        if (segment.source == 'hidden')
                                          IconButton(
                                            icon: const Icon(
                                              Icons.restore,
                                              color: Color(0xFF2196F3),
                                            ),
                                            tooltip: 'Restore segment',
                                            onPressed: () async {
                                              await db.updateSegment(
                                                segment.id,
                                                source: 'sponsorblock',
                                              );
                                              await reload(setSheetState);
                                            },
                                          )
                                        else
                                          IconButton(
                                            icon: const Icon(
                                              Icons.delete,
                                              color: Colors.redAccent,
                                            ),
                                            tooltip:
                                                segment.source == 'local'
                                                    ? 'Delete segment'
                                                    : 'Hide segment',
                                            onPressed: () async {
                                              if (segment.source == 'local' ||
                                                  segment.uuid == null) {
                                                await db.deleteSegment(
                                                  segment.id,
                                                );
                                              } else {
                                                await db.updateSegment(
                                                  segment.id,
                                                  source: 'hidden',
                                                );
                                              }
                                              await reload(setSheetState);
                                            },
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
          ),
    );
  }

  Widget _segmentColorSwatch(SponsorBlockSegment segment) {
    final colorValue =
        sponsorBlockCategoryColors[segment.category] ?? 0xFF888888;
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: Color(
          colorValue,
        ).withValues(alpha: segment.source == 'hidden' ? 0.35 : 1),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: const Color(0xFF555555)),
      ),
    );
  }

  String _sourceLabel(String source) => switch (source) {
    'sponsorblock' => 'SponsorBlock',
    'override' => 'Edited',
    'hidden' => 'Hidden',
    'local' => 'Local',
    _ => source,
  };

  Future<bool> _showSegmentEditDialog(
    Track track,
    SponsorBlockSegment segment,
  ) async {
    final db = ref.read(databaseProvider);
    var category =
        isSponsorBlockCategory(segment.category) ? segment.category : 'sponsor';
    final startController = TextEditingController(
      text: _formatMs(segment.startMs),
    );
    final endController = TextEditingController(text: _formatMs(segment.endMs));
    String? error;

    final saved = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  backgroundColor: const Color(0xFF2A2A2A),
                  title: const Text(
                    'Edit skip segment',
                    style: TextStyle(color: Colors.white),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DropdownButtonFormField<String>(
                        value: category,
                        dropdownColor: const Color(0xFF2A2A2A),
                        decoration: const InputDecoration(
                          labelText: 'Category',
                          labelStyle: TextStyle(color: Color(0xFF888888)),
                        ),
                        style: const TextStyle(color: Colors.white),
                        items:
                            sponsorBlockCategoryDefinitions
                                .map(
                                  (definition) => DropdownMenuItem(
                                    value: definition.id,
                                    child: Text(definition.label),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            (value) => setDialogState(() {
                              if (value != null) category = value;
                            }),
                      ),
                      TextField(
                        controller: startController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Start',
                          labelStyle: TextStyle(color: Color(0xFF888888)),
                        ),
                      ),
                      TextField(
                        controller: endController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'End',
                          labelStyle: TextStyle(color: Color(0xFF888888)),
                        ),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          error!,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ],
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final startMs = _parseTimestampMs(startController.text);
                        final endMs = _parseTimestampMs(endController.text);
                        if (startMs == null || endMs == null) {
                          setDialogState(() => error = 'Use mm:ss or seconds');
                          return;
                        }
                        if (endMs <= startMs) {
                          setDialogState(
                            () => error = 'End must be after start',
                          );
                          return;
                        }
                        if (segment.source == 'sponsorblock' ||
                            segment.source == 'hidden') {
                          await db.deleteSegment(segment.id);
                          await db.insertSegment(
                            SponsorBlockSegmentsCompanion.insert(
                              trackId: track.id,
                              videoId: track.videoId,
                              source: 'override',
                              uuid: Value(segment.uuid),
                              category: category,
                              actionType: Value(segment.actionType),
                              startMs: startMs,
                              endMs: endMs,
                              votes: Value(segment.votes),
                              locked: Value(segment.locked),
                              description: Value(segment.description),
                              createdAt: DateTime.now(),
                            ),
                          );
                        } else {
                          await db.updateSegment(
                            segment.id,
                            category: category,
                            startMs: startMs,
                            endMs: endMs,
                            source:
                                segment.source == 'local'
                                    ? 'local'
                                    : 'override',
                          );
                        }
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, true);
                        }
                      },
                      child: const Text('Save'),
                    ),
                  ],
                ),
          ),
    );
    startController.dispose();
    endController.dispose();
    return saved == true;
  }

  int? _parseTimestampMs(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final seconds = double.tryParse(value);
    if (seconds != null) return (seconds * 1000).round();

    final parts = value.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    var totalSeconds = 0;
    for (final part in parts) {
      final parsed = int.tryParse(part);
      if (parsed == null || parsed < 0) return null;
      totalSeconds = totalSeconds * 60 + parsed;
    }
    return totalSeconds * 1000;
  }

  String _formatMs(int ms) {
    final duration = Duration(milliseconds: ms);
    final h = duration.inHours;
    final m = duration.inMinutes % 60;
    final s = duration.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _showOverrideDialog(Track track) async {
    if (_playlist == null) return;

    final currentFile = track.filePath != null ? File(track.filePath!) : null;
    final hasFile = currentFile != null && currentFile.existsSync();
    final currentBasename =
        hasFile ? p.basenameWithoutExtension(currentFile.path) : '';
    // Strip leading "<digits>_" so the field shows just the editable portion.
    final nameWithoutPrefix = currentBasename.replaceFirst(
      RegExp(r'^\d+_'),
      '',
    );

    final titleController = TextEditingController(text: track.title);
    final filenameController = TextEditingController(
      text: hasFile ? nameWithoutPrefix : '',
    );

    final saved = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text(
              'Override',
              style: TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TapToPlaceCursorTextField(
                  controller: titleController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Title',
                    labelStyle: const TextStyle(color: Color(0xFF888888)),
                    hintText: track.title,
                    hintStyle: const TextStyle(color: Color(0xFF555555)),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TapToPlaceCursorTextField(
                  controller: filenameController,
                  enabled: hasFile,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Filename',
                    labelStyle: const TextStyle(color: Color(0xFF888888)),
                    hintText: hasFile ? nameWithoutPrefix : 'No file on disk',
                    hintStyle: const TextStyle(color: Color(0xFF555555)),
                    helperText:
                        hasFile
                            ? 'Index prefix and extension stay the same'
                            : null,
                    helperStyle: const TextStyle(color: Color(0xFF666666)),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Color(0xFF888888)),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'Save',
                  style: TextStyle(color: Color(0xFF4A9EFF)),
                ),
              ),
            ],
          ),
    );

    if (saved != true) return;

    final db = ref.read(databaseProvider);
    final newTitle = titleController.text.trim();
    final newFilename = filenameController.text.trim();

    var titleChanged = false;
    var fileChanged = false;
    String? newPath;

    if (newTitle.isNotEmpty && newTitle != track.title) {
      titleChanged = true;
    }

    if (hasFile && newFilename.isNotEmpty && newFilename != nameWithoutPrefix) {
      final ext = p.extension(currentFile.path);
      final prefixMatch = RegExp(
        r'^(\d+_)',
      ).firstMatch(p.basename(currentFile.path));
      final prefix = prefixMatch?.group(1) ?? '';
      final sanitized = MetadataService.sanitizeFilename(newFilename);
      final newName = '$prefix$sanitized$ext';
      newPath = p.join(p.dirname(currentFile.path), newName);
      if (newPath != currentFile.path) {
        if (File(newPath).existsSync()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('A file with that name already exists'),
              ),
            );
          }
          return;
        }
        try {
          await currentFile.rename(newPath);
          fileChanged = true;
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Rename failed: $e')));
          }
          return;
        }
      }
    }

    if (titleChanged || fileChanged) {
      await db.updateTrackFields(
        track.id,
        title: titleChanged ? newTitle : null,
        filePath: fileChanged ? newPath : null,
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            titleChanged || fileChanged ? 'Override saved' : 'No changes',
          ),
        ),
      );
    }
  }

  Future<void> _showErrorDetails(Track track) async {
    final raw = track.lastError ?? '';
    final isAgeGate = _isAgeGateError(raw);

    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: Row(
              children: [
                const Icon(Icons.error_outline, color: Color(0xFFAA6666)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _friendlyError(raw),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      raw,
                      style: const TextStyle(
                        color: Color(0xFFCCCCCC),
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (isAgeGate) ...[
                      const SizedBox(height: 16),
                      const Divider(color: Color(0xFF444444), height: 1),
                      const SizedBox(height: 12),
                      const Text(
                        'This video requires a signed-in session to confirm age. '
                        'WoolyTube automatically tries to bypass this using '
                        "YouTube's TV client, but this particular video can't be "
                        'fetched without cookies from a logged-in browser.',
                        style: TextStyle(
                          color: Color(0xFFAAAAAA),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _startTrackDownload(track);
                },
                child: const Text('Retry'),
              ),
            ],
          ),
    );
  }

  Future<void> _startTrackDownload(
    Track track, {
    bool deleteExistingFile = false,
  }) async {
    if (_playlist == null) return;

    final downloadService = ref.read(downloadServiceProvider);
    if (downloadService.isDownloading) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A download is already in progress')),
        );
      }
      return;
    }

    if (deleteExistingFile && track.filePath != null) {
      final file = File(track.filePath!);
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        }
        return;
      }
    }

    final playlist = _playlist!;
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Downloading "${track.title}"')));
    }

    unawaited(
      downloadService
          .downloadTrack(playlist, track)
          .then(
            (_) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Downloaded "${track.title}"')),
              );
            },
            onError: (Object e, StackTrace _) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Download failed: ${_friendlyError('$e')}'),
                ),
              );
            },
          ),
    );
  }

  Future<void> _redownloadTrack(Track track) async {
    await _startTrackDownload(track, deleteExistingFile: true);
  }
}
