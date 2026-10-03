import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:audio_service/audio_service.dart';
import 'database/database.dart';
import 'providers/providers.dart';
import 'providers/playback_providers.dart';
import 'providers/lifecycle_provider.dart';
import 'services/playback_service.dart';
import 'services/audio_handler.dart';
import 'services/picture_in_picture_service.dart';
import 'services/background_worker.dart' as background_worker;
import 'services/app_settings_service.dart';
import 'services/download_errors.dart';
import 'services/download_service.dart';
import 'pages/home_page.dart';
import 'pages/player_page.dart';
import 'widgets/mini_player.dart';

@pragma('vm:entry-point')
void backgroundMain() {
  background_worker.backgroundMain();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final appSettingsService = AppSettingsService();

  // Schedule background auto-update with the user's network preference.
  try {
    await appSettingsService.scheduleAutoUpdate();
  } catch (_) {
    // Non-critical — don't block app startup.
  }

  final database = AppDatabase();
  final playbackService = PlaybackService(database);
  final pictureInPictureService = PictureInPictureService(playbackService);
  await pictureInPictureService.initialize();
  WoolyTubeAudioHandler? audioHandler;
  try {
    final handler = await AudioService.init(
      builder: () => WoolyTubeAudioHandler(playbackService, database),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.woolytube.audio',
        androidNotificationChannelName: 'WoolyTube Playback',
        // Keep the media service foregrounded across a pause. Android 12+
        // can reject an attempt to promote a paused service again while the
        // app is in the background, leaving playback without a wake lock.
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
      ),
    );
    audioHandler = handler;
  } catch (e) {
    debugPrint('AudioService init failed: $e');
  }

  try {
    await playbackService.initializeAudioFocus(
      pauseOnAudioInterruption:
          await appSettingsService.getPauseOnAudioInterruption(),
    );
  } catch (e) {
    debugPrint('Audio focus init failed: $e');
  }

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsServiceProvider.overrideWithValue(appSettingsService),
        playbackServiceProvider.overrideWithValue(playbackService),
        pictureInPictureServiceProvider.overrideWithValue(
          pictureInPictureService,
        ),
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
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

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
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        break;
      case AppLifecycleState.resumed:
        unawaited(ref.read(pictureInPictureServiceProvider).handleAppResumed());
        break;
      case AppLifecycleState.detached:
        // Detached means the UI engine is being torn down, not merely covered
        // by another app. Stop foreground downloads while platform channels
        // are still available. Native task-removal handling is the fallback.
        unawaited(ref.read(downloadServiceProvider).cancelActiveDownloads());
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final inPictureInPicture =
        ref.watch(isInPictureInPictureProvider).valueOrNull ?? false;

    // Auto-open the full-screen player when a video track starts.
    ref.listen<AsyncValue<Track?>>(currentTrackProvider, (prev, next) {
      final track = next.valueOrNull;
      if (track == null) return;
      if (prev?.valueOrNull?.id == track.id) return;
      final svc = ref.read(playbackServiceProvider);
      if (!svc.isVideoContent) return;
      if (videoFullscreenNotifier.value) return;
      _navigatorKey.currentState?.push(playerPageRoute());
    });

    // Surface download failures from anywhere in the app, including
    // background-started downloads whose page is no longer open.
    ref.listen<AsyncValue<DownloadProgress>>(downloadProgressProvider, (
      prev,
      next,
    ) {
      final progress = next.valueOrNull;
      if (progress == null || progress.status != 'error') return;
      if (identical(prev?.valueOrNull, progress)) return;
      _showDownloadError(progress.error ?? '');
    });

    ref.listen<AsyncValue<String>>(playbackMessagesProvider, (prev, next) {
      final message = next.valueOrNull;
      if (message == null || message.isEmpty) return;
      _messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 3),
          ),
        );
    });

    return MaterialApp(
      title: 'WoolyTube',
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
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
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF2A2A2A),
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 20),
          contentTextStyle: TextStyle(color: Color(0xFFCCCCCC), fontSize: 14),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF2A2A2A),
          surfaceTintColor: Colors.transparent,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFF2A2A2A),
          surfaceTintColor: Colors.transparent,
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
        return Stack(
          fit: StackFit.expand,
          children: [
            Offstage(
              offstage: inPictureInPicture,
              child: Column(
                children: [
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeBottom: true,
                      child: child!,
                    ),
                  ),
                  MiniPlayerBar(
                    onOpenPlayer: () {
                      _navigatorKey.currentState?.push(playerPageRoute());
                    },
                  ),
                ],
              ),
            ),
            if (inPictureInPicture)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black,
                  child: Video(
                    controller:
                        ref.read(playbackServiceProvider).videoController,
                    controls: _noPictureInPictureControls,
                    pauseUponEnteringBackgroundMode: false,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
          ],
        );
      },
      home: const InitWrapper(),
    );
  }

  void _showDownloadError(String raw) {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    final friendly = friendlyDownloadError(raw);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Download failed: $friendly'),
          duration: const Duration(seconds: 6),
          action:
              raw.trim().isEmpty
                  ? null
                  : SnackBarAction(
                    label: 'Details',
                    onPressed: () => _showDownloadErrorDetails(friendly, raw),
                  ),
        ),
      );
  }

  void _showDownloadErrorDetails(String friendly, String raw) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    // The overlay's context is below the Navigator, which showDialog needs.
    final dialogContext = navigator.overlay?.context;
    if (dialogContext == null) return;
    showDialog<void>(
      context: dialogContext,
      builder:
          (ctx) => AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.error_outline, color: Color(0xFFAA6666)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    friendly,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: SelectableText(
                  raw,
                  style: const TextStyle(
                    color: Color(0xFFCCCCCC),
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }
}

Widget _noPictureInPictureControls(VideoState state) => const SizedBox.shrink();

class InitWrapper extends ConsumerStatefulWidget {
  const InitWrapper({super.key});

  @override
  ConsumerState<InitWrapper> createState() => _InitWrapperState();
}

class _InitWrapperState extends ConsumerState<InitWrapper> {
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
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Failed to initialize: $e',
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => ref.invalidate(initProvider),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      data: (_) => const HomePage(),
    );
  }
}
