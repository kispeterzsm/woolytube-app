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
import '../services/chapter_playback.dart';
import '../services/chapters.dart';
import '../services/media_thumbnail_service.dart';
import '../services/metadata_service.dart';
import '../services/track_search.dart';
import '../services/track_status_labels.dart';
import '../services/update_service.dart';
import '../widgets/lyrics_line_text.dart';
import '../widgets/mobile_data_download_guard.dart';
import '../widgets/playlist_card.dart';
import '../widgets/search_tools.dart';
import 'add_playlist_page.dart';
import 'playlist_detail_page.dart';
import 'playlist_settings_page.dart';
import 'reorder_playlists_page.dart';
import 'settings_page.dart';
import '../services/track_title.dart';

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

  /// The search filters; Lyrics is off each time search opens.
  SearchFilters _searchFilters = const SearchFilters();
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

  void _openSearch() => setState(() {
    _showSearch = true;
    _searchFilters = const SearchFilters();
  });

  void _closeSearch() {
    FocusManager.instance.primaryFocus?.unfocus();
    _searchController.clear();
    setState(() {
      _showSearch = false;
      _searchFilters = const SearchFilters();
    });
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
        // The list runs on behind the system navigation bar, while the
        // add button floats above it: add the bar's height, or the last
        // card's buttons stay under the add button.
        final bottom =
            12 +
            _fabClearance +
            overlayHeight +
            MediaQuery.viewPaddingOf(context).bottom;
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
                  filters: _searchFilters,
                  onFiltersChanged:
                      (filters) => setState(() => _searchFilters = filters),
                  onOpenPlaylist: _navigateToDetail,
                  onTrackActions: _showTrackActions,
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

  /// The options sheet of a file found by the search, as on its playlist
  /// page. It opens from this page, not from the result: results come and go
  /// as the library changes (a rename can move or drop the row, closing the
  /// search drops them all), while this page stays for the sheet and the
  /// renames, downloads and messages it starts.
  void _showTrackActions(Track track) {
    FocusManager.instance.primaryFocus?.unfocus();
    showTrackActionsSheet(context, ref, track);
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

/// The library search: a filter row with Play all, then playlists whose
/// name matches, every track whose title, number or chapter matches (best
/// matches first) and, with the Lyrics filter on, lyric and transcript lines
/// (searched a moment after typing stops). An empty query lists every track.
class _SearchResults extends ConsumerStatefulWidget {
  const _SearchResults({
    required this.query,
    required this.filters,
    required this.onFiltersChanged,
    required this.onOpenPlaylist,
    required this.onTrackActions,
  });

  final String query;
  final SearchFilters filters;
  final ValueChanged<SearchFilters> onFiltersChanged;
  final ValueChanged<Playlist> onOpenPlaylist;

  /// Opens the options sheet of a file (its own row, never a chapter).
  final ValueChanged<Track> onTrackActions;

  @override
  ConsumerState<_SearchResults> createState() => _SearchResultsState();
}

class _SearchResultsState extends ConsumerState<_SearchResults> {
  // The last search, reused while neither its inputs changed (an unrelated
  // rebuild must not search the whole library again).
  List<Track>? _searchedTracks;
  SearchQuery? _searchedQuery;
  SearchFilters? _searchedFilters;
  List<LyricsHit>? _searchedLyrics;
  List<Playlist>? _searchedPlaylists;
  List<SearchHit> _hits = const [];

  // The tracks grouped by playlist, as a queue for playback.
  List<Track>? _groupedFrom;
  Map<int, List<Track>> _byPlaylist = const {};

  // Lyric lines matching the query, searched after a short pause in typing
  // while the Lyrics filter is on.
  static const _lyricsDebounce = Duration(milliseconds: 200);
  Timer? _lyricsTimer;
  int _lyricsGeneration = 0;
  List<LyricsHit> _lyricHits = const [];

  /// The query [_lyricHits] belong to; older hits are not shown.
  String _lyricHitsQuery = '';

  late SearchQuery _query = SearchQuery(widget.query);

  @override
  void initState() {
    super.initState();
    _scheduleLyricsSearch();
  }

  @override
  void didUpdateWidget(_SearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    final query = SearchQuery(widget.query);
    final queryChanged = query != _query;
    _query = query;
    final lyricsChanged = oldWidget.filters.lyrics != widget.filters.lyrics;
    if (queryChanged || lyricsChanged) {
      // Turning the filter on searches at once.
      _scheduleLyricsSearch(now: lyricsChanged);
    }
  }

  @override
  void dispose() {
    _lyricsTimer?.cancel();
    super.dispose();
  }

  void _scheduleLyricsSearch({bool now = false}) {
    _lyricsTimer?.cancel();
    final generation = ++_lyricsGeneration;
    final query = _query.phrase;
    if (!widget.filters.lyrics || !_query.canSearchLyrics) {
      _lyricHits = const [];
      _lyricHitsQuery = '';
      return;
    }
    _lyricsTimer = Timer(now ? Duration.zero : _lyricsDebounce, () async {
      List<LyricsHit> hits;
      try {
        hits = await ref.read(lyricsSearchProvider).search(query, limit: 30);
      } catch (_) {
        hits = const [];
      }
      if (!mounted || generation != _lyricsGeneration) return;
      setState(() {
        _lyricHits = hits;
        _lyricHitsQuery = query;
      });
    });
  }

  /// The current lyric hits, when they belong to the current query.
  List<LyricsHit> get _currentLyricHits =>
      widget.filters.lyrics && _lyricHitsQuery == _query.phrase
          ? _lyricHits
          : const [];

  List<SearchHit> _search(List<Track> tracks, List<Playlist> playlists) {
    final lyricHits = _currentLyricHits;
    if (!identical(tracks, _searchedTracks) ||
        _query != _searchedQuery ||
        widget.filters != _searchedFilters ||
        !identical(lyricHits, _searchedLyrics) ||
        !identical(playlists, _searchedPlaylists)) {
      _searchedTracks = tracks;
      _searchedQuery = _query;
      _searchedFilters = widget.filters;
      _searchedLyrics = lyricHits;
      _searchedPlaylists = playlists;
      _hits = searchLibrary(
        tracks,
        _query,
        filters: widget.filters,
        lyricHits: lyricHits,
        playlistOrder: {
          for (var i = 0; i < playlists.length; i++) playlists[i].id: i,
        },
      );
    }
    return _hits;
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

  /// "Lyrics" or "Transcripts" when some playlist has lyrics on, else null.
  static String? _lyricsLabel(List<Playlist> playlists) {
    final modes = {
      for (final p in playlists)
        if (LyricsMode.fromDb(p.lyricsMode) case final mode?) mode,
    };
    if (modes.isEmpty) return null;
    return modes.length == 1 && modes.single == LyricsMode.transcript
        ? 'Transcripts'
        : 'Lyrics';
  }

  @override
  Widget build(BuildContext context) {
    final playlistsAsync = ref.watch(playlistsProvider);
    final visibleAsync = ref.watch(visiblePlaylistsProvider);
    final tracksAsync = ref.watch(allTracksProvider);

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

    final query = _query;
    final playlistsById = {for (final p in playlists) p.id: p};
    final matchingPlaylists =
        query.isEmpty
            ? const <Playlist>[]
            : [
              for (final p in visibleAsync.valueOrNull ?? playlists)
                if (matchesSearchText(p.name, query)) p,
            ];
    final hits = _search(tracks, playlists);
    // Tracks found only by a lyric line show as their lines, below.
    final trackHits = [
      for (final hit in hits)
        if (hit.reason != SearchReason.lyrics) hit,
    ];
    final lyricHits = _lyricRows(tracks);
    final lyricsLabel = _lyricsLabel(playlists);
    final entries =
        query.isEmpty ? const <QueueEntry>[] : searchQueueEntries(hits);

    final Widget results;
    if (trackHits.isEmpty && matchingPlaylists.isEmpty && lyricHits.isEmpty) {
      results =
          lyricsLabel != null && !widget.filters.lyrics && query.canSearchLyrics
              ? SearchLyricsNudge(
                message: 'No titles match',
                lyricsLabel: lyricsLabel,
                onSearchLyrics:
                    () => widget.onFiltersChanged(
                      widget.filters.copyWith(lyrics: true),
                    ),
              )
              : const _SearchMessage('Nothing matches');
    } else {
      results = _buildList(
        query: query,
        playlistsById: playlistsById,
        matchingPlaylists: matchingPlaylists,
        trackHits: trackHits,
        lyricHits: lyricHits,
        tracks: tracks,
      );
    }

    final showActions = !query.isEmpty && hits.isNotEmpty;
    final showBar = lyricsLabel != null || showActions;
    return Column(
      children: [
        if (showBar)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
            child: Row(
              children: [
                // The chips scroll and the count shrinks, so Play all always
                // keeps its size.
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: SearchFilterChips(
                          filters: widget.filters,
                          lyricsLabel: lyricsLabel,
                          onChanged: widget.onFiltersChanged,
                        ),
                      ),
                      if (showActions)
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              hits.length == 1
                                  ? '1 track'
                                  : '${hits.length} tracks',
                              key: const ValueKey('search-result-count'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _searchMuted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (showActions)
                  SearchPlayAllButton(
                    entries: entries,
                    onPlayAll: () => _playAll(entries),
                    onAddToUpNext:
                        () => addSearchResultsToUpNext(
                          context,
                          ref.read(playbackServiceProvider),
                          entries,
                        ),
                  ),
              ],
            ),
          ),
        Expanded(child: results),
      ],
    );
  }

  Widget _buildList({
    required SearchQuery query,
    required Map<int, Playlist> playlistsById,
    required List<Playlist> matchingPlaylists,
    required List<SearchHit> trackHits,
    required List<(LyricsHit, Track)> lyricHits,
    required List<Track> tracks,
  }) {
    // Rows: [playlist header + playlists], [tracks header] + tracks,
    // [lyrics header + lyric lines].
    final showHeaders = matchingPlaylists.isNotEmpty || lyricHits.isNotEmpty;
    final playlistRows =
        matchingPlaylists.isEmpty ? 0 : matchingPlaylists.length + 1;
    final trackHeader = showHeaders && trackHits.isNotEmpty ? 1 : 0;
    final trackRows = trackHeader + trackHits.length;
    final lyricRows = lyricHits.isEmpty ? 0 : lyricHits.length + 1;
    final itemCount = playlistRows + trackRows + lyricRows;
    final indexWidth = _indexWidth(context, trackHits);

    return ValueListenableBuilder<double>(
      valueListenable: audioPlayerOverlayHeightNotifier,
      builder:
          (context, overlayHeight, _) => ListView.builder(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(
              bottom:
                  overlayHeight + 12 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (index < playlistRows) {
                if (index == 0) return const _SearchHeader('Playlists');
                final playlist = matchingPlaylists[index - 1];
                return _PlaylistResultTile(
                  playlist: playlist,
                  query: query,
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
                  onActions: () => widget.onTrackActions(track),
                );
              }
              if (trackHeader == 1) {
                if (i == 0) return const _SearchHeader('Tracks');
                i--;
              }
              final hit = trackHits[i];
              final track = hit.track;
              final playlist = playlistsById[track.playlistId];
              return _SearchTrackTile(
                key: ValueKey('search-track-${track.id}'),
                hit: hit,
                query: query,
                playlist: playlist,
                indexWidth: indexWidth,
                onTap: () => _onTrackTap(hit, playlist, tracks),
                // The file's menu, also when a chapter of it was found.
                onActions: () => widget.onTrackActions(track),
              );
            },
          ),
    );
  }

  /// The width of the track numbers' column: as wide as the longest number
  /// found, as on the playlist page, so the title keeps its room next to
  /// the ⋮.
  static double _indexWidth(BuildContext context, List<SearchHit> hits) {
    var maxIndex = 9;
    for (final hit in hits) {
      if (hit.track.index > maxIndex) maxIndex = hit.track.index;
    }
    final painter = TextPainter(
      text: TextSpan(
        text: '$maxIndex',
        style: DefaultTextStyle.of(
          context,
        ).style.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble() + 2;
    painter.dispose();
    return width;
  }

  void _playAll(List<QueueEntry> entries) {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(ref.read(playbackServiceProvider).playEntries(entries));
  }

  /// The lyric hits whose track is still in the library, with the track.
  List<(LyricsHit, Track)> _lyricRows(List<Track> tracks) {
    final lyricHits = _currentLyricHits;
    if (lyricHits.isEmpty) return const [];
    final wanted = {for (final hit in lyricHits) hit.trackId};
    final byId = {
      for (final track in tracks)
        if (wanted.contains(track.id)) track.id: track,
    };
    return [
      for (final hit in lyricHits)
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

  void _onTrackTap(SearchHit hit, Playlist? playlist, List<Track> tracks) {
    final track = hit.track;
    FocusManager.instance.primaryFocus?.unfocus();
    if (playlist == null || !_canPlay(track, playlist)) return;
    ref
        .read(playbackServiceProvider)
        .playTrack(
          track,
          _queueFor(tracks, track.playlistId),
          playlist: playlist,
          chapterId: hit.chapter?.id,
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

const _searchMuted = Color(0xFF888888);

/// One matched lyric or transcript line: the track (or chapter) title, then
/// the line with its matched words highlighted and its time, and the ⋮ of
/// the file it is in.
class _LyricsResultTile extends ConsumerWidget {
  const _LyricsResultTile({
    super.key,
    required this.hit,
    required this.track,
    required this.playlist,
    required this.onTap,
    required this.onActions,
  });

  final LyricsHit hit;
  final Track track;
  final Playlist? playlist;
  final VoidCallback onTap;

  /// Opens the file's options sheet (⋮ or a long press).
  final VoidCallback onActions;

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
        onLongPress: onActions,
        child: Padding(
          // As the track results; the ⋮ brings its own room on the right.
          padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Icon(
                  hit.kind == LyricsMode.transcript
                      ? Icons.subtitles_outlined
                      : Icons.lyrics_outlined,
                  color: isCurrentTrack ? _accent : _muted,
                  size: 20,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chapter?.title ?? track.displayTitle,
                      key: ValueKey('search-lyric-title-${track.id}'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrentTrack ? _accent : Colors.white,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      chapter == null
                          ? playlistName
                          : '${track.displayTitle} · $playlistName',
                      key: ValueKey('search-lyric-source-${track.id}'),
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
              _TrackMoreButton(
                key: ValueKey('search-lyrics-more-${hit.docId}'),
                onPressed: onActions,
              ),
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
  const _PlaylistResultTile({
    required this.playlist,
    required this.query,
    required this.onTap,
  });

  final Playlist playlist;
  final SearchQuery query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.queue_music, color: Color(0xFFAAAAAA)),
      title: searchHighlightedText(
        playlist.name,
        query,
        maxLines: 2,
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

/// One track in the search results, with the words found highlighted and
/// the chapter found, if any, and the file's ⋮. Only this tile rebuilds
/// when it starts or stops being the playing track.
class _SearchTrackTile extends ConsumerWidget {
  const _SearchTrackTile({
    super.key,
    required this.hit,
    required this.query,
    required this.playlist,
    required this.indexWidth,
    required this.onTap,
    required this.onActions,
  });

  final SearchHit hit;
  final SearchQuery query;
  final Playlist? playlist;

  /// The width of the track number, the same in every row.
  final double indexWidth;
  final VoidCallback onTap;

  /// Opens the file's options sheet (⋮ or a long press).
  final VoidCallback onActions;

  Track get track => hit.track;

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
    final details = shortTrackStatus(track);
    final playlistName = playlist?.name ?? 'Playlist #${track.playlistId}';
    final subtitle =
        details.isEmpty ? playlistName : '$playlistName · $details';
    final thumbnailWidth =
        MediaQuery.sizeOf(context).width < 360 ? 96.0 : 112.0;

    return Material(
      color: isCurrentTrack ? const Color(0xFF2A2A2A) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onActions,
        child: Padding(
          // As on the playlist page; the ⋮ brings its own room on the right.
          padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
          child: Row(
            children: [
              SizedBox(
                width: indexWidth,
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
              const SizedBox(width: 8),
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
                    searchHighlightedText(
                      track.displayTitle,
                      query,
                      style: TextStyle(
                        color: isCurrentTrack ? _accent : Colors.white,
                        fontSize: 14,
                        fontWeight:
                            isCurrentTrack
                                ? FontWeight.w600
                                : FontWeight.normal,
                      ),
                      maxLines: 2,
                    ),
                    if (hit.chapter case final chapter?) ...[
                      const SizedBox(height: 2),
                      Text.rich(
                        _chapterLine(chapter),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFAAAAAA),
                          fontSize: 12,
                        ),
                      ),
                    ],
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
              const SizedBox(width: 4),
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
              _TrackMoreButton(
                key: ValueKey('search-track-more-${track.id}'),
                onPressed: onActions,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `Chapter: Title · 1:20`, and how many more chapters matched. Only the
  /// title is highlighted, not the label, the time or the count.
  TextSpan _chapterLine(MediaChapter chapter) {
    final more = hit.chapters.length - 1;
    return TextSpan(
      children: [
        const TextSpan(text: 'Chapter: '),
        ...lyricsSpans(
          chapter.title,
          searchHighlights(chapter.title, query),
          const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        TextSpan(
          text:
              ' · ${formatLyricsTime(chapter.startMs)}'
              '${more > 0 ? ' · +$more more' : ''}',
        ),
      ],
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
}

/// The ⋮ of a file in the search results, like the one of its row on the
/// playlist page. It is a little narrower than a usual button (44 wide, a
/// full 48 tall, at the edge of the screen) so the title keeps most of its
/// room, while still being easy to hit without tapping the row beside it.
class _TrackMoreButton extends StatelessWidget {
  const _TrackMoreButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.more_vert, color: _searchMuted, size: 20),
      tooltip: 'Track options',
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
