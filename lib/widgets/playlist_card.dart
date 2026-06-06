import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../database/database.dart';

class PlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final int downloadedCount;
  final int totalCount;
  final bool isDownloading;
  final double downloadProgress;
  final VoidCallback onTap;
  final VoidCallback onUpdate;
  final VoidCallback onSettings;

  const PlaylistCard({
    super.key,
    required this.playlist,
    required this.downloadedCount,
    required this.totalCount,
    required this.isDownloading,
    required this.downloadProgress,
    required this.onTap,
    required this.onUpdate,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _buildThumbnail(),
            ),
            if (isDownloading)
              LinearProgressIndicator(
                value: downloadProgress / 100.0,
                minHeight: 3,
                backgroundColor: const Color(0xFF333333),
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF2196F3)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          playlist.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(),
                          style: const TextStyle(
                            color: Color(0xFF888888),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _iconButton(
                    icon: isDownloading ? Icons.hourglass_top : Icons.sync,
                    onTap: isDownloading ? null : onUpdate,
                  ),
                  _iconButton(
                    icon: Icons.settings,
                    onTap: onSettings,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    if (playlist.thumbnailUrl != null && playlist.thumbnailUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: playlist.thumbnailUrl!,
        fit: BoxFit.cover,
        placeholder: (_, __) => _placeholderBox(),
        errorWidget: (_, __, ___) => _placeholderBox(),
      );
    }
    return _placeholderBox();
  }

  Widget _placeholderBox() {
    return Container(
      color: const Color(0xFF333333),
      child: const Center(
        child: Icon(Icons.playlist_play, color: Color(0xFF555555), size: 48),
      ),
    );
  }

  String _subtitle() {
    if (isDownloading) {
      return 'Downloading $downloadedCount / $totalCount';
    }
    if (totalCount > 0) {
      final parts = <String>[];
      parts.add('$downloadedCount / $totalCount');
      if (playlist.lastUpdated != null) {
        parts.add(_timeAgo(playlist.lastUpdated!));
      }
      return parts.join(' · ');
    }
    if (playlist.lastUpdated != null) {
      return _timeAgo(playlist.lastUpdated!);
    }
    return 'Not yet synced';
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}';
  }

  Widget _iconButton({required IconData icon, VoidCallback? onTap}) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        icon: Icon(icon, size: 18),
        color: const Color(0xFF888888),
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }
}
