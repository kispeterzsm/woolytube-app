import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart'
    hide DownloadProgress;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/playlist_counts_provider.dart';
import '../providers/providers.dart';
import '../services/download_errors.dart';
import '../services/download_service.dart';
import '../services/lyrics/lyrics_models.dart';
import '../services/media_thumbnail_service.dart';
import '../services/metadata_service.dart';
import '../services/track_search.dart';
import '../services/update_service.dart';
import '../widgets/lyrics_line_text.dart';
import '../widgets/mobile_data_download_guard.dart';
import '../widgets/playlist_card.dart';
import 'add_playlist_page.dart';
import 'playlist_detail_page.dart';
import 'playlist_settings_page.dart';
import 'reorder_playlists_page.dart';
import 'settings_page.dart';

/// Room the floating "Add playlist" button needs below the last card, so it
/// never covers that card's buttons.
const _fabClearance = 56.0 + 16.0 + 12.0;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _searchController = TextEditingController();

  /// Playlists whose Update was tapped and that are being checked for
  /// network access, before the shared sync state takes over.
  final Set<int> _startingPlaylistIds = <int>{};
  bool _showSearch = false;
  bool _importing = false;
  AppUpdate? _availableUpdate;
  Future<void>? _updateCheck;
  bool _isCheckingForUpdate = false;

  /// The yt-dlp start failure the owner closed the notice for.
  String? _dismissedYtDlpError;

  @override
  void initState() {
    super.initState();
    unawaited(_checkForUpdate());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openSearch() => setState(() => _showSearch = true);

  void _closeSearch() {
    FocusManager.instance.primaryFocus?.unfocus();
    _searchController.clear();
    setState(() => _showSearch = false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back closes the search before it leaves the app.
      canPop: !_showSearch,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showSearch) _closeSearch();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'WoolyTube',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20),
          ),
          actions: [
            if (!_showSearch &&
                (ref.watch(visiblePlaylistsProvider).valueOrNull?.length ?? 0) >
                    1)
              IconButton(
                key: const ValueKey('home-reorder-playlists'),
                icon: const Icon(Icons.swap_vert),
                tooltip: 'Reorder playlists',
                onPressed: _navigateToReorder,
              ),
            IconButton(
              icon: Icon(_showSearch ? Icons.search_off : Icons.search),
              tooltip: _showSearch ? 'Close search' : 'Search',
              onPressed: _showSearch ? _closeSearch : _openSearch,
            ),
            IconButton(
              icon: Badge(
                key: const ValueKey('settings-update-badge'),
                isLabelVisible: _availableUpdate != null,
                backgroundColor: const Color(0xFFFF7043),
                smallSize: 8,
                child: const Icon(Icons.settings_outlined),
              ),
              tooltip:
                  _availableUpdate != null
                      ? 'Settings – update to ${_availableUpdate!.version} '
                          'available'
                      : _isCheckingForUpdate
                      ? 'Settings – checking for updates'
                      : 'Settings',
              onPressed: _navigateToAppSettings,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: _showSearch ? _buildSearch() : _buildLibrary(),
        floatingActionButton:
            _showSearch
                ? null
                : ValueListenableBuilder<double>(
                  valueListenable: audioPlayerOverlayHeightNotifier,
                  builder:
                      (context, overlayHeight, child) => AnimatedPadding(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        padding: EdgeInsets.only(bottom: overlayHeight),
                        child: child,
                      ),
                  child: FloatingActionButton(
                    key: const ValueKey('home-add-playlist'),
                    onPressed: _navigateToAddPlaylist,
                    tooltip: 'Add playlist',
                    backgroundColor: const Color(0xFF2196F3),
                    child: const Icon(Icons.add, color: Colors.white),
                  ),
                ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Library

  Widget _buildLibrary() {
    final playlistsAsync = ref.watch(visiblePlaylistsProvider);
    final pendingImports = ref.watch(pendingImportsProvider);
    final notices = _buildNotices(pendingImports);

    return ValueListenableBuilder<double>(
      valueListenable: audioPlayerOverlayHeightNotifier,
      builder: (context, overlayHeight, _) {
        final bottom = 12 + _fabClearance + overlayHeight;
        return CustomScrollView(
          key: const PageStorageKey('home-library'),
          slivers: [
            if (notices.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                sliver: SliverList.separated(
                  itemCount: notices.length,
                  itemBuilder: (_, index) => notices[index],
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                ),
              ),
            ...playlistsAsync.when(
              loading:
                  () => const [
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ],
              error:
                  (e, _) => [
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('Error: $e')),
                    ),
                  ],
              data: (playlists) {
                if (playlists.isEmpty) {
                  return [
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: bottom),
                        child: const _EmptyLibrary(),
                      ),
                    ),
                  ];
                }
                return [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(12, 12, 12, bottom),
                    sliver: SliverList.separated(
                      itemCount: playlists.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        return _PlaylistCardItem(
                          key: ValueKey('playlist-card-${playlist.id}'),
                          playlist: playlist,
                          isStarting: _startingPlaylistIds.contains(
                            playlist.id,
                          ),
                          onTap: () => _navigateToDetail(playlist),
                          onUpdate: () => _startUpdate(playlist),
                          onCancel: _confirmCancelDownload,
                          onSettings: () => _navigateToSettings(playlist),
                          // No YouTube playlist is behind the temporary one.
                          onOpenOnYouTube:
                              playlist.isTemporary
                                  ? null
                                  : () => _openOnYouTube(playlist),
                          onReorder:
                              playlists.length > 1 ? _navigateToReorder : null,
                        );
                      },
                    ),
                  ),
                ];
              },
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildNotices(List<DiscoveredPlaylist> pendingImports) {
    final ytDlpError = ref.watch(ytDlpInitErrorProvider);
    final storageAccess = ref.watch(storageAccessProvider);
    return [
      if (ytDlpError != null && ytDlpError != _dismissedYtDlpError)
        _buildYtDlpNotice(ytDlpError),
      if (storageAccess == false) _buildStorageNotice(),
      if (pendingImports.isNotEmpty) _buildImportBanner(pendingImports),
    ];
  }

  Widget _buildYtDlpNotice(String reason) {
    final retrying = ref.watch(ytDlpRetryingProvider);
    return _HomeNotice(
      key: const ValueKey('ytdlp-unavailable-notice'),
      icon: Icons.warning_amber_rounded,
      color: const Color(0xFFFFB74D),
      title: 'Downloads are unavailable: $reason',
      actions: [
        TextButton(
          onPressed:
              retrying
                  ? null
                  : () {
                    // Show the notice again if the retry fails too.
                    setState(() => _dismissedYtDlpError = null);
                    // Only yt-dlp is started again: no permission prompts.
                    unawaited(ref.read(libraryStartupProvider).retryYtDlp());
                  },
          child: Text(retrying ? 'Retrying…' : 'Retry'),
        ),
      ],
      onDismiss: () => setState(() => _dismissedYtDlpError = reason),
    );
  }

  Widget _buildStorageNotice() {
    return _HomeNotice(
      key: const ValueKey('storage-access-notice'),
      icon: Icons.folder_off_outlined,
      color: const Color(0xFFFFB74D),
      title: "WoolyTube can't reach its Music and Movies folders",
      subtitle: 'Allow file access to download and find your playlists.',
      actions: [
        TextButton(
          onPressed:
              () => unawaited(
                ref.read(libraryStartupProvider).requestStorageAccess(),
              ),
          child: const Text('Allow'),
        ),
      ],
    );
  }

  Widget _buildImportBanner(List<DiscoveredPlaylist> imports) {
    final count = imports.length;
    return _HomeNotice(
      key: const ValueKey('import-banner'),
      icon: Icons.download_rounded,
      color: const Color(0xFF2196F3),
      title: 'Found $count playlist${count == 1 ? '' : 's'}',
      subtitle: 'From a previous installation',
      actions: [
        TextButton(
          onPressed: _importing ? null : () => _dismissImports(imports),
          child: const Text(
            'Not now',
            style: TextStyle(color: Color(0xFF999999)),
          ),
        ),
        FilledButton(
          onPressed: _importing ? null : () => _importAll(imports),
          child:
              _importing
                  ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                  : const Text('Import all'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Search

  Widget _buildSearch() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder:
                (context, value, _) => TextField(
                  controller: _searchController,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search tracks and playlists',
                    prefixIcon: const Icon(
                      Icons.search,
                      color: Color(0xFF888888),
                    ),
                    suffixIcon:
                        value.text.isEmpty
                            ? null
                            : IconButton(
                              icon: const Icon(Icons.clear),
                              color: const Color(0xFF888888),
                              tooltip: 'Clear',
                              onPressed: _searchController.clear,
                            ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  style: const TextStyle(color: Colors.white),
                  onTapOutside:
                      (_) => FocusManager.instance.primaryFocus?.unfocus(),
                ),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder:
                (context, value, _) => _SearchResults(
                  query: value.text,
                  onOpenPlaylist: _navigateToDetail,
                ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Actions

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

  Future<void> _confirmCancelDownload() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Stop downloading?'),
            content: const Text(
              'Finished tracks are kept; the rest download with the next '
              'update.',
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
    await ref.read(downloadServiceProvider).cancelActiveDownloads();
  }

  Future<void> _startUpdate(Playlist playlist) async {
    if (_startingPlaylistIds.contains(playlist.id)) return;

    // Read every provider before the first await; the download must start
    // even if this page goes away meanwhile.
    final downloadService = ref.read(downloadServiceProvider);
    final playlistService = ref.read(playlistServiceProvider);
    final db = ref.read(databaseProvider);
    final messenger = ScaffoldMessenger.of(context);
    if (playlistService.syncingPlaylistIds.contains(playlist.id) ||
        downloadService.activePlaylistId == playlist.id) {
      return;
    }
    if (downloadService.isDownloading && !playlist.isTemporary) {
      // Asking YouTube is refused while a download runs; say so plainly
      // instead of failing after the network check. The temporary playlist
      // asks YouTube nothing: its download waits in the queue.
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Another playlist is downloading. Update this one when it '
            'finishes.',
          ),
        ),
      );
      return;
    }
    if (explainDownloadsUnavailable(context, ref)) return;

    setState(() => _startingPlaylistIds.add(playlist.id));
    try {
      if (!await confirmManualDownload(
        context,
        ref.read(downloadNetworkPolicyProvider),
        settings: ref.read(appSettingsServiceProvider),
      )) {
        return;
      }
      if (!mounted) return;
      // The card stays "checking" (and Update stays off) until the sync has
      // handed over to the download; the finally below clears it.
      await syncAndDownloadPlaylist(
        context: context,
        playlist: playlist,
        playlists: playlistService,
        downloads: downloadService,
        db: db,
      );
    } catch (e) {
      final reason = e is StateError ? e.message : '$e';
      messenger.showSnackBar(
        SnackBar(
          content: Text('Update failed: ${friendlyDownloadError(reason)}'),
        ),
      );
    } finally {
      if (mounted && _startingPlaylistIds.contains(playlist.id)) {
        setState(() => _startingPlaylistIds.remove(playlist.id));
      }
    }
  }

  Future<void> _openOnYouTube(Playlist playlist) async {
    final messenger = ScaffoldMessenger.of(context);
    var launched = false;
    try {
      launched = await launchUrl(
        Uri.parse(playlist.url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }
    if (!launched) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open this playlist.')),
      );
    }
  }

  void _dismissImports(List<DiscoveredPlaylist> imports) {
    final pending = ref.read(pendingImportsProvider.notifier);
    final settings = ref.read(appSettingsServiceProvider);
    final log = ref.read(logServiceProvider);
    pending.state = [];
    var undone = false;
    final controller = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Hidden. You can still restore them in Settings.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            undone = true;
            pending.state = imports;
          },
        ),
      ),
    );
    // Remembered only once Undo is no longer possible.
    unawaited(
      controller.closed.then((_) async {
        if (undone) return;
        try {
          await settings.addDismissedImportUrls(imports.map((i) => i.url));
        } catch (e) {
          log.warn('could not persist dismissal: $e');
        }
      }),
    );
  }

  Future<void> _importAll(List<DiscoveredPlaylist> imports) async {
    if (_importing) return;
    setState(() => _importing = true);
    final metadata = ref.read(metadataServiceProvider);
    final failures = <String>[];
    var imported = 0;
    try {
      for (final discovered in imports) {
        try {
          await metadata.importPlaylist(discovered);
          imported++;
          final remaining = ref.read(pendingImportsProvider);
          ref.read(pendingImportsProvider.notifier).state =
              remaining.where((p) => p.url != discovered.url).toList();
        } on PlaylistExistsException {
          // Already in the library (for example added again by URL since
          // the banner appeared): nothing to import.
          final remaining = ref.read(pendingImportsProvider);
          ref.read(pendingImportsProvider.notifier).state =
              remaining.where((p) => p.url != discovered.url).toList();
        } catch (e) {
          failures.add(discovered.name);
          ref
              .read(logServiceProvider)
              .warn('import of ${discovered.name} failed: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
    if (!mounted) return;
    final String message;
    if (failures.isEmpty) {
      message = 'Imported $imported playlist${imported == 1 ? '' : 's'}';
    } else if (imported == 0) {
      message =
          'Could not import ${failures.length} '
          'playlist${failures.length == 1 ? '' : 's'}: ${failures.join(', ')}';
    } else {
      message =
          'Imported $imported, failed ${failures.length}: '
          '${failures.join(', ')}';
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _navigateToAddPlaylist() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AddPlaylistPage()));
  }

  void _navigateToDetail(Playlist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => PlaylistDetailPage(
              playlistId: playlist.id,
              initialName: playlist.name,
            ),
      ),
    );
  }

  void _navigateToSettings(Playlist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistSettingsPage(playlistId: playlist.id),
      ),
    );
  }

  void _navigateToReorder() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ReorderPlaylistsPage()));
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

/// One playlist card with its live state. Each card watches only its own
/// slice of the counts, the download progress and the playing track, so a
/// progress tick rebuilds the downloading card and nothing else.
class _PlaylistCardItem extends ConsumerWidget {
  const _PlaylistCardItem({
    super.key,
    required this.playlist,
    required this.isStarting,
    required this.onTap,
    required this.onUpdate,
    required this.onCancel,
    required this.onSettings,
    required this.onOpenOnYouTube,
    this.onReorder,
  });

  final Playlist playlist;
  final bool isStarting;
  final VoidCallback onTap;
  final VoidCallback onUpdate;
  final VoidCallback onCancel;
  final VoidCallback onSettings;
  final VoidCallback? onOpenOnYouTube;
  final VoidCallback? onReorder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = playlist.id;
    final counts = ref.watch(playlistCountsProvider(id));
    final syncing = ref.watch(
      syncingPlaylistsProvider.select(
        (async) => async.valueOrNull?.contains(id) ?? false,
      ),
    );
    final queued = ref.watch(
      downloadQueueProvider.select(
        (async) => async.valueOrNull?.contains(id) ?? false,
      ),
    );
    final run = ref.watch(
      downloadProgressProvider.select((async) {
        final p = async.valueOrNull;
        if (p == null || !p.isBusy || p.playlistId != id) return null;
        return (
          phase: p.phase,
          index: p.currentTrackIndex,
          total: p.totalTracks,
          // Whole percents: finer steps would not show on a card.
          percent: (p.overallFraction * 100).round(),
        );
      }),
    );
    final isNowPlaying = ref.watch(
      currentTrackProvider.select(
        (async) => async.valueOrNull?.playlistId == id,
      ),
    );
    final isPlaying =
        isNowPlaying &&
        ref.watch(
          isPlayingProvider.select((async) => async.valueOrNull ?? false),
        );

    final PlaylistCardActivity activity;
    if (run != null) {
      activity = switch (run.phase) {
        DownloadPhase.preparing ||
        DownloadPhase.none => PlaylistCardActivity.preparing,
        DownloadPhase.downloading => PlaylistCardActivity.downloading,
        DownloadPhase.finishing => PlaylistCardActivity.finishing,
      };
    } else if (syncing || isStarting) {
      activity = PlaylistCardActivity.syncing;
    } else if (queued) {
      activity = PlaylistCardActivity.queued;
    } else {
      activity = PlaylistCardActivity.idle;
    }

    return PlaylistCard(
      playlist: playlist,
      counts: counts.counts,
      countsLoaded: counts.loaded,
      activity: activity,
      runIndex: run?.index ?? 0,
      runTotal: run?.total ?? 0,
      progress: (run?.percent ?? 0) / 100,
      isNowPlaying: isNowPlaying,
      isPlaying: isPlaying,
      onTap: onTap,
      onUpdate: onUpdate,
      onCancel: onCancel,
      onSettings: onSettings,
      onOpenOnYouTube: onOpenOnYouTube,
      onReorder: onReorder,
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.playlist_add, size: 64, color: Color(0xFF555555)),
          SizedBox(height: 16),
          Text(
            'No playlists yet',
            style: TextStyle(color: Color(0xFF888888), fontSize: 16),
          ),
          SizedBox(height: 8),
          Text(
            'Tap + to add your first playlist',
            style: TextStyle(color: Color(0xFF666666), fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// A notice above the playlists: an icon, a line or two of text, and its
/// buttons in a row below the text (right-aligned, wrapping when the text is
/// large), so long text and buttons never squeeze each other.
class _HomeNotice extends StatelessWidget {
  const _HomeNotice({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.onDismiss,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// Shows a close button at the top right.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(14, 6, 6, actions.isEmpty ? 6 : 2),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.12),
          const Color(0xFF1E1E1E),
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.7), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    0,
                    8,
                    onDismiss == null ? 8 : 0,
                    4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Color(0xFFEEEEEE),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: const TextStyle(
                            color: Color(0xFFAAAAAA),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: const Color(0xFF888888),
                  tooltip: 'Dismiss',
                  onPressed: onDismiss,
                ),
            ],
          ),
          if (actions.isNotEmpty)
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              children: actions,
            ),
        ],
      ),
    );
  }
}

/// The library search: playlists whose name matches, then every track whose
/// title, number or chapter matches, then lyric and transcript lines (searched
/// a moment after typing stops). An empty query lists every track.
class _SearchResults extends ConsumerStatefulWidget {
  const _SearchResults({required this.query, required this.onOpenPlaylist});

  final String query;
  final ValueChanged<Playlist> onOpenPlaylist;

  @override
  ConsumerState<_SearchResults> createState() => _SearchResultsState();
}

class _SearchResultsState extends ConsumerState<_SearchResults> {
  // The last filter, reused while neither the tracks nor the query changed
  // (an unrelated rebuild must not filter the whole library again).
  List<Track>? _filteredFrom;
  String? _filteredQuery;
  List<Track> _filtered = const [];

  // The tracks grouped by playlist, as a queue for playback.
  List<Track>? _groupedFrom;
  Map<int, List<Track>> _byPlaylist = const {};

  // Lyric lines matching the query, searched after a short pause in typing.
  static const _lyricsDebounce = Duration(milliseconds: 200);
  Timer? _lyricsTimer;
  int _lyricsGeneration = 0;
  List<LyricsHit> _lyricHits = const [];

  @override
  void initState() {
    super.initState();
    _scheduleLyricsSearch();
  }

  @override
  void didUpdateWidget(_SearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query.trim() != widget.query.trim()) _scheduleLyricsSearch();
  }

  @override
  void dispose() {
    _lyricsTimer?.cancel();
    super.dispose();
  }

  void _scheduleLyricsSearch() {
    _lyricsTimer?.cancel();
    final generation = ++_lyricsGeneration;
    final query = widget.query.trim();
    if (query.length < 2) {
      _lyricHits = const [];
      return;
    }
    _lyricsTimer = Timer(_lyricsDebounce, () async {
      List<LyricsHit> hits;
      try {
        hits = await ref.read(lyricsSearchProvider).search(query, limit: 30);
      } catch (_) {
        hits = const [];
      }
      if (!mounted || generation != _lyricsGeneration) return;
      setState(() => _lyricHits = hits);
    });
  }

  List<Track> _filter(List<Track> tracks, String normalized) {
    if (!identical(tracks, _filteredFrom) || normalized != _filteredQuery) {
      _filteredFrom = tracks;
      _filteredQuery = normalized;
      _filtered =
          normalized.isEmpty
              ? tracks
              : [
                for (final track in tracks)
                  if (matchesNormalizedTrackSearch(track, normalized)) track,
              ];
    }
    return _filtered;
  }

  List<Track> _queueFor(List<Track> tracks, int playlistId) {
    if (!identical(tracks, _groupedFrom)) {
      _groupedFrom = tracks;
      final grouped = <int, List<Track>>{};
      for (final track in tracks) {
        grouped.putIfAbsent(track.playlistId, () => []).add(track);
      }
      _byPlaylist = grouped;
    }
    return _byPlaylist[playlistId] ?? const [];
  }

  @override
  Widget build(BuildContext context) {
    final playlistsAsync = ref.watch(playlistsProvider);
    final visibleAsync = ref.watch(visiblePlaylistsProvider);
    final tracksAsync = ref.watch(allTracksProvider);
    final normalized = normalizeTrackSearchQuery(widget.query);

    if (playlistsAsync.hasError || tracksAsync.hasError) {
      return Center(
        child: Text('Error: ${playlistsAsync.error ?? tracksAsync.error}'),
      );
    }
    final playlists = playlistsAsync.valueOrNull;
    final tracks = tracksAsync.valueOrNull;
    if (playlists == null || tracks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tracks.isEmpty && playlists.isEmpty) {
      return const _SearchMessage('No tracks yet. Add a playlist first.');
    }

    final playlistsById = {for (final p in playlists) p.id: p};
    final matchingPlaylists =
        normalized.isEmpty
            ? const <Playlist>[]
            : [
              for (final p in visibleAsync.valueOrNull ?? playlists)
                if (p.name.toLowerCase().contains(normalized)) p,
            ];
    final filtered = _filter(tracks, normalized);
    final lyricHits = _lyricRows(tracks);
    if (filtered.isEmpty && matchingPlaylists.isEmpty && lyricHits.isEmpty) {
      return const _SearchMessage('Nothing matches');
    }

    // Rows: [playlist header + playlists], [tracks header] + tracks,
    // [lyrics header + lyric lines].
    final showHeaders = matchingPlaylists.isNotEmpty || lyricHits.isNotEmpty;
    final playlistRows =
        matchingPlaylists.isEmpty ? 0 : matchingPlaylists.length + 1;
    final trackHeader = showHeaders && filtered.isNotEmpty ? 1 : 0;
    final trackRows = trackHeader + filtered.length;
    final lyricRows = lyricHits.isEmpty ? 0 : lyricHits.length + 1;
    final itemCount = playlistRows + trackRows + lyricRows;

    return ValueListenableBuilder<double>(
      valueListenable: audioPlayerOverlayHeightNotifier,
      builder:
          (context, overlayHeight, _) => ListView.builder(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(bottom: overlayHeight + 12),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (index < playlistRows) {
                if (index == 0) return const _SearchHeader('Playlists');
                final playlist = matchingPlaylists[index - 1];
                return _PlaylistResultTile(
                  playlist: playlist,
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    widget.onOpenPlaylist(playlist);
                  },
                );
              }
              var i = index - playlistRows;
              if (i >= trackRows) {
                i -= trackRows;
                if (i == 0) return const _SearchHeader('Lyrics');
                final (hit, track) = lyricHits[i - 1];
                final playlist = playlistsById[track.playlistId];
                return _LyricsResultTile(
                  key: ValueKey('search-lyrics-${hit.docId}'),
                  hit: hit,
                  track: track,
                  playlist: playlist,
                  onTap: () => _onLyricsTap(hit, track, playlist, tracks),
                );
              }
              if (trackHeader == 1) {
                if (i == 0) return const _SearchHeader('Tracks');
                i--;
              }
              final track = filtered[i];
              final playlist = playlistsById[track.playlistId];
              return _SearchTrackTile(
                key: ValueKey('search-track-${track.id}'),
                track: track,
                playlist: playlist,
                onTap: () => _onTrackTap(track, playlist, tracks),
              );
            },
          ),
    );
  }

  /// The lyric hits whose track is still in the library, with the track.
  List<(LyricsHit, Track)> _lyricRows(List<Track> tracks) {
    if (_lyricHits.isEmpty || widget.query.trim().length < 2) return const [];
    final wanted = {for (final hit in _lyricHits) hit.trackId};
    final byId = {
      for (final track in tracks)
        if (wanted.contains(track.id)) track.id: track,
    };
    return [
      for (final hit in _lyricHits)
        if (byId[hit.trackId] case final track?) (hit, track),
    ];
  }

  void _onLyricsTap(
    LyricsHit hit,
    Track track,
    Playlist? playlist,
    List<Track> tracks,
  ) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (playlist == null || !_canPlay(track, playlist)) return;
    final target = lyricsHitTarget(track, hit);
    ref
        .read(playbackServiceProvider)
        .playTrack(
          track,
          _queueFor(tracks, track.playlistId),
          playlist: playlist,
          chapterId: target.chapter?.id,
          startAt: target.startAt,
        );
  }

  void _onTrackTap(Track track, Playlist? playlist, List<Track> tracks) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (playlist == null || !_canPlay(track, playlist)) return;
    ref
        .read(playbackServiceProvider)
        .playTrack(
          track,
          _queueFor(tracks, track.playlistId),
          playlist: playlist,
          chapterId: matchingChapterForSearch(track, widget.query)?.id,
        );
  }

  /// Whether [track] has a file to play; if not, says why.
  bool _canPlay(Track track, Playlist playlist) {
    if (track.status != 'complete') {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              track.status == 'unavailable'
                  ? 'This track is unavailable on YouTube'
                  : 'Not downloaded yet',
            ),
            action: SnackBarAction(
              label: 'Open playlist',
              onPressed: () => widget.onOpenPlaylist(playlist),
            ),
          ),
        );
      return false;
    }
    return true;
  }
}

/// One matched lyric or transcript line: the track (or chapter) title, then
/// the line with its matched words highlighted and its time.
class _LyricsResultTile extends ConsumerWidget {
  const _LyricsResultTile({
    super.key,
    required this.hit,
    required this.track,
    required this.playlist,
    required this.onTap,
  });

  final LyricsHit hit;
  final Track track;
  final Playlist? playlist;
  final VoidCallback onTap;

  static const _muted = Color(0xFF888888);
  static const _accent = Color(0xFF2196F3);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCurrentTrack = ref.watch(
      currentTrackProvider.select((async) => async.valueOrNull?.id == track.id),
    );
    final chapter = lyricsHitTarget(track, hit).chapter;
    final playlistName = playlist?.name ?? 'Playlist #${track.playlistId}';
    final position = hit.positionMs;
    return Material(
      color: isCurrentTrack ? const Color(0xFF2A2A2A) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 32,
                child: Icon(
                  hit.kind == LyricsMode.transcript
                      ? Icons.subtitles_outlined
                      : Icons.lyrics_outlined,
                  color: isCurrentTrack ? _accent : _muted,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chapter?.title ?? track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrentTrack ? _accent : Colors.white,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      chapter == null
                          ? playlistName
                          : '${track.title} · $playlistName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    LyricsLineText(
                      hit: hit,
                      snippet: true,
                      style: const TextStyle(
                        color: Color(0xFFAAAAAA),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (position != null) ...[
                const SizedBox(width: 8),
                Text(
                  formatLyricsTime(position),
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchMessage extends StatelessWidget {
  const _SearchMessage(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          style: const TextStyle(color: Color(0xFF888888)),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _SearchHeader extends StatelessWidget {
  const _SearchHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF2196F3),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PlaylistResultTile extends StatelessWidget {
  const _PlaylistResultTile({required this.playlist, required this.onTap});

  final Playlist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.queue_music, color: Color(0xFFAAAAAA)),
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: Text(
        playlist.audioOnly ? 'Audio playlist' : 'Video playlist',
        style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, color: Color(0xFF888888)),
      onTap: onTap,
    );
  }
}

/// One track in the search results. Only this tile rebuilds when it starts
/// or stops being the playing track.
class _SearchTrackTile extends ConsumerWidget {
  const _SearchTrackTile({
    super.key,
    required this.track,
    required this.playlist,
    required this.onTap,
  });

  final Track track;
  final Playlist? playlist;
  final VoidCallback onTap;

  static const _accent = Color(0xFF2196F3);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCurrentTrack = ref.watch(
      currentTrackProvider.select((async) => async.valueOrNull?.id == track.id),
    );
    final isCurrentlyPlaying =
        isCurrentTrack &&
        ref.watch(
          isPlayingProvider.select((async) => async.valueOrNull ?? false),
        );

    final isUnavailable = track.status == 'unavailable';
    final hasLocalFile =
        track.status == 'complete' && track.unavailableReason != null;
    final hasError = track.status == 'error' && track.lastError != null;
    final details = _details(
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
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Text(
                  track.index.toString(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isCurrentTrack ? _accent : const Color(0xFF888888),
                    fontSize: 13,
                    fontWeight:
                        isCurrentTrack ? FontWeight.w600 : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: thumbnailWidth,
                  height: thumbnailWidth * 9 / 16,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildThumbnail(context, thumbnailWidth),
                      if (isCurrentlyPlaying)
                        const ColoredBox(
                          color: Colors.black38,
                          child: Center(
                            child: Icon(
                              Icons.equalizer,
                              color: _accent,
                              size: 24,
                            ),
                          ),
                        ),
                    ],
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
                        color: isCurrentTrack ? _accent : Colors.white,
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
                            color: _accent,
                            size: 20,
                          )
                          : _statusIcon(hasLocalFile: hasLocalFile),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context, double width) {
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context)).round();
    final url = resolveRemoteThumbnailUrl(
      thumbnailUrl: track.thumbnailUrl,
      youtubeVideoId: track.videoId,
    );
    final fallback =
        url != null
            ? CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              memCacheWidth: cacheWidth,
              placeholder:
                  (_, __) => const ColoredBox(color: Color(0xFF333333)),
              errorWidget: (_, __, ___) => _placeholder(),
            )
            : _placeholder();
    final localPath = existingThumbnailPath(track.thumbnailPath);
    if (localPath == null) return fallback;
    return Image(
      image: ResizeImage(
        FileImage(File(localPath)),
        width: cacheWidth,
        policy: ResizeImagePolicy.fit,
      ),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => fallback,
    );
  }

  static Widget _placeholder() => const ColoredBox(
    color: Color(0xFF333333),
    child: Icon(Icons.music_note, color: Color(0xFF555555), size: 24),
  );

  Widget _statusIcon({required bool hasLocalFile}) {
    switch (track.status) {
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

  String _details({
    required bool hasError,
    required bool isUnavailable,
    required bool hasLocalFile,
  }) {
    if (hasError) return 'Download failed';
    if (isUnavailable) return _unavailableTrackLabel(track.unavailableReason);
    if (hasLocalFile) {
      return '${_unavailableTrackLabel(track.unavailableReason)} (local file)';
    }
    return _formatDuration(track.durationSeconds);
  }

  static String _formatDuration(int? seconds) {
    if (seconds == null || seconds == 0) return '';
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
  }
}

/// Why a track cannot be downloaded, in words.
String _unavailableTrackLabel(String? reason) {
  switch (reason) {
    case removedFromYouTubeReason:
      return 'Removed from YouTube';
    case 'private':
      return 'Private video';
    case 'deleted':
      return 'Deleted video';
    case 'removed':
      return 'Removed from playlist';
    case 'needs_auth':
      return 'Requires sign-in';
    case 'premium_only':
      return 'Premium only';
    default:
      return 'Unavailable';
  }
}
