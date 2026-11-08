import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_widgets.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';

/// Switches plane mode on and off from the player.
class PlaneModeButton extends ConsumerWidget {
  final Color activeColor;
  final Color inactiveColor;
  final double iconSize;
  final bool showLabel;
  final VoidCallback? onAction;

  /// Whether a short message confirms each switch. Off over a full-screen
  /// video, where it would cover the controls; the icon shows the state.
  final bool announce;

  const PlaneModeButton({
    super.key,
    this.activeColor = const Color(0xFF2196F3),
    this.inactiveColor = const Color(0xFF888888),
    this.iconSize = 24,
    this.showLabel = false,
    this.announce = true,
    this.onAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(planeModeProvider).valueOrNull ?? false;
    return PlayerActionButton(
      key: const ValueKey('plane-mode-button'),
      icon: on ? Icons.flight_rounded : Icons.airplanemode_inactive_rounded,
      label: 'Plane',
      tooltip:
          on
              ? 'Plane mode: on (quiet parts lifted over engine noise)'
              : 'Plane mode: off',
      toggled: on,
      showLabel: showLabel,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      iconSize: iconSize,
      onPressed: () {
        onAction?.call();
        togglePlaneModeWithFeedback(context, ref, announce: announce);
      },
    );
  }
}

/// Toggles plane mode and, when [announce], says what changed. The first
/// time it is switched on, explains how to get the most out of it.
Future<void> togglePlaneModeWithFeedback(
  BuildContext context,
  WidgetRef ref, {
  bool announce = true,
}) async {
  final service = ref.read(playbackServiceProvider);
  final enable = !service.planeMode;
  final messenger = ScaffoldMessenger.maybeOf(context);
  await service.setPlaneModePreference(enable);
  if (!enable) {
    if (!announce) return;
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(const SnackBar(content: Text('Plane mode off')));
    return;
  }
  var showTips = false;
  try {
    final settings = ref.read(appSettingsServiceProvider);
    showTips = !await settings.getPlaneModeTipShown();
    if (showTips) await settings.setPlaneModeTipShown();
  } catch (_) {
    // Without stored settings the short message is enough.
  }
  if (showTips && context.mounted) {
    await showPlaneModeTips(context);
    return;
  }
  if (!announce) return;
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(
    const SnackBar(
      content: Text(
        'Plane mode on. Set the volume so the quiet parts are just clear.',
      ),
    ),
  );
}

/// What plane mode does and how to listen quieter on a flight.
Future<void> showPlaneModeTips(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder:
        (context) => AlertDialog(
          key: const ValueKey('plane-mode-tips'),
          icon: const Icon(Icons.flight_rounded),
          title: const Text('Plane mode is on'),
          content: const SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Songs now play at an even level and their quiet parts are '
                  'lifted, so they stay clear over engine noise. Set the '
                  'volume so the quiet parts are just clear, and no louder: '
                  'that is easier on your ears on a long flight.',
                ),
                SizedBox(height: 12),
                Text(
                  'The biggest help is a tight fit. Push the earbuds in '
                  'firmly, or try a bigger tip size or foam tips. A good seal '
                  'blocks more engine noise than any setting.',
                ),
                SizedBox(height: 12),
                Text(
                  'Each song is measured once, the playing and next ones '
                  'first; the rest of the library while the phone charges. '
                  'A song not measured yet plays at a typical level, and '
                  'evened out from its next play.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
  );
}
