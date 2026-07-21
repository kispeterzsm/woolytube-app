import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/widgets/tap_to_place_cursor_text_field.dart';

void main() {
  testWidgets('a single Android tap places the cursor when Shift is stuck', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = TextEditingController.fromValue(
      const TextEditingValue(
        text: 'Example override title',
        selection: TextSelection.collapsed(offset: 22),
      ),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: TapToPlaceCursorTextField(controller: controller),
              ),
            ),
          ),
        ),
      );

      final field = find.byType(TextField);
      await tester.tap(field);
      await tester.pump(const Duration(seconds: 1));
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final rect = tester.getRect(field);
      await tester.tapAt(Offset(rect.left + 24, rect.center.dy));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(controller.selection.isCollapsed, isTrue);
      expect(
        controller.selection.extentOffset,
        lessThan(controller.text.length),
      );
    } finally {
      controller.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
