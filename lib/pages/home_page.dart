import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';
import '../database/database.dart';
import '../services/download_service.dart';
import '../services/metadata_service.dart';
import '../widgets/playlist_card.dart';
import 'add_playlist_page.dart';
import 'playlist_detail_page.dart';
import 'playlist_settings_page.dart';
import 'debug_log_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final Map<int, int> _downloadedCounts = {};
  final Map<int, int> _totalCounts = {};

  @override
  Widget build(BuildContext context) {
    final playlistsAsync = ref.watch(playlistsProvider);
    final downloadAsync = ref.watch(downloadProgressProvider);
    final downloadProgress =
        downloadAsync.valueOrNull ?? DownloadProgress.idle;
    final pendingImports = ref.watch(pendingImportsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'WoolyTube',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report, color: Color(0xFF888888), size: 20),
            tooltip: 'Debug Log',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DebugLogPage()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (pendingImports.isNotEmpty)
            _buildImportBanner(pendingImports),
          Expanded(
            child: playlistsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (playlists) {
                if (playlists.isEmpty && pendingImports.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.playlist_add,
                            size: 64, color: Color(0xFF555555)),
                        const SizedBox(height: 16),
                        const Text(
                          'No playlists yet',
                          style: TextStyle(color: Color(0xFF888888), fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Tap + to add your first playlist',
                          style: TextStyle(color: Color(0xFF666666), fontSize: 14),
                        ),
                      ],
                    ),
                  );
                }
                return _buildPlaylistGrid(playlists, downloadProgress);
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

  Widget _buildPlaylistGrid(
      List<Playlist> playlists, DownloadProgress downloadProgress) {
    _refreshCounts(playlists);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.75,
        ),
        itemCount: playlists.length,
        itemBuilder: (context, index) {
          final playlist = playlists[index];
          final isDownloading =
              downloadProgress.status == 'downloading' &&
                  downloadProgress.playlistId == playlist.id;

          return PlaylistCard(
            playlist: playlist,
            downloadedCount:
                _downloadedCounts[playlist.id] ?? 0,
            totalCount: _totalCounts[playlist.id] ?? 0,
            isDownloading: isDownloading,
            downloadProgress:
                isDownloading ? downloadProgress.trackProgress : 0,
            onTap: () => _navigateToDetail(context, playlist),
            onUpdate: () => _startUpdate(playlist),
            onSettings: () => _navigateToSettings(context, playlist),
          );
        },
      ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Synced: ${parts.join(', ')}')),
      );
    }

    if (result.hasConflicts && mounted) {
      await _showReplacementConflicts(result.replacementConflicts);
    }

    final freshPlaylist =
        await ref.read(databaseProvider).getPlaylist(playlist.id);
    downloadService.downloadPlaylist(freshPlaylist);
  }

  Future<void> _showReplacementConflicts(List<Track> conflicts) async {
    final db = ref.read(databaseProvider);
    for (final track in conflicts) {
      if (!mounted) return;
      final decision = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('Video Available Again',
              style: TextStyle(color: Colors.white)),
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
          const Icon(Icons.download_rounded, color: Color(0xFF2196F3), size: 24),
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
            onPressed: () =>
                ref.read(pendingImportsProvider.notifier).state = [],
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
                  borderRadius: BorderRadius.circular(8)),
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
              'Imported ${imports.length} playlist${imports.length == 1 ? '' : 's'}'),
        ),
      );
    }
  }

  void _navigateToAddPlaylist(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AddPlaylistPage()),
    );
  }

  void _navigateToDetail(BuildContext context, Playlist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => PlaylistDetailPage(playlistId: playlist.id)),
    );
  }

  void _navigateToSettings(BuildContext context, Playlist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => PlaylistSettingsPage(playlistId: playlist.id)),
    );
  }
}
