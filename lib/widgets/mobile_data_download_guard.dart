import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_settings_service.dart';
import '../services/download_network_policy.dart';

/// What the owner chose for a download started by hand.
enum DownloadNowChoice {
  /// Download now (Wi-Fi, or mobile data the owner agreed to).
  now,

  /// The owner chose to wait (for example for Wi-Fi).
  later,

  /// There is no network connection.
  offline,
}

/// [decideDownloadNow] when there is nobody to ask (the page that started
/// the download is gone): mobile data that needs the owner's consent counts
/// as [DownloadNowChoice.later].
Future<DownloadNowChoice> decideDownloadNowWithoutAsking(
  DownloadNetworkPolicy policy,
) async {
  switch (await policy.manualDownloadDecision()) {
    case ManualDownloadDecision.allow:
      return DownloadNowChoice.now;
    case ManualDownloadDecision.offline:
      return DownloadNowChoice.offline;
    case ManualDownloadDecision.confirmMobileData:
      return DownloadNowChoice.later;
  }
}

/// Decides whether a download the owner asked for may start now. On mobile
/// data (when automatic mobile downloads are off) it asks; [laterLabel] is
/// the button that declines. With [settings], the question also offers
/// "Always allow mobile data", which turns on mobile downloads for good
/// (also for automatic updates).
///
/// Offline is returned without a message; see [confirmManualDownload] for
/// the variant that explains it.
Future<DownloadNowChoice> decideDownloadNow(
  BuildContext context,
  DownloadNetworkPolicy policy, {
  AppSettingsService? settings,
  String message =
      "You're on mobile data. Download now, or wait until you're on Wi-Fi?",
  String laterLabel = 'Not now',
}) async {
  final decision = await policy.manualDownloadDecision();
  switch (decision) {
    case ManualDownloadDecision.allow:
      return DownloadNowChoice.now;
    case ManualDownloadDecision.offline:
      return DownloadNowChoice.offline;
    case ManualDownloadDecision.confirmMobileData:
      break;
  }
  if (!context.mounted) return DownloadNowChoice.later;

  var alwaysAllow = false;
  final download = await showDialog<bool>(
    context: context,
    builder:
        (dialogContext) => StatefulBuilder(
          builder:
              (dialogContext, setDialogState) => AlertDialog(
                title: const Text('Use mobile data?'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message),
                    if (settings != null) ...[
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        key: const ValueKey('mobile-data-always-allow'),
                        value: alwaysAllow,
                        onChanged:
                            (value) => setDialogState(
                              () => alwaysAllow = value ?? false,
                            ),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text(
                          'Always allow mobile data',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          'Also for automatic updates',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: Text(laterLabel),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('Download now'),
                  ),
                ],
              ),
        ),
  );
  if (download != true) return DownloadNowChoice.later;
  if (alwaysAllow && settings != null) {
    // Also reschedules the background updates; this download need not wait
    // for that, and goes ahead even if saving fails.
    unawaited(
      settings.setAutoDownloadWithMobileData(true).catchError((Object _) {}),
    );
  }
  return DownloadNowChoice.now;
}

/// Whether a download the owner started by hand may run now: true on Wi-Fi,
/// after the owner agreed to use mobile data, or when mobile downloads are
/// allowed. Offline it says so and returns false.
Future<bool> confirmManualDownload(
  BuildContext context,
  DownloadNetworkPolicy policy, {
  AppSettingsService? settings,
}) async {
  final choice = await decideDownloadNow(context, policy, settings: settings);
  if (choice == DownloadNowChoice.offline && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No network connection available')),
    );
  }
  return choice == DownloadNowChoice.now;
}
