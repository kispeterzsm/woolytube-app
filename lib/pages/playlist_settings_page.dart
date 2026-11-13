import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../database/database.dart';
import '../providers/chapter_fetch_jobs.dart';
import '../providers/lyrics_fetch_jobs.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/download_errors.dart';
import '../services/download_service.dart';
import '../services/library_gate.dart';
import '../services/lyrics/lyrics_models.dart';
import '../services/playback_service.dart';
import '../services/playlist_service.dart';
import '../services/sponsorblock_categories.dart';
import '../services/subtitles.dart';
import '../services/video_quality.dart';
import '../widgets/mobile_data_download_guard.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/subtitle_languages_dialog.dart';
import '../widgets/update_frequency_dropdown.dart';
import '../widgets/video_quality_picker.dart';
import 'sponsorblock_settings_page.dart';

/// One playlist's settings. Every change is saved at once (the name when
/// editing it finishes); only switching between audio and video asks
/// first, because it moves the playlist's files.
class PlaylistSettingsPage extends ConsumerStatefulWidget {
  final int playlistId;

  const PlaylistSettingsPage({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistSettingsPage> createState() =>
      _PlaylistSettingsPageState();
}

class _PlaylistSettingsPageState extends ConsumerState<PlaylistSettingsPage> {
  static const _red = Color(0xFFEF5350);

  /// How long deleting waits for the playlist's running download to stop.
  static const _downloadStopTimeout = Duration(seconds: 30);

  Playlist? _playlist;
  final _nameController = TextEditingController();
  final _nameFocus = FocusNode();
  late final AppDatabase _db;
  late final PlaylistService _playlists;
  PlaybackService? _player;

  /// Kept so a save that fails after the page closed can still say so.
  ScaffoldMessengerState? _messenger;

  /// Writes run one after another, so a quick second change can never be
  /// overtaken by an earlier one.
  Future<void> _saves = Future<void>.value();
  int _unsavedChanges = 0;

  /// A save failed: once every queued change is saved, the page shows what
  /// is stored.
  bool _reloadWhenSaved = false;
  bool _switchingFormat = false;
  bool _deleting = false;
  bool _switchingLyricsMode = false;
  bool _isForceInserting = false;

  bool get _busy => _switchingFormat || _deleting || _switchingLyricsMode;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseProvider);
    _playlists = ref.read(playlistServiceProvider);
    try {
      _player = ref.read(playbackServiceProvider);
    } catch (_) {
      // No player (widget tests); live updates are skipped.
    }
    _nameController.addListener(_onNameChanged);
    _nameFocus.addListener(_onNameFocusChanged);
    unawaited(_loadPlaylist());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  void _onNameChanged() {
    // The error text depends on the name.
    if (mounted) setState(() {});
  }

  void _onNameFocusChanged() {
    if (!_nameFocus.hasFocus) _commitName();
  }

  Future<void> _loadPlaylist() async {
    final Playlist playlist;
    try {
      playlist = await _db.getPlaylist(widget.playlistId);
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not load playlist: $e');
      Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    setState(() {
      _playlist = playlist;
      _nameController.text = playlist.name;
    });
  }

  /// Re-reads the row after another page changed it.
  Future<void> _reload() async {
    try {
      final playlist = await _db.getPlaylist(widget.playlistId);
      if (mounted) setState(() => _playlist = playlist);
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameFocus.removeListener(_onNameFocusChanged);
    _nameController.removeListener(_onNameChanged);
    // Leaving by any other way than Back (which already saved) still keeps
    // a finished edit.
    _commitName(disposing: true);
    _nameFocus.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _tellPlayer() async {
    try {
      await _player?.playlistSettingsChanged(widget.playlistId);
    } catch (_) {
      // Live update is a nicety; the next song reads the new settings.
    }
  }

  /// Shows [updated] at once, then saves it with [write]. On failure the
  /// page says why ([failure] names what was being saved) and, once the
  /// changes queued after it are saved too, shows what is stored.
  Future<bool> _update(
    Playlist updated,
    Future<void> Function(PlaylistService playlists) write, {
    String failure = 'Could not save',
  }) {
    setState(() => _playlist = updated);
    return _queueSave(write, failure: failure);
  }

  Future<bool> _queueSave(
    Future<void> Function(PlaylistService playlists) write, {
    required String failure,
  }) {
    _unsavedChanges++;
    final saved = Completer<bool>();
    _saves = _saves.then((_) async {
      String? problem;
      try {
        await write(_playlists);
        await _tellPlayer();
      } on LibraryBusyException catch (e) {
        problem = e.message;
      } catch (e) {
        problem = '$failure: ${_errorText(e)}';
      }
      _unsavedChanges--;
      if (problem != null) {
        _reloadWhenSaved = true;
        _showMessage(problem);
      }
      if (_unsavedChanges == 0 && _reloadWhenSaved) await _showStored();
      saved.complete(problem == null);
    });
    return saved.future;
  }

  /// After a failed save: shows the stored playlist, unless a newer change
  /// is waiting (its save does this again).
  Future<void> _showStored() async {
    final Playlist stored;
    try {
      stored = await _db.getPlaylist(widget.playlistId);
    } catch (_) {
      return;
    }
    if (!mounted || _unsavedChanges > 0) return;
    _reloadWhenSaved = false;
    setState(() {
      _playlist = stored;
      if (!_nameFocus.hasFocus) _nameController.text = stored.name;
    });
  }

  void _commitName({bool disposing = false}) {
    final playlist = _playlist;
    if (playlist == null || _deleting) return;
    final name = _nameController.text.trim();
    if (name == playlist.name) return;
    if (name.isEmpty) {
      if (disposing) return;
      _nameController.text = playlist.name;
      _showMessage('A playlist needs a name, so it stays "${playlist.name}".');
      return;
    }
    final failure = 'Could not rename the playlist to "$name"';
    Future<void> write(PlaylistService playlists) =>
        playlists.updatePlaylistSettings(id: playlist.id, name: name);
    if (disposing) {
      // No setState now; a failure is still reported.
      unawaited(_queueSave(write, failure: failure));
      return;
    }
    unawaited(_update(playlist.copyWith(name: name), write, failure: failure));
  }

  Future<void> _setAudioOnly(bool value) async {
    final playlist = _playlist;
    if (playlist == null || value == playlist.audioOnly || _busy) return;
    final format = value ? 'audio' : 'video';
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: Text(
              value ? 'Switch to audio only?' : 'Switch to video?',
              style: const TextStyle(color: Colors.white),
            ),
            content: Text(
              'The playlist moves to a new $format folder now. Each song '
              'keeps playing its current file until its $format version is '
              'downloaded at the next update. Local files and songs YouTube '
              'no longer has move along as they are. No file is deleted.',
              style: const TextStyle(color: Color(0xFFCCCCCC)),
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
    setState(() => _switchingFormat = true);
    Future<void> write(PlaylistService playlists) =>
        playlists.updatePlaylistSettings(id: playlist.id, audioOnly: value);
    // A running lyrics job would write its files into the old folder.
    final lyricsJobs = ref.read(lyricsFetchJobsProvider.notifier);
    if (lyricsJobs.isRunning(playlist.id)) {
      await lyricsJobs.stop(playlist.id);
      if (!mounted) {
        // The page was closed meanwhile: the switch still happens.
        unawaited(_queueSave(write, failure: 'Could not save'));
        return;
      }
    }
    final saved = await _update(
      (_playlist ?? playlist).copyWith(audioOnly: value),
      write,
    );
    if (!mounted) return;
    setState(() => _switchingFormat = false);
    if (saved) {
      await _reload();
      if (mounted) {
        _showMessage(value ? 'Switched to audio only.' : 'Switched to video.');
      }
    }
  }

  Future<void> _chooseUpdateFrequency() async {
    final playlist = _playlist;
    if (playlist == null) return;
    final hours = await showUpdateFrequencyPicker(
      context,
      playlist.updateFrequencyHours,
    );
    if (hours == null || !mounted || hours == playlist.updateFrequencyHours) {
      return;
    }
    await _update(
      playlist.copyWith(updateFrequencyHours: hours),
      (playlists) => playlists.updatePlaylistSettings(
        id: playlist.id,
        updateFrequencyHours: hours,
      ),
    );
  }

  Future<void> _chooseSubtitleLanguages() async {
    final playlist = _playlist;
    if (playlist == null || _busy) return;
    final current = subtitleLanguagesFor(playlist);
    final languages = await showSubtitleLanguagesDialog(
      context,
      initialValue: current,
    );
    if (languages == null || !mounted || languages == current) return;
    // Read again: the page may have changed while the dialog was open.
    final latest = _playlist ?? playlist;
    await _update(
      latest.copyWith(subtitleLanguages: Value(languages)),
      (playlists) => playlists.updatePlaylistSettings(
        id: playlist.id,
        subtitleLanguages: Value(languages),
      ),
    );
  }

  /// Saves a new video quality at once, then offers to download again the
  /// files it would change.
  Future<void> _chooseVideoQuality() async {
    final playlist = _playlist;
    if (playlist == null || _busy) return;
    final picked = await showVideoQualityPicker(
      context,
      current: playlist.videoQuality,
    );
    if (picked == null || !mounted) return;
    final maxHeight = picked.value;
    if (maxHeight == playlist.videoQuality) return;
    final saved = await _update(
      playlist.copyWith(videoQuality: Value(maxHeight)),
      (playlists) => playlists.setPlaylistVideoQuality(playlist.id, maxHeight),
    );
    if (!saved || !mounted) return;

    final List<Track> affected;
    try {
      affected = await _playlists.tracksAffectedByQualityChange(
        playlist,
        oldMax: playlist.videoQuality,
        newMax: maxHeight,
      );
    } catch (_) {
      return;
    }
    if (affected.isEmpty || !mounted) return;
    final again = await confirmQualityRedownload(
      context,
      count: affected.length,
      maxHeight: maxHeight,
    );
    if (!again || !mounted) return;
    try {
      await _playlists.requestRedownload(playlist.id, [
        for (final track in affected) track.id,
      ]);
    } catch (e) {
      _showMessage('Could not save: ${_errorText(e)}');
      return;
    }
    if (!mounted) return;
    final videos =
        '${affected.length} ${affected.length == 1 ? 'video' : 'videos'}';
    final unavailable = ref.read(ytDlpInitErrorProvider);
    if (unavailable != null) {
      _showMessage('Downloads are unavailable: $unavailable');
      return;
    }
    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      _showMessage('The $videos download again at the next update.');
      return;
    }
    final Playlist fresh;
    try {
      fresh = await _db.getPlaylist(playlist.id);
    } catch (_) {
      return;
    }
    // Queued when another download runs; a run of this playlist does
    // another pass for them right after.
    unawaited(
      ref
          .read(downloadServiceProvider)
          .downloadPlaylist(fresh, sourceChecked: false)
          .catchError((Object _) => DownloadStart.started),
    );
    _showMessage('Downloading $videos again');
  }

  Future<void> _openSkipSegments() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SponsorBlockSettingsPage(playlistId: widget.playlistId),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _delete() async {
    if (_deleting) return;
    final downloads = ref.read(downloadServiceProvider);
    final downloading =
        downloads.isDownloading &&
        downloads.activePlaylistId == widget.playlistId;
    final queued = downloads.queuedPlaylistIds.contains(widget.playlistId);
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
                                'deletes its downloaded files, including '
                                'older copies kept after replacing a file. '
                                'Anything else in its folder is kept.'
                            : 'This removes the playlist from the app. '
                                'Downloaded files are kept on the device.',
                        style: const TextStyle(color: Color(0xFF888888)),
                      ),
                      if (downloading || queued)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            downloading
                                ? 'Its running download will be stopped.'
                                : 'Its waiting download will be cancelled.',
                            style: const TextStyle(color: Color(0xFF888888)),
                          ),
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
                        style: TextStyle(color: _red),
                      ),
                    ),
                  ],
                ),
          ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    final chapterJobs = ref.read(chapterFetchJobsProvider.notifier);
    final lyricsJobs = ref.read(lyricsFetchJobsProvider.notifier);
    try {
      // They would keep writing into a playlist that is going away.
      await chapterJobs.stop(widget.playlistId);
      await lyricsJobs.stop(widget.playlistId);
      if (!await _stopDownloadOfThisPlaylist(downloads)) {
        if (!mounted) return;
        setState(() => _deleting = false);
        _showMessage('Could not stop the download. Try again.');
        return;
      }
      await _saves;
      // Its songs leave the queue; a song of it that is playing stops.
      try {
        await _player?.playlistRemoved(widget.playlistId);
      } catch (_) {}
      await _playlists.deletePlaylist(
        widget.playlistId,
        deleteFiles: deleteFiles,
      );
      if (!mounted) return;
      // Pages under this one (the playlist itself) refer to a playlist that
      // no longer exists, so return all the way to the home page.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on LibraryBusyException catch (e) {
      // Deleting files waits for downloads and updates to finish.
      if (!mounted) return;
      setState(() => _deleting = false);
      _showMessage(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _showMessage('Could not delete playlist: ${_errorText(e)}');
    }
  }

  /// A download of this playlist would hold the library and keep writing
  /// into a playlist that is going away, so it is stopped first (and taken
  /// out of the queue). False when it did not stop in time.
  Future<bool> _stopDownloadOfThisPlaylist(DownloadService downloads) async {
    downloads.removeFromQueue(widget.playlistId);
    if (!downloads.isDownloading ||
        downloads.activePlaylistId != widget.playlistId) {
      return true;
    }
    await downloads.cancelActiveDownloads();
    try {
      await downloads.runFinished.timeout(_downloadStopTimeout);
      return true;
    } on TimeoutException {
      return !downloads.isDownloading ||
          downloads.activePlaylistId != widget.playlistId;
    }
  }

  Future<void> _openPlaylistOnYouTube() async {
    final url = _playlist?.url;
    if (url == null) return;
    var launched = false;
    try {
      launched = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
    if (!launched && mounted) {
      _showMessage('Could not open this playlist.');
    }
  }

  Future<void> _copyLink() async {
    final url = _playlist?.url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) _showMessage('Link copied');
  }

  Future<void> _fetchMissingChapters() async {
    final jobs = ref.read(chapterFetchJobsProvider.notifier);
    if (jobs.isRunning(widget.playlistId)) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final missing = await ref
          .read(chapterServiceProvider)
          .countMissing(widget.playlistId);
      if (!mounted) return;
      if (missing == 0) {
        _showMessage('All downloaded videos already have chapter info.');
        return;
      }
      if (!await confirmManualDownload(
        context,
        ref.read(downloadNetworkPolicyProvider),
      )) {
        return;
      }
      // The job keeps running if the page is closed; the result is still
      // reported.
      final result = await jobs.start(widget.playlistId);
      // Null: stopped for a mode switch or because the playlist is being
      // deleted.
      if (result == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text(chapterFetchSummary(result))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Could not fetch chapters: ${friendlyDownloadError(_errorText(e))}',
          ),
        ),
      );
    }
  }

  /// Saves a new lyrics mode at once. Turning it on starts fetching.
  Future<void> _chooseLyricsMode() async {
    final playlist = _playlist;
    if (playlist == null || _busy) return;
    final current = LyricsMode.fromDb(playlist.lyricsMode);
    final picked = await showLyricsModePicker(context, current: current);
    if (picked == null || !mounted) return;
    final mode = picked.mode;
    if (mode == current) return;
    final jobs = ref.read(lyricsFetchJobsProvider.notifier);
    Future<void> write(PlaylistService playlists) => playlists
        .updatePlaylistSettings(id: playlist.id, lyricsMode: Value(mode));
    const failure = 'Could not save the lyrics mode';
    // Deleting or switching the format waits until the new mode is saved.
    setState(() => _switchingLyricsMode = true);
    final bool saved;
    try {
      // A running job would go on with the old mode. Wait for it to end
      // (after its current track), so the new mode's fetch can start; its
      // own summary is dropped.
      if (jobs.isRunning(playlist.id)) {
        await jobs.stop(playlist.id);
        if (!mounted) {
          // The page was closed meanwhile: the choice is still saved.
          unawaited(_queueSave(write, failure: failure));
          return;
        }
      }
      // Settings changed during the wait are on the latest copy.
      final latest = _playlist ?? playlist;
      saved = await _update(
        latest.copyWith(lyricsMode: Value(LyricsMode.toDb(mode))),
        write,
        failure: failure,
      );
    } finally {
      if (mounted) setState(() => _switchingLyricsMode = false);
    }
    if (!saved || !mounted || mode == null) return;
    await _fetchLyrics(mode, startedBySwitch: true);
  }

  Future<void> _fetchLyrics(
    LyricsMode mode, {
    bool startedBySwitch = false,
  }) async {
    final jobs = ref.read(lyricsFetchJobsProvider.notifier);
    if (jobs.isRunning(widget.playlistId)) return;
    final messenger = ScaffoldMessenger.of(context);
    final what = mode == LyricsMode.transcript ? 'Transcripts' : 'Lyrics';
    try {
      if (!await confirmManualDownload(
        context,
        ref.read(downloadNetworkPolicyProvider),
      )) {
        if (startedBySwitch) {
          _showMessage('$what are fetched at the next update.');
        }
        return;
      }
      // A delete started meanwhile: no new job on a playlist going away.
      if (!mounted || _deleting) return;
      // The job keeps running if the page is closed; the result is still
      // reported.
      final result = await jobs.start(widget.playlistId);
      // Null: stopped because the playlist is being deleted.
      if (result == null) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(lyricsFetchSummary(result, mode: mode))),
        );
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Could not fetch ${what.toLowerCase()}: ${_errorText(e)}',
            ),
          ),
        );
    }
  }

  Future<void> _forceInsert() async {
    final playlist = _playlist;
    if (playlist == null || _isForceInserting || _busy) return;

    setState(() => _isForceInserting = true);
    try {
      final tracks = await _playlists.getTracksForPlaylist(playlist.id);
      var highestIndex = 0;
      for (final track in tracks) {
        if (track.index > highestIndex) highestIndex = track.index;
      }
      final maximumIndex = tracks.isEmpty ? 1 : highestIndex + 1;
      if (!mounted) return;

      final index = await showDialog<int>(
        context: context,
        builder:
            (_) => _ForceInsertIndexDialog(
              maximumIndex: maximumIndex,
              audioOnly: playlist.audioOnly,
            ),
      );
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

      final inserted = await _playlists.forceInsert(
        playlistId: playlist.id,
        index: index,
        sourcePath: sourcePath,
        sourceFileName: picked.name,
      );
      if (mounted) {
        _showMessage('Added "${inserted.title}" at position $index.');
      }
    } on ForceInsertException catch (error) {
      if (mounted) _showMessage(error.message);
    } on LibraryBusyException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (error) {
      if (mounted) {
        _showMessage('Could not add the selected file: ${_errorText(error)}');
      }
    } finally {
      if (mounted) setState(() => _isForceInserting = false);
    }
  }

  void _showMessage(String message) {
    final messenger =
        mounted ? ScaffoldMessenger.maybeOf(context) ?? _messenger : _messenger;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _playlist;
    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Playlist settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final busy = _busy;
    final sponsorBlockActions = decodeSponsorBlockCategoryActions(
      playlist.sponsorBlockCategoryActions,
      legacyCategories: playlist.sponsorBlockCategories,
    );
    final nameValid = _nameController.text.trim().isNotEmpty;
    final temporary = playlist.isTemporary;
    return PopScope(
      // Back saves a name that is still being edited.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _commitName();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Playlist settings'),
          bottom:
              busy
                  ? const PreferredSize(
                    preferredSize: Size.fromHeight(2),
                    child: LinearProgressIndicator(minHeight: 2),
                  )
                  : null,
        ),
        body: ValueListenableBuilder<double>(
          valueListenable: audioPlayerOverlayHeightNotifier,
          builder:
              (context, overlay, _) => ListView(
                padding: EdgeInsets.only(bottom: 24 + overlay),
                children: [
                  const SettingsSectionHeader('Playlist'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: TextField(
                      key: const ValueKey('playlist-name-field'),
                      controller: _nameController,
                      focusNode: _nameFocus,
                      enabled: !busy,
                      textInputAction: TextInputAction.done,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      decoration: InputDecoration(
                        labelText: 'Name',
                        labelStyle: const TextStyle(color: Color(0xFF888888)),
                        border: const OutlineInputBorder(),
                        errorText: nameValid ? null : 'Enter a name',
                      ),
                      onSubmitted: (_) => _commitName(),
                      onTapOutside: (_) => _nameFocus.unfocus(),
                    ),
                  ),
                  // The temporary playlist has no YouTube playlist, and it
                  // only downloads videos the owner saved on purpose.
                  if (!temporary)
                    ListTile(
                      key: const ValueKey('playlist-open-youtube'),
                      leading: const Icon(Icons.open_in_new),
                      title: const Text('Open on YouTube'),
                      subtitle: Text(
                        playlist.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: _openPlaylistOnYouTube,
                      trailing: IconButton(
                        tooltip: 'Copy link',
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: _copyLink,
                      ),
                    ),
                  const SettingsSectionHeader('Downloads'),
                  if (!temporary)
                    ListTile(
                      key: const ValueKey('playlist-audio-only'),
                      leading: const Icon(Icons.music_note_outlined),
                      title: const Text('Audio only'),
                      subtitle: Text(
                        playlist.audioOnly
                            ? 'Downloads sound only (m4a)'
                            : 'Off: downloads videos',
                      ),
                      enabled: !busy,
                      onTap: () => _setAudioOnly(!playlist.audioOnly),
                      trailing:
                          _switchingFormat
                              ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : Switch(
                                value: playlist.audioOnly,
                                onChanged: busy ? null : _setAudioOnly,
                              ),
                    ),
                  SwitchListTile(
                    key: const ValueKey('playlist-include-thumbnails'),
                    secondary: const Icon(Icons.image_outlined),
                    title: const Text('Add cover art to files'),
                    subtitle: const Text('Applies to new downloads'),
                    value: playlist.includeThumbnails,
                    onChanged:
                        busy
                            ? null
                            : (value) => _update(
                              playlist.copyWith(includeThumbnails: value),
                              (playlists) => playlists.updatePlaylistSettings(
                                id: playlist.id,
                                includeThumbnails: value,
                              ),
                            ),
                  ),
                  if (!playlist.audioOnly) ...[
                    ListTile(
                      key: const ValueKey('playlist-video-quality'),
                      leading: const Icon(Icons.high_quality_outlined),
                      title: const Text('Video quality'),
                      subtitle: Text(videoQualityLabel(playlist.videoQuality)),
                      enabled: !busy,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _chooseVideoQuality,
                    ),
                    SwitchListTile(
                      key: const ValueKey('playlist-download-subtitles'),
                      secondary: const Icon(Icons.closed_caption_outlined),
                      title: const Text('Download subtitles'),
                      subtitle: const Text(
                        'Inside the video file, including automatic '
                        'captions. Applies to new downloads',
                      ),
                      value: playlist.downloadSubtitles,
                      onChanged:
                          busy
                              ? null
                              : (value) => _update(
                                playlist.copyWith(downloadSubtitles: value),
                                (playlists) => playlists.updatePlaylistSettings(
                                  id: playlist.id,
                                  downloadSubtitles: value,
                                ),
                              ),
                    ),
                    if (playlist.downloadSubtitles)
                      ListTile(
                        key: const ValueKey('playlist-subtitle-languages'),
                        leading: const SizedBox(width: 24),
                        title: const Text('Subtitle languages'),
                        subtitle: Text(
                          subtitleLanguagesLabel(
                            subtitleLanguagesFor(playlist),
                          ),
                        ),
                        enabled: !busy,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _chooseSubtitleLanguages,
                      ),
                  ],
                  if (!temporary) ...[
                    const SettingsSectionHeader('Updates'),
                    SwitchListTile(
                      key: const ValueKey('playlist-auto-update'),
                      secondary: const Icon(Icons.update),
                      title: const Text('Check for new videos automatically'),
                      subtitle: const Text(
                        'New videos in the YouTube playlist download in the '
                        'background',
                      ),
                      value: playlist.autoUpdate,
                      onChanged:
                          busy
                              ? null
                              : (value) => _update(
                                playlist.copyWith(autoUpdate: value),
                                (playlists) => playlists.updatePlaylistSettings(
                                  id: playlist.id,
                                  autoUpdate: value,
                                ),
                              ),
                    ),
                    ListTile(
                      key: const ValueKey('playlist-update-frequency'),
                      leading: const SizedBox(width: 24),
                      title: const Text('How often'),
                      subtitle: Text(
                        updateFrequencyLabel(playlist.updateFrequencyHours),
                      ),
                      enabled: playlist.autoUpdate && !busy,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _chooseUpdateFrequency,
                    ),
                  ],
                  const SettingsSectionHeader('Playback'),
                  SwitchListTile(
                    key: const ValueKey('playlist-play-chapters'),
                    secondary: const Icon(Icons.bookmarks_outlined),
                    title: const Text('Play chapters as tracks'),
                    subtitle: const Text(
                      'Videos with chapters play each chapter as its own '
                      'track, with next and previous',
                    ),
                    value: playlist.playChapters ?? true,
                    onChanged:
                        busy
                            ? null
                            : (value) => _update(
                              playlist.copyWith(
                                playChapters: Value<bool?>(value),
                              ),
                              (playlists) => playlists.updatePlaylistSettings(
                                id: playlist.id,
                                playChapters: value,
                              ),
                            ),
                  ),
                  SwitchListTile(
                    key: const ValueKey('playlist-sponsorblock'),
                    secondary: const Icon(Icons.fast_forward_outlined),
                    title: const Text('SponsorBlock'),
                    subtitle: const Text(
                      'Skip sponsors and other parts that viewers marked',
                    ),
                    value: playlist.sponsorBlockEnabled,
                    onChanged:
                        busy
                            ? null
                            : (value) => _update(
                              playlist.copyWith(sponsorBlockEnabled: value),
                              (playlists) => playlists.updatePlaylistSettings(
                                id: playlist.id,
                                sponsorBlockEnabled: value,
                              ),
                            ),
                  ),
                  ListTile(
                    key: const ValueKey('playlist-skip-segments'),
                    leading: const SizedBox(width: 24),
                    title: const Text('Choose what to skip'),
                    subtitle: Text(sponsorBlockSummary(sponsorBlockActions)),
                    enabled: playlist.sponsorBlockEnabled && !busy,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _openSkipSegments,
                  ),
                  ListTile(
                    key: const ValueKey('playlist-lyrics-mode'),
                    leading: const Icon(Icons.lyrics_outlined),
                    title: const Text('Lyrics'),
                    subtitle: Text(
                      lyricsModeLabel(LyricsMode.fromDb(playlist.lyricsMode)),
                    ),
                    enabled: !busy,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _chooseLyricsMode,
                  ),
                  const SettingsSectionHeader('Tools'),
                  _FetchChaptersTile(
                    playlistId: playlist.id,
                    enabled: !busy,
                    onStart: _fetchMissingChapters,
                  ),
                  if (LyricsMode.fromDb(playlist.lyricsMode) case final mode?)
                    _FetchLyricsTile(
                      playlistId: playlist.id,
                      mode: mode,
                      enabled: !busy,
                      onStart: () => _fetchLyrics(mode),
                    ),
                  ListTile(
                    key: const ValueKey('force-insert-button'),
                    leading:
                        _isForceInserting
                            ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : const Icon(Icons.playlist_add),
                    title: const Text('Add a file from this phone'),
                    subtitle: Text(
                      playlistForceInsertDescription(playlist.audioOnly),
                    ),
                    enabled: !busy && !_isForceInserting,
                    onTap: _forceInsert,
                  ),
                  // Deleted with its files kept, they would all come back
                  // the next time a video is saved to it. Its page has
                  // "Clear all" instead.
                  if (!temporary) ...[
                    const SettingsSectionHeader('Danger zone', color: _red),
                    ListTile(
                      key: const ValueKey('delete-playlist-button'),
                      leading:
                          _deleting
                              ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _red,
                                ),
                              )
                              : const Icon(Icons.delete_outline, color: _red),
                      title: const Text(
                        'Delete playlist',
                        style: TextStyle(color: _red),
                      ),
                      subtitle: const Text('You can choose to keep the files'),
                      enabled: !busy && !_isForceInserting,
                      onTap: _delete,
                    ),
                  ],
                ],
              ),
        ),
      ),
    );
  }
}

/// "Fetch missing chapters", with the running job's progress and Stop.
class _FetchChaptersTile extends ConsumerWidget {
  const _FetchChaptersTile({
    required this.playlistId,
    required this.enabled,
    required this.onStart,
  });

  final int playlistId;
  final bool enabled;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      chapterFetchJobsProvider.select((jobs) => jobs[playlistId]),
    );
    if (progress == null) {
      return ListTile(
        key: const ValueKey('fetch-missing-chapters'),
        leading: const Icon(Icons.download_outlined),
        title: const Text('Fetch missing chapters'),
        subtitle: const Text(
          'Look up YouTube chapters for downloaded videos that have none yet',
        ),
        enabled: enabled,
        onTap: onStart,
      );
    }
    final status =
        progress.cancelling
            ? 'Stopping after this video…'
            : progress.total == 0
            ? 'Getting ready…'
            : 'Checking ${progress.done} of ${progress.total}…';
    return ListTile(
      key: const ValueKey('fetch-missing-chapters'),
      leading: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      title: const Text('Fetching missing chapters'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress.fraction),
        ],
      ),
      trailing: TextButton(
        key: const ValueKey('fetch-missing-chapters-stop'),
        onPressed:
            progress.cancelling
                ? null
                : () => ref
                    .read(chapterFetchJobsProvider.notifier)
                    .cancel(playlistId),
        child: const Text('Stop'),
      ),
    );
  }
}

/// "Fetch lyrics now", with the running job's progress and Stop.
class _FetchLyricsTile extends ConsumerWidget {
  const _FetchLyricsTile({
    required this.playlistId,
    required this.mode,
    required this.enabled,
    required this.onStart,
  });

  final int playlistId;
  final LyricsMode mode;
  final bool enabled;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      lyricsFetchJobsProvider.select((jobs) => jobs[playlistId]),
    );
    final what = mode == LyricsMode.transcript ? 'transcripts' : 'lyrics';
    if (progress == null) {
      return ListTile(
        key: const ValueKey('fetch-lyrics'),
        leading: const Icon(Icons.lyrics_outlined),
        title: Text('Fetch $what now'),
        subtitle: Text(
          'Look up $what for downloaded tracks that have none yet. Updates '
          'do this too',
        ),
        enabled: enabled,
        onTap: onStart,
      );
    }
    final status =
        progress.cancelling
            ? 'Stopping after this track…'
            : progress.total == 0
            ? 'Getting ready…'
            : 'Checking ${progress.done} of ${progress.total}…';
    return ListTile(
      key: const ValueKey('fetch-lyrics'),
      leading: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      title: Text('Fetching $what'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress.fraction),
        ],
      ),
      trailing: TextButton(
        key: const ValueKey('fetch-lyrics-stop'),
        onPressed:
            progress.cancelling
                ? null
                : () => ref
                    .read(lyricsFetchJobsProvider.notifier)
                    .cancel(playlistId),
        child: const Text('Stop'),
      ),
    );
  }
}

/// The lyrics mode as shown under the setting.
String lyricsModeLabel(LyricsMode? mode) => switch (mode) {
  null => 'Off',
  LyricsMode.lyrics => 'Song lyrics',
  LyricsMode.transcript => 'Spoken transcript',
};

/// Asks for a lyrics mode. Returns null when cancelled, otherwise the
/// chosen mode in a record (null inside = off).
Future<({LyricsMode? mode})?> showLyricsModePicker(
  BuildContext context, {
  required LyricsMode? current,
}) async {
  Widget option(
    BuildContext ctx,
    String id,
    LyricsMode? mode,
    String explanation,
  ) => RadioListTile<String>(
    key: ValueKey('lyrics-mode-option-$id'),
    value: id,
    groupValue: current?.dbValue ?? 'off',
    title: Text(lyricsModeLabel(mode)),
    subtitle: Text(explanation),
    onChanged: (_) => Navigator.pop(ctx, (mode: mode)),
  );
  return showDialog<({LyricsMode? mode})>(
    context: context,
    builder:
        (ctx) => SimpleDialog(
          key: const ValueKey('lyrics-mode-picker'),
          title: const Text('Lyrics'),
          children: [
            option(ctx, 'off', null, 'Nothing is fetched'),
            option(
              ctx,
              'lyrics',
              LyricsMode.lyrics,
              'For music. Finds the words of each song, so you can search '
                  'for a line you remember',
            ),
            option(
              ctx,
              'transcript',
              LyricsMode.transcript,
              'For podcasts, talks and audiobooks. Uses the video\'s '
                  'captions, so you can search for what was said',
            ),
          ],
        ),
  );
}

/// The message of an error meant for the owner, without Dart's "Bad state:"
/// prefix.
String _errorText(Object error) =>
    error is StateError ? error.message : '$error';

String playlistForceInsertDescription(bool audioOnly) {
  final kind = audioOnly ? 'an audio' : 'a video';
  return 'Put $kind file from your phone into this playlist at a position '
      'you choose. Songs from there on move down one place.';
}

class _ForceInsertIndexDialog extends StatefulWidget {
  final int maximumIndex;
  final bool audioOnly;

  const _ForceInsertIndexDialog({
    required this.maximumIndex,
    required this.audioOnly,
  });

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
    final last = widget.maximumIndex;
    return AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text(
        'Add a file from this phone',
        style: TextStyle(color: Colors.white),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            last == 1
                ? 'The file becomes song 1. Next, choose the '
                    '${widget.audioOnly ? 'audio' : 'video'} file.'
                : 'Where should it go? 1 puts it first, $last puts it last. '
                    'The song at that position and the ones after it move '
                    'down one place. Next, choose the '
                    '${widget.audioOnly ? 'audio' : 'video'} file.',
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
              labelText: 'Position',
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
          child: const Text('Choose file'),
        ),
      ],
    );
  }
}
