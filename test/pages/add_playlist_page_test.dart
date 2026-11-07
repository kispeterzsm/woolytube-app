import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/pages/add_playlist_page.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/add_playlist_defaults.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/download_network_policy.dart';
import 'package:woolytube/services/download_service.dart';
import 'package:woolytube/services/playlist_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';

import '../helpers/test_database.dart';

void main() {
  const addButton = ValueKey('add-playlist-button');
  const lookupButton = ValueKey('add-playlist-lookup');
  final urlField = find.byKey(const ValueKey('add-playlist-url-field'));
  final nameField = find.byKey(const ValueKey('add-playlist-name-field'));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpPage(
    WidgetTester tester,
    YtDlpService ytdlp, {
    List<Playlist> playlists = const [],
    List<Override> overrides = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ytdlpServiceProvider.overrideWithValue(ytdlp),
          playlistsProvider.overrideWith((ref) => Stream.value(playlists)),
          ...overrides,
        ],
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed:
                          () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const AddPlaylistPage(),
                            ),
                          ),
                      child: const Text('open'),
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, ValueKey<String> key) =>
      tester.widget<ButtonStyleButton>(find.byKey(key)).enabled;

  testWidgets('Add is only enabled for the URL that was looked up', (
    tester,
  ) async {
    final ytdlp = _YtDlp(
      info: {'title': 'Fetched list', 'thumbnail': null, 'count': 4},
    );
    await pumpPage(tester, ytdlp);

    expect(find.byKey(addButton), findsNothing);
    expect(enabled(tester, lookupButton), isFalse);
    await tester.enterText(urlField, 'https://youtube.com/playlist?list=one');
    await tester.pump();
    await tester.tap(find.byKey(lookupButton));
    await tester.pumpAndSettle();

    expect(ytdlp.requestedUrls, ['https://youtube.com/playlist?list=one']);
    expect(find.text('Fetched list'), findsOneWidget);
    expect(find.text('4 videos'), findsOneWidget);
    expect(enabled(tester, addButton), isTrue);
    expect(find.text('Add & download'), findsOneWidget);
    // The interval sits right under its switch and hides with it.
    expect(find.text('1 day'), findsOneWidget);
    await tester.tap(find.text('Keep up to date'));
    await tester.pumpAndSettle();
    expect(find.text('1 day'), findsNothing);

    // A playlist never gets a blank name.
    await tester.enterText(nameField, '   ');
    await tester.pump();
    expect(find.text('Enter a name'), findsOneWidget);
    expect(enabled(tester, addButton), isFalse);
    await tester.enterText(nameField, 'My list');
    await tester.pump();
    expect(enabled(tester, addButton), isTrue);

    // Editing the URL drops the stale preview so Add cannot pair the new
    // link with the old tracks.
    await tester.enterText(urlField, 'https://youtube.com/playlist?list=two');
    await tester.pumpAndSettle();
    expect(find.byKey(addButton), findsNothing);
    expect(find.text('My list'), findsNothing);
  });

  testWidgets('an untitled single video is prefilled with a name', (
    tester,
  ) async {
    final ytdlp = _YtDlp(
      info: {'title': '  ', 'count': 1, 'isPlaylist': false},
    );
    await pumpPage(tester, ytdlp);
    await tester.enterText(urlField, 'https://youtube.com/watch?v=abc');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(nameField).controller!.text, 'Playlist');
    expect(
      find.text('A single video, added as a playlist with one track'),
      findsOneWidget,
    );
    expect(enabled(tester, addButton), isTrue);
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
    await tester.enterText(urlField, 'https://youtube.com/playlist?list=p');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();

    expect(find.text("Couldn't read this link: Private video"), findsOneWidget);
    expect(find.byKey(addButton), findsNothing);
  });

  testWidgets('Paste looks up a YouTube link; Cancel drops the answer', (
    tester,
  ) async {
    final ytdlp = _YtDlp(
      info: {'title': 'Slow list', 'count': 600},
      gate: Completer<void>(),
    );
    String? clipboard = 'https://www.youtube.com/playlist?list=slow';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': clipboard} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpPage(tester, ytdlp);

    await tester.tap(find.byKey(const ValueKey('add-playlist-paste')));
    await tester.pump();
    await tester.pump();
    expect(ytdlp.requestedUrls, ['https://www.youtube.com/playlist?list=slow']);
    expect(find.text('Reading the playlist…'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-playlist-cancel-lookup')));
    await tester.pump();
    expect(find.text('Reading the playlist…'), findsNothing);
    ytdlp.gate!.complete();
    await tester.pumpAndSettle();
    // The cancelled lookup's answer is ignored.
    expect(find.text('Slow list'), findsNothing);
    expect(find.byKey(addButton), findsNothing);

    // A non-YouTube text is pasted but not looked up.
    clipboard = 'hello';
    await tester.tap(find.byKey(const ValueKey('add-playlist-paste')));
    await tester.pumpAndSettle();
    expect(ytdlp.requestedUrls, hasLength(1));
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('a playlist already in the library cannot be added again', (
    tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final existing = await insertTestPlaylist(
      db,
      name: 'Mine',
      url: 'https://www.youtube.com/playlist?list=dup',
      audioOnly: true,
    );
    final ytdlp = _YtDlp(info: {'title': 'Dup', 'count': 3});
    await pumpPage(tester, ytdlp, playlists: [existing]);
    await tester.enterText(
      urlField,
      'https://youtube.com/playlist?list=dup&si=x',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();

    // As video it is new; as audio it is already there.
    expect(find.byKey(const ValueKey('add-playlist-exists')), findsNothing);
    expect(enabled(tester, addButton), isTrue);
    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-playlist-exists')), findsOneWidget);
    expect(enabled(tester, addButton), isFalse);
  });

  testWidgets('on mobile data, Later keeps the playlist and remembers '
      'the options', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final playlists = _Playlists(db);
    final downloads = _Downloads();
    final settings = AppSettingsService();
    final ytdlp = _YtDlp(info: {'title': 'Commute', 'count': 2});
    await pumpPage(
      tester,
      ytdlp,
      overrides: [
        databaseProvider.overrideWithValue(db),
        playlistServiceProvider.overrideWithValue(playlists),
        downloadServiceProvider.overrideWithValue(downloads),
        appSettingsServiceProvider.overrideWithValue(settings),
        downloadNetworkPolicyProvider.overrideWithValue(
          DownloadNetworkPolicy(
            settings,
            checkConnectivity: () async => [ConnectivityResult.mobile],
          ),
        ),
      ],
    );
    await tester.enterText(urlField, 'https://youtube.com/playlist?list=c');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Audio'));
    await tester.pump();

    // A double tap adds it once.
    await tester.tap(find.byKey(addButton));
    await tester.tap(find.byKey(addButton), warnIfMissed: false);
    // "Adding…" spins while the question is open: no pumpAndSettle.
    await _settle(tester);
    expect(playlists.added, 1);
    expect(find.text('Use mobile data?'), findsOneWidget);

    await tester.tap(find.text('Later on Wi-Fi'));
    await tester.pumpAndSettle();
    expect(downloads.started, isEmpty);
    final saved = await db.getAllPlaylists();
    expect(saved.single.name, 'Commute');
    expect(saved.single.audioOnly, isTrue);
    expect(find.byType(AddPlaylistPage), findsNothing);
    expect(
      find.textContaining('next automatic update on Wi-Fi'),
      findsOneWidget,
    );

    final defaults = await AddPlaylistDefaults().load();
    expect(defaults.audioOnly, isTrue);
  });

  testWidgets('"Always allow mobile data" downloads and keeps allowing', (
    tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final downloads = _Downloads();
    final settings = AppSettingsService();
    await pumpPage(
      tester,
      _YtDlp(info: {'title': 'Gym', 'count': 2}),
      overrides: [
        databaseProvider.overrideWithValue(db),
        playlistServiceProvider.overrideWithValue(_Playlists(db)),
        downloadServiceProvider.overrideWithValue(downloads),
        appSettingsServiceProvider.overrideWithValue(settings),
        downloadNetworkPolicyProvider.overrideWithValue(
          DownloadNetworkPolicy(
            settings,
            checkConnectivity: () async => [ConnectivityResult.mobile],
          ),
        ),
      ],
    );
    await tester.enterText(urlField, 'https://youtube.com/playlist?list=g');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(addButton));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-data-always-allow')));
    await tester.pump();
    await tester.tap(find.text('Download now'));
    await tester.pumpAndSettle();

    expect(downloads.started, ['Gym']);
    expect(await settings.getAutoDownloadWithMobileData(), isTrue);
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _YtDlp implements YtDlpService {
  _YtDlp({this.info, this.error, this.gate});

  final Map<String, dynamic>? info;
  final Object? error;
  final Completer<void>? gate;
  final requestedUrls = <String>[];

  @override
  Future<Map<String, dynamic>> getPlaylistInfo(String url) async {
    requestedUrls.add(url);
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return info!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playlists implements PlaylistService {
  _Playlists(this.db);

  final AppDatabase db;
  var added = 0;

  @override
  Future<int> addPlaylist({
    required String url,
    required String name,
    String? thumbnailUrl,
    bool audioOnly = false,
    bool autoUpdate = true,
    bool playChapters = true,
    int updateFrequencyHours = 24,
    bool includeThumbnails = true,
    bool sponsorBlockEnabled = true,
    List<String>? sponsorBlockCategories,
    Object? sponsorBlockCategoryActions,
  }) async {
    added++;
    final playlist = await insertTestPlaylist(
      db,
      url: url,
      name: name,
      audioOnly: audioOnly,
    );
    return playlist.id;
  }

  @override
  Future<int> getTotalCount(int playlistId) async => 0;

  @override
  Future<void> populateTracksFromInfo(
    int playlistId,
    Map<String, dynamic> info,
  ) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads implements DownloadService {
  final started = <String>[];

  @override
  bool get isDownloading => false;

  @override
  Future<DownloadStart> downloadPlaylist(
    Playlist playlist, {
    bool sourceChecked = true,
    bool Function()? shouldStop,
  }) async {
    started.add(playlist.name);
    return DownloadStart.started;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
