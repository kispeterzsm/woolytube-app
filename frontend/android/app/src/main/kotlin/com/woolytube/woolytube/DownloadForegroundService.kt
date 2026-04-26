package com.woolytube.woolytube

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
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

class DownloadForegroundService : Service() {
    companion object {
        private const val TAG = "WoolyTube.DLService"
        private const val CHANNEL_ID = "com.woolytube.downloads.fg"
        private const val CHANNEL_NAME = "WoolyTube Downloads"
        private const val NOTIFICATION_ID = 2000
        private const val WAKE_LOCK_TAG = "WoolyTube:DownloadWakeLock"

        const val ACTION_START_OR_UPDATE = "com.woolytube.download.START_OR_UPDATE"
        const val ACTION_STOP = "com.woolytube.download.STOP"

        const val EXTRA_PLAYLIST_NAME = "playlistName"
        const val EXTRA_CURRENT_TRACK = "currentTrack"
        const val EXTRA_TOTAL_TRACKS = "totalTracks"
        const val EXTRA_PROGRESS = "progress"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var startedForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
            acquire(60 * 60 * 1000L)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START_OR_UPDATE, null -> {
                val playlistName = intent?.getStringExtra(EXTRA_PLAYLIST_NAME) ?: "playlist"
                val current = intent?.getIntExtra(EXTRA_CURRENT_TRACK, 0) ?: 0
                val total = intent?.getIntExtra(EXTRA_TOTAL_TRACKS, 0) ?: 0
                val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
                val notification = buildNotification(playlistName, current, total, progress)

                if (!startedForeground) {
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
                } else {
                    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.notify(NOTIFICATION_ID, notification)
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to release wake lock", e)
        }
        wakeLock = null
        super.onDestroy()
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

    private fun buildNotification(
        playlistName: String,
        currentTrack: Int,
        totalTracks: Int,
        progress: Int
    ): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPi = launchIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        val body = if (totalTracks > 0) "Track $currentTrack of $totalTracks" else "Preparing…"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Downloading $playlistName")
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, progress.coerceIn(0, 100), false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentPi)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }
}
