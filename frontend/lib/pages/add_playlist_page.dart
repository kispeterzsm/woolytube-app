import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/providers.dart';

class AddPlaylistPage extends ConsumerStatefulWidget {
  const AddPlaylistPage({super.key});

  @override
  ConsumerState<AddPlaylistPage> createState() => _AddPlaylistPageState();
}

class _AddPlaylistPageState extends ConsumerState<AddPlaylistPage> {
  final _urlController = TextEditingController();
  bool _audioOnly = false;
  bool _autoUpdate = true;
  int _updateFrequencyHours = 24;
  bool _includeThumbnails = true;

  bool _fetching = false;
  bool _adding = false;
  String? _error;

  // Fetched playlist info
  String? _playlistTitle;
  String? _playlistThumbnail;
  int _trackCount = 0;
  Map<String, dynamic>? _playlistInfo;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _fetchInfo() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _fetching = true;
      _error = null;
      _playlistInfo = null;
    });

    try {
      final ytdlp = ref.read(ytdlpServiceProvider);
      final info = await ytdlp.getPlaylistInfo(url);
      setState(() {
        _playlistInfo = info;
        _playlistTitle = info['title'] as String? ?? 'Unknown Playlist';
        _playlistThumbnail = info['thumbnail'] as String?;
        _trackCount = info['count'] as int? ?? 0;
        _fetching = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to fetch playlist info: $e';
        _fetching = false;
      });
    }
  }

  Future<void> _addPlaylist() async {
    if (_playlistInfo == null || _playlistTitle == null) return;

    setState(() => _adding = true);

    try {
      final service = ref.read(playlistServiceProvider);
      final playlistId = await service.addPlaylist(
        url: _urlController.text.trim(),
        name: _playlistTitle!,
        thumbnailUrl: _playlistThumbnail,
        audioOnly: _audioOnly,
        autoUpdate: _autoUpdate,
        updateFrequencyHours: _updateFrequencyHours,
        includeThumbnails: _includeThumbnails,
      );

      await service.populateTracksFromInfo(playlistId, _playlistInfo!);

      if (mounted) {
        // Start downloading automatically
        final db = ref.read(databaseProvider);
        final playlist = await db.getPlaylist(playlistId);
        ref.read(downloadServiceProvider).downloadPlaylist(playlist);

        Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to add playlist: $e';
        _adding = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Playlist'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Paste YouTube playlist URL...',
                prefixIcon:
                    const Icon(Icons.link, color: Color(0xFF888888)),
                suffixIcon: _fetching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.search,
                            color: Color(0xFF2196F3)),
                        onPressed: _fetchInfo,
                      ),
              ),
              onSubmitted: (_) => _fetchInfo(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
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
                  onPressed: _adding ? null : _addPlaylist,
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
                placeholder: (_, __) => Container(
                  color: const Color(0xFF333333),
                  child: const Center(child: CircularProgressIndicator()),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: const Color(0xFF333333),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _playlistTitle ?? '',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$_trackCount videos',
                  style:
                      const TextStyle(color: Color(0xFF888888), fontSize: 14),
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
      ],
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
