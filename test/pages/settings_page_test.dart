import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/pages/settings_page.dart';
import 'package:woolytube/services/app_settings_service.dart';

void main() {
  testWidgets('enables subtitle downloads and saves validated languages', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsPage())),
    );
    await tester.pumpAndSettle();
    final languages = find.widgetWithText(ListTile, 'Subtitle languages');
    expect(tester.widget<ListTile>(languages).enabled, isFalse);
    await tester.tap(find.text('Download subtitles'));
    await tester.pumpAndSettle();
    expect(await AppSettingsService().getDownloadSubtitles(), isTrue);
    await tester.tap(languages);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'en, hu');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(await AppSettingsService().getSubtitleLanguages(), 'en,hu');
    expect(find.text('en,hu'), findsOneWidget);
  });
}
