import 'package:flutter/material.dart';

/// Auto-update intervals offered to the user, in hours.
const Map<int, String> updateFrequencyOptions = <int, String>{
  1: '1 hour',
  12: '12 hours',
  24: '1 day',
  72: '3 days',
  168: '1 week',
};

/// Snaps an arbitrary hour count (from the database or an imported playlist)
/// to the closest offered option.
int nearestUpdateFrequency(int hours) {
  return updateFrequencyOptions.keys.reduce(
    (nearest, option) =>
        (option - hours).abs() < (nearest - hours).abs() ? option : nearest,
  );
}

class UpdateFrequencyDropdown extends StatelessWidget {
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const UpdateFrequencyDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DropdownButtonFormField<int>(
        value: nearestUpdateFrequency(value),
        isExpanded: true,
        dropdownColor: const Color(0xFF2A2A2A),
        decoration: const InputDecoration(
          labelText: 'Auto-update frequency',
          labelStyle: TextStyle(color: Color(0xFF888888)),
          border: OutlineInputBorder(),
        ),
        items:
            updateFrequencyOptions.entries
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
                )
                .toList(),
        onChanged:
            enabled
                ? (selected) {
                  if (selected != null) onChanged(selected);
                }
                : null,
      ),
    );
  }
}
