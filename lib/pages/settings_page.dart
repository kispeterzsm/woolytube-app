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
import '../services/audio_processing.dart';
import '../services/backup_check_service.dart';
import '../services/library_export_service.dart';
import '../services/library_layout.dart';
import '../services/library_restore_service.dart';
import '../services/loudness_service.dart';
import '../services/metadata_service.dart';
import '../services/playback_service.dart';
import '../widgets/plane_mode_toggle.dart';
import '../widgets/settings_section_header.dart';
import 'debug_log_page.dart';
import 'labels_page.dart';

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
  bool _evenOutVolume = false;
  EvenOutMode _evenOutMode = EvenOutMode.normal;
  bool _loudnessOnlyWhileCharging = true;
  PlaneModeStrength _planeModeStrength = PlaneModeStrength.standard;
  DateTime? _lastYtDlpUpdateCheck;
  String? _appVersion;
  bool _isLoadingSettings = true;
  bool _isSavingSettings = false;
  bool _isCheckingForUpdate = false;
  bool _isDownloadingUpdate = false;
  _BackupWork? _backupWork;
  bool _isRestoringSettings = false;
  LibraryExportProgress? _backupProgress;

  /// The newest change to the app's files in the library folders.
  DateTime? _libraryFoldersUpdated;

  static final _dateFormat = DateFormat('d MMM y, HH:mm');

  @override
  void initState() {
    super.initState();
    _availableUpdate = widget.initialUpdate;
    unawaited(_loadSettings());
    unawaited(_loadVersion());
    unawaited(_loadLibraryFoldersUpdated());
  }

  Future<void> _loadLibraryFoldersUpdated() async {
    try {
      final updated = await ref.read(backupCheckServiceProvider).lastUpdated();
      if (mounted) setState(() => _libraryFoldersUpdated = updated);
    } catch (_) {
      // Shown without a time.
    }
  }

  Future<void> _loadSettings() async {
    try {
      final settings = ref.read(appSettingsServiceProvider);
      final values = await Future.wait([
        settings.getAutoDownloadWithMobileData(),
        settings.getPauseOnAudioInterruption(),
      ]);
      final lastCheck = await settings.getLastYtDlpUpdateAttempt();
      final evenOutVolume = await settings.getEvenOutVolume();
      final evenOutMode = await settings.getEvenOutMode();
      final onlyWhileCharging = await settings.getLoudnessOnlyWhileCharging();
      final strength = await settings.getPlaneModeStrength();
      if (mounted) {
        setState(() {
          _evenOutVolume = evenOutVolume;
          _evenOutMode = evenOutMode;
          _loudnessOnlyWhileCharging = onlyWhileCharging;
          _planeModeStrength = strength;
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
  /// fails. Returns whether it was saved.
  Future<bool> _save({
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
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(revert);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save setting: $error')));
      return false;
    } finally {
      if (mounted) setState(() => _isSavingSettings = false);
    }
  }

  Future<void> _setPauseOnAudioInterruption(bool enabled) async {
    final player = _playerOrNull();
    final saved = await _save(
      apply: () => _pauseOnAudioInterruption = enabled,
      revert: () => _pauseOnAudioInterruption = !enabled,
      write:
          () => ref
              .read(appSettingsServiceProvider)
              .setPauseOnAudioInterruption(enabled),
    );
    if (!saved) return;
    // The choice is stored either way; the player picks it up at the
    // latest at the next start.
    try {
      await player?.setPauseOnAudioInterruption(enabled);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved. The player could not use it yet, so it applies after '
            'the app restarts ($error).',
          ),
        ),
      );
    }
  }

  Future<void> _setEvenOutVolume(bool enabled) async {
    final player = _playerOrNull();
    final saved = await _save(
      apply: () => _evenOutVolume = enabled,
      revert: () => _evenOutVolume = !enabled,
      write:
          () => ref.read(appSettingsServiceProvider).setEvenOutVolume(enabled),
    );
    if (saved) await _tellPlayer(() => player?.setEvenOutVolume(enabled));
  }

  Future<void> _setEvenOutMode(EvenOutMode mode) async {
    final player = _playerOrNull();
    final previous = _evenOutMode;
    final saved = await _save(
      apply: () => _evenOutMode = mode,
      revert: () => _evenOutMode = previous,
      write: () => ref.read(appSettingsServiceProvider).setEvenOutMode(mode),
    );
    if (saved) await _tellPlayer(() => player?.setEvenOutMode(mode));
  }

  Future<void> _setLoudnessOnlyWhileCharging(bool enabled) async {
    final saved = await _save(
      apply: () => _loudnessOnlyWhileCharging = enabled,
      revert: () => _loudnessOnlyWhileCharging = !enabled,
      write:
          () => ref
              .read(appSettingsServiceProvider)
              .setLoudnessOnlyWhileCharging(enabled),
    );
    if (saved) _loudnessOrNull()?.setOnlyWhileCharging(enabled);
  }

  Future<void> _setPlaneModeStrength(PlaneModeStrength strength) async {
    final player = _playerOrNull();
    final previous = _planeModeStrength;
    final saved = await _save(
      apply: () => _planeModeStrength = strength,
      revert: () => _planeModeStrength = previous,
      write:
          () => ref
              .read(appSettingsServiceProvider)
              .setPlaneModeStrength(strength),
    );
    if (saved) await _tellPlayer(() => player?.setPlaneModeStrength(strength));
  }

  /// Hands a saved sound setting to the player. The choice is stored
  /// either way; the player picks it up at the latest at the next start.
  Future<void> _tellPlayer(Future<void>? Function() apply) async {
    try {
      await apply();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved. The player could not use it yet, so it applies after '
            'the app restarts ($error).',
          ),
        ),
      );
    }
  }

  /// The player; there is none in some tests.
  PlaybackService? _playerOrNull() {
    try {
      return ref.read(playbackServiceProvider);
    } catch (_) {
      return null;
    }
  }

  /// Loudness measuring; there is none in some tests.
  LoudnessService? _loudnessOrNull() => _readLoudness(ref);

  Future<void> _setAutoDownloadWithMobileData(bool enabled) => _save(
    apply: () => _autoDownloadWithMobileData = enabled,
    revert: () => _autoDownloadWithMobileData = !enabled,
    write:
        () => ref
            .read(appSettingsServiceProvider)
            .setAutoDownloadWithMobileData(enabled),
  );

  Future<void> _restoreSettings() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Restore settings?'),
            content: const Text(
              'Replaces the playback, sound, mobile data and new playlist '
              'settings with the ones saved in the library folder. '
              'Playlists are not changed.',
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
    // Read now: the restore may end after the page is closed.
    final exporter = ref.read(libraryExportServiceProvider);
    final settings = ref.read(appSettingsServiceProvider);
    final player = _playerOrNull();
    final loudness = _loudnessOrNull();
    setState(() => _isRestoringSettings = true);
    String message;
    try {
      final applied = await exporter.restoreSettings();
      message =
          applied == null
              ? 'No settings file found in the library folder.'
              : 'Restored ${_count(applied, 'setting')}.';
      if (applied != null) {
        await applyRestoredSettings(settings, player, loudness);
        // Shows what is stored now.
        if (mounted) await _loadSettings();
      }
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

  /// Top to bottom: app update, downloads, library, backup, sound,
  /// playback, then troubleshooting.
  List<Widget> _rows() => [
    ..._updateRows(),
    ..._downloadRows(),
    ..._libraryRows(),
    ..._backupRows(),
    ..._soundRows(),
    ..._playbackRows(),
    ..._troubleshootingRows(),
  ];

  /// The app's version, and checking for and installing a new one.
  List<Widget> _updateRows() {
    return [
      const SettingsSectionHeader('Update'),
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
    ];
  }

  /// What gets downloaded and when, and the downloader itself.
  List<Widget> _downloadRows() {
    final saving = _isSavingSettings;
    return [
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
    ];
  }

  /// Organizing the library.
  List<Widget> _libraryRows() {
    return [
      const SettingsSectionHeader('Library'),
      ListTile(
        key: const ValueKey('settings-labels'),
        leading: const Icon(Icons.label_outline),
        title: const Text('Labels'),
        subtitle: const Text(
          'Mark files and chapters with genres, bands or anything else',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap:
            () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const LabelsPage())),
      ),
    ];
  }

  /// Backing up the library and bringing playlists or settings back.
  List<Widget> _backupRows() {
    return [
      const SettingsSectionHeader('Backup and restore'),
      ListTile(
        key: const ValueKey('check-backup'),
        leading: const Icon(Icons.fact_check_outlined),
        title: const Text('Check backup'),
        subtitle: Text(_backupStatusText),
        isThreeLine: _backupWork == null && _libraryFoldersUpdated != null,
        trailing:
            _backupWork != null
                ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : null,
        onTap: _backupWork != null ? null : _checkBackup,
      ),
      if (_backupWork != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LinearProgressIndicator(value: _backupFraction),
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
        subtitle: const Text('From the library folder'),
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
    ];
  }

  /// Loudness and other audio processing.
  List<Widget> _soundRows() {
    final saving = _isSavingSettings;
    return [
      const SettingsSectionHeader('Sound'),
      SwitchListTile(
        key: const ValueKey('even-out-volume'),
        secondary: const Icon(Icons.equalizer),
        title: const Text('Even out volume'),
        subtitle: const Text(
          'Plays every song at a similar loudness, so a loud song does '
          'not follow a quiet one.',
        ),
        value: _evenOutVolume,
        onChanged: saving ? null : _setEvenOutVolume,
      ),
      // A row of its own, so tapping its text never turns the switch off
      // and a screen reader reaches Normal and Quiet one by one.
      if (_evenOutVolume)
        ListTile(
          key: const ValueKey('even-out-mode-row'),
          // Lines the buttons up with the switch's title.
          leading: const SizedBox(width: 24),
          title: Align(
            alignment: AlignmentDirectional.centerStart,
            child: SegmentedButton<EvenOutMode>(
              key: const ValueKey('even-out-mode'),
              showSelectedIcon: false,
              segments: [
                for (final mode in EvenOutMode.values)
                  ButtonSegment(value: mode, label: Text(mode.label)),
              ],
              selected: {_evenOutMode},
              onSelectionChanged:
                  saving ? null : (value) => _setEvenOutMode(value.first),
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(switch (_evenOutMode) {
              EvenOutMode.normal =>
                'Normal: quiet songs are turned up too; a limiter keeps '
                    'them from clipping.',
              EvenOutMode.quiet =>
                'Quiet: a lower level that leaves the sound untouched. '
                    'Turn the phone up a little.',
            }),
          ),
        ),
      _PlaneModeTile(enabled: !saving),
      ListTile(
        key: const ValueKey('plane-mode-strength'),
        leading: const Icon(Icons.tune),
        title: const Text('Plane mode strength'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(switch (_planeModeStrength) {
              PlaneModeStrength.standard =>
                'Standard: gentle, fine for a whole flight.',
              PlaneModeStrength.strong =>
                'Strong: lifts quiet parts further; can sound squeezed.',
            }),
            const SizedBox(height: 8),
            SegmentedButton<PlaneModeStrength>(
              showSelectedIcon: false,
              segments: [
                for (final strength in PlaneModeStrength.values)
                  ButtonSegment(value: strength, label: Text(strength.label)),
              ],
              selected: {_planeModeStrength},
              onSelectionChanged:
                  saving ? null : (value) => _setPlaneModeStrength(value.first),
            ),
          ],
        ),
      ),
      const _LoudnessProgressTile(),
      _LoudnessOnlyWhileChargingTile(
        value: _loudnessOnlyWhileCharging,
        onChanged: saving ? null : _setLoudnessOnlyWhileCharging,
      ),
    ];
  }

  /// How playback behaves.
  List<Widget> _playbackRows() {
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
    ];
  }

  /// Help with finding out what went wrong.
  List<Widget> _troubleshootingRows() {
    return [
      const SettingsSectionHeader('Troubleshooting'),
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

  String get _backupStatusText {
    final work = _backupWork;
    if (work == null) {
      final updated = _libraryFoldersUpdated;
      const always = 'Everything is saved in the library folders as you go.';
      if (updated == null) return always;
      return '$always\nLibrary folders last updated: '
          '${_dateFormat.format(updated)}';
    }
    final progress = _backupProgress;
    final verb = work == _BackupWork.checking ? 'Checking' : 'Fixing';
    if (progress == null) return 'Getting ready';
    if (progress.done >= progress.total) {
      return work == _BackupWork.checking
          ? 'Checking the settings'
          : 'Saving the settings, lyrics and loudness';
    }
    return '$verb playlist ${progress.done + 1} of ${progress.total}: '
        '${progress.current ?? ''}';
  }

  double? get _backupFraction {
    final progress = _backupProgress;
    if (progress == null || progress.total == 0) return null;
    return progress.done / progress.total;
  }

  void _onBackupProgress(LibraryExportProgress progress) {
    if (mounted) setState(() => _backupProgress = progress);
  }

  void _endBackupWork() {
    if (!mounted) return;
    setState(() {
      _backupWork = null;
      _backupProgress = null;
    });
    unawaited(_loadLibraryFoldersUpdated());
  }

  /// Looks for anything missing in the library folders, without writing,
  /// and offers to fix it.
  Future<void> _checkBackup() async {
    final messenger = ScaffoldMessenger.of(context);
    final service = ref.read(backupCheckServiceProvider);
    setState(() {
      _backupWork = _BackupWork.checking;
      _backupProgress = null;
    });
    BackupReport report;
    try {
      report = await service.check(onProgress: _onBackupProgress);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not check the backup: $error')),
      );
      _endBackupWork();
      return;
    }
    _endBackupWork();
    if (!mounted) return;
    final fix = await showDialog<bool>(
      context: context,
      builder: (_) => _BackupCheckDialog(report: report),
    );
    if (fix == true && mounted) await _fixBackup();
  }

  /// Writes what the library folders lack (no copy of the database), then
  /// checks again and shows what is left.
  Future<void> _fixBackup() async {
    // The fix keeps running if the page is closed; a snack bar then still
    // reports the end.
    final messenger = ScaffoldMessenger.of(context);
    final networkPolicy = ref.read(downloadNetworkPolicyProvider);
    final service = ref.read(backupCheckServiceProvider);
    setState(() {
      _backupWork = _BackupWork.fixing;
      _backupProgress = null;
    });
    try {
      var allowNetwork = false;
      try {
        allowNetwork = await networkPolicy.allowsAutomaticNetworkUse();
      } catch (_) {
        // Covers come from the files and the image cache.
      }
      final result = await service.fix(
        allowNetwork: allowNetwork,
        onProgress: _onBackupProgress,
      );
      if (mounted) {
        setState(() {
          _backupWork = _BackupWork.checking;
          _backupProgress = null;
        });
      }
      final report = await service.check(onProgress: _onBackupProgress);
      if (!mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              report.problems.isEmpty && result.problems.isEmpty
                  ? 'Backup fixed.'
                  : 'Backup fixed in part: '
                      '${_count(report.problems.length + result.problems.length, 'problem')} left.',
            ),
          ),
        );
        return;
      }
      _endBackupWork();
      await showDialog<void>(
        context: context,
        builder: (_) => _BackupCheckDialog(report: report, fixed: result),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not fix the backup: $error')),
      );
    } finally {
      if (_backupWork != null) _endBackupWork();
    }
  }

  Future<void> _openRestorePage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _RestorePlaylistsPage()),
    );
    // Settings may have been restored from a chosen folder.
    if (mounted) await _loadSettings();
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

final _numberFormat = NumberFormat('#,##0', 'en_US');

/// 1400 as `1,400`.
String _number(int count) => _numberFormat.format(count);

String _count(int count, String noun, [String? plural]) =>
    '$count ${count == 1 ? noun : plural ?? '${noun}s'}';

enum _BackupWork { checking, fixing }

/// What "Check backup" found, with a "Fix" button when something can be
/// written. After a fix ([fixed]), what was done and what is left.
class _BackupCheckDialog extends StatelessWidget {
  const _BackupCheckDialog({required this.report, this.fixed});

  final BackupReport report;
  final LibraryExportResult? fixed;

  static String _time(DateTime time) =>
      _SettingsPageState._dateFormat.format(time);

  static String _megabytes(int bytes) {
    final mb = bytes / (1024 * 1024);
    return mb >= 10 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    const strong = TextStyle(fontWeight: FontWeight.w600);
    final problems = report.problems;
    final fixed = this.fixed;
    final canFix = fixed == null && report.needsFix;
    final String title;
    if (fixed == null) {
      title = problems.isEmpty ? 'Backup is complete' : 'Backup needs fixing';
    } else {
      title =
          problems.isEmpty && fixed.problems.isEmpty
              ? 'Backup fixed'
              : 'Backup fixed in part';
    }
    final infoTotal = report.infoTotal;
    final infoMissing = infoTotal - report.infoSaved;
    final infoToFetch = infoMissing - report.infoUnavailable;
    final infoPausedUntil = report.infoPausedUntil;
    final newer = [
      for (final pl in report.playlists)
        if (pl.newerMetadataVersion != null) pl.name,
    ];
    final libraryFileSaved = report.libraryFiles
        .map((file) => file.savedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(
          null,
          (newest, time) =>
              newest == null || time.isAfter(newest) ? time : newest,
        );
    final outside = report.foldersOutsideLibrary;

    Widget gap([double height = 12]) => SizedBox(height: height);
    Widget bullet(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text('• $text'),
    );

    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_count(report.playlists.length, 'playlist')} and '
              '${_count(report.tracks, 'downloaded track')}.',
            ),
            if (report.lastUpdated case final updated?)
              Text('Library folders last updated: ${_time(updated)}.'),
            if (fixed != null && fixed.newCovers > 0) ...[
              gap(),
              Text('Saved ${_count(fixed.newCovers, 'new cover')}.'),
            ],
            if (problems.isNotEmpty) ...[
              gap(16),
              Text(
                fixed == null
                    ? 'Missing or out of date:'
                    : 'Still missing or out of date:',
                style: strong,
              ),
              gap(4),
              for (final problem in problems) bullet(problem),
            ],
            if (fixed != null && fixed.problems.isNotEmpty) ...[
              gap(16),
              const Text('Could not fix:', style: strong),
              gap(4),
              for (final problem in fixed.problems) bullet(problem),
            ],
            if (report.writeErrors.isNotEmpty) ...[
              gap(16),
              const Text(
                'Could not be saved since the app started:',
                style: strong,
              ),
              gap(4),
              for (final error in report.writeErrors)
                bullet(
                  '${error.what}: ${error.message}'
                  '${error.count > 1 ? ' (${error.count} times)' : ''}'
                  '${error.resolved ? '. Saved again later.' : ''}',
                ),
            ],
            gap(16),
            const Text('Saved files:', style: strong),
            gap(4),
            Text(
              report.settingsWaitForRestore
                  ? 'Settings: kept from the copied library until you '
                      'restore it.'
                  : report.settingsSavedAt == null
                  ? 'Settings: not saved yet.'
                  : 'Settings: ${_time(report.settingsSavedAt!)}.',
            ),
            Text(
              libraryFileSaved == null
                  ? 'Home order and last song: not saved yet.'
                  : 'Home order and last song: ${_time(libraryFileSaved)}.',
            ),
            if (infoTotal > 0)
              Text(
                'YouTube info: ${_number(report.infoSaved)} of '
                '${_number(infoTotal)} saved.',
              ),
            if (infoToFetch > 0)
              Text(
                infoPausedUntil != null
                    ? 'YouTube asked to slow down, so the rest is fetched '
                        'from ${_time(infoPausedUntil)}, on Wi-Fi.'
                    : 'The rest is fetched slowly in the background, on '
                        'Wi-Fi.',
              ),
            if (report.infoUnavailable > 0)
              Text(
                'The info of ${_count(report.infoUnavailable, 'track')} '
                'cannot be fetched: removed, private or unavailable on '
                'YouTube.',
              ),
            if (newer.isNotEmpty) ...[
              gap(),
              Text(
                'A newer version of the app wrote the playlist file of '
                '${newer.map((name) => '"$name"').join(', ')}. Update the app '
                'to keep ${newer.length == 1 ? 'it' : 'them'} up to date.',
              ),
            ],
            gap(16),
            Text(
              outside.isEmpty
                  ? 'Everything is in these two folders:'
                  : 'Everything is in these folders:',
            ),
            gap(4),
            Text(_displayPath(LibraryLayout.audioBasePath), style: strong),
            Text(_displayPath(LibraryLayout.videoBasePath), style: strong),
            for (final folder in outside)
              Text(_displayPath(folder), style: strong),
            gap(),
            const Text(
              'Copy them to a computer to back up the library, and onto '
              'another phone to move it there.',
            ),
            if (report.oldDatabaseCopies > 0) ...[
              gap(),
              Text(
                'Older versions of the app also saved '
                '${_count(report.oldDatabaseCopies, 'copy', 'copies')} of the '
                'app data (${_megabytes(report.oldDatabaseCopyBytes)}) in '
                '${_displayPath(LibraryExportService.backupDir)}. Nothing '
                'uses them any more, so you can delete them.',
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (canFix) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Close'),
          ),
          FilledButton(
            key: const ValueKey('fix-backup'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Fix'),
          ),
        ] else
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
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
    // Read now: the restore may end after the page is closed.
    final exporter = ref.read(libraryExportServiceProvider);
    final settings = ref.read(appSettingsServiceProvider);
    PlaybackService? player;
    try {
      player = ref.read(playbackServiceProvider);
    } catch (_) {}
    final loudness = _readLoudness(ref);
    String message;
    try {
      final applied = await exporter.restoreSettings(folder: _source);
      message =
          applied == null
              ? 'No settings backup found in this folder.'
              : 'Restored ${_count(applied, 'setting')}.';
      if (applied != null) {
        await applyRestoredSettings(settings, player, loudness);
      }
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
    final restore = ref.read(libraryRestoreServiceProvider);
    final settings = ref.read(appSettingsServiceProvider);
    final log = ref.read(logServiceProvider);
    final pendingImports = ref.read(pendingImportsProvider.notifier);
    setState(() => _importingFolder = discovered.folderPath);
    String message;
    try {
      // Goes where the copied library had it on the home page.
      await restore.importOne(discovered, folder: _source);
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
                      'Playback, sound, mobile data and new playlist settings '
                      'from its backup',
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

/// Plane mode on or off, in step with the player's button.
class _PlaneModeTile extends ConsumerWidget {
  const _PlaneModeTile({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(planeModeProvider).valueOrNull ?? false;
    return SwitchListTile(
      key: const ValueKey('plane-mode-setting'),
      secondary: const Icon(Icons.flight_rounded),
      title: const Text('Plane mode'),
      subtitle: const Text(
        'Evens out songs and lifts their quiet parts, so music stays clear '
        'over engine noise at a lower volume. Also in the player.',
      ),
      value: on,
      onChanged:
          enabled ? (_) => togglePlaneModeWithFeedback(context, ref) : null,
    );
  }
}

/// Loudness measuring; there is none in some tests.
LoudnessService? _readLoudness(WidgetRef ref) {
  try {
    return ref.read(loudnessServiceProvider);
  } catch (_) {
    return null;
  }
}

/// Whether plane mode or "Even out volume" is on, so songs are measured.
bool _watchMeasuring(WidgetRef ref) =>
    ref.watch(audioProcessingSettingsProvider).valueOrNull?.needsLoudness ??
    false;

/// How many songs have their loudness measured, while measuring is on, and
/// "Measure now" for the rest of the library.
class _LoudnessProgressTile extends ConsumerWidget {
  const _LoudnessProgressTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_watchMeasuring(ref)) return const SizedBox.shrink();
    final progress = ref.watch(loudnessProgressProvider).valueOrNull;
    if (progress == null) return const SizedBox.shrink();
    final String text;
    if (progress.total == 0) {
      if (!progress.working) return const SizedBox.shrink();
      text = 'Measuring songs\u2026';
    } else if (progress.measured >= progress.total && !progress.working) {
      text = 'All ${progress.total} songs measured';
    } else {
      text = 'Measured ${progress.measured} of ${progress.total} songs';
    }
    final failed =
        progress.failed > 0 ? '${progress.failed} could not be measured. ' : '';
    final String status;
    if (progress.waitingForLibrary) {
      status = 'Paused while files are moved or deleted.';
    } else if (progress.forced) {
      status = 'Measuring the whole library now, also on battery.';
    } else if (progress.waitingForCharger) {
      status =
          'The playing and next songs are measured right away; the rest '
          'of the library while the phone charges.';
    } else if (progress.failed > 0 && !progress.working) {
      status = 'Measure now tries them again.';
    } else {
      status =
          'Each song is measured once, in the background, while plane '
          'mode or Even out volume is on.';
    }
    return ListTile(
      key: const ValueKey('loudness-progress'),
      dense: true,
      leading: const SizedBox(width: 24),
      title: Text(text),
      subtitle: Text('$failed$status'),
      trailing:
          progress.forced
              ? TextButton(
                key: const ValueKey('loudness-measure-now'),
                onPressed: () => _readLoudness(ref)?.stopMeasuringNow(),
                child: const Text('Stop'),
              )
              : progress.hasWorkLeft
              ? TextButton(
                key: const ValueKey('loudness-measure-now'),
                onPressed: () => _measureNow(context, ref),
                child: const Text('Measure now'),
              )
              : null,
    );
  }

  void _measureNow(BuildContext context, WidgetRef ref) {
    _readLoudness(ref)?.measureNow();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Measuring all songs now. Keep WoolyTube open; it uses some '
          'battery.',
        ),
      ),
    );
  }
}

/// Whether the library is only measured while the phone is plugged in,
/// shown while measuring is on.
class _LoudnessOnlyWhileChargingTile extends ConsumerWidget {
  const _LoudnessOnlyWhileChargingTile({
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_watchMeasuring(ref)) return const SizedBox.shrink();
    return SwitchListTile(
      key: const ValueKey('loudness-only-charging'),
      secondary: const Icon(Icons.battery_charging_full),
      title: const Text('Only measure while charging'),
      subtitle: const Text(
        'When off, songs are measured whenever WoolyTube is open or '
        'playing. The playing and next songs are measured either way.',
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}
