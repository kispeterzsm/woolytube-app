package com.woolytube.woolytube

import android.content.Context
import android.graphics.Rect
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * The app's own platform channels, scoped to the Flutter engine rather than
 * to MainActivity.
 *
 * The app engine is audio_service's cached engine and outlives the activity.
 * Handlers installed by the activity kept the destroyed activity reachable
 * and called into it; these handlers only hold the application context and
 * reach the activity through [MainActivity.current] when one is alive.
 */
class WoolyTubeAppPlugin : FlutterPlugin {
    companion object {
        private const val BACKGROUND_CHANNEL = "com.woolytube/background"
        private const val APP_UPDATE_CHANNEL = "com.woolytube/app_update"
        const val PLAYBACK_CHANNEL = "com.woolytube/playback"
    }

    private var backgroundChannel: MethodChannel? = null
    private var appUpdateChannel: MethodChannel? = null

    /** Dart's picture-in-picture handler (PictureInPictureService). */
    var playbackChannel: MethodChannel? = null
        private set

    private var scope: CoroutineScope? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context: Context = binding.applicationContext
        val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        scope = pluginScope
        val installer = AppUpdateInstaller(context)

        backgroundChannel = MethodChannel(binding.binaryMessenger, BACKGROUND_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "scheduleAutoUpdate" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val allowMobileData =
                            arguments?.get("allowMobileData") as? Boolean ?: false
                        try {
                            AutoUpdateWorker.schedule(context, allowMobileData)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SCHEDULE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        appUpdateChannel = MethodChannel(binding.binaryMessenger, APP_UPDATE_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "downloadAndInstallApk" ->
                        installer.downloadAndInstall(
                            call.arguments as? Map<*, *>,
                            result,
                            pluginScope
                        )
                    "getSupportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    else -> result.notImplemented()
                }
            }
        }

        playbackChannel = MethodChannel(binding.binaryMessenger, PLAYBACK_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "updatePictureInPicture" -> {
                        PipState.update(call.arguments as? Map<*, *>)
                        MainActivity.current?.applyPictureInPictureState()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        backgroundChannel?.setMethodCallHandler(null)
        appUpdateChannel?.setMethodCallHandler(null)
        playbackChannel?.setMethodCallHandler(null)
        backgroundChannel = null
        appUpdateChannel = null
        playbackChannel = null
        scope?.cancel()
        scope = null
    }
}

/**
 * What Dart last said about picture-in-picture. Kept outside the activity so
 * a recreated activity starts with the current state.
 */
object PipState {
    @Volatile
    var videoActive = false
        private set

    @Volatile
    var playing = false
        private set

    @Volatile
    var aspectRatio = 16.0 / 9.0
        private set

    /** Where the video is drawn, in window pixels, when Dart knows it. */
    @Volatile
    var sourceRect: Rect? = null
        private set

    fun update(args: Map<*, *>?) {
        videoActive = args?.get("videoActive") as? Boolean ?: false
        playing = args?.get("playing") as? Boolean ?: false
        aspectRatio = (args?.get("aspectRatio") as? Number)?.toDouble()
            ?.takeIf { it.isFinite() && it > 0.0 }
            ?: 16.0 / 9.0
        sourceRect = (args?.get("sourceRect") as? Map<*, *>)?.let { rect ->
            val left = (rect["left"] as? Number)?.toInt()
            val top = (rect["top"] as? Number)?.toInt()
            val right = (rect["right"] as? Number)?.toInt()
            val bottom = (rect["bottom"] as? Number)?.toInt()
            if (left == null || top == null || right == null || bottom == null) {
                null
            } else {
                Rect(left, top, right, bottom).takeUnless { it.isEmpty }
            }
        }
    }

    fun disableVideo() {
        videoActive = false
    }
}
