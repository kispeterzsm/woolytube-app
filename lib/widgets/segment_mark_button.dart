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
      // The active bookmark immediately confirms the start. In particular,
      // avoid a SnackBar here because it covers the video controls and makes
      // it impossible to finish very short segments promptly.
      if (context.mounted && result.error != null) {
        _showMessage(context, result.error!);
      }
      onAction?.call();
      return;
    }

    final category = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      isScrollControlled: true,
      builder:
          (context) => SafeArea(
            child: FractionallySizedBox(
              heightFactor: 0.9,
              child: SegmentCategoryPicker(
                onCategorySelected:
                    (category) => Navigator.pop(context, category),
                onDiscard: () {
                  svc.cancelLocalSegmentMark();
                  Navigator.pop(context);
                },
              ),
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

/// Scrollable category selector shared by the audio and video segment marker.
///
/// A fixed-height sheet keeps every SponsorBlock type reachable in landscape
/// video playback, where a full list of tiles does not fit onscreen.
class SegmentCategoryPicker extends StatelessWidget {
  final ValueChanged<String> onCategorySelected;
  final VoidCallback onDiscard;

  const SegmentCategoryPicker({
    super.key,
    required this.onCategorySelected,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
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
        const Divider(height: 1, color: Color(0xFF444444)),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: sponsorBlockCategories.length,
            itemBuilder: (context, index) {
              final category = sponsorBlockCategories[index];
              return ListTile(
                key: ValueKey('segment-category-$category'),
                title: Text(
                  sponsorBlockCategoryLabels[category] ?? category,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => onCategorySelected(category),
              );
            },
          ),
        ),
        const Divider(height: 1, color: Color(0xFF444444)),
        TextButton(
          key: const ValueKey('discard-segment'),
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          onPressed: onDiscard,
          child: const Text('Discard segment'),
        ),
      ],
    );
  }
}
