import 'package:flutter/material.dart';

/// The small coloured title above a group of rows on a settings page.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(
    this.label, {
    super.key,
    this.color = const Color(0xFF2196F3),
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
