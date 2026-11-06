import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/providers.dart';
import '../services/download_errors.dart';
import '../services/playlist_service.dart';
import '../widgets/mobile_data_download_guard.dart';
import '../widgets/update_frequency_dropdown.dart';

class AddPlaylistPage extends ConsumerStatefulWidget {
  const AddPlaylistPage({super.key});

  @override
  ConsumerState<AddPlaylistPage> createState() => _AddPlaylistPageState();
}

class _AddPlaylistPageState extends ConsumerState<AddPlaylistPage> {
  final _urlController = TextEditingController();

  /// The playlist's name in the app and its folder name; starts as the
  /// YouTube title.
  final _nameController = TextEditingController();
  bool _audioOnly = false;
  bool _playChapters = true;
  bool _autoUpdate = true;
  int _updateFrequencyHours = 24;
  bool _includeThumbnails = true;

  bool _fetching = false;
  bool _adding = false;
  String? _error;

  // Fetched playlist info
  String? _playlistThumbnail;
  int _trackCount = 0;
  Map<String, dynamic>? _playlistInfo;

  /// The URL [_playlistInfo] was fetched for. Add is only enabled while the
  /// text field still contains this URL, so stale tracks are never combined
  /// with a different link.
  String? _fetchedUrl;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_onUrlChanged);
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _onUrlChanged() {
    if (_playlistInfo == null && _error == null) return;
    if (_urlController.text.trim() == _fetchedUrl) return;
    setState(() {
      _playlistInfo = null;
      _playlistThumbnail = null;
      _trackCount = 0;
      _fetchedUrl = null;
      _error = null;
    });
  }

  bool get _nameValid => _nameController.text.trim().isNotEmpty;

  bool get _canAdd =>
      !_adding &&
      !_fetching &&
      _nameValid &&
      _playlistInfo != null &&
      _fetchedUrl != null &&
      _urlController.text.trim() == _fetchedUrl;

  Future<void> _fetchInfo() async {
    if (_fetching) return;
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _fetching = true;
      _error = null;
      _playlistInfo = null;
      _fetchedUrl = null;
    });

    try {
      final ytdlp = ref.read(ytdlpServiceProvider);
      final info = await ytdlp.getPlaylistInfo(url);
      if (!mounted) return;
      final title = (info['title'] as String? ?? '').trim();
      setState(() {
        _playlistInfo = info;
        _fetchedUrl = url;
        // Never prefill a blank name: it also names the playlist's folder.
        _nameController.text = title.isEmpty ? 'Playlist' : title;
        _playlistThumbnail = info['thumbnail'] as String?;
        _trackCount = info['count'] as int? ?? 0;
        _fetching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error =
            'Failed to fetch playlist info: ${friendlyDownloadError('$e')}';
        _fetching = false;
      });
    }
  }

  Future<void> _addPlaylist() async {
    if (!_canAdd) return;
    final info = _playlistInfo;
    final url = _fetchedUrl;
    final name = _nameController.text.trim();
    if (info == null || url == null || name.isEmpty) return;

    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      return;
    }
    if (!mounted) return;

    setState(() => _adding = true);

    // Read providers before awaiting: `ref` is unusable after disposal and
    // the download must still start if the user leaves this page.
    final service = ref.read(playlistServiceProvider);
    final db = ref.read(databaseProvider);
    final downloadService = ref.read(downloadServiceProvider);
    final messenger = ScaffoldMessenger.of(context);
    final int playlistId;
    try {
      playlistId = await service.addPlaylist(
        url: url,
        name: name,
        thumbnailUrl: _playlistThumbnail,
        audioOnly: _audioOnly,
        playChapters: _playChapters,
        autoUpdate: _autoUpdate,
        updateFrequencyHours: _updateFrequencyHours,
        includeThumbnails: _includeThumbnails,
      );
      // The import banner must not offer this playlist's folder again.
      final pending = ref.read(pendingImportsProvider);
      if (pending.isNotEmpty) {
        ref.read(pendingImportsProvider.notifier).state = await ref
            .read(metadataServiceProvider)
            .findUnimportedPlaylists(candidates: pending);
      }
    } on PlaylistExistsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _adding = false;
      });
      return;
    } catch (e) {
      if (!mounted) return;
      final reason = e is StateError ? e.message : '$e';
      setState(() {
        _error = 'Failed to add playlist: ${friendlyDownloadError(reason)}';
        _adding = false;
      });
      return;
    }

    // The playlist exists from here on, so the page closes whatever happens
    // next; Update on the playlist retries anything left undone.
    String message;
    try {
      // A backup found in the playlist's folder was restored with its
      // tracks and their order; the fetched list only adds what is new.
      final restored = await service.getTotalCount(playlistId);
      await service.populateTracksFromInfo(playlistId, info);

      // Start downloading automatically. The download runs regardless of
      // whether this page is still open.
      final playlist = await db.getPlaylist(playlistId);
      unawaited(downloadService.downloadPlaylist(playlist));
      message =
          restored > 0
              ? 'Added "${playlist.name}". Restored $restored '
                  'track${restored == 1 ? '' : 's'} from the existing folder.'
              : 'Added "${playlist.name}"';
    } catch (e) {
      final reason = e is StateError ? e.message : '$e';
      message =
          'Added "$name", but its tracks are not listed yet. Tap Update on '
          'the playlist to fetch them.\n$reason';
    }

    if (mounted) Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Playlist')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('add-playlist-url-field'),
              controller: _urlController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Paste YouTube playlist URL...',
                prefixIcon: const Icon(Icons.link, color: Color(0xFF888888)),
                suffixIcon:
                    _fetching
                        ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                        : IconButton(
                          icon: const Icon(
                            Icons.search,
                            color: Color(0xFF2196F3),
                          ),
                          tooltip: 'Fetch playlist info',
                          onPressed: _fetchInfo,
                        ),
              ),
              onSubmitted: (_) {
                if (!_fetching) _fetchInfo();
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
            if (_playlistInfo != null) ...[
              const SizedBox(height: 24),
              _buildPreview(),
              const SizedBox(height: 24),
              _buildSettings(),
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  key: const ValueKey('add-playlist-button'),
                  onPressed: _canAdd ? _addPlaylist : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2196F3),
                    disabledBackgroundColor: const Color(0xFF333333),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _adding ? 'Adding...' : 'Add Playlist',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_playlistThumbnail != null && _playlistThumbnail!.isNotEmpty)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: CachedNetworkImage(
                imageUrl: _playlistThumbnail!,
                fit: BoxFit.cover,
                placeholder:
                    (_, __) => Container(
                      color: const Color(0xFF333333),
                      child: const Center(child: CircularProgressIndicator()),
                    ),
                errorWidget:
                    (_, __, ___) => Container(color: const Color(0xFF333333)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('add-playlist-name-field'),
                  controller: _nameController,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Name',
                    labelStyle: const TextStyle(color: Color(0xFF888888)),
                    errorText: _nameValid ? null : 'Enter a name',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$_trackCount videos',
                  style: const TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettings() {
    return Column(
      children: [
        _settingsToggle(
          'Audio only',
          'Download audio tracks only (m4a)',
          _audioOnly,
          (v) => setState(() => _audioOnly = v),
        ),
        _settingsToggle(
          'Auto-update',
          'Automatically check for new videos',
          _autoUpdate,
          (v) => setState(() => _autoUpdate = v),
        ),
        _settingsToggle(
          'Play chapters as tracks',
          'Use chapter titles, progress, and next/previous controls',
          _playChapters,
          (v) => setState(() => _playChapters = v),
        ),
        _settingsToggle(
          'Include thumbnails',
          'Embed thumbnails in downloaded files',
          _includeThumbnails,
          (v) => setState(() => _includeThumbnails = v),
        ),
        const SizedBox(height: 16),
        UpdateFrequencyDropdown(
          value: _updateFrequencyHours,
          enabled: _autoUpdate,
          onChanged: (hours) => setState(() => _updateFrequencyHours = hours),
        ),
      ],
    );
  }

  Widget _settingsToggle(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFF2196F3),
            inactiveTrackColor: const Color(0xFF333333),
          ),
        ],
      ),
    );
  }
}
