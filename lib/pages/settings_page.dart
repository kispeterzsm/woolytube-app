import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/update_service.dart';
import '../services/app_settings_service.dart';
import '../services/library_export_service.dart';
import '../services/library_layout.dart';
import '../services/metadata_service.dart';
import '../services/playback_service.dart';
import '../widgets/settings_section_header.dart';
import 'debug_log_page.dart';

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
  DateTime? _lastYtDlpUpdateCheck;
  String? _appVersion;
  bool _isLoadingSettings = true;
  bool _isSavingSettings = false;
  bool _isCheckingForUpdate = false;
  bool _isDownloadingUpdate = false;
  bool _isExporting = false;
  bool _isRestoringSettings = false;
  LibraryExportProgress? _exportProgress;

  static final _dateFormat = DateFormat('d MMM y, HH:mm');

  @override
  void initState() {
    super.initState();
    _availableUpdate = widget.initialUpdate;
    unawaited(_loadSettings());
    unawaited(_loadVersion());
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
      final lastCheck = await settings.getLastYtDlpUpdateAttempt();
      if (mounted) {
        setState(() {
          _downloadSubtitles = values[2];
          _subtitleLanguages = languages;
          _autoDownloadWithMobileData = values[0];
          _pauseOnAudioInterruption = values[1];
          _lastYtDlpUpdateCheck = lastCheck;
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

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {
      // Shown without a number.
    }
  }

  /// Saves one setting. The control moves at once and goes back if saving
  /// fails.
  Future<void> _save({
    required VoidCallback apply,
    required VoidCallback revert,
    required Future<void> Function() write,
  }) async {
    setState(() {
      apply();
      _isSavingSettings = true;
    });
    try {
      await write();
    } catch (error) {
      if (!mounted) return;
      setState(revert);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save setting: $error')));
    } finally {
      if (mounted) setState(() => _isSavingSettings = false);
    }
  }

  Future<void> _setPauseOnAudioInterruption(bool enabled) => _save(
    apply: () => _pauseOnAudioInterruption = enabled,
    revert: () => _pauseOnAudioInterruption = !enabled,
    write: () async {
      await ref
          .read(appSettingsServiceProvider)
          .setPauseOnAudioInterruption(enabled);
      await _applyPauseOnAudioInterruption(enabled);
    },
  );

  /// Tells the player; there is none in some tests.
  Future<void> _applyPauseOnAudioInterruption(bool enabled) async {
    PlaybackService player;
    try {
      player = ref.read(playbackServiceProvider);
    } catch (_) {
      return;
    }
    await player.setPauseOnAudioInterruption(enabled);
  }

  Future<void> _setAutoDownloadWithMobileData(bool enabled) => _save(
    apply: () => _autoDownloadWithMobileData = enabled,
    revert: () => _autoDownloadWithMobileData = !enabled,
    write:
        () => ref
            .read(appSettingsServiceProvider)
            .setAutoDownloadWithMobileData(enabled),
  );

  Future<void> _setDownloadSubtitles(bool enabled) => _save(
    apply: () => _downloadSubtitles = enabled,
    revert: () => _downloadSubtitles = !enabled,
    write:
        () =>
            ref.read(appSettingsServiceProvider).setDownloadSubtitles(enabled),
  );

  Future<void> _editSubtitleLanguages() async {
    final languages = await showDialog<String>(
      context: context,
      builder:
          (_) => _SubtitleLanguagesDialog(initialValue: _subtitleLanguages),
    );
    if (!mounted || languages == null || languages == _subtitleLanguages) {
      return;
    }
    final previous = _subtitleLanguages;
    await _save(
      apply: () => _subtitleLanguages = languages,
      revert: () => _subtitleLanguages = previous,
      write:
          () => ref
              .read(appSettingsServiceProvider)
              .setSubtitleLanguages(languages),
    );
  }

  /// Shows what is stored now and applies the audio setting to the player,
  /// after a restore changed the settings behind this page.
  Future<void> _reloadAfterRestore() async {
    await _loadSettings();
    try {
      await _applyPauseOnAudioInterruption(_pauseOnAudioInterruption);
    } catch (_) {}
  }

  Future<void> _restoreSettings() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Restore settings?'),
            content: const Text(
              'Replaces the playback, subtitle and mobile data settings with '
              'the ones saved by the last library backup. Playlists are not '
              'changed.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Restore'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isRestoringSettings = true);
    String message;
    try {
      final applied =
          await ref.read(libraryExportServiceProvider).restoreSettings();
      message =
          applied == null
              ? 'No settings backup found. Back up the library first.'
              : 'Restored ${_count(applied, 'setting')}.';
      if (applied != null && mounted) await _reloadAfterRestore();
    } catch (e) {
      message = 'Could not restore settings: $e';
    } finally {
      if (mounted) setState(() => _isRestoringSettings = false);
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  void _openDebugLog() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const DebugLogPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body:
          _isLoadingSettings
              ? const Center(child: CircularProgressIndicator())
              : ValueListenableBuilder<double>(
                valueListenable: audioPlayerOverlayHeightNotifier,
                builder:
                    (context, overlay, _) => ListView(
                      padding: EdgeInsets.only(bottom: 16 + overlay),
                      children: _rows(),
                    ),
              ),
    );
  }

  List<Widget> _rows() {
    final saving = _isSavingSettings;
    return [
      const SettingsSectionHeader('Playback'),
      SwitchListTile(
        secondary: const Icon(Icons.pause_circle_outline),
        title: const Text('Pause when other apps play sound'),
        subtitle: const Text(
          'Also resumes after a call. Unplugging headphones always pauses.',
        ),
        value: _pauseOnAudioInterruption,
        onChanged: saving ? null : _setPauseOnAudioInterruption,
      ),
      const SettingsSectionHeader('Downloads and updates'),
      SwitchListTile(
        secondary: const Icon(Icons.network_cell),
        title: const Text('Update playlists on mobile data'),
        subtitle: const Text(
          'For automatic updates. Downloads you start yourself ask first.',
        ),
        value: _autoDownloadWithMobileData,
        onChanged: saving ? null : _setAutoDownloadWithMobileData,
      ),
      SwitchListTile(
        secondary: const Icon(Icons.closed_caption_outlined),
        title: const Text('Download subtitles'),
        subtitle: const Text(
          'For video playlists, including automatic captions. Applies to new '
          'downloads.',
        ),
        value: _downloadSubtitles,
        onChanged: saving ? null : _setDownloadSubtitles,
      ),
      if (_downloadSubtitles)
        ListTile(
          key: const ValueKey('subtitle-languages'),
          leading: const SizedBox(width: 24),
          title: const Text('Subtitle languages'),
          subtitle: Text(_subtitleLanguages),
          enabled: !saving,
          trailing: const Icon(Icons.chevron_right),
          onTap: _editSubtitleLanguages,
        ),
      const SettingsSectionHeader('Backup and restore'),
      ListTile(
        leading: const Icon(Icons.save_alt),
        title: const Text('Back up library'),
        subtitle: Text(_exportStatusText),
        trailing:
            _isExporting
                ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : null,
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
          'Bring back removed playlists, or ones from a copied backup',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openRestorePage,
      ),
      ListTile(
        key: const ValueKey('restore-settings'),
        leading: const Icon(Icons.settings_backup_restore),
        title: const Text('Restore settings'),
        subtitle: const Text('From the last library backup'),
        trailing:
            _isRestoringSettings
                ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : null,
        onTap: _isRestoringSettings ? null : _restoreSettings,
      ),
      const SettingsSectionHeader('About'),
      ListTile(
        key: const ValueKey('app-update'),
        leading: Icon(
          _isDownloadingUpdate ? Icons.downloading : Icons.system_update,
          color:
              _availableUpdate == null
                  ? const Color(0xFF888888)
                  : const Color(0xFF2196F3),
        ),
        title: Text(
          _appVersion == null ? 'WoolyTube' : 'WoolyTube $_appVersion',
        ),
        subtitle: Text(_updateStatusText),
        trailing:
            _isCheckingForUpdate || _isDownloadingUpdate
                ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : null,
        onTap:
            _isCheckingForUpdate || _isDownloadingUpdate
                ? null
                : _onUpdatePressed,
      ),
      ListTile(
        leading: const Icon(Icons.download_for_offline_outlined),
        title: const Text('Downloader (yt-dlp)'),
        subtitle: Text(
          _lastYtDlpUpdateCheck == null
              ? 'Updates itself when the app starts'
              : 'Last update check: '
                  '${_dateFormat.format(_lastYtDlpUpdateCheck!)}',
        ),
      ),
      ListTile(
        key: const ValueKey('debug-log'),
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text('Debug log'),
        subtitle: const Text(
          'What the app and background updates did, for troubleshooting',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openDebugLog,
      ),
    ];
  }

  String get _exportStatusText {
    final progress = _exportProgress;
    if (!_isExporting) {
      return 'Saves covers, playlist files and a copy of the app data next '
          'to your downloads';
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
                  ? 'Library backed up.'
                  : 'Library backed up with '
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
        SnackBar(content: Text('Could not back up the library: $error')),
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

  Future<void> _openRestorePage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _RestorePlaylistsPage()),
    );
    // Settings may have been restored from a chosen folder.
    if (mounted) await _reloadAfterRestore();
  }

  String get _updateStatusText {
    if (_isDownloadingUpdate) return 'Downloading the update';
    if (_isCheckingForUpdate) return 'Checking for updates';
    final update = _availableUpdate;
    if (update != null) {
      return 'Version ${update.version} is available. Tap to install.';
    }
    return 'Tap to check for updates';
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
    // Errors are still reported after the owner leaves Settings.
    final messenger = ScaffoldMessenger.of(context);
    final updates = ref.read(updateServiceProvider);

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
      if (showBackgroundMessage) {
        messenger.showSnackBar(
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
      await updates.downloadAndInstallUpdate(update);
      closeProgressDialog();
    } on PlatformException catch (error) {
      closeProgressDialog();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.code == 'INSTALL_PERMISSION_REQUIRED'
                ? 'Allow WoolyTube to install unknown apps, then tap '
                    'WoolyTube in Settings again.'
                : error.message ?? 'Could not download and install the update.',
          ),
        ),
      );
    } catch (error) {
      closeProgressDialog();
      messenger.showSnackBar(
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
            if (result.foldersOutsideLibrary.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'These playlists were restored from other folders and are '
                'still there:',
              ),
              const SizedBox(height: 4),
              for (final folder in result.foldersOutsideLibrary)
                Text(_displayPath(folder), style: strong),
            ],
            const SizedBox(height: 12),
            Text(
              result.foldersOutsideLibrary.isEmpty
                  ? 'Copy these two folders to keep a complete backup that '
                      'plays without the app.'
                  : 'Copy all of these folders to keep a complete backup that '
                      'plays without the app.',
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

  Future<void> _restoreSettings() async {
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      final applied = await ref
          .read(libraryExportServiceProvider)
          .restoreSettings(folder: _source);
      message =
          applied == null
              ? 'No settings backup found in this folder.'
              : 'Restored ${_count(applied, 'setting')}.';
    } catch (e) {
      message = 'Could not restore settings: $e';
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
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
      body: ValueListenableBuilder<double>(
        valueListenable: audioPlayerOverlayHeightNotifier,
        builder:
            (context, overlay, child) => ListView(
              padding: EdgeInsets.only(bottom: 16 + overlay),
              children: [
                ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: const Text('Choose a folder…'),
                  subtitle: const Text(
                    'Look for playlists in a copied backup. Restored playlists keep '
                    'using that folder.',
                  ),
                  enabled: idle,
                  onTap: _chooseFolder,
                ),
                // Settings from the library backup are restored on the Settings
                // page; here only from a folder the owner picked.
                if (source != null)
                  ListTile(
                    key: const ValueKey('restore-settings-from-folder'),
                    leading: const Icon(Icons.settings_backup_restore),
                    title: const Text('Restore settings from this folder'),
                    subtitle: const Text(
                      'Playback, subtitle and mobile data settings from its backup',
                    ),
                    enabled: idle,
                    onTap: _restoreSettings,
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
                SettingsSectionHeader(
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
  /// Offered as one-tap choices; any other code can be typed.
  static const _common = <(String, String)>[
    ('en', 'English'),
    ('hu', 'Hungarian'),
    ('de', 'German'),
    ('es', 'Spanish'),
    ('fr', 'French'),
    ('it', 'Italian'),
    ('pt', 'Portuguese'),
    ('ja', 'Japanese'),
  ];

  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  List<String> get _codes =>
      _controller.text
          .split(',')
          .map((code) => code.trim())
          .where((code) => code.isNotEmpty)
          .toList();

  void _toggle(String code, bool selected) {
    final codes = _codes..remove(code);
    if (selected) codes.add(code);
    _controller.text = codes.join(', ');
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
  Widget build(BuildContext context) {
    final codes = _codes;
    return AlertDialog(
      title: const Text('Subtitle languages'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  for (final (code, name) in _common)
                    FilterChip(
                      label: Text(name),
                      selected: codes.contains(code),
                      onSelected: (selected) => _toggle(code, selected),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _controller,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Language codes',
                  helperText:
                      'Separate codes with commas: en, hu, de. '
                      'en.* also gets en-US and en-GB.',
                  helperMaxLines: 2,
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
            ],
          ),
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
}
