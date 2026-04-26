import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart'
    hide DownloadProgress;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../database/database.dart';
import '../providers/providers.dart';
import '../providers/playback_providers.dart';
import '../services/download_service.dart';
import '../services/metadata_service.dart';

class PlaylistDetailPage extends ConsumerStatefulWidget {
  final int playlistId;

  const PlaylistDetailPage({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  Playlist? _playlist;
  String _searchQuery = '';
  bool _showSearch = false;
  bool _isUpdating = false;

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
    final audioOnlyMode = ref.watch(audioOnlyModeProvider).valueOrNull ?? false;
    final isVideoPlaylist = _playlist?.audioOnly == false;
    final playbackService = ref.watch(playbackServiceProvider);
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

          final filteredTracks =
              _searchQuery.isEmpty
                  ? tracks
                  : tracks
                      .where(
                        (t) => t.title.toLowerCase().contains(
                          _searchQuery.toLowerCase(),
                        ),
                      )
                      .toList();

          final playableTracks =
              tracks.where((t) => t.status == 'complete').toList();

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

    final isUnavailable = track.status == 'unavailable';
    final hasLocalFile =
        track.status == 'complete' && track.unavailableReason != null;
    final hasError = track.status == 'error' && track.lastError != null;

    return ListTile(
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
      tileColor: isCurrentTrack ? const Color(0xFF2A2A2A) : Colors.transparent,
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
                    child: Icon(
                      Icons.play_arrow,
                      color: Colors.white70,
                      size: 24,
                    ),
                  ),
                ),
              // Now playing indicator
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
        hasError
            ? 'Download failed · ${_friendlyError(track.lastError!)}'
            : isUnavailable
            ? '${_unavailableLabel(track.unavailableReason)} · ${track.videoId}'
            : hasLocalFile
            ? '${_formatDuration(track.durationSeconds)} · ${_unavailableLabel(track.unavailableReason)} (local file)'
            : _formatDuration(track.durationSeconds),
        style: TextStyle(
          color:
              hasError
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
      trailing:
          isCurrentTrack
              ? Icon(
                isCurrentlyPlaying ? Icons.pause : Icons.play_arrow,
                color: const Color(0xFF2196F3),
                size: 20,
              )
              : _statusIcon(track.status, hasLocalFile: hasLocalFile),
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
        errorWidget:
            (_, __, ___) => Container(
              color: const Color(0xFF333333),
              child: const Icon(
                Icons.music_note,
                color: Color(0xFF555555),
                size: 24,
              ),
            ),
      );
    }
    return Container(
      color: const Color(0xFF333333),
      child: const Icon(Icons.music_note, color: Color(0xFF555555), size: 24),
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

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds == 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m}:${s.toString().padLeft(2, '0')}';
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

  void _showTrackActions(Track track) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      isScrollControlled: true,
      builder:
          (sheetContext) => SafeArea(
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
                  // Always: Copy video ID
                  ListTile(
                    leading: const Icon(Icons.copy, color: Colors.white70),
                    title: const Text(
                      'Copy video ID',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      track.videoId,
                      style: const TextStyle(color: Color(0xFF888888)),
                    ),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: track.videoId));
                      Navigator.pop(sheetContext);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Video ID copied')),
                      );
                    },
                  ),
                  // Always: Open on YouTube
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
                      launchUrl(
                        Uri.parse(
                          'https://www.youtube.com/watch?v=${track.videoId}',
                        ),
                      );
                    },
                  ),
                  // Unavailable: Search on quiteaplaylist.com
                  if (track.status == 'unavailable')
                    ListTile(
                      leading: const Icon(
                        Icons.travel_explore,
                        color: Colors.white70,
                      ),
                      title: const Text(
                        'Search on quiteaplaylist.com',
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        'Find this video in web archives',
                        style: TextStyle(color: Color(0xFF888888)),
                      ),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        launchUrl(
                          Uri.parse(
                            'https://quiteaplaylist.com/search?url=https://www.youtube.com/watch?v=${track.videoId}',
                          ),
                        );
                      },
                    ),
                  // Always: Pick local replacement
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
                  // Always: Override title / filename
                  ListTile(
                    leading: const Icon(Icons.edit, color: Colors.white70),
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
                  // Complete: Redownload
                  if (track.status == 'complete')
                    ListTile(
                      leading: const Icon(Icons.refresh, color: Colors.white70),
                      title: const Text(
                        'Redownload',
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        'Delete file and re-download from YouTube',
                        style: TextStyle(color: Color(0xFF888888)),
                      ),
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        await _redownloadTrack(track);
                      },
                    ),
                  // Error: Show details
                  if (track.status == 'error' && track.lastError != null)
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
                  // Error: Retry download
                  if (track.status == 'error')
                    ListTile(
                      leading: const Icon(Icons.replay, color: Colors.white70),
                      title: const Text(
                        'Retry download',
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        'Reset and queue for download',
                        style: TextStyle(color: Color(0xFF888888)),
                      ),
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        final db = ref.read(databaseProvider);
                        await db.resetTrackForRedownload(track.id);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Queued "${track.title}" for download',
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  const SizedBox(height: 8),
                ],
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
          'm4a', 'mp3', 'opus', 'ogg', 'flac', 'wav',
          'mp4', 'mkv', 'webm', 'avi', 'mov',
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

    final db = ref.read(databaseProvider);
    final totalTracks = await db.getTotalTrackCount(_playlist!.id);
    final indexStr = MetadataService.paddedIndex(track.index, totalTracks);

    final ext = p.extension(picked.name);
    final base = p.basenameWithoutExtension(picked.name);
    final sanitized = MetadataService.sanitizeFilename(base);
    final newName = '${indexStr}_$sanitized$ext';
    final newPath = p.join(_playlist!.outputPath, newName);

    // Remove any existing file for this track's index prefix.
    final existing = MetadataService.resolveMediaFile(
      _playlist!.outputPath,
      '${indexStr}_',
    );
    if (existing != null && existing != newPath) {
      try {
        await File(existing).delete();
      } catch (_) {
        // Non-fatal — the copy below may still overwrite it.
      }
    }

    try {
      await File(sourcePath).copy(newPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Copy failed: $e')));
      }
      return;
    }

    await db.updateTrackStatus(
      track.id,
      'complete',
      filePath: newPath,
      isLocalReplacement: true,
    );

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Replaced with $newName')));
    }
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
                TextField(
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
                TextField(
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
                  final db = ref.read(databaseProvider);
                  await db.resetTrackForRedownload(track.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Queued "${track.title}" for download'),
                      ),
                    );
                  }
                },
                child: const Text('Retry'),
              ),
            ],
          ),
    );
  }

  Future<void> _redownloadTrack(Track track) async {
    // Delete the existing file on disk
    if (track.filePath != null) {
      final file = File(track.filePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }

    // Reset track in database
    final db = ref.read(databaseProvider);
    await db.resetTrackForRedownload(track.id);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued "${track.title}" for re-download')),
      );
    }
  }
}
