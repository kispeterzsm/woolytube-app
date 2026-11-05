import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/update_service.dart';
import '../services/app_settings_service.dart';
import '../services/library_export_service.dart';
import '../services/library_layout.dart';
import '../services/metadata_service.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.initialUpdate, this.onUpdateChanged});

  final AppUpdate? initialUpdate;
  final ValueChanged<AppUpdate?>? onUpdateChanged;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  AppUpdate? _availableUpdate;
  bool _autoDownloadWithMobileData = false;
  bool _pauseOnAudioInterruption = true;
  bool _downloadSubtitles = false;
  String _subtitleLanguages = 'en';
  bool _isLoadingSettings = true;
  bool _isSavingSettings = false;
  bool _isCheckingForUpdate = false;
  bool _isDownloadingUpdate = false;
  bool _isExporting = false;
  LibraryExportProgress? _exportProgress;

  @override
  void initState() {
    super.initState();
    _availableUpdate = widget.initialUpdate;
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    try {
      final settings = ref.read(appSettingsServiceProvider);
      final values = await Future.wait([
        settings.getAutoDownloadWithMobileData(),
        settings.getPauseOnAudioInterruption(),
        settings.getDownloadSubtitles(),
      ]);
      final languages = await settings.getSubtitleLanguages();
      if (mounted) {
        setState(() {
          _downloadSubtitles = values[2];
          _subtitleLanguages = languages;
          _autoDownloadWithMobileData = values[0];
          _pauseOnAudioInterruption = values[1];
        });
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load settings: $error')),
      );
    } finally {
      if (mounted) setState(() => _isLoadingSettings = false);
    }
  }

  Future<void> _setPauseOnAudioInterruption(bool enabled) async {
    setState(() {
      _pauseOnAudioInterruption = enabled;
      _isSavingSettings = true;
    });
    try {
      await ref
          .read(appSettingsServiceProvider)
          .setPauseOnAudioInterruption(enabled);
      await ref
          .read(playbackServiceProvider)
          .setPauseOnAudioInterruption(enabled);
    } catch (error) {
      if (!mounted) return;
      setState(() => _pauseOnAudioInterruption = !enabled);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save setting: $error')));
    } finally {
      if (mounted) setState(() => _isSavingSettings = false);
    }
  }

  Future<void> _setAutoDownloadWithMobileData(bool enabled) async {
    setState(() {
      _autoDownloadWithMobileData = enabled;
      _isSavingSettings = true;
    });
    try {
      await ref
          .read(appSettingsServiceProvider)
          .setAutoDownloadWithMobileData(enabled);
    } catch (error) {
      if (!mounted) return;
      setState(() => _autoDownloadWithMobileData = !enabled);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save setting: $error')));
    } finally {
      if (mounted) setState(() => _isSavingSettings = false);
    }
  }

  Future<void> _setDownloadSubtitles(bool enabled) async {
    setState(() => _isSavingSettings = true);
    try {
      await ref.read(appSettingsServiceProvider).setDownloadSubtitles(enabled);
      if (mounted) setState(() => _downloadSubtitles = enabled);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save setting: $error')));
    } finally {
      if (mounted) setState(() => _isSavingSettings = false);
    }
  }

  Future<void> _editSubtitleLanguages() async {
    final languages = await showDialog<String>(
      context: context,
      builder:
          (_) => _SubtitleLanguagesDialog(initialValue: _subtitleLanguages),
    );
    if (!mounted || languages == null) return;
    setState(() => _isSavingSettings = true);
    try {
      await ref
          .read(appSettingsServiceProvider)
          .setSubtitleLanguages(languages);
      if (mounted) setState(() => _subtitleLanguages = languages);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save setting: $error')));
    } finally {
      if (mounted) setState(() => _isSavingSettings = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Playback'),
          SwitchListTile(
            secondary: const Icon(Icons.pause_circle_outline),
            title: const Text('Pause for other apps'),
            subtitle: const Text(
              'Pause WoolyTube when another app starts playing audio',
            ),
            value: _pauseOnAudioInterruption,
            onChanged:
                _isLoadingSettings || _isSavingSettings
                    ? null
                    : _setPauseOnAudioInterruption,
          ),
          const Divider(height: 1),
          const _SectionHeader('Downloads'),
          SwitchListTile(
            secondary: const Icon(Icons.closed_caption_outlined),
            title: const Text('Download subtitles'),
            subtitle: const Text(
              'Include available subtitles in future video downloads, including '
              'automatic captions. Re-download existing videos to add subtitles.',
            ),
            value: _downloadSubtitles,
            onChanged:
                _isLoadingSettings || _isSavingSettings
                    ? null
                    : _setDownloadSubtitles,
          ),
          ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('Subtitle languages'),
            subtitle: Text(_subtitleLanguages),
            enabled:
                _downloadSubtitles && !_isLoadingSettings && !_isSavingSettings,
            onTap: _editSubtitleLanguages,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.mobile_friendly),
            title: const Text('Auto download with mobile data'),
            subtitle: const Text(
              'Allow automatic playlist updates when connected using mobile data',
            ),
            value: _autoDownloadWithMobileData,
            onChanged:
                _isLoadingSettings || _isSavingSettings
                    ? null
                    : _setAutoDownloadWithMobileData,
          ),
          const Divider(height: 1),
          const _SectionHeader('Library backup'),
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('Export library'),
            subtitle: Text(_exportStatusText),
            trailing:
                _isExporting
                    ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.chevron_right),
            onTap: _isExporting ? null : _exportLibrary,
          ),
          if (_isExporting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(value: _exportFraction),
            ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Restore playlists'),
            subtitle: const Text(
              'Bring back removed playlists or playlists from a copied backup',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openRestorePage,
          ),
          const Divider(height: 1),
          const _SectionHeader('About'),
          ListTile(
            leading: Icon(
              _isDownloadingUpdate ? Icons.downloading : Icons.system_update,
              color:
                  _availableUpdate == null
                      ? const Color(0xFF888888)
                      : const Color(0xFF2196F3),
            ),
            title: const Text('App update'),
            subtitle: Text(_updateStatusText),
            trailing:
                _isCheckingForUpdate || _isDownloadingUpdate
                    ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.chevron_right),
            onTap:
                _isCheckingForUpdate || _isDownloadingUpdate
                    ? null
                    : _onUpdatePressed,
          ),
        ],
      ),
    );
  }

  String get _exportStatusText {
    final progress = _exportProgress;
    if (!_isExporting) {
      return 'Save covers, playlist files and a copy of the app data '
          'in the library folders';
    }
    if (progress == null) return 'Getting ready';
    if (progress.done >= progress.total) return 'Saving a copy of the app data';
    return 'Playlist ${progress.done + 1} of ${progress.total}: '
        '${progress.current ?? ''}';
  }

  double? get _exportFraction {
    final progress = _exportProgress;
    if (progress == null || progress.total == 0) return null;
    return progress.done / progress.total;
  }

  Future<void> _exportLibrary() async {
    // The export keeps running if the page is closed; a snack bar then
    // still reports the end.
    final messenger = ScaffoldMessenger.of(context);
    final networkPolicy = ref.read(downloadNetworkPolicyProvider);
    final exporter = ref.read(libraryExportServiceProvider);
    setState(() {
      _isExporting = true;
      _exportProgress = null;
    });
    try {
      var allowNetwork = false;
      try {
        allowNetwork = await networkPolicy.allowsAutomaticNetworkUse();
      } catch (_) {
        // Offline export: covers come from the files and the image cache.
      }
      final result = await exporter.exportLibrary(
        allowNetwork: allowNetwork,
        onProgress: (progress) {
          if (mounted) setState(() => _exportProgress = progress);
        },
      );
      if (!mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              result.problems.isEmpty
                  ? 'Library exported.'
                  : 'Library exported with '
                      '${_count(result.problems.length, 'problem')}.',
            ),
          ),
        );
        return;
      }
      setState(() {
        _isExporting = false;
        _exportProgress = null;
      });
      await showDialog<void>(
        context: context,
        builder: (_) => _ExportSummaryDialog(result: result),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not export the library: $error')),
      );
    } finally {
      if (mounted && _isExporting) {
        setState(() {
          _isExporting = false;
          _exportProgress = null;
        });
      }
    }
  }

  void _openRestorePage() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const _RestorePlaylistsPage()));
  }

  String get _updateStatusText {
    if (_isDownloadingUpdate) return 'Downloading update';
    if (_isCheckingForUpdate) return 'Checking for updates';
    final update = _availableUpdate;
    if (update != null) return 'WoolyTube ${update.version} is available';
    return 'Check for a new version';
  }

  Future<void> _onUpdatePressed() async {
    final update = _availableUpdate;
    if (update != null) {
      await _confirmAndInstallUpdate(update);
      return;
    }

    setState(() => _isCheckingForUpdate = true);
    try {
      final result = await ref.read(updateServiceProvider).checkForUpdate();
      if (!mounted) return;
      setState(() => _availableUpdate = result);
      widget.onUpdateChanged?.call(result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result == null
                ? 'WoolyTube is up to date.'
                : 'WoolyTube ${result.version} is available.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not check for updates: $error')),
      );
    } finally {
      if (mounted) setState(() => _isCheckingForUpdate = false);
    }
  }

  Future<void> _confirmAndInstallUpdate(AppUpdate update) async {
    final shouldUpdate = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Update available'),
            content: Text(
              'WoolyTube ${update.version} is available. '
              'You are running ${update.currentVersion}. '
              'Download and install the new APK?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Later'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Update'),
              ),
            ],
          ),
    );
    if (!mounted || shouldUpdate != true) return;

    // The dialog closes itself through its own context; whenComplete tracks
    // every way it can go away so we never pop an unrelated route.
    var progressDialogOpen = true;
    BuildContext? progressDialogContext;
    void closeProgressDialog({bool showBackgroundMessage = false}) {
      if (!progressDialogOpen) return;
      final dialogContext = progressDialogContext;
      if (dialogContext != null && dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      }
      if (showBackgroundMessage && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Update download continues in the background. '
              'You’ll be prompted to install it when ready.',
            ),
          ),
        );
      }
    }

    setState(() => _isDownloadingUpdate = true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          progressDialogContext = dialogContext;
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('Downloading update'),
              content: const Row(
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'You can keep using WoolyTube while this downloads. '
                      'The installer will open when it is ready.',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed:
                      () => closeProgressDialog(showBackgroundMessage: true),
                  child: const Text('Close — keep downloading'),
                ),
              ],
            ),
          );
        },
      ).whenComplete(() {
        progressDialogOpen = false;
        progressDialogContext = null;
      }),
    );

    try {
      await ref.read(updateServiceProvider).downloadAndInstallUpdate(update);
      closeProgressDialog();
    } on PlatformException catch (error) {
      closeProgressDialog();
      if (!mounted) return;
      final message =
          error.code == 'INSTALL_PERMISSION_REQUIRED'
              ? 'Allow WoolyTube to install unknown apps, then tap App update again.'
              : error.message ?? 'Could not download and install the update.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      closeProgressDialog();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not install the update: $error')),
      );
    } finally {
      if (mounted) setState(() => _isDownloadingUpdate = false);
    }
  }
}

/// `/storage/emulated/0/Music/WoolyTube` as `Music/WoolyTube`.
String _displayPath(String path) {
  const sharedStorage = '/storage/emulated/0/';
  return path.startsWith(sharedStorage)
      ? path.substring(sharedStorage.length)
      : path;
}

String _count(int count, String noun) => '$count $noun${count == 1 ? '' : 's'}';

class _ExportSummaryDialog extends StatelessWidget {
  const _ExportSummaryDialog({required this.result});

  final LibraryExportResult result;

  @override
  Widget build(BuildContext context) {
    final covers = result.trackCovers + result.playlistCovers;
    const strong = TextStyle(fontWeight: FontWeight.w600);
    return AlertDialog(
      title: Text(
        result.problems.isEmpty
            ? 'Library exported'
            : 'Library exported with problems',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_count(result.playlists, 'playlist')}, '
              '${_count(result.tracks, 'track')} and '
              '${_count(covers, 'cover')}'
              '${result.newCovers > 0 ? ' (${result.newCovers} new)' : ''}.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Each playlist folder holds its files with covers, a playlist '
              'file (.m3u8) in your order and woolytube_meta.json.',
            ),
            const SizedBox(height: 12),
            const Text('Everything is in these two folders:'),
            const SizedBox(height: 4),
            Text(_displayPath(LibraryLayout.audioBasePath), style: strong),
            Text(_displayPath(LibraryLayout.videoBasePath), style: strong),
            if (result.databaseCopyPath != null) ...[
              const SizedBox(height: 12),
              Text(
                'A copy of the app data and settings is in '
                '${_displayPath(LibraryExportService.backupDir)}.',
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Copy these two folders to keep a complete backup that plays '
              'without the app.',
            ),
            if (result.problems.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Not exported:', style: strong),
              const SizedBox(height: 4),
              for (final problem in result.problems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(problem),
                ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// Lists playlist folders that are not in the app, including ones the owner
/// removed or dismissed before, and imports them one at a time.
class _RestorePlaylistsPage extends ConsumerStatefulWidget {
  const _RestorePlaylistsPage();

  @override
  ConsumerState<_RestorePlaylistsPage> createState() =>
      _RestorePlaylistsPageState();
}

class _RestorePlaylistsPageState extends ConsumerState<_RestorePlaylistsPage> {
  /// Null while looking.
  List<DiscoveredPlaylist>? _found;

  /// The chosen folder, or null for the library folders.
  String? _source;
  String? _importingFolder;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan({String? folder}) async {
    final metadata = ref.read(metadataServiceProvider);
    setState(() {
      _found = null;
      _source = folder;
    });
    List<DiscoveredPlaylist> found;
    try {
      final candidates =
          folder == null ? null : await metadata.scanDirectory(folder);
      // Dismissed playlists are listed too: they are what the owner may
      // want back.
      found = await metadata.findUnimportedPlaylists(candidates: candidates);
    } catch (error) {
      found = const [];
      if (mounted) _showMessage('Could not look for playlists: $error');
    }
    if (mounted) setState(() => _found = found);
  }

  Future<void> _chooseFolder() async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose a folder with playlists',
      );
    } catch (error) {
      if (mounted) _showMessage('Could not open the folder picker: $error');
      return;
    }
    if (path == null || !mounted) return;
    await _scan(folder: path);
  }

  Future<void> _import(DiscoveredPlaylist discovered) async {
    final metadata = ref.read(metadataServiceProvider);
    final settings = ref.read(appSettingsServiceProvider);
    final log = ref.read(logServiceProvider);
    final pendingImports = ref.read(pendingImportsProvider.notifier);
    setState(() => _importingFolder = discovered.folderPath);
    String message;
    try {
      await metadata.importPlaylist(discovered);
      try {
        await settings.removeDismissedImportUrl(discovered.url);
      } catch (e) {
        log.warn('could not clear dismissal of ${discovered.name}: $e');
      }
      // Drop it, and other copies of the same playlist, from this list and
      // from the import banner on the home page.
      pendingImports.state = await metadata.findUnimportedPlaylists(
        candidates: pendingImports.state,
      );
      final remaining = await metadata.findUnimportedPlaylists(
        candidates: [...?_found]..remove(discovered),
      );
      if (mounted) setState(() => _found = remaining);
      message =
          'Restored "${discovered.name}" with '
          '${_count(discovered.tracks.length, 'track')}.';
    } catch (error) {
      log.warn('restore of ${discovered.name} failed: $error');
      message = 'Could not restore "${discovered.name}": $error';
    } finally {
      if (mounted) setState(() => _importingFolder = null);
    }
    if (mounted) _showMessage(message);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    final source = _source;
    final idle = found != null && _importingFolder == null;
    final libraryFolders =
        '${_displayPath(LibraryLayout.audioBasePath)} and '
        '${_displayPath(LibraryLayout.videoBasePath)}';
    return Scaffold(
      appBar: AppBar(title: const Text('Restore playlists')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Choose a folder...'),
            subtitle: const Text(
              'Look for playlists in a copied backup. Restored playlists keep '
              'using that folder.',
            ),
            enabled: idle,
            onTap: _chooseFolder,
          ),
          if (source != null)
            ListTile(
              leading: const Icon(Icons.library_music_outlined),
              title: const Text('Library folders'),
              subtitle: Text('Look in $libraryFolders again'),
              enabled: idle,
              onTap: _scan,
            ),
          const Divider(height: 1),
          _SectionHeader(
            source == null
                ? 'In $libraryFolders'
                : 'In ${_displayPath(source)}',
          ),
          if (found == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (found.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                source == null
                    ? 'Nothing to restore. Every playlist in the library '
                        'folders is already in WoolyTube.'
                    : 'No playlists here that are not already in WoolyTube.',
                style: const TextStyle(color: Color(0xFF888888)),
              ),
            )
          else
            for (final playlist in found)
              ListTile(
                leading: Icon(
                  playlist.audioOnly
                      ? Icons.music_note_outlined
                      : Icons.movie_outlined,
                ),
                title: Text(playlist.name),
                subtitle: Text(
                  '${_count(playlist.tracks.length, 'track')} · '
                  '${_displayPath(playlist.folderPath)}',
                ),
                trailing:
                    _importingFolder == playlist.folderPath
                        ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : TextButton(
                          onPressed:
                              _importingFolder == null
                                  ? () => _import(playlist)
                                  : null,
                          child: const Text('Import'),
                        ),
              ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF2196F3),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SubtitleLanguagesDialog extends StatefulWidget {
  const _SubtitleLanguagesDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_SubtitleLanguagesDialog> createState() =>
      _SubtitleLanguagesDialogState();
}

class _SubtitleLanguagesDialogState extends State<_SubtitleLanguagesDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(
        context,
        AppSettingsService.normalizeSubtitleLanguages(_controller.text),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Subtitle languages'),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'Language codes',
          helperText: 'Separate codes with commas: en, hu, de',
        ),
        validator: (value) {
          try {
            AppSettingsService.normalizeSubtitleLanguages(value ?? '');
            return null;
          } on FormatException catch (error) {
            return error.message;
          }
        },
        onFieldSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
