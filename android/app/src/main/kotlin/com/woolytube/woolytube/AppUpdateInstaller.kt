package com.woolytube.woolytube

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Downloads a release APK with DownloadManager and opens the installer.
 * Uses only the application context, so it works whether or not an
 * activity is alive, and always answers the Dart call.
 */
class AppUpdateInstaller(private val context: Context) {
    companion object {
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        private const val TAG = "WoolyTubeUpdate"
    }

    fun downloadAndInstall(
        args: Map<*, *>?,
        result: MethodChannel.Result,
        scope: CoroutineScope
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

        scope.launch {
            try {
                val apkFile = downloadApk(url, requestedFileName, title)
                openApkInstaller(apkFile)
                result.success(null)
            } catch (e: CancellationException) {
                // The engine is going away; nobody is left to answer.
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "App update failed", e)
                result.error("APP_UPDATE_ERROR", e.message, null)
            }
        }
    }

    private fun canInstallPackages(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${context.packageName}")
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Could not open the install permission screen", e)
        }
    }

    private suspend fun downloadApk(url: String, requestedFileName: String, title: String): File {
        return withContext(Dispatchers.IO) {
            val baseDownloadsDir =
                context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: context.filesDir
            val downloadsDir = File(baseDownloadsDir, "updates").apply {
                mkdirs()
            }
            downloadsDir.listFiles()
                ?.filter { it.isFile && it.extension.equals("apk", ignoreCase = true) }
                ?.forEach { it.delete() }

            val apkFile = File(downloadsDir, sanitizeApkFileName(requestedFileName))
            if (apkFile.exists()) {
                apkFile.delete()
            }

            val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
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
            context,
            "${context.packageName}.fileprovider",
            apkFile
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, APK_MIME_TYPE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
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
