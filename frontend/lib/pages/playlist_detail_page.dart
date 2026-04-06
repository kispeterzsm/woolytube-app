import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../database/database.dart';
import '../providers/providers.dart';
import '../providers/playback_providers.dart';

class PlaylistDetailPage extends ConsumerStatefulWidget {
  final int playlistId;

  const PlaylistDetailPage({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistDetailPage> createState() =>
      _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  Playlist? _playlist;
  String _searchQuery = '';
  bool _showSearch = false;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
  }

  Future<void> _loadPlaylist() async {
    final db = ref.read(databaseProvider);
    final playlist = await db.getPlaylist(widget.playlistId);
    setState(() => _playlist = playlist);
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
    final playbackService = ref.watch(playbackServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_playlist?.name ?? 'Playlist'),
        actions: [
          IconButton(
            icon: Icon(
              _showSearch ? Icons.search_off : Icons.search,
              color: _showSearch
                  ? const Color(0xFF2196F3)
                  : Colors.white,
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

          final filteredTracks = _searchQuery.isEmpty
              ? tracks
              : tracks
                  .where((t) => t.title
                      .toLowerCase()
                      .contains(_searchQuery.toLowerCase()))
                  .toList();

          final playableTracks =
              tracks.where((t) => t.status == 'complete').toList();

          return Column(
            children: [
              // Search bar
              if (_showSearch)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search tracks...',
                      prefixIcon:
                          Icon(Icons.search, color: Color(0xFF888888)),
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                    style: const TextStyle(color: Colors.white),
                    onChanged: (q) => setState(() => _searchQuery = q),
                  ),
                ),
              // Controls row
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    // Play all
                    if (playableTracks.isNotEmpty)
                      TextButton.icon(
                        onPressed: () {
                          playbackService.playTrack(
                            playableTracks.first,
                            tracks,
                            playlist: _playlist,
                          );
                        },
                        icon: const Icon(Icons.play_arrow, size: 20),
                        label: const Text('Play all'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF2196F3),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    const Spacer(),
                    // Shuffle toggle
                    IconButton(
                      icon: Icon(
                        Icons.shuffle,
                        color: shuffleEnabled
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
                        color: autoplayEnabled
                            ? const Color(0xFF2196F3)
                            : const Color(0xFF888888),
                        size: 24,
                      ),
                      onPressed: playbackService.toggleAutoplay,
                      tooltip:
                          autoplayEnabled ? 'Autoplay on' : 'Autoplay off',
                      constraints: const BoxConstraints(minWidth: 36),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFF333333)),
              // Track list
              Expanded(
                child: ListView.builder(
                  itemCount: filteredTracks.length,
                  itemBuilder: (context, index) {
                    final track = filteredTracks[index];
                    final isCurrentTrack = currentTrack?.id == track.id;
                    return _buildTrackTile(
                      track,
                      isCurrentTrack: isCurrentTrack,
                      isCurrentlyPlaying: isCurrentTrack && isPlaying,
                      allTracks: tracks,
                    );
                  },
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

    return ListTile(
      onTap: isPlayable
          ? () {
              playbackService.playTrack(track, allTracks, playlist: _playlist);
            }
          : null,
      tileColor:
          isCurrentTrack ? const Color(0xFF2A2A2A) : Colors.transparent,
      leading: SizedBox(
        width: 64,
        height: 48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildTrackThumbnail(track),
              // Play overlay for playable tracks
              if (isPlayable && !isCurrentTrack)
                Container(
                  color: Colors.black26,
                  child: const Center(
                    child: Icon(Icons.play_arrow,
                        color: Colors.white70, size: 24),
                  ),
                ),
              // Now playing indicator
              if (isCurrentlyPlaying)
                Container(
                  color: Colors.black38,
                  child: const Center(
                    child: Icon(Icons.equalizer,
                        color: Color(0xFF2196F3), size: 24),
                  ),
                ),
            ],
          ),
        ),
      ),
      title: Text(
        track.title,
        style: TextStyle(
          color: isCurrentTrack ? const Color(0xFF2196F3) : Colors.white,
          fontSize: 14,
          fontWeight: isCurrentTrack ? FontWeight.w600 : FontWeight.normal,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _formatDuration(track.durationSeconds),
        style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
      ),
      trailing: isCurrentTrack
          ? Icon(
              isCurrentlyPlaying ? Icons.pause : Icons.play_arrow,
              color: const Color(0xFF2196F3),
              size: 20,
            )
          : _statusIcon(track.status),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }

  Widget _buildTrackThumbnail(Track track) {
    final url = _trackThumbnailUrl(track);
    if (url != null) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(color: const Color(0xFF333333)),
        errorWidget: (_, __, ___) => Container(
          color: const Color(0xFF333333),
          child: const Icon(Icons.music_note,
              color: Color(0xFF555555), size: 24),
        ),
      );
    }
    return Container(
      color: const Color(0xFF333333),
      child:
          const Icon(Icons.music_note, color: Color(0xFF555555), size: 24),
    );
  }

  /// Get thumbnail URL with YouTube fallback from video ID
  String? _trackThumbnailUrl(Track track) {
    if (track.thumbnailUrl != null && track.thumbnailUrl!.isNotEmpty) {
      return track.thumbnailUrl;
    }
    if (track.videoId.isNotEmpty) {
      return 'https://i.ytimg.com/vi/${track.videoId}/hqdefault.jpg';
    }
    return null;
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case 'complete':
        return const Icon(Icons.check_circle, color: Colors.green, size: 20);
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

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds == 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m}:${s.toString().padLeft(2, '0')}';
  }
}
