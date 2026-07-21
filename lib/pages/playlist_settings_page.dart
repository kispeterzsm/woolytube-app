import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../database/database.dart';
import '../providers/providers.dart';
import '../services/sponsorblock_service.dart';
import 'sponsorblock_settings_page.dart';

class PlaylistSettingsPage extends ConsumerStatefulWidget {
  final int playlistId;

  const PlaylistSettingsPage({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistSettingsPage> createState() =>
      _PlaylistSettingsPageState();
}

class _PlaylistSettingsPageState extends ConsumerState<PlaylistSettingsPage> {
  static const _updateFrequencyOptions = <int, String>{
    1: '1 hour',
    12: '12 hours',
    24: '1 day',
    72: '3 days',
    168: '1 week',
  };

  Playlist? _playlist;
  late TextEditingController _nameController;
  bool _audioOnly = false;
  bool _autoUpdate = true;
  int _updateFrequencyHours = 24;
  bool _includeThumbnails = true;
  bool _sponsorBlockEnabled = true;
  Map<String, SponsorBlockCategoryAction> _sponsorBlockCategoryActions =
      defaultSponsorBlockCategoryActions();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _loadPlaylist();
  }

  Future<void> _loadPlaylist() async {
    final db = ref.read(databaseProvider);
    final playlist = await db.getPlaylist(widget.playlistId);
    setState(() {
      _playlist = playlist;
      _nameController.text = playlist.name;
      _audioOnly = playlist.audioOnly;
      _autoUpdate = playlist.autoUpdate;
      _updateFrequencyHours = _nearestUpdateFrequency(
        playlist.updateFrequencyHours,
      );
      _includeThumbnails = playlist.includeThumbnails;
      _sponsorBlockEnabled = playlist.sponsorBlockEnabled;
      _sponsorBlockCategoryActions = decodeSponsorBlockCategoryActions(
        playlist.sponsorBlockCategoryActions,
        legacyCategories: playlist.sponsorBlockCategories,
      );
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final service = ref.read(playlistServiceProvider);
    await service.updatePlaylistSettings(
      id: widget.playlistId,
      name: _nameController.text.trim(),
      audioOnly: _audioOnly,
      autoUpdate: _autoUpdate,
      updateFrequencyHours: _updateFrequencyHours,
      includeThumbnails: _includeThumbnails,
      sponsorBlockEnabled: _sponsorBlockEnabled,
      sponsorBlockCategoryActions: _sponsorBlockCategoryActions,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text(
              'Delete playlist?',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'This will remove the playlist from the app. Downloaded files will not be deleted.',
              style: TextStyle(color: Color(0xFF888888)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      final service = ref.read(playlistServiceProvider);
      await service.deletePlaylist(widget.playlistId);
      if (mounted) Navigator.of(context).pop();
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

  @override
  void dispose() {
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlist Settings'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'Save',
              style: TextStyle(color: Color(0xFF2196F3), fontSize: 16),
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
              controller: _nameController,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
              decoration: const InputDecoration(
                labelText: 'Playlist name',
                labelStyle: TextStyle(color: Color(0xFF888888)),
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
              (v) => setState(() => _audioOnly = v),
            ),
            _settingsToggle(
              'Auto-update',
              'Automatically check for new videos',
              _autoUpdate,
              (v) => setState(() => _autoUpdate = v),
            ),
            const SizedBox(height: 8),
            Opacity(
              opacity: _autoUpdate ? 1 : 0.45,
              child: DropdownButtonFormField<int>(
                value: _updateFrequencyHours,
                isExpanded: true,
                dropdownColor: const Color(0xFF2A2A2A),
                decoration: const InputDecoration(
                  labelText: 'Auto-update frequency',
                  labelStyle: TextStyle(color: Color(0xFF888888)),
                  border: OutlineInputBorder(),
                ),
                items:
                    _updateFrequencyOptions.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                onChanged:
                    _autoUpdate
                        ? (value) {
                          if (value != null) {
                            setState(() => _updateFrequencyHours = value);
                          }
                        }
                        : null,
              ),
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
            const SizedBox(height: 48),
            OutlinedButton(
              onPressed: _delete,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text(
                'Delete Playlist',
                style: TextStyle(color: Colors.red, fontSize: 16),
              ),
            ),
          ],
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

  int _nearestUpdateFrequency(int hours) {
    return _updateFrequencyOptions.keys.reduce(
      (nearest, option) =>
          (option - hours).abs() < (nearest - hours).abs() ? option : nearest,
    );
  }
}
