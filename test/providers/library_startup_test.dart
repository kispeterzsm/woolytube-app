import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/download_network_policy.dart';
import 'package:woolytube/services/library_gate.dart';
import 'package:woolytube/services/metadata_service.dart';
import 'package:woolytube/services/playlist_service.dart';

import '../helpers/fakes.dart';
import '../helpers/test_database.dart';

class _StartupYtDlp extends FakeYtDlpService {
  var initializeCalls = 0;
  Object? initializeError;
  Completer<void>? initializeGate;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    await initializeGate?.future;
    final error = initializeError;
    if (error != null) throw error;
  }
}

class _CountingMetadata extends MetadataService {
  _CountingMetadata(super.db);

  var repairs = 0;

  @override
  Future<int> recoverInterruptedDownloads({
    void Function(Playlist playlist, Object error)? onProblem,
  }) async {
    repairs++;
    return 0;
  }

  @override
  Future<List<DiscoveredPlaylist>> findUnimportedPlaylists({
    Set<String> excludeUrls = const {},
    List<DiscoveredPlaylist>? candidates,
    bool skipOtherModeCopies = false,
  }) async => const [];
}

class _StreamPlaylistService extends PlaylistService {
  _StreamPlaylistService(AppDatabase db)
    : super(
        db,
        FakeYtDlpService(),
        MetadataService(db),
        null,
        null,
        LibraryGate.unlocked(),
      );

  var listens = 0;
  var cancels = 0;

  @override
  Stream<List<Track>> watchTracksForPlaylist(int playlistId) {
    late final StreamController<List<Track>> controller;
    controller = StreamController<List<Track>>(
      onListen: () {
        listens++;
        controller.add(const []);
      },
      onCancel: () => cancels++,
    );
    return controller.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _StartupYtDlp ytdlp;
  late _CountingMetadata metadata;
  late ProviderContainer container;
  var storageGranted = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openTestDatabase();
    ytdlp = _StartupYtDlp();
    metadata = _CountingMetadata(db);
    storageGranted = false;
    final settings = AppSettingsService();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ytdlpServiceProvider.overrideWithValue(ytdlp),
        metadataServiceProvider.overrideWithValue(metadata),
        libraryGateProvider.overrideWithValue(LibraryGate.unlocked()),
        appSettingsServiceProvider.overrideWithValue(settings),
        downloadNetworkPolicyProvider.overrideWithValue(
          DownloadNetworkPolicy(
            settings,
            checkConnectivity: () async => [ConnectivityResult.none],
          ),
        ),
        libraryStartupProvider.overrideWith((ref) {
          final startup = LibraryStartup(
            ref,
            storageAccess: ({required bool ask}) async => storageGranted,
          );
          ref.onDispose(startup.dispose);
          return startup;
        }),
      ],
    );
  });

  tearDown(() async {
    await pumpEventQueue();
    container.dispose();
    await db.close();
  });

  test('the library work waits for storage access', () async {
    final startup = container.read(libraryStartupProvider);

    expect(await startup.checkStorageAccess(ask: true), isFalse);
    expect(container.read(storageAccessProvider), isFalse);
    await startup.startLibrary();
    expect(metadata.repairs, 0);

    // Granted in the system settings while the app was in the background.
    storageGranted = true;
    await startup.onAppResumed();
    expect(container.read(storageAccessProvider), isTrue);
    await startup.startLibrary();
    expect(metadata.repairs, 1);

    // Once per session.
    await startup.startLibrary();
    await startup.onAppResumed();
    await startup.requestStorageAccess();
    await pumpEventQueue();
    expect(metadata.repairs, 1);
    startup.onAppPaused();
  });

  test('retrying yt-dlp starts only yt-dlp', () async {
    final startup = container.read(libraryStartupProvider);
    ytdlp.initializeError = Exception('no space left');
    await startup.initializeYtDlp();
    expect(container.read(ytDlpInitErrorProvider), contains('no space left'));

    ytdlp.initializeError = null;
    ytdlp.initializeGate = Completer<void>();
    final retry = startup.retryYtDlp();
    expect(container.read(ytDlpRetryingProvider), isTrue);
    // A second tap while it runs does not start another attempt.
    await startup.retryYtDlp();
    ytdlp.initializeGate!.complete();
    await retry;

    expect(container.read(ytDlpRetryingProvider), isFalse);
    expect(container.read(ytDlpInitErrorProvider), isNull);
    expect(ytdlp.initializeCalls, 2);
    expect(metadata.repairs, 0);
    expect(container.read(storageAccessProvider), isNull);
  });

  test('a playlist\'s tracks stay cached for a while after its page '
      'closed', () {
    final service = _StreamPlaylistService(db);
    fakeAsync((async) {
      final tracks = ProviderContainer(
        overrides: [playlistServiceProvider.overrideWithValue(service)],
      );
      final first = tracks.listen(tracksProvider(1), (_, _) {});
      async.flushMicrotasks();
      expect(service.listens, 1);

      first.close();
      async.elapse(tracksCacheDuration ~/ 2);
      expect(service.cancels, 0);

      // Opened again within the cache time: the same query keeps running.
      final second = tracks.listen(tracksProvider(1), (_, _) {});
      async.elapse(tracksCacheDuration * 2);
      expect(service.listens, 1);
      expect(service.cancels, 0);

      second.close();
      async.elapse(tracksCacheDuration + const Duration(seconds: 1));
      expect(service.cancels, 1);
      tracks.dispose();
    });
  });
}
