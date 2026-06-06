import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/playback_providers.dart';
import '../services/sponsorblock_service.dart';

class SegmentMarkButton extends ConsumerWidget {
  final Color activeColor;
  final Color inactiveColor;
  final double iconSize;
  final VoidCallback? onAction;

  const SegmentMarkButton({
    super.key,
    this.activeColor = const Color(0xFF2196F3),
    this.inactiveColor = const Color(0xFF888888),
    this.iconSize = 22,
    this.onAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending =
        ref.watch(pendingSegmentMarkStartProvider).valueOrNull != null;
    return IconButton(
      icon: Icon(
        pending ? Icons.bookmark : Icons.bookmark_add_outlined,
        color: pending ? activeColor : inactiveColor,
        size: iconSize,
      ),
      tooltip: pending ? 'Finish segment' : 'Mark segment start',
      onPressed: () => _handlePressed(context, ref, pending),
    );
  }

  Future<void> _handlePressed(
    BuildContext context,
    WidgetRef ref,
    bool pending,
  ) async {
    final svc = ref.read(playbackServiceProvider);
    if (!pending) {
      final result = await svc.markLocalSegmentBoundary('sponsor');
      if (context.mounted) {
        _showMessage(context, result.error ?? 'Segment start marked');
      }
      onAction?.call();
      return;
    }

    final category = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Segment category',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final category in sponsorBlockCategories)
                  ListTile(
                    title: Text(
                      sponsorBlockCategoryLabels[category] ?? category,
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () => Navigator.pop(context, category),
                  ),
                TextButton(
                  onPressed: () {
                    svc.cancelLocalSegmentMark();
                    Navigator.pop(context);
                  },
                  child: const Text('Cancel segment'),
                ),
              ],
            ),
          ),
    );
    if (category == null) return;

    final result = await svc.markLocalSegmentBoundary(category);
    if (context.mounted) {
      _showMessage(
        context,
        result.error ??
            'Segment saved as ${sponsorBlockCategoryLabels[category] ?? category}',
      );
    }
    onAction?.call();
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
