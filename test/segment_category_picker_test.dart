import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/sponsorblock_categories.dart';
import 'package:woolytube/widgets/segment_mark_button.dart';

void main() {
  testWidgets(
    'segment category picker keeps every type reachable and can discard',
    (tester) async {
      String? selectedCategory;
      var discardCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 220,
                child: SegmentCategoryPicker(
                  onCategorySelected: (category) => selectedCategory = category,
                  onDiscard: () => discardCount++,
                ),
              ),
            ),
          ),
        ),
      );

      final scrollable = find.descendant(
        of: find.byType(SegmentCategoryPicker),
        matching: find.byType(Scrollable),
      );
      for (final category in sponsorBlockCategories) {
        final categoryTile = find.byKey(ValueKey('segment-category-$category'));
        await tester.scrollUntilVisible(
          categoryTile,
          100,
          scrollable: scrollable,
        );
        expect(categoryTile, findsOneWidget);
      }

      final lastCategory = sponsorBlockCategories.last;
      await tester.tap(find.byKey(ValueKey('segment-category-$lastCategory')));
      expect(selectedCategory, lastCategory);

      final discardButton = find.byKey(const ValueKey('discard-segment'));
      final button = tester.widget<TextButton>(discardButton);
      expect(
        button.style?.foregroundColor?.resolve(<WidgetState>{}),
        Colors.redAccent,
      );

      await tester.tap(discardButton);
      expect(discardCount, 1);
    },
  );
}
