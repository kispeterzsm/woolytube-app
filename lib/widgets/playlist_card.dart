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
    return SizedBox(
      height: 96,
      child: Material(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(aspectRatio: 16 / 9, child: _buildThumbnail()),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 4, 2),
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
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Expanded(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    _subtitle(),
                                    style: const TextStyle(
                                      color: Color(0xFF888888),
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                  ),
                                ),
                              ),
                              _iconButton(
                                icon:
                                    isDownloading
                                        ? Icons.hourglass_top
                                        : Icons.sync,
                                tooltip:
                                    isDownloading
                                        ? 'Downloading playlist'
                                        : 'Update playlist',
                                onTap: isDownloading ? null : onUpdate,
                              ),
                              _iconButton(
                                icon: Icons.settings,
                                tooltip: 'Playlist settings',
                                onTap: onSettings,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (isDownloading)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(
                    value: downloadProgress / 100.0,
                    minHeight: 4,
                    backgroundColor: const Color(0xFF333333),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF2196F3),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    if (playlist.thumbnailUrl != null && playlist.thumbnailUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: playlist.thumbnailUrl!,
        fit: BoxFit.contain,
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
      parts.add('$downloadedCount/$totalCount');
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

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        icon: Icon(icon, size: 26),
        color: const Color(0xFF888888),
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        onPressed: onTap,
      ),
    );
  }
}
