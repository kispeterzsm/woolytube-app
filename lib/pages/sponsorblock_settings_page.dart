import 'package:flutter/material.dart';

import '../services/sponsorblock_categories.dart';

/// Asks whether unsaved edits on a settings page should be thrown away.
Future<bool> showDiscardChangesDialog(BuildContext context) async {
  final discard = await showDialog<bool>(
    context: context,
    builder:
        (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text(
            'Discard changes?',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'You have unsaved changes.',
            style: TextStyle(color: Color(0xFFCCCCCC)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
  );
  return discard == true;
}

class SponsorBlockSettingsPage extends StatefulWidget {
  final Map<String, SponsorBlockCategoryAction> categoryActions;

  const SponsorBlockSettingsPage({super.key, required this.categoryActions});

  @override
  State<SponsorBlockSettingsPage> createState() =>
      _SponsorBlockSettingsPageState();
}

class _SponsorBlockSettingsPageState extends State<SponsorBlockSettingsPage> {
  late Map<String, SponsorBlockCategoryAction> _categoryActions;

  @override
  void initState() {
    super.initState();
    _categoryActions = {...widget.categoryActions};
  }

  void _save() {
    Navigator.of(context).pop(_categoryActions);
  }

  bool get _isDirty {
    for (final definition in sponsorBlockCategoryDefinitions) {
      final original =
          widget.categoryActions[definition.id] ?? definition.defaultAction;
      final current =
          _categoryActions[definition.id] ?? definition.defaultAction;
      if (original != current) return true;
    }
    return false;
  }

  Future<void> _onPopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    final discard = await showDiscardChangesDialog(context);
    if (discard && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('SponsorBlock Settings'),
          actions: [
            TextButton(
              onPressed: _save,
              child: const Text(
                'Save',
                style: TextStyle(color: Color(0xFF2196F3), fontSize: 16),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Choose how each type of segment is handled during playback.',
              style: TextStyle(color: Color(0xFF888888), fontSize: 13),
            ),
            const SizedBox(height: 16),
            for (final definition in sponsorBlockCategoryDefinitions)
              _categoryActionRow(definition),
          ],
        ),
      ),
    );
  }

  Widget _categoryActionRow(SponsorBlockCategoryDefinition definition) {
    final action = _categoryActions[definition.id] ?? definition.defaultAction;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: Color(definition.colorValue),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              definition.label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<SponsorBlockCategoryAction>(
              value: action,
              dropdownColor: const Color(0xFF2A2A2A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              iconEnabledColor: const Color(0xFF888888),
              items:
                  SponsorBlockCategoryAction.values
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _categoryActions = {
                      ..._categoryActions,
                      definition.id: value,
                    };
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
