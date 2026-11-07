package com.woolytube.ytdlp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat

/** What the download notification shows. */
internal data class DownloadNotificationState(
    val playlistName: String,
    val currentTrack: Int,
    val totalTracks: Int,
    val progress: Int,
    val trackTitle: String?
)

/**
 * Keeps the process and a wake lock alive while a playlist downloads, and
 * shows its progress with a Cancel button.
 *
 * The service is started once per run ([ACTION_START]). Progress updates do
 * not go through startForegroundService (a binder call on the main thread
 * per update); the plugin hands them to [publishState], which redraws the
 * notification at most every [MIN_NOTIFY_INTERVAL_MS].
 */
class DownloadForegroundService : Service() {
    companion object {
        private const val TAG = "WoolyTube.DLService"
        private const val CHANNEL_ID = "com.woolytube.downloads.fg"
        private const val CHANNEL_NAME = "WoolyTube Downloads"
        private const val NOTIFICATION_ID = 2000
        private const val WAKE_LOCK_TAG = "WoolyTube:DownloadWakeLock"
        private const val WAKE_LOCK_TIMEOUT_MS = 60 * 60 * 1000L
        private const val WAKE_LOCK_RENEW_INTERVAL_MS = 5 * 60 * 1000L
        private const val MIN_NOTIFY_INTERVAL_MS = 500L
        private const val CANCEL_REQUEST_CODE = 1

        const val ACTION_START = "com.woolytube.download.START"

        /** Kept for intents sent by an older plugin build. */
        const val ACTION_START_OR_UPDATE = "com.woolytube.download.START_OR_UPDATE"
        const val ACTION_STOP = "com.woolytube.download.STOP"
        const val ACTION_CANCEL = "com.woolytube.download.CANCEL"

        const val EXTRA_PLAYLIST_NAME = "playlistName"
        const val EXTRA_CURRENT_TRACK = "currentTrack"
        const val EXTRA_TOTAL_TRACKS = "totalTracks"
        const val EXTRA_PROGRESS = "progress"

        @Volatile
        private var state = DownloadNotificationState("playlist", 0, 0, 0, null)

        /** The running service; only touched on the main thread. */
        private var instance: DownloadForegroundService? = null

        /**
         * Records the latest progress and redraws the notification if the
         * service runs. Called by the plugin on the main thread.
         */
        fun publishState(
            playlistName: String,
            currentTrack: Int,
            totalTracks: Int,
            progress: Int,
            trackTitle: String?
        ) {
            val previous = state
            val next = DownloadNotificationState(
                playlistName,
                currentTrack,
                totalTracks,
                progress.coerceIn(0, 100),
                trackTitle?.takeIf { it.isNotBlank() } ?: previous.trackTitle?.takeIf {
                    previous.currentTrack == currentTrack && previous.playlistName == playlistName
                }
            )
            state = next
            if (Looper.myLooper() == Looper.getMainLooper()) {
                instance?.onStateChanged(previous, next)
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var startedForeground = false
    private var cancelling = false
    private var lastNotifyAtMs = 0L
    private var lastWakeLockRenewAtMs = 0L
    private var contentIntent: PendingIntent? = null
    private lateinit var cancelIntent: PendingIntent

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureNotificationChannel()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        // Acquired only when a run starts, so a stray create/stop never
        // holds it.
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
        }
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        cancelIntent = PendingIntent.getService(
            this,
            CANCEL_REQUEST_CODE,
            Intent(this, DownloadForegroundService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    // Re-arms the timeout; the lock is not reference counted, so a repeated
    // acquire only extends it. Without this a playlist taking longer than an
    // hour continued without the lock.
    private fun renewWakeLock() {
        try {
            wakeLock?.acquire(WAKE_LOCK_TIMEOUT_MS)
            lastWakeLockRenewAtMs = SystemClock.elapsedRealtime()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to renew wake lock", e)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            ACTION_CANCEL -> {
                if (!startedForeground) {
                    // A tap on a notification left from a killed process.
                    YtDlpPlugin.requestCancelFromUser(this, "notification")
                    stopSelf()
                } else if (!cancelling) {
                    cancelling = true
                    notifyNow(buildCancellingNotification())
                    YtDlpPlugin.requestCancelFromUser(this, "notification")
                }
            }
            ACTION_START, ACTION_START_OR_UPDATE, null -> {
                // A new run (or a restart) clears an earlier cancel.
                cancelling = false
                if (intent?.action == ACTION_START_OR_UPDATE) {
                    publishState(
                        playlistName = intent.getStringExtra(EXTRA_PLAYLIST_NAME) ?: "playlist",
                        currentTrack = intent.getIntExtra(EXTRA_CURRENT_TRACK, 0),
                        totalTracks = intent.getIntExtra(EXTRA_TOTAL_TRACKS, 0),
                        progress = intent.getIntExtra(EXTRA_PROGRESS, 0),
                        trackTitle = null
                    )
                }
                renewWakeLock()
                // Every startForegroundService call is answered with
                // startForeground, also when the service already runs.
                val notification = buildProgressNotification(state)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        startForeground(
                            NOTIFICATION_ID,
                            notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                    startedForeground = true
                } catch (e: Exception) {
                    // Android 12+ can refuse a foreground start from the
                    // background. The download runs on without it.
                    Log.w(TAG, "Could not show the download notification: ${e.message}")
                    if (!startedForeground) {
                        stopSelf()
                        return START_NOT_STICKY
                    }
                }
                lastNotifyAtMs = SystemClock.elapsedRealtime()
            }
        }
        return START_NOT_STICKY
    }

    private fun onStateChanged(
        previous: DownloadNotificationState,
        next: DownloadNotificationState
    ) {
        if (!startedForeground || cancelling) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastWakeLockRenewAtMs >= WAKE_LOCK_RENEW_INTERVAL_MS) renewWakeLock()
        // A new track or title is shown at once; progress is rate limited.
        val textChanged = previous.currentTrack != next.currentTrack ||
            previous.totalTracks != next.totalTracks ||
            previous.trackTitle != next.trackTitle ||
            previous.playlistName != next.playlistName
        if (!textChanged && previous.progress == next.progress) return
        if (!textChanged && now - lastNotifyAtMs < MIN_NOTIFY_INTERVAL_MS) return
        lastNotifyAtMs = now
        notifyNow(buildProgressNotification(next))
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to release wake lock", e)
        }
        wakeLock = null
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Ask the Dart side to stop its run first, so it does not treat the
        // killed process as a failed track and start the next one. Native
        // kills what is left shortly after.
        YtDlpPlugin.requestCancelFromUser(this, "taskRemoved")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun notifyNow(notification: Notification) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update download notification", e)
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Active download progress"
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        nm.createNotificationChannel(channel)
    }

    // The pending intents are made once in onCreate; building a notification
    // is then plain object work, with no binder calls.
    private fun baseBuilder(): NotificationCompat.Builder =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentIntent)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

    private fun buildProgressNotification(current: DownloadNotificationState): Notification {
        val position = if (current.totalTracks > 0) {
            "Track ${current.currentTrack} of ${current.totalTracks}"
        } else {
            null
        }
        val text = current.trackTitle ?: position ?: "Preparing…"
        return baseBuilder()
            .setContentTitle("Downloading ${current.playlistName}")
            .setContentText(text)
            .setSubText(if (current.trackTitle != null) position else null)
            .setProgress(100, current.progress, current.totalTracks <= 0)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Cancel",
                cancelIntent
            )
            .build()
    }

    private fun buildCancellingNotification(): Notification {
        return baseBuilder()
            .setContentTitle("Stopping download…")
            .setContentText(state.playlistName)
            .setProgress(0, 0, true)
            .build()
    }
}
