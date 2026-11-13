import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/label_service.dart';
import '../widgets/label_widgets.dart';

const _muted = Color(0xFF888888);

/// The owner's labels: make, rename, recolor, reorder and delete them. The
/// order here is the order of the label chips everywhere.
class LabelsPage extends ConsumerStatefulWidget {
  const LabelsPage({super.key});

  @override
  ConsumerState<LabelsPage> createState() => _LabelsPageState();
}

class _LabelsPageState extends ConsumerState<LabelsPage> {
  /// How many files and chapters carry each label; null until counted.
  Map<String, LabelUsage>? _usage;
  int _usageGeneration = 0;

  /// The order just dragged into place, shown until the saved order
  /// arrives.
  List<Label>? _dragged;

  LabelService get _service => ref.read(labelServiceProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_countUsage());
  }

  Future<void> _countUsage() async {
    final generation = ++_usageGeneration;
    try {
      final usage = await _service.usage();
      if (mounted && generation == _usageGeneration) {
        setState(() => _usage = usage);
      }
    } catch (_) {
      // The rows just show no counts.
    }
  }

  void _showMessage(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _create() async {
    await showLabelEditor(context, ref);
  }

  Future<void> _edit(Label label) async {
    await showLabelEditor(context, ref, label: label);
  }

  Future<void> _delete(Label label) async {
    var counted = _usage?[label.uid];
    if (counted == null) {
      try {
        counted = (await _service.usage())[label.uid];
      } catch (_) {}
    }
    final usage = counted ?? const LabelUsage();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text('Delete "${label.name}"?'),
            content: Text(
              usage.isEmpty
                  ? 'No file or chapter has it.'
                  : 'It is on ${labelUsageText(usage)}. They lose it; Undo '
                      'right after brings it back.',
              key: const ValueKey('label-delete-usage'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('label-delete-confirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE57373),
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    // The SnackBar outlives this page (it is on the app's messenger), so
    // its Undo must not need this page's ref or context.
    final service = _service;
    final messenger = ScaffoldMessenger.of(context);
    void show(String message, {SnackBarAction? action}) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message), action: action));
    }

    try {
      await service.delete(label.uid);
    } catch (e) {
      show('Could not delete: $e');
      return;
    }
    show(
      'Deleted "${label.name}"',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          try {
            await service.restore(label.uid);
          } on LabelException catch (e) {
            show(e.message);
          } catch (e) {
            show('Could not bring it back: $e');
          }
        },
      ),
    );
  }

  void _reorder(List<Label> labels, int from, int to) {
    final order = [...labels];
    if (to > from) to--;
    order.insert(to, order.removeAt(from));
    setState(() => _dragged = order);
    unawaited(
      _service.reorder([for (final label in order) label.uid]).catchError((
        Object e,
      ) {
        if (mounted) setState(() => _dragged = null);
        _showMessage('Could not save the order: $e');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(labelsProvider, (_, __) {
      _dragged = null;
      unawaited(_countUsage());
    });
    final labelsAsync = ref.watch(labelsProvider);
    final labels = _dragged ?? labelsAsync.valueOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Labels'),
        actions: [
          IconButton(
            key: const ValueKey('labels-new'),
            icon: const Icon(Icons.add),
            tooltip: 'New label',
            onPressed: _create,
          ),
        ],
      ),
      body:
          labels == null
              ? labelsAsync.hasError
                  ? Center(child: Text('Error: ${labelsAsync.error}'))
                  : const Center(child: CircularProgressIndicator())
              : ValueListenableBuilder<double>(
                valueListenable: audioPlayerOverlayHeightNotifier,
                builder:
                    (context, overlay, _) =>
                        labels.isEmpty
                            ? _empty()
                            : _list(labels, bottom: 16 + overlay),
              ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.label_outline, size: 48, color: _muted),
            const SizedBox(height: 12),
            const Text(
              'Labels mark files and chapters, as many as you like: genres, '
              'bands, moods. Search for a label to play everything that has '
              'it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('labels-new-empty'),
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('New label'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(List<Label> labels, {required double bottom}) {
    final usage = _usage;
    return ReorderableListView.builder(
      key: const ValueKey('labels-list'),
      buildDefaultDragHandles: false,
      padding: EdgeInsets.only(bottom: bottom),
      itemCount: labels.length,
      onReorder: (from, to) => _reorder(labels, from, to),
      itemBuilder: (context, index) {
        final label = labels[index];
        final count = usage?[label.uid];
        return ListTile(
          key: ValueKey('label-row-${label.uid}'),
          leading: LabelSwatch(color: label.color, size: 24),
          title: Text(label.name),
          subtitle: Text(
            count == null ? ' ' : labelUsageText(count),
            key: ValueKey('label-usage-${label.uid}'),
            style: const TextStyle(color: _muted),
          ),
          onTap: () => _edit(label),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: ValueKey('label-delete-${label.uid}'),
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: () => _delete(label),
              ),
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle, color: _muted),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
