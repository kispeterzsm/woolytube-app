import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../widgets/playlist_card.dart';

/// Changes the order of the playlists on the home page by dragging them.
/// Every drop is saved at once.
class ReorderPlaylistsPage extends ConsumerStatefulWidget {
  const ReorderPlaylistsPage({super.key});

  @override
  ConsumerState<ReorderPlaylistsPage> createState() =>
      _ReorderPlaylistsPageState();
}

class _ReorderPlaylistsPageState extends ConsumerState<ReorderPlaylistsPage> {
  static const _muted = Color(0xFF999999);

  /// The order just dropped, shown until the database publishes it, so a
  /// dragged playlist never jumps back for a frame.
  List<Playlist>? _pendingOrder;
  List<Playlist>? _orderBeforeDrop;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(visiblePlaylistsProvider);
    final published = async.valueOrNull;
    if (_pendingOrder != null && !identical(published, _orderBeforeDrop)) {
      _pendingOrder = null;
      _orderBeforeDrop = null;
    }
    final playlists = _pendingOrder ?? published;

    return Scaffold(
      appBar: AppBar(title: const Text('Reorder playlists')),
      body:
          playlists == null
              ? Center(
                child:
                    async.hasError
                        ? Text('Error: ${async.error}')
                        : const CircularProgressIndicator(),
              )
              : _buildList(playlists, published!),
    );
  }

  Widget _buildList(List<Playlist> playlists, List<Playlist> published) {
    final cacheWidth = (64 * MediaQuery.devicePixelRatioOf(context)).round();
    return ValueListenableBuilder<double>(
      valueListenable: audioPlayerOverlayHeightNotifier,
      builder:
          (context, overlay, _) => ReorderableListView.builder(
            key: const ValueKey('reorder-playlists-list'),
            buildDefaultDragHandles: false,
            padding: EdgeInsets.only(top: 4, bottom: 12 + overlay),
            header: const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Drag ≡ to change the order on the home page.',
                style: TextStyle(color: _muted),
              ),
            ),
            itemCount: playlists.length,
            onReorder: (from, to) => _move(playlists, published, from, to),
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              return Material(
                key: ValueKey('reorder-playlist-${playlist.id}'),
                color: Colors.transparent,
                child: ListTile(
                  contentPadding: const EdgeInsets.only(left: 4, right: 16),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.drag_handle, color: _muted),
                    ),
                  ),
                  title: Text(
                    playlist.name,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 64,
                      height: 36,
                      child: ColoredBox(
                        color: const Color(0xFF222222),
                        child: PlaylistCoverImage(
                          playlist: playlist,
                          cacheWidth: cacheWidth,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
    );
  }

  Future<void> _move(
    List<Playlist> shown,
    List<Playlist> published,
    int from,
    int to,
  ) async {
    // ReorderableListView reports the slot before removal.
    if (to > from) to -= 1;
    if (to == from) return;
    final reordered = [...shown];
    final moved = reordered.removeAt(from);
    reordered.insert(to, moved);
    setState(() {
      _orderBeforeDrop = published;
      _pendingOrder = reordered;
    });
    final before = to + 1 < reordered.length ? reordered[to + 1].id : null;
    try {
      await ref
          .read(playlistServiceProvider)
          .movePlaylist(moved.id, beforeId: before);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingOrder = null;
        _orderBeforeDrop = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save the order: $e')));
    }
  }
}
