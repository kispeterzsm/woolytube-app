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

  final playbackService = PlaybackService();
  WoolyTubeAudioHandler? audioHandler;
  try {
    final handler = await AudioService.init(
      builder: () => WoolyTubeAudioHandler(playbackService),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.woolytube.audio',
        androidNotificationChannelName: 'WoolyTube Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    audioHandler = handler as WoolyTubeAudioHandler;
  } catch (e) {
    debugPrint('AudioService init failed: $e');
  }

  runApp(ProviderScope(
    overrides: [
      playbackServiceProvider.overrideWithValue(playbackService),
      if (audioHandler != null)
        audioHandlerProvider.overrideWithValue(audioHandler),
    ],
    child: const WoolyTubeApp(),
  ));
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

class InitWrapper extends ConsumerWidget {
  const InitWrapper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final init = ref.watch(initProvider);

    return init.when(
      loading: () => const Scaffold(
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
      error: (e, _) => Scaffold(
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
      data: (_) => const HomePage(),
    );
  }
}
