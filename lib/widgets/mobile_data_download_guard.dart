import 'package:flutter/material.dart';

import '../services/download_network_policy.dart';

Future<bool> confirmManualDownload(
  BuildContext context,
  DownloadNetworkPolicy policy,
) async {
  final decision = await policy.manualDownloadDecision();
  if (!context.mounted) return false;

  switch (decision) {
    case ManualDownloadDecision.allow:
      return true;
    case ManualDownloadDecision.offline:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No network connection available')),
      );
      return false;
    case ManualDownloadDecision.confirmMobileData:
      return await showDialog<bool>(
            context: context,
            builder:
                (dialogContext) => AlertDialog(
                  title: const Text('Use mobile data?'),
                  content: const Text(
                    'Auto download with mobile data is turned off. '
                    'Do you want to start this download using mobile data?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: const Text('Download'),
                    ),
                  ],
                ),
          ) ??
          false;
  }
}
