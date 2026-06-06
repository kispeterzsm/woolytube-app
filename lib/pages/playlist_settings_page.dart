import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/providers.dart';

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
  bool _autoUpdate = true;
  int _updateFrequencyHours = 24;
  bool _includeThumbnails = true;
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
      _updateFrequencyHours = playlist.updateFrequencyHours;
      _includeThumbnails = playlist.includeThumbnails;
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
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Delete playlist?',
            style: TextStyle(color: Colors.white)),
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
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
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
            child: const Text('Save',
                style: TextStyle(color: Color(0xFF2196F3), fontSize: 16)),
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
                  fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                labelText: 'Playlist name',
                labelStyle: TextStyle(color: Color(0xFF888888)),
              ),
            ),
            if (_playlist?.url != null) ...[
              const SizedBox(height: 8),
              Text(
                _playlist!.url,
                style:
                    const TextStyle(color: Color(0xFF666666), fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
            _settingsToggle(
              'Include thumbnails',
              'Embed thumbnails in downloaded files',
              _includeThumbnails,
              (v) => setState(() => _includeThumbnails = v),
            ),
            if (_autoUpdate) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Update every',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Slider(
                      value: _updateFrequencyHours.toDouble(),
                      min: 1,
                      max: 168,
                      divisions: 167,
                      activeColor: const Color(0xFF2196F3),
                      inactiveColor: const Color(0xFF333333),
                      onChanged: (v) =>
                          setState(() => _updateFrequencyHours = v.round()),
                    ),
                  ),
                  SizedBox(
                    width: 60,
                    child: Text(
                      _formatFrequency(_updateFrequencyHours),
                      style: const TextStyle(
                          color: Color(0xFF888888), fontSize: 13),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ],
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
              child: const Text('Delete Playlist',
                  style: TextStyle(color: Colors.red, fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingsToggle(
      String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 14)),
                Text(subtitle,
                    style: const TextStyle(
                        color: Color(0xFF888888), fontSize: 12)),
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

  String _formatFrequency(int hours) {
    if (hours < 24) return '${hours}h';
    final days = hours ~/ 24;
    if (days == 7) return '1 week';
    return '${days}d';
  }
}
