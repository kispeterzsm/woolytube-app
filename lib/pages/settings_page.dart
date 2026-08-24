import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/update_service.dart';

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
  bool _isLoadingSettings = true;
  bool _isSavingSettings = false;
  bool _isCheckingForUpdate = false;
  bool _isDownloadingUpdate = false;

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
      ]);
      if (mounted) {
        setState(() {
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

    var progressDialogVisible = true;
    void closeProgressDialog({bool showBackgroundMessage = false}) {
      if (!mounted || !progressDialogVisible) return;
      progressDialogVisible = false;
      Navigator.of(context, rootNavigator: true).pop();
      if (showBackgroundMessage) {
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
        builder:
            (dialogContext) => AlertDialog(
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
      ),
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
    } finally {
      if (mounted) setState(() => _isDownloadingUpdate = false);
    }
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
