import 'package:flutter/material.dart';

/// A text field that treats a single tap as cursor placement even when Flutter
/// incorrectly reports that Shift is still pressed on Android.
class TapToPlaceCursorTextField extends StatelessWidget {
  final TextEditingController controller;
  final bool? enabled;
  final TextStyle? style;
  final InputDecoration? decoration;

  const TapToPlaceCursorTextField({
    super.key,
    required this.controller,
    this.enabled,
    this.style,
    this.decoration,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      style: style,
      decoration: decoration,
      onTap: () {
        final selection = controller.selection;
        if (!selection.isValid || selection.isCollapsed) return;

        controller.selection = TextSelection.collapsed(
          offset: selection.extentOffset,
          affinity: selection.affinity,
        );
      },
    );
  }
}
