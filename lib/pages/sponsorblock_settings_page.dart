import 'package:flutter/material.dart';

import '../services/sponsorblock_categories.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
