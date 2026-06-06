import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:audio_service/audio_service.dart';
import 'database/database.dart';
import 'providers/providers.dart';
import 'providers/playback_providers.dart';
import 'providers/lifecycle_provider.dart';
import 'services/playback_service.dart';
import 'services/audio_handler.dart';
import 'pages/home_page.dart';
import 'pages/player_page.dart';
import 'widgets/mini_player.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Schedule background auto-update via native WorkManager
  const backgroundChannel = MethodChannel('com.woolytube/background');
  try {
    await backgroundChannel.invokeMethod('scheduleAutoUpdate');
  } catch (_) {
    // Non-critical — don't block app startup
  }

  final database = AppDatabase();
  final playbackService = PlaybackService(database);
  WoolyTubeAudioHandler? audioHandler;
  try {
    final handler = await AudioService.init(
      builder: () => WoolyTubeAudioHandler(playbackService, database),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.woolytube.audio',
        androidNotificationChannelName: 'WoolyTube Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    audioHandler = handler;
  } catch (e) {
    debugPrint('AudioService init failed: $e');
  }

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        playbackServiceProvider.overrideWithValue(playbackService),
        if (audioHandler != null)
          audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const WoolyTubeApp(),
    ),
  );
}

class WoolyTubeApp extends ConsumerStatefulWidget {
  const WoolyTubeApp({super.key});

  @override
  ConsumerState<WoolyTubeApp> createState() => _WoolyTubeAppState();
}

class _WoolyTubeAppState extends ConsumerState<WoolyTubeApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(appLifecycleProvider.notifier).state = state;
    final playbackService = ref.read(playbackServiceProvider);
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        playbackService.handleAppInactive();
        break;
      case AppLifecycleState.resumed:
        playbackService.handleAppResumed();
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Auto-open the full-screen player when a video track starts.
    ref.listen<AsyncValue<Track?>>(currentTrackProvider, (prev, next) {
      final track = next.valueOrNull;
      if (track == null) return;
      if (prev?.valueOrNull?.id == track.id) return;
      final svc = ref.read(playbackServiceProvider);
      if (!svc.isVideoContent) return;
      if (videoFullscreenNotifier.value) return;
      _navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const PlayerPage()),
      );
    });

    return MaterialApp(
      title: 'WoolyTube',
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF2196F3),
          surface: Color(0xFF1E1E1E),
          onSurface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF2A2A2A),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          hintStyle: const TextStyle(color: Color(0xFF888888)),
        ),
      ),
      builder: (context, child) {
        return Column(
          children: [
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: child!,
              ),
            ),
            const MiniPlayerBar(),
          ],
        );
      },
      home: const InitWrapper(),
    );
  }
}

class InitWrapper extends ConsumerStatefulWidget {
  const InitWrapper({super.key});

  @override
  ConsumerState<InitWrapper> createState() => _InitWrapperState();
}

class _InitWrapperState extends ConsumerState<InitWrapper> {
  bool _checkedForUpdates = false;

  void _checkForUpdatesAfterStartup() {
    if (_checkedForUpdates) return;
    _checkedForUpdates = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final updateService = ref.read(updateServiceProvider);
      final log = ref.read(logServiceProvider);

      try {
        final update = await updateService.checkForUpdate();
        if (!mounted || update == null) return;

        final shouldUpdate = await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                title: const Text('Update available'),
                content: Text(
                  'WoolyTube ${update.version} is available. '
                  'You are running ${update.currentVersion}. '
                  'Download and install the new APK?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Later'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Update'),
                  ),
                ],
              ),
        );
        if (!mounted || shouldUpdate != true) return;

        var progressDialogVisible = true;
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder:
                (context) => const AlertDialog(
                  title: Text('Downloading update'),
                  content: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: Text('The installer will open when ready.'),
                      ),
                    ],
                  ),
                ),
          ),
        );

        void closeProgressDialog() {
          if (!mounted || !progressDialogVisible) return;
          progressDialogVisible = false;
          Navigator.of(context, rootNavigator: true).pop();
        }

        try {
          await updateService.downloadAndInstallUpdate(update);
          closeProgressDialog();
        } on PlatformException catch (e) {
          closeProgressDialog();
          if (!mounted) return;

          final message =
              e.code == 'INSTALL_PERMISSION_REQUIRED'
                  ? 'Allow WoolyTube to install unknown apps, then tap Update again.'
                  : e.message ?? 'Could not download and install the update.';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      } catch (e) {
        log.warn('update check failed: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final init = ref.watch(initProvider);

    return init.when(
      loading:
          () => const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF2196F3)),
                  SizedBox(height: 16),
                  Text(
                    'Initializing yt-dlp...',
                    style: TextStyle(color: Color(0xFF888888)),
                  ),
                ],
              ),
            ),
          ),
      error:
          (e, _) => Scaffold(
            body: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Failed to initialize: $e',
                  style: TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
      data: (_) {
        _checkForUpdatesAfterStartup();
        return const HomePage();
      },
    );
  }
}
