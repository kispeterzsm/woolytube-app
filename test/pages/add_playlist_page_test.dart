import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/pages/add_playlist_page.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/ytdlp_service.dart';

void main() {
  const addButton = ValueKey('add-playlist-button');
  final urlField = find.byKey(const ValueKey('add-playlist-url-field'));
  final nameField = find.byKey(const ValueKey('add-playlist-name-field'));

  Future<void> pumpPage(WidgetTester tester, _YtDlp ytdlp) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [ytdlpServiceProvider.overrideWithValue(ytdlp)],
        child: const MaterialApp(home: AddPlaylistPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Add is only enabled for the URL that was fetched', (
    tester,
  ) async {
    final ytdlp = _YtDlp(
      info: {'title': 'Fetched list', 'thumbnail': null, 'count': 4},
    );
    await pumpPage(tester, ytdlp);

    expect(find.byKey(addButton), findsNothing);
    await tester.enterText(urlField, 'https://youtube.com/playlist?list=one');
    await tester.tap(find.byTooltip('Fetch playlist info'));
    await tester.pumpAndSettle();

    expect(ytdlp.requestedUrls, ['https://youtube.com/playlist?list=one']);
    expect(find.text('Fetched list'), findsOneWidget);
    expect(find.text('4 videos'), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byKey(addButton)).enabled,
      isTrue,
    );
    // Fixed dropdown replaces the 1-168 h slider.
    expect(find.byType(Slider), findsNothing);
    expect(find.text('1 day'), findsOneWidget);

    // A playlist never gets a blank name.
    await tester.enterText(nameField, '   ');
    await tester.pump();
    expect(find.text('Enter a name'), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byKey(addButton)).enabled,
      isFalse,
    );
    await tester.enterText(nameField, 'My list');
    await tester.pump();
    expect(
      tester.widget<ElevatedButton>(find.byKey(addButton)).enabled,
      isTrue,
    );

    // Editing the URL drops the stale preview so Add cannot pair the new
    // link with the old tracks.
    await tester.enterText(urlField, 'https://youtube.com/playlist?list=two');
    await tester.pumpAndSettle();
    expect(find.byKey(addButton), findsNothing);
    expect(find.text('My list'), findsNothing);
  });

  testWidgets('an untitled playlist is prefilled with a name', (tester) async {
    final ytdlp = _YtDlp(info: {'title': '  ', 'count': 1});
    await pumpPage(tester, ytdlp);
    await tester.enterText(urlField, 'https://youtube.com/watch?v=abc');
    await tester.tap(find.byTooltip('Fetch playlist info'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(nameField).controller!.text, 'Playlist');
    expect(
      tester.widget<ElevatedButton>(find.byKey(addButton)).enabled,
      isTrue,
    );
  });

  testWidgets('fetch failures are shown with a friendly message', (
    tester,
  ) async {
    final ytdlp = _YtDlp(
      error: StateError(
        'yt-dlp exited 1: ERROR: [youtube] abc: Private video. '
        'Sign in if you have been granted access',
      ),
    );
    await pumpPage(tester, ytdlp);
    await tester.enterText(
      find.byType(TextField),
      'https://youtube.com/playlist?list=private',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      find.text('Failed to fetch playlist info: Private video'),
      findsOneWidget,
    );
    expect(find.byKey(addButton), findsNothing);
  });
}

class _YtDlp implements YtDlpService {
  _YtDlp({this.info, this.error});

  final Map<String, dynamic>? info;
  final Object? error;
  final requestedUrls = <String>[];

  @override
  Future<Map<String, dynamic>> getPlaylistInfo(String url) async {
    requestedUrls.add(url);
    if (error != null) throw error!;
    return info!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
