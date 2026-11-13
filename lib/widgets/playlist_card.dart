import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database/database.dart';
import '../services/media_thumbnail_service.dart';
import '../services/playlist_summary.dart';

/// What a playlist is busy with, as its card shows it.
enum PlaylistCardActivity {
  idle,

  /// Asking YouTube for new videos (before the download).
  syncing,

  /// Waiting for another playlist's download to finish.
  queued,

  /// The download is getting ready (checking files, choosing tracks).
  preparing,

  /// Tracks are being downloaded.
  downloading,

  /// Writing metadata and the like after the last track.
  finishing,
}

/// One playlist on the home page: cover, name, a short status, and two
/// buttons, "Update now" and "Playlist settings". A long press opens a menu
/// with the same actions plus "Reorder playlists" and "Open on YouTube".
class PlaylistCard extends StatelessWidget {
  final Playlist playlist;

  /// Null while the counts are loading, or when the playlist has no tracks
  /// (see [countsLoaded]).
  final PlaylistCounts? counts;
  final bool countsLoaded;
  final PlaylistCardActivity activity;

  /// While downloading: the position of the current track in this run, and
  /// how many tracks the run downloads.
  final int runIndex;
  final int runTotal;

  /// Progress of the whole run, 0 to 1, shown as a bar while downloading.
  final double progress;

  /// The playing (or paused) track belongs to this playlist.
  final bool isNowPlaying;
  final bool isPlaying;

  final VoidCallback onTap;
  final VoidCallback onUpdate;
  final VoidCallback onSettings;

  /// Stops this playlist's download.
  final VoidCallback? onCancel;
  final VoidCallback? onOpenOnYouTube;

  /// Opens the page that changes the order of the playlists.
  final VoidCallback? onReorder;

  const PlaylistCard({
    super.key,
    required this.playlist,
    this.counts,
    this.countsLoaded = true,
    this.activity = PlaylistCardActivity.idle,
    this.runIndex = 0,
    this.runTotal = 0,
    this.progress = 0,
    this.isNowPlaying = false,
    this.isPlaying = false,
    required this.onTap,
    required this.onUpdate,
    required this.onSettings,
    this.onCancel,
    this.onOpenOnYouTube,
    this.onReorder,
  });

  static const _surface = Color(0xFF2A2A2A);
  static const _accent = Color(0xFF2196F3);
  static const _muted = Color(0xFF999999);
  static const _iconColor = Color(0xFFCCCCCC);

  bool get _isDownloadRun =>
      activity == PlaylistCardActivity.preparing ||
      activity == PlaylistCardActivity.downloading ||
      activity == PlaylistCardActivity.finishing;

  bool get _isBusy => activity != PlaylistCardActivity.idle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _showMenu(context),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final coverWidth = constraints.maxWidth < 380 ? 112.0 : 136.0;
            return Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
                  child: Row(
                    children: [
                      _buildCover(context, coverWidth),
                      const SizedBox(width: 12),
                      Expanded(child: _buildText()),
                      _buildActions(),
                    ],
                  ),
                ),
                if (_isBusy && activity != PlaylistCardActivity.queued)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      key: const ValueKey('playlist-card-progress'),
                      value:
                          activity == PlaylistCardActivity.downloading
                              ? progress.clamp(0.0, 1.0)
                              : null,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF3A3A3A),
                      valueColor: const AlwaysStoppedAnimation<Color>(_accent),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildText() {
    final secondary = _secondaryLine();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          playlist.name,
          style: TextStyle(
            color: isNowPlaying ? _accent : Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            height: 1.25,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        _buildStatusLine(),
        if (secondary != null) ...[const SizedBox(height: 2), secondary],
      ],
    );
  }

  Widget _buildStatusLine() {
    if (!_isBusy && !countsLoaded) {
      // Placeholder until the counts arrive, instead of a misleading
      // "Not updated yet" that changes a moment later.
      return Container(
        key: const ValueKey('playlist-card-counts-loading'),
        width: 96,
        height: 10,
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF3A3A3A),
          borderRadius: BorderRadius.circular(5),
        ),
      );
    }
    // Two lines: "0 of 600 downloaded · updated 3d ago" does not fit one
    // line next to the cover on a narrow phone.
    return Text(
      statusText(),
      key: const ValueKey('playlist-card-status'),
      style: TextStyle(color: _isBusy ? _accent : _muted, fontSize: 12.5),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// The status line, in words.
  @visibleForTesting
  String statusText({DateTime? now}) {
    switch (activity) {
      case PlaylistCardActivity.syncing:
        return 'Checking for new videos…';
      case PlaylistCardActivity.queued:
        return 'Queued after the current download';
      case PlaylistCardActivity.preparing:
        return 'Getting ready to download…';
      case PlaylistCardActivity.downloading:
        return runTotal > 0
            ? 'Downloading $runIndex of $runTotal'
            : 'Downloading…';
      case PlaylistCardActivity.finishing:
        return 'Finishing up…';
      case PlaylistCardActivity.idle:
        break;
    }
    final updated = playlist.lastUpdated;
    final when = updated == null ? null : 'updated ${timeAgo(updated, now)}';
    final c = counts;
    if (c == null || c.total == 0) {
      return when == null ? 'Not updated yet' : 'No videos · $when';
    }
    final amount = playlistDownloadedText(c);
    return when == null ? amount : '$amount · $when';
  }

  /// Failed, unavailable and kept tracks, in the playlist page's words;
  /// failed ones in red.
  Widget? _secondaryLine() {
    final c = counts;
    if (c == null || activity != PlaylistCardActivity.idle) return null;
    final spans = <InlineSpan>[];
    for (final (kind, count) in trackCountNotes(c)) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: ' · '));
      spans.add(
        TextSpan(
          text: trackCountLabel(kind, count),
          style:
              kind.isProblem ? const TextStyle(color: Color(0xFFE57373)) : null,
        ),
      );
    }
    if (spans.isEmpty) return null;
    return Text.rich(
      TextSpan(children: spans),
      key: const ValueKey('playlist-card-problems'),
      style: const TextStyle(color: Color(0xFF777777), fontSize: 12),
      // Two lines: all four kinds do not fit one beside the cover.
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildActions() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [_buildUpdateButton(), _buildSettingsButton()],
    );
  }

  Widget _buildUpdateButton() {
    if (_isDownloadRun) {
      return _iconButton(
        key: const ValueKey('playlist-card-cancel'),
        icon: Icons.stop_circle_outlined,
        tooltip: 'Stop download',
        onTap: onCancel,
      );
    }
    if (activity == PlaylistCardActivity.syncing) {
      return _tapAbsorber(
        const Tooltip(
          message: 'Checking for new videos',
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
            ),
          ),
        ),
      );
    }
    if (activity == PlaylistCardActivity.queued) {
      return _tapAbsorber(
        const Tooltip(
          message: 'Queued',
          child: Icon(Icons.schedule, color: _muted, size: 22),
        ),
      );
    }
    return _iconButton(
      key: const ValueKey('playlist-card-update'),
      icon: Icons.refresh,
      tooltip: 'Update now',
      onTap: onUpdate,
    );
  }

  /// Holds the Update button's place while it is unavailable. A tap there
  /// (a quick second tap on Update) must not fall through to the card and
  /// open the playlist.
  static Widget _tapAbsorber(Widget child) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () {},
    child: SizedBox(width: 48, height: 48, child: child),
  );

  Widget _buildSettingsButton() => _iconButton(
    key: const ValueKey('playlist-card-settings'),
    icon: Icons.tune,
    tooltip: 'Playlist settings',
    onTap: onSettings,
  );

  Widget _iconButton({
    Key? key,
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        key: key,
        icon: Icon(icon, size: 24),
        color: _iconColor,
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        onPressed: onTap,
      ),
    );
  }

  Widget _buildCover(BuildContext context, double width) {
    final height = width * 9 / 16;
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: const Color(0xFF222222),
              child: PlaylistCoverImage(
                playlist: playlist,
                cacheWidth: cacheWidth,
              ),
            ),
            if (isNowPlaying)
              Positioned(
                left: 4,
                bottom: 4,
                child: Container(
                  key: const ValueKey('playlist-card-now-playing'),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    isPlaying ? Icons.equalizer : Icons.pause,
                    color: _accent,
                    size: 16,
                    semanticLabel: isPlaying ? 'Playing' : 'Paused',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    HapticFeedback.selectionClick();
    final action = await showModalBottomSheet<VoidCallback>(
      context: context,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    playlist.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_isDownloadRun)
                  ListTile(
                    key: const ValueKey('playlist-menu-stop'),
                    leading: const Icon(Icons.stop_circle_outlined),
                    title: const Text('Stop download'),
                    enabled: onCancel != null,
                    onTap: () => Navigator.pop(sheetContext, onCancel),
                  )
                else
                  ListTile(
                    key: const ValueKey('playlist-menu-update'),
                    leading: const Icon(Icons.refresh),
                    title: const Text('Update now'),
                    subtitle: Text(
                      _isBusy
                          ? statusText()
                          : playlist.isTemporary
                          ? 'Download videos not downloaded yet'
                          : 'Check for new videos and download them',
                    ),
                    enabled: !_isBusy,
                    onTap: () => Navigator.pop(sheetContext, onUpdate),
                  ),
                ListTile(
                  key: const ValueKey('playlist-menu-settings'),
                  leading: const Icon(Icons.tune),
                  title: const Text('Playlist settings'),
                  onTap: () => Navigator.pop(sheetContext, onSettings),
                ),
                if (onReorder != null)
                  ListTile(
                    key: const ValueKey('playlist-menu-reorder'),
                    leading: const Icon(Icons.swap_vert),
                    title: const Text('Reorder playlists'),
                    onTap: () => Navigator.pop(sheetContext, onReorder),
                  ),
                if (onOpenOnYouTube != null)
                  ListTile(
                    key: const ValueKey('playlist-menu-youtube'),
                    leading: const Icon(Icons.open_in_new),
                    title: const Text('Open on YouTube'),
                    onTap: () => Navigator.pop(sheetContext, onOpenOnYouTube),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
    );
    action?.call();
  }
}

/// A playlist's cover. The one saved in the playlist folder works offline,
/// so it comes first; the YouTube image is the fallback. Both are decoded at
/// [cacheWidth] pixels wide.
class PlaylistCoverImage extends StatelessWidget {
  const PlaylistCoverImage({
    super.key,
    required this.playlist,
    required this.cacheWidth,
  });

  final Playlist playlist;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    final url = playlist.thumbnailUrl;
    final remote =
        url != null && url.isNotEmpty
            ? CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              memCacheWidth: cacheWidth,
              placeholder: (_, __) => const SizedBox.expand(),
              errorWidget: (_, __, ___) => _placeholder(),
            )
            : _placeholder();
    final localPath = existingThumbnailPath(playlist.thumbnailPath);
    if (localPath == null) return remote;
    return Image(
      image: ResizeImage(
        FileImage(File(localPath)),
        width: cacheWidth,
        policy: ResizeImagePolicy.fit,
      ),
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => remote,
    );
  }

  Widget _placeholder() => const Center(
    child: Icon(Icons.playlist_play, color: Color(0xFF555555), size: 36),
  );
}

/// "just now", "5m ago", "3h ago", "2d ago", or the date for older times.
String timeAgo(DateTime time, [DateTime? now]) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final date = '${months[time.month - 1]} ${time.day}';
  return (now ?? DateTime.now()).year == time.year
      ? date
      : '$date ${time.year}';
}
