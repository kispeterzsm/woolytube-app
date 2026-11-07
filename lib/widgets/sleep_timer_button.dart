import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_widgets.dart';
import '../providers/playback_providers.dart';

class SleepTimerButton extends ConsumerWidget {
  static const durations = <Duration>[
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(hours: 1),
  ];

  final Color activeColor;
  final Color inactiveColor;
  final double iconSize;
  final VoidCallback? onAction;

  /// Shows 'Sleep', or the remaining time while a timer runs, under the icon.
  final bool showLabel;

  const SleepTimerButton({
    super.key,
    this.activeColor = const Color(0xFF2196F3),
    this.inactiveColor = const Color(0xFF888888),
    this.iconSize = 22,
    this.showLabel = false,
    this.onAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(sleepTimerRemainingProvider).valueOrNull;
    final endOfSong = ref.watch(stopAfterCurrentProvider).valueOrNull ?? false;
    final isChapter =
        ref.watch(currentItemIsChapterProvider).valueOrNull ?? false;
    final unit = isChapter ? 'chapter' : 'file';
    final active = remaining != null || endOfSong;
    final activeLabel =
        remaining != null
            ? formatSleepTimerRemaining(remaining)
            : isChapter
            ? 'Chapter end'
            : 'File end';

    return PlayerActionButton(
      key: const ValueKey('sleep-timer-button'),
      icon: active ? Icons.bedtime : Icons.bedtime_outlined,
      label: active ? activeLabel : 'Sleep',
      tooltip:
          remaining != null
              ? 'Sleep timer: ${formatSleepTimerRemaining(remaining)} remaining'
              : endOfSong
              ? 'Sleep timer: pauses when this $unit ends'
              : 'Sleep timer',
      toggled: active,
      showLabel: showLabel,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      iconSize: iconSize,
      onPressed: () => _showOptions(context, ref, remaining, endOfSong, unit),
    );
  }

  Future<void> _showOptions(
    BuildContext context,
    WidgetRef ref,
    Duration? remaining,
    bool endOfSong,
    String unit,
  ) async {
    final selection = await showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      isScrollControlled: true,
      builder:
          (context) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                    child: Column(
                      children: [
                        const Text(
                          'Sleep timer',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (remaining != null || endOfSong) ...[
                          const SizedBox(height: 4),
                          Text(
                            remaining != null
                                ? '${formatSleepTimerRemaining(remaining)} remaining'
                                : 'Pauses when this $unit ends',
                            style: const TextStyle(color: Color(0xFFBBBBBB)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF444444)),
                  for (final duration in durations)
                    ListTile(
                      key: ValueKey('sleep-timer-${duration.inMinutes}'),
                      leading: const Icon(
                        Icons.schedule,
                        color: Color(0xFFBBBBBB),
                      ),
                      title: Text(
                        _durationLabel(duration),
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () => Navigator.pop(context, duration),
                    ),
                  ListTile(
                    key: const ValueKey('sleep-timer-end-of-song'),
                    leading: const Icon(
                      Icons.music_off_outlined,
                      color: Color(0xFFBBBBBB),
                    ),
                    title: Text(
                      'End of this $unit',
                      style: TextStyle(color: Colors.white),
                    ),
                    onTap: () => Navigator.pop(context, Duration.zero),
                  ),
                  if (remaining != null || endOfSong) ...[
                    const Divider(height: 1, color: Color(0xFF444444)),
                    ListTile(
                      key: const ValueKey('cancel-sleep-timer'),
                      leading: const Icon(
                        Icons.timer_off_outlined,
                        color: Colors.redAccent,
                      ),
                      title: const Text(
                        'Cancel timer',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                      onTap: () {
                        final playback = ref.read(playbackServiceProvider);
                        playback.cancelSleepTimer();
                        playback.setStopAfterCurrent(false);
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
    );

    if (selection != null) {
      final playback = ref.read(playbackServiceProvider);
      if (selection == Duration.zero) {
        // 'End of this file' replaces a running countdown.
        playback.cancelSleepTimer();
        playback.setStopAfterCurrent(true);
      } else {
        playback.setStopAfterCurrent(false);
        playback.startSleepTimer(selection);
      }
    }
    onAction?.call();
  }

  static String _durationLabel(Duration duration) {
    if (duration.inHours == 1 && duration.inMinutes == 60) return '1 hour';
    return '${duration.inMinutes} minutes';
  }
}

String formatSleepTimerRemaining(Duration duration) {
  final totalSeconds = duration.inSeconds.clamp(0, 24 * 60 * 60);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final minuteSecond =
      '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$minuteSecond' : minuteSecond;
}
