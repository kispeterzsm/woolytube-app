package com.woolytube.woolytube

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.PictureInPictureUiState
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Rational
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class MainActivity : AudioServiceFragmentActivity() {
    companion object {
        private const val ACTION_AUDIO_ONLY = "com.woolytube.action.AUDIO_ONLY"
        private const val ACTION_TOGGLE_PLAYBACK = "com.woolytube.action.TOGGLE_PLAYBACK"
        private const val ACTION_SKIP_NEXT = "com.woolytube.action.SKIP_NEXT"
        private const val AUDIO_ONLY_REQUEST_CODE = 501
        private const val TOGGLE_PLAYBACK_REQUEST_CODE = 502
        private const val SKIP_NEXT_REQUEST_CODE = 503
        private const val TAG = "WoolyTube"

        private var currentRef: WeakReference<MainActivity>? = null

        /** The live activity, if any. Main thread only. */
        val current: MainActivity?
            get() = currentRef?.get()?.takeUnless { it.isDestroyed }
    }

    /** The engine-scoped plugin that owns the app's channels. */
    private var appPlugin: WoolyTubeAppPlugin? = null
    private var pipReceiverRegistered = false

    private val playbackChannel: MethodChannel?
        get() = appPlugin?.playbackChannel

    private val pipActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_TOGGLE_PLAYBACK ->
                    playbackChannel?.invokeMethod("togglePlayPause", null)
                ACTION_SKIP_NEXT -> playbackChannel?.invokeMethod("skipNext", null)
                ACTION_AUDIO_ONLY -> {
                    playbackChannel?.invokeMethod(
                        "enableAudioOnly",
                        null,
                        object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                PipState.disableVideo()
                                applyPictureInPictureState()
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                                    !isDestroyed && isInPictureInPictureMode
                                ) {
                                    // Playback is now owned by the foreground media
                                    // service, so the video task no longer needs to be visible.
                                    moveTaskToBack(true)
                                }
                            }

                            override fun error(
                                errorCode: String,
                                errorMessage: String?,
                                errorDetails: Any?
                            ) {
                                Log.w(TAG, "Could not enable audio-only PiP action: $errorMessage")
                            }

                            override fun notImplemented() {
                                Log.w(TAG, "Audio-only PiP action is not implemented")
                            }
                        }
                    )
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        currentRef = WeakReference(this)
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && supportsPictureInPicture()) {
            val filter = IntentFilter().apply {
                addAction(ACTION_AUDIO_ONLY)
                addAction(ACTION_TOGGLE_PLAYBACK)
                addAction(ACTION_SKIP_NEXT)
            }
            ContextCompat.registerReceiver(
                this,
                pipActionReceiver,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            pipReceiverRegistered = true
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The engine is cached by audio_service and outlives this activity, so
        // the plugin is added once per engine, not once per activity.
        val plugins = flutterEngine.plugins
        if (!plugins.has(WoolyTubeAppPlugin::class.java)) {
            plugins.add(WoolyTubeAppPlugin())
        }
        appPlugin = plugins.get(WoolyTubeAppPlugin::class.java) as? WoolyTubeAppPlugin
        // A recreated activity picks up the state Dart sent earlier.
        applyPictureInPictureState()
    }

    override fun onDestroy() {
        if (pipReceiverRegistered) {
            unregisterReceiver(pipActionReceiver)
            pipReceiverRegistered = false
        }
        // A new activity may already have replaced this one.
        if (currentRef?.get() === this) currentRef = null
        appPlugin = null
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT in Build.VERSION_CODES.O..Build.VERSION_CODES.R &&
            PipState.videoActive && PipState.playing && supportsPictureInPicture()
        ) {
            notifyPictureInPictureMode(true)
            try {
                val entered = enterPictureInPictureMode(buildPictureInPictureParams())
                if (!entered) notifyPictureInPictureMode(false)
            } catch (error: IllegalStateException) {
                notifyPictureInPictureMode(false)
                Log.w(TAG, "Could not enter picture-in-picture", error)
            }
        }
    }

    /**
     * Android 15+ says when the auto-enter animation starts. Switching Flutter
     * to the video-only layout now, not after the animation, keeps the rest
     * of the app out of the shrinking window.
     */
    override fun onPictureInPictureUiStateChanged(pipState: PictureInPictureUiState) {
        super.onPictureInPictureUiStateChanged(pipState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
            pipState.isTransitioningToPip && !isInPictureInPictureMode
        ) {
            notifyPictureInPictureMode(true)
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        notifyPictureInPictureMode(isInPictureInPictureMode)
        if (!isInPictureInPictureMode && PipState.videoActive &&
            lifecycle.currentState == Lifecycle.State.CREATED
        ) {
            // The window was closed (X or swipe), not expanded: the activity
            // stopped instead of resuming. Dart can stop decoding video that
            // nobody sees.
            playbackChannel?.invokeMethod("pipDismissed", null)
        }
    }

    private fun supportsPictureInPicture(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun notifyPictureInPictureMode(enabled: Boolean) {
        playbackChannel?.invokeMethod("pictureInPictureChanged", enabled)
    }

    /** Applies the latest [PipState] to this window. */
    fun applyPictureInPictureState() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !supportsPictureInPicture()) {
            return
        }
        if (isDestroyed || isFinishing) return
        try {
            setPictureInPictureParams(buildPictureInPictureParams())
        } catch (e: Exception) {
            Log.w(TAG, "Could not update picture-in-picture parameters", e)
        }
    }

    private fun buildPictureInPictureParams(): PictureInPictureParams {
        val safeAspect = PipState.aspectRatio.coerceIn(0.42, 2.38)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((safeAspect * 1000).toInt(), 1000))
            .setActions(
                if (PipState.videoActive) {
                    listOf(audioOnlyAction(), playPauseAction(), skipNextAction())
                } else {
                    emptyList()
                }
            )

        sourceRectHint(safeAspect)?.let { builder.setSourceRectHint(it) }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder
                .setAutoEnterEnabled(PipState.videoActive && PipState.playing)
                // Android recommends seamless resize only for non-video
                // content; PiP here is always video.
                .setSeamlessResizeEnabled(false)
        }

        return builder.build()
    }

    /**
     * Where the video is when PiP starts, so the system animates the video
     * itself into the window. The whole window was passed before, which
     * never matches a 16:9 window on a portrait screen and made the entire
     * app shrink and then jump.
     */
    private fun sourceRectHint(aspect: Double): Rect? {
        PipState.sourceRect?.let { return Rect(it) }
        // Without a rect from Dart, the only known position is the PiP
        // layout itself (the video fitted and centred in the window). Flutter
        // switches to it before the animation on API 26-30 (onUserLeaveHint)
        // and on 35+ (onPictureInPictureUiStateChanged). On 31-34 the app
        // still shows its normal page when the animation starts, so no hint
        // is better than a wrong one.
        val earlySwitch = Build.VERSION.SDK_INT <= Build.VERSION_CODES.R ||
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM
        if (!earlySwitch) return null
        val bounds = Rect()
        if (!window.decorView.getGlobalVisibleRect(bounds) || bounds.isEmpty) return null
        val width = bounds.width()
        val height = bounds.height()
        val fittedWidth: Int
        val fittedHeight: Int
        if (width.toDouble() / height > aspect) {
            fittedHeight = height
            fittedWidth = (height * aspect).toInt()
        } else {
            fittedWidth = width
            fittedHeight = (width / aspect).toInt()
        }
        if (fittedWidth <= 0 || fittedHeight <= 0) return null
        val left = bounds.left + (width - fittedWidth) / 2
        val top = bounds.top + (height - fittedHeight) / 2
        return Rect(left, top, left + fittedWidth, top + fittedHeight)
    }

    private fun audioOnlyAction(): RemoteAction {
        return pipAction(
            action = ACTION_AUDIO_ONLY,
            requestCode = AUDIO_ONLY_REQUEST_CODE,
            iconResource = R.drawable.ic_headphones,
            title = "Audio only",
            description = "Continue with audio only"
        )
    }

    private fun playPauseAction(): RemoteAction = pipAction(
        action = ACTION_TOGGLE_PLAYBACK,
        requestCode = TOGGLE_PLAYBACK_REQUEST_CODE,
        iconResource = if (PipState.playing) R.drawable.ic_pause else R.drawable.ic_play_arrow,
        title = if (PipState.playing) "Pause" else "Play",
        description = if (PipState.playing) "Pause playback" else "Resume playback"
    )

    private fun skipNextAction(): RemoteAction = pipAction(
        action = ACTION_SKIP_NEXT,
        requestCode = SKIP_NEXT_REQUEST_CODE,
        iconResource = R.drawable.ic_skip_next,
        title = "Next",
        description = "Skip to next"
    )

    private fun pipAction(
        action: String,
        requestCode: Int,
        iconResource: Int,
        title: String,
        description: String
    ): RemoteAction {
        val intent = Intent(action).setPackage(packageName)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return RemoteAction(
            Icon.createWithResource(this, iconResource),
            title,
            description,
            pendingIntent
        )
    }
}
