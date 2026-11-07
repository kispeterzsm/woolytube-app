import 'package:flutter/material.dart';

/// Auto-update intervals offered to the user, in hours.
const Map<int, String> updateFrequencyOptions = <int, String>{
  1: '1 hour',
  12: '12 hours',
  24: '1 day',
  72: '3 days',
  168: '1 week',
};

/// Snaps an arbitrary hour count to the closest offered option.
int nearestUpdateFrequency(int hours) {
  return updateFrequencyOptions.keys.reduce(
    (nearest, option) =>
        (option - hours).abs() < (nearest - hours).abs() ? option : nearest,
  );
}

/// 'Every day', 'Every 6 hours': how often a playlist is checked.
String updateFrequencyLabel(int hours) {
  if (hours == 24) return 'Every day';
  if (hours == 168) return 'Every week';
  if (hours == 1) return 'Every hour';
  if (hours > 0 && hours % 168 == 0) return 'Every ${hours ~/ 168} weeks';
  if (hours > 24 && hours % 24 == 0) return 'Every ${hours ~/ 24} days';
  return 'Every $hours hours';
}

/// The offered options plus [current] when it is none of them (a value from
/// an imported or older playlist), so it can be shown as it is instead of
/// being silently replaced by the nearest option.
Map<int, String> updateFrequencyChoices(int current) {
  if (updateFrequencyOptions.containsKey(current) || current <= 0) {
    return updateFrequencyOptions;
  }
  final choices = {
    ...updateFrequencyOptions,
    current: updateFrequencyLabel(current).replaceFirst('Every ', ''),
  };
  final sorted = choices.keys.toList()..sort();
  return {for (final hours in sorted) hours: choices[hours]!};
}

/// Asks how often a playlist should be checked; null when cancelled.
Future<int?> showUpdateFrequencyPicker(BuildContext context, int current) {
  final choices = updateFrequencyChoices(current);
  return showDialog<int>(
    context: context,
    builder:
        (ctx) => SimpleDialog(
          title: const Text('Check for new videos'),
          children: [
            for (final hours in choices.keys)
              RadioListTile<int>(
                value: hours,
                groupValue: current,
                title: Text(updateFrequencyLabel(hours)),
                onChanged: (hours) => Navigator.pop(ctx, hours),
              ),
          ],
        ),
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
    final choices = updateFrequencyChoices(value);
    return DropdownButtonFormField<int>(
      // The value is shown as it is stored; an unusual one is listed as an
      // extra choice instead of being snapped to a different interval.
      value: choices.containsKey(value) ? value : nearestUpdateFrequency(value),
      isExpanded: true,
      dropdownColor: const Color(0xFF2A2A2A),
      decoration: const InputDecoration(
        labelText: 'Auto-update frequency',
        labelStyle: TextStyle(color: Color(0xFF888888)),
        border: OutlineInputBorder(),
      ),
      items:
          choices.entries
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
    );
  }
}
