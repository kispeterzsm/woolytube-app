import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../database/database.dart';
import '../providers/providers.dart';
import '../services/download_errors.dart';
import '../services/playlist_service.dart';
import '../services/sponsorblock_categories.dart';
import '../services/sponsorblock_service.dart';
import 'sponsorblock_settings_page.dart';
import '../widgets/mobile_data_download_guard.dart';
import '../widgets/update_frequency_dropdown.dart';

class PlaylistSettingsPage extends ConsumerStatefulWidget {
  final int playlistId;

  const PlaylistSettingsPage({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistSettingsPage> createState() =>
      _PlaylistSettingsPageState();
}

class _PlaylistSettingsPageState extends ConsumerState<PlaylistSettingsPage> {
  Playlist? _playlist;
  late TextEditingController _nameController;
  bool _audioOnly = false;
  bool _playChapters = true;
  bool _fetchingChapters = false;
  bool _autoUpdate = true;
  int _updateFrequencyHours = 24;
  bool _includeThumbnails = true;
  bool _sponsorBlockEnabled = true;
  Map<String, SponsorBlockCategoryAction> _sponsorBlockCategoryActions =
      defaultSponsorBlockCategoryActions();
  Map<String, SponsorBlockCategoryAction> _loadedSponsorBlockCategoryActions =
      defaultSponsorBlockCategoryActions();
  bool _loaded = false;
  bool _isForceInserting = false;
  bool _saving = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _nameController.addListener(_onNameChanged);
    _loadPlaylist();
  }

  void _onNameChanged() {
    // Save enablement and the dirty check depend on the name text.
    if (mounted) setState(() {});
  }

  Future<void> _loadPlaylist() async {
    final db = ref.read(databaseProvider);
    final Playlist playlist;
    try {
      playlist = await db.getPlaylist(widget.playlistId);
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not load playlist: $e');
      Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    final actions = decodeSponsorBlockCategoryActions(
      playlist.sponsorBlockCategoryActions,
      legacyCategories: playlist.sponsorBlockCategories,
    );
    setState(() {
      _playlist = playlist;
      _nameController.text = playlist.name;
      _audioOnly = playlist.audioOnly;
      _playChapters = playlist.playChapters ?? true;
      _autoUpdate = playlist.autoUpdate;
      _updateFrequencyHours = nearestUpdateFrequency(
        playlist.updateFrequencyHours,
      );
      _includeThumbnails = playlist.includeThumbnails;
      _sponsorBlockEnabled = playlist.sponsorBlockEnabled;
      _sponsorBlockCategoryActions = actions;
      _loadedSponsorBlockCategoryActions = {...actions};
      _loaded = true;
    });
  }

  bool get _nameValid => _nameController.text.trim().isNotEmpty;

  bool get _isDirty {
    final playlist = _playlist;
    if (playlist == null) return false;
    if (_nameController.text.trim() != playlist.name) return true;
    if (_audioOnly != playlist.audioOnly) return true;
    if (_playChapters != (playlist.playChapters ?? true)) return true;
    if (_autoUpdate != playlist.autoUpdate) return true;
    if (_updateFrequencyHours !=
        nearestUpdateFrequency(playlist.updateFrequencyHours)) {
      return true;
    }
    if (_includeThumbnails != playlist.includeThumbnails) return true;
    if (_sponsorBlockEnabled != playlist.sponsorBlockEnabled) return true;
    for (final definition in sponsorBlockCategoryDefinitions) {
      final loaded =
          _loadedSponsorBlockCategoryActions[definition.id] ??
          definition.defaultAction;
      final current =
          _sponsorBlockCategoryActions[definition.id] ??
          definition.defaultAction;
      if (loaded != current) return true;
    }
    return false;
  }

  Future<void> _onPopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    final discard = await showDiscardChangesDialog(context);
    if (discard && mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_saving || !_nameValid) return;
    setState(() => _saving = true);
    try {
      final service = ref.read(playlistServiceProvider);
      await service.updatePlaylistSettings(
        id: widget.playlistId,
        name: _nameController.text.trim(),
        audioOnly: _audioOnly,
        playChapters: _playChapters,
        autoUpdate: _autoUpdate,
        updateFrequencyHours: _updateFrequencyHours,
        includeThumbnails: _includeThumbnails,
        sponsorBlockEnabled: _sponsorBlockEnabled,
        sponsorBlockCategoryActions: _sponsorBlockCategoryActions,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showMessage('Could not save settings: $e');
    }
  }

  Future<void> _setAudioOnly(bool value) async {
    final playlist = _playlist;
    if (value && playlist != null && !playlist.audioOnly) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF2A2A2A),
              title: const Text(
                'Switch to audio only?',
                style: TextStyle(color: Colors.white),
              ),
              content: const Text(
                'Audio-only downloads are stored in a separate folder, so '
                'every track in this playlist will be downloaded again on '
                'the next update. The existing video files stay where they '
                'are.',
                style: TextStyle(color: Color(0xFFCCCCCC)),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Switch'),
                ),
              ],
            ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _audioOnly = value);
  }

  Future<void> _delete() async {
    if (_deleting) return;
    var deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  backgroundColor: const Color(0xFF2A2A2A),
                  title: const Text(
                    'Delete playlist?',
                    style: TextStyle(color: Colors.white),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deleteFiles
                            ? 'This removes the playlist from the app and '
                                'deletes its downloaded files from storage.'
                            : 'This removes the playlist from the app. '
                                'Downloaded files are kept on the device.',
                        style: const TextStyle(color: Color(0xFF888888)),
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        key: const ValueKey('delete-files-checkbox'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: deleteFiles,
                        onChanged:
                            (value) => setDialogState(
                              () => deleteFiles = value ?? false,
                            ),
                        title: const Text(
                          'Also delete downloaded files',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      key: const ValueKey('delete-playlist-confirm'),
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
          ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      final service = ref.read(playlistServiceProvider);
      await service.deletePlaylist(widget.playlistId, deleteFiles: deleteFiles);
      if (!mounted) return;
      // The detail page underneath refers to a playlist that no longer
      // exists, so return all the way to the home page.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _showMessage('Could not delete playlist: $e');
    }
  }

  Future<void> _openPlaylistOnYouTube() async {
    final url = _playlist?.url;
    if (url == null) return;

    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open this playlist.')),
      );
    }
  }

  Future<void> _openSponsorBlockSettings() async {
    final actions = await Navigator.of(
      context,
    ).push<Map<String, SponsorBlockCategoryAction>>(
      MaterialPageRoute(
        builder:
            (_) => SponsorBlockSettingsPage(
              categoryActions: _sponsorBlockCategoryActions,
            ),
      ),
    );
    if (actions != null && mounted) {
      setState(() => _sponsorBlockCategoryActions = actions);
    }
  }

  Future<void> _fetchMissingChapters() async {
    if (_fetchingChapters) return;
    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _fetchingChapters = true);
    try {
      final result = await ref
          .read(chapterServiceProvider)
          .fetchMissing(widget.playlistId);
      if (mounted) {
        _showMessage('Checked ${result.$1} files; ${result.$2} failed.');
      }
    } catch (e) {
      if (mounted) {
        _showMessage(
          'Could not fetch chapters: ${friendlyDownloadError('$e')}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _fetchingChapters = false);
      }
    }
  }

  Future<void> _forceInsert() async {
    final playlist = _playlist;
    if (playlist == null || _isForceInserting) return;

    setState(() => _isForceInserting = true);
    try {
      final service = ref.read(playlistServiceProvider);
      final tracks = await service.getTracksForPlaylist(playlist.id);
      var highestIndex = 0;
      for (final track in tracks) {
        if (track.index > highestIndex) highestIndex = track.index;
      }
      final maximumIndex = tracks.isEmpty ? 1 : highestIndex + 1;
      if (!mounted) return;

      final index = await _askForceInsertIndex(maximumIndex);
      if (index == null || !mounted) return;

      final allowedExtensions =
          playlist.audioOnly
              ? PlaylistService.allowedAudioExtensions
              : PlaylistService.allowedVideoExtensions;
      FilePickerResult? result;
      try {
        result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: allowedExtensions,
          withData: false,
        );
      } catch (_) {
        // Some Android document providers reject custom filters. The service
        // still validates the selected extension after this fallback.
        result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          withData: false,
        );
      }
      if (result == null || result.files.isEmpty || !mounted) return;

      final picked = result.files.single;
      final sourcePath = picked.path;
      if (sourcePath == null) {
        _showMessage('Could not access the selected file.');
        return;
      }

      final inserted = await service.forceInsert(
        playlistId: playlist.id,
        index: index,
        sourcePath: sourcePath,
        sourceFileName: picked.name,
      );
      if (mounted) {
        _showMessage('Inserted "${inserted.title}" at #$index.');
      }
    } on ForceInsertException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (error) {
      if (mounted) _showMessage('Could not insert the selected file: $error');
    } finally {
      if (mounted) setState(() => _isForceInserting = false);
    }
  }

  Future<int?> _askForceInsertIndex(int maximumIndex) async {
    return showDialog<int>(
      context: context,
      builder: (_) => _ForceInsertIndexDialog(maximumIndex: maximumIndex),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final busy = _saving || _deleting;
    return PopScope(
      canPop: !_isDirty || busy,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Playlist Settings'),
          actions: [
            TextButton(
              key: const ValueKey('playlist-settings-save'),
              onPressed: busy || !_nameValid ? null : _save,
              child:
                  _saving
                      ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : Text(
                        'Save',
                        style: TextStyle(
                          color:
                              _nameValid
                                  ? const Color(0xFF2196F3)
                                  : const Color(0xFF666666),
                          fontSize: 16,
                        ),
                      ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('playlist-name-field'),
                controller: _nameController,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  labelText: 'Playlist name',
                  labelStyle: const TextStyle(color: Color(0xFF888888)),
                  errorText: _nameValid ? null : 'Enter a name',
                ),
              ),
              if (_playlist != null) ...[
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: _playlist!.url,
                        readOnly: true,
                        maxLines: null,
                        style: const TextStyle(color: Color(0xFFBBBBBB)),
                        decoration: const InputDecoration(
                          labelText: 'Playlist link',
                          labelStyle: TextStyle(color: Color(0xFF888888)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _openPlaylistOnYouTube,
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('YouTube'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 32),
              _settingsToggle(
                'Audio only',
                'Download audio tracks only (m4a)',
                _audioOnly,
                _setAudioOnly,
              ),
              _settingsToggle(
                'Auto-update',
                'Automatically check for new videos',
                _autoUpdate,
                (v) => setState(() => _autoUpdate = v),
              ),
              const SizedBox(height: 8),
              UpdateFrequencyDropdown(
                value: _updateFrequencyHours,
                enabled: _autoUpdate,
                onChanged:
                    (hours) => setState(() => _updateFrequencyHours = hours),
              ),
              const SizedBox(height: 12),
              _settingsToggle(
                'Include thumbnails',
                'Embed thumbnails in downloaded files',
                _includeThumbnails,
                (v) => setState(() => _includeThumbnails = v),
              ),
              const SizedBox(height: 24),
              _settingsToggle(
                'Play chapters as tracks',
                'Use chapter titles, progress, and next/previous controls',
                _playChapters,
                (v) => setState(() => _playChapters = v),
              ),
              TextButton.icon(
                icon: const Icon(Icons.download),
                label: Text(
                  _fetchingChapters
                      ? 'Fetching chapters…'
                      : 'Fetch missing chapters for downloaded files',
                ),
                onPressed: _fetchingChapters ? null : _fetchMissingChapters,
              ),
              _settingsToggle(
                'SponsorBlock',
                'Skip configured segments during playback',
                _sponsorBlockEnabled,
                (v) => setState(() => _sponsorBlockEnabled = v),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openSponsorBlockSettings,
                icon: const Icon(Icons.tune),
                label: const Text('SponsorBlock settings'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                playlistForceInsertDescription(_playlist!.audioOnly),
                style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('force-insert-button'),
                onPressed: _isForceInserting ? null : _forceInsert,
                icon:
                    _isForceInserting
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.playlist_add),
                label: const Text('Force Insert'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 48),
              OutlinedButton(
                key: const ValueKey('delete-playlist-button'),
                onPressed: busy ? null : _delete,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child:
                    _deleting
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.red,
                          ),
                        )
                        : const Text(
                          'Delete Playlist',
                          style: TextStyle(color: Colors.red, fontSize: 16),
                        ),
              ),
            ],
          ),
        ),
      ),
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

String playlistForceInsertDescription(bool audioOnly) {
  final kind = audioOnly ? 'audio' : 'video';
  return 'Insert a local $kind file at an exact playlist index. Later items '
      'will be moved forward.';
}

class _ForceInsertIndexDialog extends StatefulWidget {
  final int maximumIndex;

  const _ForceInsertIndexDialog({required this.maximumIndex});

  @override
  State<_ForceInsertIndexDialog> createState() =>
      _ForceInsertIndexDialogState();
}

class _ForceInsertIndexDialogState extends State<_ForceInsertIndexDialog> {
  final _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final index = int.tryParse(_controller.text);
    if (index == null || index < 1 || index > widget.maximumIndex) {
      setState(
        () => _errorText = 'Enter a number from 1 to ${widget.maximumIndex}.',
      );
      return;
    }
    Navigator.pop(context, index);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text('Force Insert', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Choose an index from 1 to ${widget.maximumIndex}. Items at '
            'that index and later will move forward.',
            style: const TextStyle(color: Color(0xFFBBBBBB)),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('force-insert-index-field'),
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Index',
              errorText: _errorText,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('force-insert-select-file'),
          onPressed: _submit,
          child: const Text('Select file'),
        ),
      ],
    );
  }
}
