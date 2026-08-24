import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart'
    hide DownloadProgress;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';
import '../providers/playback_providers.dart';
import '../database/database.dart';
import '../services/download_service.dart';
import '../services/media_thumbnail_service.dart';
import '../services/metadata_service.dart';
import '../services/update_service.dart';
import '../widgets/playlist_card.dart';
import '../widgets/mobile_data_download_guard.dart';
import 'add_playlist_page.dart';
import 'playlist_detail_page.dart';
import 'playlist_settings_page.dart';
import 'debug_log_page.dart';
import 'settings_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final Map<int, int> _downloadedCounts = {};
  final Map<int, int> _totalCounts = {};
  String _searchQuery = '';
  bool _showSearch = false;
  AppUpdate? _availableUpdate;
  Future<void>? _updateCheck;
  bool _isCheckingForUpdate = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkForUpdate());
  }

  @override
  Widget build(BuildContext context) {
    final playlistsAsync = ref.watch(playlistsProvider);
    final allTracksAsync =
        _showSearch
            ? ref.watch(allTracksProvider)
            : const AsyncValue<List<Track>>.data([]);
    final currentTrack =
        _showSearch ? ref.watch(currentTrackProvider).valueOrNull : null;
    final isPlaying =
        _showSearch ? ref.watch(isPlayingProvider).valueOrNull ?? false : false;
    final downloadAsync = ref.watch(downloadProgressProvider);
    final downloadProgress = downloadAsync.valueOrNull ?? DownloadProgress.idle;
    final pendingImports = ref.watch(pendingImportsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'WoolyTube',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _showSearch ? Icons.search_off : Icons.search,
              color: _showSearch ? const Color(0xFF2196F3) : Colors.white,
            ),
            tooltip: _showSearch ? 'Close search' : 'Search tracks',
            onPressed: () {
              setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) _searchQuery = '';
              });
            },
          ),
          IconButton(
            icon: Icon(
              Icons.settings,
              color:
                  _availableUpdate == null
                      ? const Color(0xFF888888)
                      : const Color(0xFF2196F3),
              size: 20,
            ),
            tooltip:
                _availableUpdate != null
                    ? 'Settings — update to ${_availableUpdate!.version} available'
                    : _isCheckingForUpdate
                    ? 'Settings — checking for updates'
                    : 'Settings',
            onPressed: _navigateToAppSettings,
          ),
          IconButton(
            icon: const Icon(
              Icons.bug_report,
              color: Color(0xFF888888),
              size: 20,
            ),
            tooltip: 'Debug Log',
            onPressed:
                () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const DebugLogPage())),
          ),
        ],
      ),
      body: Column(
        children: [
          if (pendingImports.isNotEmpty) _buildImportBanner(pendingImports),
          if (_showSearch)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search tracks...',
                  prefixIcon: Icon(Icons.search, color: Color(0xFF888888)),
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                style: const TextStyle(color: Colors.white),
                onChanged: (query) => setState(() => _searchQuery = query),
              ),
            ),
          Expanded(
            child:
                _showSearch
                    ? _buildTrackSearchResults(
                      playlistsAsync,
                      allTracksAsync,
                      currentTrack: currentTrack,
                      isPlaying: isPlaying,
                    )
                    : playlistsAsync.when(
                      loading:
                          () =>
                              const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(child: Text('Error: $e')),
                      data: (playlists) {
                        if (playlists.isEmpty && pendingImports.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.playlist_add,
                                  size: 64,
                                  color: Color(0xFF555555),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'No playlists yet',
                                  style: TextStyle(
                                    color: Color(0xFF888888),
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Tap + to add your first playlist',
                                  style: TextStyle(
                                    color: Color(0xFF666666),
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return _buildPlaylistList(playlists, downloadProgress);
                      },
                    ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _navigateToAddPlaylist(context),
        backgroundColor: const Color(0xFF2196F3),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildTrackSearchResults(
    AsyncValue<List<Playlist>> playlistsAsync,
    AsyncValue<List<Track>> allTracksAsync, {
    required Track? currentTrack,
    required bool isPlaying,
  }) {
    return playlistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data:
          (playlists) => allTracksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (tracks) {
              final normalizedQuery = _searchQuery.trim().toLowerCase();
              final filteredTracks =
                  normalizedQuery.isEmpty
                      ? tracks
                      : tracks
                          .where(
                            (track) =>
                                _matchesTrackSearch(track, normalizedQuery),
                          )
                          .toList();

              if (tracks.isEmpty) {
                return const Center(
                  child: Text(
                    'No tracks yet. Sync a playlist to fetch them.',
                    style: TextStyle(color: Color(0xFF888888)),
                    textAlign: TextAlign.center,
                  ),
                );
              }

              if (filteredTracks.isEmpty) {
                return const Center(
                  child: Text(
                    'No matching tracks',
                    style: TextStyle(color: Color(0xFF888888)),
                  ),
                );
              }

              final playlistsById = {
                for (final playlist in playlists) playlist.id: playlist,
              };
              final tracksByPlaylistId = <int, List<Track>>{};
              for (final track in tracks) {
                tracksByPlaylistId
                    .putIfAbsent(track.playlistId, () => [])
                    .add(track);
              }

              return ValueListenableBuilder<double>(
                valueListenable: audioPlayerOverlayHeightNotifier,
                builder:
                    (context, overlayHeight, _) => ListView.builder(
                      padding: EdgeInsets.only(bottom: overlayHeight),
                      itemCount: filteredTracks.length,
                      itemBuilder: (context, index) {
                        final track = filteredTracks[index];
                        final playlist = playlistsById[track.playlistId];
                        final playlistTracks =
                            tracksByPlaylistId[track.playlistId] ?? const [];
                        final isCurrentTrack = currentTrack?.id == track.id;
                        return _buildSearchTrackTile(
                          track,
                          playlist: playlist,
                          playlistTracks: playlistTracks,
                          isCurrentTrack: isCurrentTrack,
                          isCurrentlyPlaying: isCurrentTrack && isPlaying,
                        );
                      },
                    ),
              );
            },
          ),
    );
  }

  Widget _buildSearchTrackTile(
    Track track, {
    required Playlist? playlist,
    required List<Track> playlistTracks,
    required bool isCurrentTrack,
    required bool isCurrentlyPlaying,
  }) {
    final isPlayable = track.status == 'complete';
    final isUnavailable = track.status == 'unavailable';
    final hasLocalFile =
        track.status == 'complete' && track.unavailableReason != null;
    final hasError = track.status == 'error' && track.lastError != null;
    final details = _searchTrackDetails(
      track,
      hasError: hasError,
      isUnavailable: isUnavailable,
      hasLocalFile: hasLocalFile,
    );
    final playlistName = playlist?.name ?? 'Playlist #${track.playlistId}';
    final subtitle =
        details.isEmpty ? playlistName : '$playlistName · $details';
    final thumbnailWidth =
        MediaQuery.sizeOf(context).width < 360 ? 96.0 : 112.0;

    return Material(
      color: isCurrentTrack ? const Color(0xFF2A2A2A) : Colors.transparent,
      child: InkWell(
        onTap:
            isPlayable && playlist != null
                ? () {
                  ref
                      .read(playbackServiceProvider)
                      .playTrack(track, playlistTracks, playlist: playlist);
                }
                : null,
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
                        _buildSearchTrackThumbnail(track),
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
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color:
                            hasError || isUnavailable
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
                          : _searchTrackStatusIcon(
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

  Widget _buildSearchTrackThumbnail(Track track) {
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
              errorWidget: (_, __, ___) => _searchThumbnailPlaceholder(),
            )
            : _searchThumbnailPlaceholder();
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

  Widget _searchThumbnailPlaceholder() {
    return Container(
      color: const Color(0xFF333333),
      child: const Icon(Icons.music_note, color: Color(0xFF555555), size: 24),
    );
  }

  Widget _searchTrackStatusIcon(String status, {bool hasLocalFile = false}) {
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

  String _searchTrackDetails(
    Track track, {
    required bool hasError,
    required bool isUnavailable,
    required bool hasLocalFile,
  }) {
    if (hasError) return 'Download failed';
    if (isUnavailable) return _unavailableLabel(track.unavailableReason);
    if (hasLocalFile) {
      return '${_unavailableLabel(track.unavailableReason)} (local file)';
    }
    return _formatDuration(track.durationSeconds);
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds == 0) return '';
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
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

  Future<void> _checkForUpdate() {
    final existingCheck = _updateCheck;
    if (existingCheck != null) return existingCheck;

    final check = _performUpdateCheck();
    _updateCheck = check;
    unawaited(
      check.whenComplete(() {
        if (identical(_updateCheck, check)) {
          _updateCheck = null;
        }
      }),
    );
    return check;
  }

  Future<void> _performUpdateCheck() async {
    if (mounted) {
      setState(() => _isCheckingForUpdate = true);
    }

    try {
      final update = await ref.read(updateServiceProvider).checkForUpdate();
      if (!mounted) return;
      setState(() => _availableUpdate = update);
    } catch (e) {
      ref.read(logServiceProvider).warn('update check failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isCheckingForUpdate = false);
      }
    }
  }

  Widget _buildPlaylistList(
    List<Playlist> playlists,
    DownloadProgress downloadProgress,
  ) {
    _refreshCounts(playlists);

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: playlists.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        final isDownloading =
            downloadProgress.status == 'downloading' &&
            downloadProgress.playlistId == playlist.id;

        return PlaylistCard(
          playlist: playlist,
          downloadedCount: _downloadedCounts[playlist.id] ?? 0,
          totalCount: _totalCounts[playlist.id] ?? 0,
          isDownloading: isDownloading,
          downloadProgress: isDownloading ? downloadProgress.trackProgress : 0,
          onTap: () => _navigateToDetail(context, playlist),
          onUpdate: () => _startUpdate(playlist),
          onSettings: () => _navigateToSettings(context, playlist),
        );
      },
    );
  }

  void _refreshCounts(List<Playlist> playlists) {
    final service = ref.read(playlistServiceProvider);
    for (final playlist in playlists) {
      service.getDownloadedCount(playlist.id).then((count) {
        if (mounted && _downloadedCounts[playlist.id] != count) {
          setState(() => _downloadedCounts[playlist.id] = count);
        }
      });
      service.getTotalCount(playlist.id).then((count) {
        if (mounted && _totalCounts[playlist.id] != count) {
          setState(() => _totalCounts[playlist.id] = count);
        }
      });
    }
  }

  void _startUpdate(Playlist playlist) async {
    final downloadService = ref.read(downloadServiceProvider);
    if (downloadService.isDownloading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A download is already in progress')),
      );
      return;
    }

    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      return;
    }

    // Sync first to detect new, unavailable, and removed tracks
    final playlistService = ref.read(playlistServiceProvider);
    final result = await playlistService.syncPlaylist(playlist);

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
        .getPlaylist(playlist.id);
    downloadService.downloadPlaylist(freshPlaylist);
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

  Widget _buildImportBanner(List<DiscoveredPlaylist> imports) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E3A5F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2196F3), width: 0.5),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.download_rounded,
            color: Color(0xFF2196F3),
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Found ${imports.length} playlist${imports.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'From a previous installation',
                  style: TextStyle(color: Color(0xFFAABBCC), fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed:
                () => ref.read(pendingImportsProvider.notifier).state = [],
            child: const Text(
              'Dismiss',
              style: TextStyle(color: Color(0xFF888888), fontSize: 13),
            ),
          ),
          const SizedBox(width: 4),
          ElevatedButton(
            onPressed: () => _importAll(imports),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2196F3),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Import All', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _importAll(List<DiscoveredPlaylist> imports) async {
    final metadata = ref.read(metadataServiceProvider);
    for (final discovered in imports) {
      await metadata.importPlaylist(discovered);
    }
    ref.read(pendingImportsProvider.notifier).state = [];
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${imports.length} playlist${imports.length == 1 ? '' : 's'}',
          ),
        ),
      );
    }
  }

  void _navigateToAddPlaylist(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AddPlaylistPage()));
  }

  void _navigateToDetail(BuildContext context, Playlist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(playlistId: playlist.id),
      ),
    );
  }

  void _navigateToSettings(BuildContext context, Playlist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistSettingsPage(playlistId: playlist.id),
      ),
    );
  }

  void _navigateToAppSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => SettingsPage(
              initialUpdate: _availableUpdate,
              onUpdateChanged: (update) {
                if (mounted) setState(() => _availableUpdate = update);
              },
            ),
      ),
    );
  }
}
