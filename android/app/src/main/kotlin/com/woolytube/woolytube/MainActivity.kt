package com.woolytube.woolytube

import android.app.DownloadManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.net.Uri
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Log
import android.util.Rational
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import androidx.work.*
import java.util.concurrent.TimeUnit

class MainActivity : AudioServiceFragmentActivity() {
    companion object {
        private const val BACKGROUND_CHANNEL = "com.woolytube/background"
        private const val APP_UPDATE_CHANNEL = "com.woolytube/app_update"
        private const val MEDIA_METADATA_CHANNEL = "com.woolytube/media_metadata"
        private const val PLAYBACK_CHANNEL = "com.woolytube/playback"
        private const val ACTION_AUDIO_ONLY = "com.woolytube.action.AUDIO_ONLY"
        private const val ACTION_TOGGLE_PLAYBACK = "com.woolytube.action.TOGGLE_PLAYBACK"
        private const val ACTION_SKIP_NEXT = "com.woolytube.action.SKIP_NEXT"
        private const val AUDIO_ONLY_REQUEST_CODE = 501
        private const val TOGGLE_PLAYBACK_REQUEST_CODE = 502
        private const val SKIP_NEXT_REQUEST_CODE = 503
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        private const val TAG = "WoolyTubeUpdate"
    }

    private val updateScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var playbackChannel: MethodChannel? = null
    private var pipVideoActive = false
    private var pipPlaying = false
    private var pipAspectRatio = 16.0 / 9.0
    private var pipReceiverRegistered = false

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
                                pipVideoActive = false
                                updatePictureInPictureParams()
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                                    isInPictureInPictureMode
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
        configureWoolyTubeEngine(flutterEngine)
    }

    private fun configureWoolyTubeEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scheduleAutoUpdate" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val allowMobileData =
                            arguments?.get("allowMobileData") as? Boolean ?: false
                        scheduleAutoUpdate(allowMobileData)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "downloadAndInstallApk" -> {
                        handleDownloadAndInstallApk(call.arguments as? Map<*, *>, result)
                    }
                    "getSupportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_METADATA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractEmbeddedThumbnail" -> {
                        handleExtractEmbeddedThumbnail(call.arguments as? Map<*, *>, result)
                    }
                    else -> result.notImplemented()
                }
            }

        playbackChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PLAYBACK_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "updatePictureInPicture" -> {
                        val args = call.arguments as? Map<*, *>
                        pipVideoActive = args?.get("videoActive") as? Boolean ?: false
                        pipPlaying = args?.get("playing") as? Boolean ?: false
                        pipAspectRatio =
                            (args?.get("aspectRatio") as? Number)?.toDouble()
                                ?.takeIf { it.isFinite() && it > 0.0 }
                                ?: 16.0 / 9.0
                        updatePictureInPictureParams()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDestroy() {
        if (pipReceiverRegistered) {
            unregisterReceiver(pipActionReceiver)
            pipReceiverRegistered = false
        }
        playbackChannel = null
        updateScope.cancel()
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT in Build.VERSION_CODES.O..Build.VERSION_CODES.R &&
            pipVideoActive && pipPlaying && supportsPictureInPicture()
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

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        notifyPictureInPictureMode(isInPictureInPictureMode)
    }

    private fun supportsPictureInPicture(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun notifyPictureInPictureMode(enabled: Boolean) {
        playbackChannel?.invokeMethod("pictureInPictureChanged", enabled)
    }

    private fun updatePictureInPictureParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !supportsPictureInPicture()) {
            return
        }
        setPictureInPictureParams(buildPictureInPictureParams())
    }

    private fun buildPictureInPictureParams(): PictureInPictureParams {
        val safeAspect = pipAspectRatio.coerceIn(0.42, 2.38)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((safeAspect * 1000).toInt(), 1000))
            .setActions(
                if (pipVideoActive) {
                    listOf(audioOnlyAction(), playPauseAction(), skipNextAction())
                } else {
                    emptyList()
                }
            )

        val sourceRect = Rect()
        if (window.decorView.getGlobalVisibleRect(sourceRect) && !sourceRect.isEmpty) {
            builder.setSourceRectHint(sourceRect)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder
                .setAutoEnterEnabled(pipVideoActive && pipPlaying)
                .setSeamlessResizeEnabled(true)
        }

        return builder.build()
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
        iconResource = if (pipPlaying) R.drawable.ic_pause else R.drawable.ic_play_arrow,
        title = if (pipPlaying) "Pause" else "Play",
        description = if (pipPlaying) "Pause playback" else "Resume playback"
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

    private fun scheduleAutoUpdate(allowMobileData: Boolean) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val request = PeriodicWorkRequestBuilder<AutoUpdateWorker>(
            1, TimeUnit.HOURS
        )
            .setConstraints(constraints)
            .setInputData(
                workDataOf(
                    AutoUpdateWorker.INPUT_ALLOW_MOBILE_DATA to allowMobileData
                )
            )
            .build()

        WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
            "woolytube_auto_update",
            // Refresh the installed periodic request on every app start so
            // changes to its interval or constraints are not hidden behind an
            // older request left by a previous app version.
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }

    private fun handleExtractEmbeddedThumbnail(
        args: Map<*, *>?,
        result: MethodChannel.Result
    ) {
        val mediaPath = args?.get("mediaPath") as? String
        val playlistPath = args?.get("playlistPath") as? String
        val trackId = (args?.get("trackId") as? Number)?.toLong()
        if (mediaPath.isNullOrBlank() || playlistPath.isNullOrBlank() || trackId == null) {
            result.error("INVALID_ARGS", "mediaPath, playlistPath, and trackId are required", null)
            return
        }

        updateScope.launch {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(mediaPath)
                val artwork = retriever.embeddedPicture
                val thumbnailDir = File(playlistPath, ".woolytube_thumbnails")
                val filePrefix = "track_${trackId}."

                // A replacement without artwork must not retain the previous
                // replacement's thumbnail.
                thumbnailDir.listFiles()
                    ?.filter { it.isFile && it.name.startsWith(filePrefix) }
                    ?.forEach { it.delete() }

                if (artwork == null || artwork.isEmpty()) {
                    withContext(Dispatchers.Main) { result.success(null) }
                    return@launch
                }

                if (!thumbnailDir.exists() && !thumbnailDir.mkdirs()) {
                    throw IllegalStateException("Could not create thumbnail directory")
                }
                val extension = imageExtension(artwork)
                val target = File(thumbnailDir, "track_${trackId}.$extension")
                val temporary = File(thumbnailDir, "${target.name}.tmp")
                temporary.writeBytes(artwork)
                if (target.exists()) target.delete()
                if (!temporary.renameTo(target)) {
                    target.writeBytes(artwork)
                    temporary.delete()
                }
                withContext(Dispatchers.Main) { result.success(target.absolutePath) }
            } catch (e: Exception) {
                Log.w(TAG, "Could not extract embedded artwork from $mediaPath", e)
                withContext(Dispatchers.Main) { result.success(null) }
            } finally {
                retriever.release()
            }
        }
    }

    private fun imageExtension(bytes: ByteArray): String {
        fun byteAt(index: Int): Int = bytes[index].toInt() and 0xff
        if (bytes.size >= 3 && byteAt(0) == 0xff && byteAt(1) == 0xd8 && byteAt(2) == 0xff) {
            return "jpg"
        }
        if (bytes.size >= 4 && byteAt(0) == 0x89 && bytes[1].toInt().toChar() == 'P' &&
            bytes[2].toInt().toChar() == 'N' && bytes[3].toInt().toChar() == 'G') {
            return "png"
        }
        if (bytes.size >= 12 && String(bytes, 0, 4, Charsets.US_ASCII) == "RIFF" &&
            String(bytes, 8, 4, Charsets.US_ASCII) == "WEBP") {
            return "webp"
        }
        if (bytes.size >= 3 && String(bytes, 0, 3, Charsets.US_ASCII) == "GIF") {
            return "gif"
        }
        return "jpg"
    }

    private fun handleDownloadAndInstallApk(
        args: Map<*, *>?,
        result: MethodChannel.Result
    ) {
        val url = args?.get("url") as? String
        val requestedFileName = args?.get("fileName") as? String ?: "woolytube-update.apk"
        val title = args?.get("title") as? String ?: "WoolyTube update"

        if (url.isNullOrBlank()) {
            result.error("INVALID_ARGS", "url is required", null)
            return
        }

        if (!canInstallPackages()) {
            openInstallPermissionSettings()
            result.error(
                "INSTALL_PERMISSION_REQUIRED",
                "Allow WoolyTube to install unknown apps, then tap Update again.",
                null
            )
            return
        }

        updateScope.launch {
            try {
                val apkFile = downloadApk(url, requestedFileName, title)
                withContext(Dispatchers.Main) {
                    openApkInstaller(apkFile)
                    result.success(null)
                }
            } catch (e: Exception) {
                Log.e(TAG, "App update failed", e)
                withContext(Dispatchers.Main) {
                    result.error("APP_UPDATE_ERROR", e.message, null)
                }
            }
        }
    }

    private fun canInstallPackages(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName")
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private suspend fun downloadApk(url: String, requestedFileName: String, title: String): File {
        return withContext(Dispatchers.IO) {
            val baseDownloadsDir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
            val downloadsDir = File(
                baseDownloadsDir,
                "updates"
            ).apply {
                mkdirs()
            }
            downloadsDir.listFiles()
                ?.filter { it.isFile && it.extension.equals("apk", ignoreCase = true) }
                ?.forEach { it.delete() }

            val apkFile = File(downloadsDir, sanitizeApkFileName(requestedFileName))
            if (apkFile.exists()) {
                apkFile.delete()
            }

            val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            val request = DownloadManager.Request(Uri.parse(url)).apply {
                setTitle(title)
                setDescription("Downloading WoolyTube update")
                setMimeType(APK_MIME_TYPE)
                setAllowedOverMetered(true)
                setAllowedOverRoaming(true)
                setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                )
                setDestinationUri(Uri.fromFile(apkFile))
            }

            val downloadId = manager.enqueue(request)
            try {
                waitForDownload(manager, downloadId)
            } catch (e: Exception) {
                manager.remove(downloadId)
                throw e
            }

            if (!apkFile.exists() || apkFile.length() == 0L) {
                throw IllegalStateException("Downloaded APK file is empty")
            }
            apkFile
        }
    }

    private suspend fun waitForDownload(manager: DownloadManager, downloadId: Long) {
        val query = DownloadManager.Query().setFilterById(downloadId)
        val deadline = System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(20)

        while (System.currentTimeMillis() < deadline) {
            var isComplete = false
            manager.query(query)?.use { cursor ->
                if (!cursor.moveToFirst()) {
                    throw IllegalStateException("APK download was cancelled")
                }

                val status = cursor.getInt(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
                )
                when (status) {
                    DownloadManager.STATUS_SUCCESSFUL -> isComplete = true
                    DownloadManager.STATUS_FAILED -> {
                        val reason = cursor.getInt(
                            cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)
                        )
                        throw IllegalStateException("APK download failed with reason $reason")
                    }
                }
            } ?: throw IllegalStateException("Could not query APK download")

            if (isComplete) return
            delay(1000)
        }

        throw IllegalStateException("APK download timed out")
    }

    private fun openApkInstaller(apkFile: File) {
        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apkFile
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, APK_MIME_TYPE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun sanitizeApkFileName(fileName: String): String {
        val cleaned = fileName
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace(Regex("[^A-Za-z0-9._-]"), "-")
            .ifBlank { "woolytube-update.apk" }

        return if (cleaned.endsWith(".apk", ignoreCase = true)) {
            cleaned
        } else {
            "$cleaned.apk"
        }
    }
}
