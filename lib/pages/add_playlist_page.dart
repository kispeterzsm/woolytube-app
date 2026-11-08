import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/add_playlist_defaults.dart';
import '../services/download_errors.dart';
import '../services/metadata_service.dart';
import '../services/video_quality.dart';
import '../widgets/mobile_data_download_guard.dart';
import '../widgets/update_frequency_dropdown.dart';
import 'playlist_detail_page.dart';

/// Remembers the options of the last playlist added (see
/// [AddPlaylistDefaults]).
final addPlaylistDefaultsProvider = Provider<AddPlaylistDefaults>(
  (ref) => AddPlaylistDefaults(),
);

/// Whether [text] looks like a YouTube link (worth looking up right away
/// after pasting).
bool looksLikeYouTubeUrl(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
  final host = uri.host.toLowerCase();
  return host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com');
}

class AddPlaylistPage extends ConsumerStatefulWidget {
  const AddPlaylistPage({super.key});

  @override
  ConsumerState<AddPlaylistPage> createState() => _AddPlaylistPageState();
}

class _AddPlaylistPageState extends ConsumerState<AddPlaylistPage> {
  static const _accent = Color(0xFF2196F3);
  static const _muted = Color(0xFF888888);

  final _urlController = TextEditingController();

  /// The playlist's name in the app and its folder name; starts as the
  /// YouTube title.
  final _nameController = TextEditingController();
  bool _audioOnly = false;
  bool _playChapters = true;
  bool _autoUpdate = true;
  int _updateFrequencyHours = 24;
  bool _includeThumbnails = true;

  /// Set once the owner touched an option, so the remembered defaults that
  /// load a moment later do not overwrite the choice.
  bool _optionsTouched = false;

  /// Save only the video of the link to the temporary playlist instead of
  /// adding a playlist (offered when the link names one video).
  bool _toTemporary = false;

  bool _fetching = false;
  bool _adding = false;
  String? _error;

  /// Bumped by every lookup, URL edit and Cancel: a lookup whose number is
  /// no longer current is ignored when its answer arrives.
  ///
  /// Cancel only stops waiting: yt-dlp has no way to stop a running lookup,
  /// so it finishes in the background and its answer is dropped.
  int _fetchGeneration = 0;

  /// The URL field's text as last seen by [_onUrlChanged]. The controller
  /// also notifies for cursor and composing changes (tapping the field,
  /// unfocusing it), which must not cancel a lookup.
  String _lastUrlText = '';

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
    unawaited(_loadDefaults());
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadDefaults() async {
    try {
      final options = await ref.read(addPlaylistDefaultsProvider).load();
      if (!mounted || _optionsTouched) return;
      setState(() {
        _audioOnly = options.audioOnly;
        _autoUpdate = options.autoUpdate;
        _updateFrequencyHours = options.updateFrequencyHours;
        _playChapters = options.playChapters;
        _includeThumbnails = options.includeThumbnails;
      });
    } catch (_) {
      // The built-in defaults stay.
    }
  }

  void _setOption(VoidCallback change) {
    setState(() {
      _optionsTouched = true;
      change();
    });
  }

  void _onUrlChanged() {
    final raw = _urlController.text;
    if (raw == _lastUrlText) return;
    final linkChanged = raw.trim() != _lastUrlText.trim();
    _lastUrlText = raw;
    final text = raw.trim();
    if (!linkChanged || text == _fetchedUrl) {
      // Only the clear button may need to change.
      setState(() {});
      return;
    }
    // Drops a preview or lookup that belongs to another link.
    setState(() {
      if (_fetching) {
        _fetchGeneration++;
        _fetching = false;
      }
      _playlistInfo = null;
      _playlistThumbnail = null;
      _trackCount = 0;
      _fetchedUrl = null;
      _error = null;
      _toTemporary = false;
    });
  }

  bool get _nameValid => _nameController.text.trim().isNotEmpty;

  /// The playlist already in the library for the fetched link and the
  /// chosen format, if any (the same link may be added once as audio and
  /// once as video).
  Playlist? _existing(List<Playlist> playlists) {
    final url = _fetchedUrl;
    if (url == null) return null;
    for (final playlist in playlists) {
      if (playlist.audioOnly == _audioOnly &&
          MetadataService.samePlaylistUrl(playlist.url, url)) {
        return playlist;
      }
    }
    return null;
  }

  bool _canAdd(Playlist? existing) =>
      !_adding &&
      !_fetching &&
      existing == null &&
      _nameValid &&
      _playlistInfo != null &&
      _fetchedUrl != null &&
      _urlController.text.trim() == _fetchedUrl;

  /// Whether the looked-up link names one video: a single video, or a
  /// video inside a playlist (`watch?v=X&list=Y`).
  bool get _namesOneVideo {
    final info = _playlistInfo;
    if (info == null) return false;
    if (info['isPlaylist'] == false) {
      return (info['entries'] as List<dynamic>?)?.isNotEmpty ?? false;
    }
    return youTubeVideoIdFromUrl(_fetchedUrl) != null;
  }

  bool get _savingToTemporary => _toTemporary && _namesOneVideo;

  bool get _canSaveToTemporary =>
      !_adding &&
      !_fetching &&
      _namesOneVideo &&
      _fetchedUrl != null &&
      _urlController.text.trim() == _fetchedUrl;

  /// The entry of the one video the link names, as far as the lookup knows
  /// it (null when only the playlist around it was read).
  Map<String, dynamic>? get _knownVideoEntry {
    final info = _playlistInfo;
    if (info == null) return null;
    final entries = info['entries'] as List<dynamic>? ?? const [];
    if (info['isPlaylist'] == false) {
      return entries.isEmpty ? null : entries.first as Map<String, dynamic>;
    }
    final id = youTubeVideoIdFromUrl(_fetchedUrl);
    for (final entry in entries) {
      if (entry is Map<String, dynamic> && entry['id'] == id) return entry;
    }
    return null;
  }

  /// Saves the video of the link to the temporary playlist and downloads
  /// it. The add options do not apply: Temporary keeps its own settings.
  Future<void> _saveToTemporary() async {
    if (!_canSaveToTemporary) return;
    final info = _playlistInfo!;
    final url = _fetchedUrl!;
    setState(() {
      _adding = true;
      _error = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    final ytdlp = ref.read(ytdlpServiceProvider);
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      Map<String, dynamic> entry;
      if (info['isPlaylist'] == false) {
        entry = Map.of(_knownVideoEntry!);
        final thumbnail = entry['thumbnail'] as String?;
        if (thumbnail == null || thumbnail.isEmpty) {
          entry['thumbnail'] = info['thumbnail'];
        }
      } else {
        // Only the video, not the playlist around it (`--no-playlist`).
        entry = videoEntryFromInfo(await ytdlp.getVideoInfo(url));
      }
      if (!mounted) return;
      message = await saveVideoToTemporary(context, ref, entry);
    } catch (e) {
      if (!mounted) return;
      final reason = e is StateError ? e.message : '$e';
      setState(() {
        _error = "Couldn't save the video: ${friendlyDownloadError(reason)}";
        _adding = false;
      });
      return;
    }
    if (mounted) Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _paste() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } catch (_) {
      text = null;
    }
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('The clipboard is empty')));
      return;
    }
    _urlController.text = text;
    _urlController.selection = TextSelection.collapsed(offset: text.length);
    if (looksLikeYouTubeUrl(text)) unawaited(_fetchInfo());
  }

  void _cancelFetch() {
    setState(() {
      _fetchGeneration++;
      _fetching = false;
    });
  }

  Future<void> _fetchInfo() async {
    if (_fetching || _adding) return;
    // The keyboard's Go key is not disabled like the Look up button.
    if (ref.read(ytDlpInitErrorProvider) != null) return;
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    if (url == _fetchedUrl && _playlistInfo != null) return;
    FocusManager.instance.primaryFocus?.unfocus();

    final generation = ++_fetchGeneration;
    setState(() {
      _fetching = true;
      _error = null;
      _playlistInfo = null;
      _fetchedUrl = null;
    });

    try {
      final ytdlp = ref.read(ytdlpServiceProvider);
      final info = await ytdlp.getPlaylistInfo(url);
      if (!mounted || generation != _fetchGeneration) return;
      final title = (info['title'] as String? ?? '').trim();
      setState(() {
        _playlistInfo = info;
        _fetchedUrl = url;
        // Never prefill a blank name: it also names the playlist's folder.
        _nameController.text = title.isEmpty ? 'Playlist' : title;
        _playlistThumbnail = info['thumbnail'] as String?;
        _trackCount = info['count'] as int? ?? 0;
        _fetching = false;
        _toTemporary = false;
      });
    } catch (e) {
      if (!mounted || generation != _fetchGeneration) return;
      setState(() {
        _error = "Couldn't read this link: ${friendlyDownloadError('$e')}";
        _fetching = false;
      });
    }
  }

  Future<void> _addPlaylist() async {
    final existing = _existing(
      ref.read(playlistsProvider).valueOrNull ?? const [],
    );
    if (!_canAdd(existing)) return;
    final info = _playlistInfo;
    final url = _fetchedUrl;
    final name = _nameController.text.trim();
    if (info == null || url == null || name.isEmpty) return;
    // Set before the first await, so a second tap cannot add it twice.
    setState(() => _adding = true);
    FocusManager.instance.primaryFocus?.unfocus();

    // Read providers before awaiting: `ref` is unusable after disposal and
    // the download must still start if the owner leaves this page.
    final service = ref.read(playlistServiceProvider);
    final db = ref.read(databaseProvider);
    final downloadService = ref.read(downloadServiceProvider);
    final policy = ref.read(downloadNetworkPolicyProvider);
    final settings = ref.read(appSettingsServiceProvider);
    final defaults = ref.read(addPlaylistDefaultsProvider);
    final metadata = ref.read(metadataServiceProvider);
    final pendingImports = ref.read(pendingImportsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final options = AddPlaylistOptions(
      audioOnly: _audioOnly,
      autoUpdate: _autoUpdate,
      updateFrequencyHours: _updateFrequencyHours,
      playChapters: _playChapters,
      includeThumbnails: _includeThumbnails,
    );
    final int playlistId;
    try {
      playlistId = await service.addPlaylist(
        url: url,
        name: name,
        thumbnailUrl: _playlistThumbnail,
        audioOnly: options.audioOnly,
        playChapters: options.playChapters,
        autoUpdate: options.autoUpdate,
        updateFrequencyHours: options.updateFrequencyHours,
        includeThumbnails: options.includeThumbnails,
      );
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
        _error = "Couldn't add the playlist: ${friendlyDownloadError(reason)}";
        _adding = false;
      });
      return;
    }
    unawaited(defaults.save(options).catchError((_) {}));

    // The playlist exists from here on, so the page closes whatever happens
    // next; Update on the playlist retries anything left undone.
    String message;
    try {
      // The import banner must not offer this playlist's folder again.
      final pending = pendingImports.state;
      if (pending.isNotEmpty) {
        pendingImports.state = await metadata.findUnimportedPlaylists(
          candidates: pending,
        );
      }
      // A backup found in the playlist's folder was restored with its
      // tracks and their order; the fetched list only adds what is new.
      final restored = await service.getTotalCount(playlistId);
      await service.populateTracksFromInfo(playlistId, info);
      final playlist = await db.getPlaylist(playlistId);
      final added =
          restored > 0
              ? 'Added "${playlist.name}" and restored $restored '
                  'track${restored == 1 ? '' : 's'} from its folder.'
              : 'Added "${playlist.name}".';

      // Asked only now: declining must not throw the new playlist away.
      // Asked even if the owner left the page meanwhile: on Wi-Fi it still
      // downloads; only the mobile data question needs the page.
      DownloadNowChoice choice;
      try {
        choice =
            mounted
                ? await decideDownloadNow(
                  context,
                  policy,
                  settings: settings,
                  message:
                      options.autoUpdate
                          ? "You're on mobile data. Download it now, or wait "
                              "until you're on Wi-Fi?"
                          : "You're on mobile data. Download it now?",
                  laterLabel: options.autoUpdate ? 'Later on Wi-Fi' : 'Not now',
                )
                : await decideDownloadNowWithoutAsking(policy);
      } catch (_) {
        choice = DownloadNowChoice.later;
      }
      if (choice != DownloadNowChoice.now &&
          options.autoUpdate &&
          playlist.lastUpdated != null) {
        // A playlist restored from its folder keeps the backup's last update
        // time; clear it so the next automatic update takes it at once
        // instead of after a whole interval.
        try {
          await db.updatePlaylistFields(
            playlistId,
            const PlaylistsCompanion(lastUpdated: Value(null)),
          );
        } catch (_) {
          // It is then picked up when its interval has passed.
        }
      }
      switch (choice) {
        case DownloadNowChoice.now:
          final busy = downloadService.isDownloading;
          // The download runs whether or not this page is still open.
          unawaited(downloadService.downloadPlaylist(playlist));
          message =
              busy ? '$added It downloads after the current download.' : added;
        case DownloadNowChoice.later:
          message =
              options.autoUpdate
                  ? '$added It downloads with the next automatic update on '
                      'Wi-Fi.'
                  : '$added Tap Update on it to download.';
        case DownloadNowChoice.offline:
          message =
              options.autoUpdate
                  ? "$added You're offline; it downloads with the next "
                      'automatic update.'
                  : "$added You're offline; tap Update on it later.";
      }
    } catch (e) {
      final reason = e is StateError ? e.message : '$e';
      message =
          'Added "$name", but its tracks are not listed yet. Tap Update on '
          'the playlist to fetch them.\n$reason';
    }

    if (mounted) Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  void _openExisting(Playlist playlist) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder:
            (_) => PlaylistDetailPage(
              playlistId: playlist.id,
              initialName: playlist.name,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ytDlpError = ref.watch(ytDlpInitErrorProvider);
    final playlists = ref.watch(playlistsProvider).valueOrNull ?? const [];
    // While adding, the playlist being added shows up in the library and
    // must not be reported as already there.
    final existing = _adding ? null : _existing(playlists);
    final hasPreview = _playlistInfo != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Add playlist')),
      body: ValueListenableBuilder<double>(
        valueListenable: audioPlayerOverlayHeightNotifier,
        builder:
            (context, overlayHeight, child) => ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              // With a preview, the Add bar below already sits above the
              // player panel.
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                24 + (hasPreview ? 0 : overlayHeight),
              ),
              children: [
                _buildUrlField(),
                const SizedBox(height: 12),
                if (ytDlpError != null) ...[
                  _buildYtDlpNotice(ytDlpError),
                  const SizedBox(height: 12),
                ],
                if (_fetching)
                  _buildFetchingCard()
                else if (!hasPreview)
                  _buildLookupButtons(enabled: ytDlpError == null),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    key: const ValueKey('add-playlist-error'),
                    style: const TextStyle(
                      color: Color(0xFFEF5350),
                      fontSize: 13,
                    ),
                  ),
                ],
                if (hasPreview) ...[
                  const SizedBox(height: 4),
                  if (_namesOneVideo) ...[
                    _buildDestination(),
                    const SizedBox(height: 12),
                  ],
                  _buildPreview(),
                  if (!_savingToTemporary) ...[
                    if (existing != null) ...[
                      const SizedBox(height: 12),
                      _buildExistingNotice(existing),
                    ],
                    const SizedBox(height: 16),
                    _buildOptions(),
                  ],
                ],
              ],
            ),
      ),
      bottomNavigationBar:
          hasPreview
              ? _buildAddButton(
                enabled:
                    _savingToTemporary
                        ? _canSaveToTemporary
                        : _canAdd(existing),
              )
              : null,
    );
  }

  Widget _buildUrlField() {
    final hasText = _urlController.text.isNotEmpty;
    return TextField(
      key: const ValueKey('add-playlist-url-field'),
      controller: _urlController,
      enabled: !_adding,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      autocorrect: false,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: 'YouTube playlist link',
        labelStyle: const TextStyle(color: _muted),
        hintText: 'https://youtube.com/playlist?list=…',
        prefixIcon: const Icon(Icons.link, color: _muted),
        suffixIcon:
            hasText
                ? IconButton(
                  icon: const Icon(Icons.clear),
                  color: _muted,
                  tooltip: 'Clear',
                  onPressed: _urlController.clear,
                )
                : null,
      ),
      onSubmitted: (_) => _fetchInfo(),
    );
  }

  Widget _buildLookupButtons({required bool enabled}) {
    final hasText = _urlController.text.trim().isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: const ValueKey('add-playlist-paste'),
            onPressed: enabled ? _paste : null,
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            key: const ValueKey('add-playlist-lookup'),
            onPressed: enabled && hasText ? _fetchInfo : null,
            icon: const Icon(Icons.playlist_play),
            label: const Text('Look up'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFetchingCard() {
    return Container(
      key: const ValueKey('add-playlist-fetching'),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Reading the playlist…',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                SizedBox(height: 2),
                Text(
                  'Large playlists can take a minute.',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton(
            key: const ValueKey('add-playlist-cancel-lookup'),
            onPressed: _cancelFetch,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildYtDlpNotice(String reason) {
    final retrying = ref.watch(ytDlpRetryingProvider);
    return _Notice(
      icon: Icons.warning_amber_rounded,
      color: const Color(0xFFFFB74D),
      text: 'Downloads are unavailable: $reason',
      action: TextButton(
        onPressed:
            retrying
                ? null
                : () =>
                    unawaited(ref.read(libraryStartupProvider).retryYtDlp()),
        child: Text(retrying ? 'Retrying…' : 'Retry'),
      ),
    );
  }

  Widget _buildExistingNotice(Playlist existing) {
    return _Notice(
      key: const ValueKey('add-playlist-exists'),
      icon: Icons.info_outline,
      color: _accent,
      text:
          'Already in your library as "${existing.name}" '
          '(${existing.audioOnly ? 'audio' : 'video'}).',
      action: TextButton(
        onPressed: () => _openExisting(existing),
        child: const Text('Open'),
      ),
    );
  }

  /// Add the link as a playlist, or save just its video to Temporary.
  Widget _buildDestination() {
    final isPlaylist = _playlistInfo?['isPlaylist'] as bool? ?? true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          key: const ValueKey('add-playlist-destination'),
          segments: [
            ButtonSegment(
              value: false,
              icon: const Icon(Icons.playlist_add),
              label: Text(isPlaylist ? 'Whole playlist' : 'As a playlist'),
            ),
            const ButtonSegment(
              value: true,
              icon: Icon(Icons.watch_later_outlined),
              label: Text('Temporary'),
            ),
          ],
          selected: {_toTemporary},
          showSelectedIcon: false,
          onSelectionChanged:
              _adding
                  ? null
                  : (selection) => setState(() {
                    _toTemporary = selection.first;
                    _error = null;
                  }),
        ),
        const SizedBox(height: 4),
        Text(
          _toTemporary
              ? 'Saves just this video in your Temporary playlist, to watch '
                  'offline and remove when done.'
              : isPlaylist
              ? 'Adds the whole playlist and keeps it up to date.'
              : 'Adds the video as a playlist of its own.',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    final isPlaylist = _playlistInfo?['isPlaylist'] as bool? ?? true;
    final temporary = _savingToTemporary;
    final video = temporary ? _knownVideoEntry : null;
    final videoId = youTubeVideoIdFromUrl(_fetchedUrl);
    final cover =
        !temporary
            ? _playlistThumbnail
            : (video?['thumbnail'] as String?) ??
                (videoId == null
                    ? _playlistThumbnail
                    : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg');
    final coverWidth = 128.0;
    final cacheWidth =
        (coverWidth * MediaQuery.devicePixelRatioOf(context)).round();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: coverWidth,
                  height: coverWidth * 9 / 16,
                  child:
                      cover != null && cover.isNotEmpty
                          ? CachedNetworkImage(
                            imageUrl: cover,
                            fit: BoxFit.cover,
                            memCacheWidth: cacheWidth,
                            placeholder:
                                (_, __) =>
                                    const ColoredBox(color: Color(0xFF333333)),
                            errorWidget: (_, __, ___) => _coverPlaceholder(),
                          )
                          : _coverPlaceholder(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  temporary
                      ? (video?['title'] as String? ?? 'The video in this link')
                      : isPlaylist
                      ? '$_trackCount video${_trackCount == 1 ? '' : 's'}'
                      : 'A single video, added as a playlist with one track',
                  style: TextStyle(
                    color: temporary ? Colors.white : _muted,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          if (!temporary) const SizedBox(height: 12),
          if (!temporary)
            TextField(
              key: const ValueKey('add-playlist-name-field'),
              controller: _nameController,
              enabled: !_adding,
              onChanged: (_) => setState(() {}),
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                labelText: 'Name',
                labelStyle: const TextStyle(color: _muted),
                fillColor: const Color(0xFF333333),
                errorText: _nameValid ? null : 'Enter a name',
              ),
            ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder() => const ColoredBox(
    color: Color(0xFF333333),
    child: Center(
      child: Icon(Icons.playlist_play, color: Color(0xFF555555), size: 32),
    ),
  );

  Widget _buildOptions() {
    final enabled = !_adding;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('Download as'),
        SegmentedButton<bool>(
          key: const ValueKey('add-playlist-format'),
          segments: const [
            ButtonSegment(
              value: true,
              icon: Icon(Icons.music_note),
              label: Text('Audio'),
            ),
            ButtonSegment(
              value: false,
              icon: Icon(Icons.movie_outlined),
              label: Text('Video'),
            ),
          ],
          selected: {_audioOnly},
          showSelectedIcon: false,
          onSelectionChanged:
              enabled
                  ? (selection) =>
                      _setOption(() => _audioOnly = selection.first)
                  : null,
        ),
        const SizedBox(height: 4),
        Text(
          _audioOnly
              ? 'Saves the sound only (m4a); smaller files.'
              : 'Saves the full video.',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          key: const ValueKey('add-playlist-auto-update'),
          contentPadding: EdgeInsets.zero,
          value: _autoUpdate,
          onChanged: enabled ? (v) => _setOption(() => _autoUpdate = v) : null,
          title: const Text('Keep up to date'),
          subtitle: const Text(
            'Check for new videos automatically',
            style: TextStyle(color: _muted),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child:
              _autoUpdate
                  ? Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    child: DropdownButtonFormField<int>(
                      key: const ValueKey('add-playlist-frequency'),
                      value: nearestUpdateFrequency(_updateFrequencyHours),
                      isExpanded: true,
                      dropdownColor: const Color(0xFF2A2A2A),
                      decoration: const InputDecoration(
                        labelText: 'Check every',
                        labelStyle: TextStyle(color: _muted),
                      ),
                      items: [
                        for (final entry in updateFrequencyOptions.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged:
                          enabled
                              ? (hours) {
                                if (hours == null) return;
                                _setOption(() => _updateFrequencyHours = hours);
                              }
                              : null,
                    ),
                  )
                  : const SizedBox(width: double.infinity),
        ),
        Theme(
          // No divider lines around the expansion tile.
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const ValueKey('add-playlist-more-options'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: const Text('More options'),
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _playChapters,
                onChanged:
                    enabled ? (v) => _setOption(() => _playChapters = v) : null,
                title: const Text('Split chapters into tracks'),
                subtitle: const Text(
                  'A video with chapters plays as separate tracks, with '
                  'next and previous between them',
                  style: TextStyle(color: _muted),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _includeThumbnails,
                onChanged:
                    enabled
                        ? (v) => _setOption(() => _includeThumbnails = v)
                        : null,
                title: const Text('Save cover art inside files'),
                subtitle: const Text(
                  'Other music apps then show the cover too',
                  style: TextStyle(color: _muted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAddButton({required bool enabled}) {
    final temporary = _savingToTemporary;
    return ValueListenableBuilder<double>(
      valueListenable: audioPlayerOverlayHeightNotifier,
      builder:
          (context, overlayHeight, _) => SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + overlayHeight),
              child: FilledButton(
                key: ValueKey(
                  temporary
                      ? 'add-playlist-to-temporary'
                      : 'add-playlist-button',
                ),
                onPressed:
                    enabled
                        ? (temporary ? _saveToTemporary : _addPlaylist)
                        : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child:
                    _adding
                        ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(temporary ? 'Saving…' : 'Adding…'),
                          ],
                        )
                        : Text(
                          temporary ? 'Save to Temporary' : 'Add & download',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
              ),
            ),
          ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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

/// A one-line notice with an icon and an optional button.
class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                text,
                style: const TextStyle(color: Color(0xFFDDDDDD), fontSize: 13),
              ),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}
