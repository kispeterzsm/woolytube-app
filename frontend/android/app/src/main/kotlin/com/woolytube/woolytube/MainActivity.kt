package com.woolytube.woolytube

import android.util.Log
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDLRequest
import kotlinx.coroutines.*
import org.json.JSONObject
import org.json.JSONArray

class MainActivity : AudioServiceFragmentActivity() {
    companion object {
        private const val METHOD_CHANNEL = "com.woolytube/ytdlp"
        private const val EVENT_CHANNEL = "com.woolytube/ytdlp_progress"
        private const val TAG = "WoolyTube"
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var progressSink: EventChannel.EventSink? = null
    private var isInitialized = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    progressSink = events
                }
                override fun onCancel(arguments: Any?) {
                    progressSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> handleInitialize(result)
                    "download" -> handleDownload(call.arguments as Map<*, *>, result)
                    "getVideoInfo" -> handleGetVideoInfo(call.arguments as Map<*, *>, result)
                    "getPlaylistInfo" -> handleGetPlaylistInfo(call.arguments as Map<*, *>, result)
                    "cancelDownload" -> handleCancelDownload(call.arguments as Map<*, *>, result)
                    "updateYtDlp" -> handleUpdateYtDlp(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleInitialize(result: MethodChannel.Result) {
        scope.launch {
            try {
                YoutubeDL.getInstance().init(applicationContext)
                FFmpeg.getInstance().init(applicationContext)
                isInitialized = true
                withContext(Dispatchers.Main) { result.success(true) }
            } catch (e: Exception) {
                Log.e(TAG, "Init failed", e)
                withContext(Dispatchers.Main) { result.error("INIT_ERROR", e.message, null) }
            }
        }
    }

    private fun handleDownload(args: Map<*, *>, result: MethodChannel.Result) {
        val url = args["url"] as? String
        val outputPath = args["outputPath"] as? String
        val audioOnly = args["audioOnly"] as? Boolean ?: false
        val embedThumbnail = args["embedThumbnail"] as? Boolean ?: true
        val outputTemplate = args["outputTemplate"] as? String
        val formatOption = args["format"] as? String

        if (url == null || outputPath == null) {
            result.error("INVALID_ARGS", "url and outputPath required", null)
            return
        }
        if (!isInitialized) {
            result.error("NOT_INITIALIZED", "Call initialize first", null)
            return
        }

        scope.launch {
            try {
                startDownload(url, outputPath, audioOnly, embedThumbnail, outputTemplate, formatOption)
                withContext(Dispatchers.Main) {
                    sendProgress(mapOf("status" to "complete", "progress" to 100.0))
                    result.success(null)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Download failed", e)
                withContext(Dispatchers.Main) {
                    sendProgress(mapOf(
                        "status" to "error",
                        "progress" to 0.0,
                        "error" to (e.message ?: "Unknown error")
                    ))
                    result.error("DOWNLOAD_ERROR", e.message, null)
                }
            }
        }
    }

    private fun handleGetVideoInfo(args: Map<*, *>, result: MethodChannel.Result) {
        val url = args["url"] as? String
        if (url == null) {
            result.error("INVALID_ARGS", "url required", null)
            return
        }
        scope.launch {
            try {
                val request = YoutubeDLRequest(url)
                request.addOption("--dump-json")
                request.addOption("--no-download")
                val response = YoutubeDL.getInstance().execute(request)
                withContext(Dispatchers.Main) { result.success(response.out) }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) { result.error("INFO_ERROR", e.message, null) }
            }
        }
    }

    private fun handleGetPlaylistInfo(args: Map<*, *>, result: MethodChannel.Result) {
        val url = args["url"] as? String
        if (url == null) {
            result.error("INVALID_ARGS", "url required", null)
            return
        }
        scope.launch {
            try {
                val request = YoutubeDLRequest(url)
                request.addOption("--flat-playlist")
                request.addOption("--dump-json")
                request.addOption("--no-download")
                val response = YoutubeDL.getInstance().execute(request)

                // yt-dlp outputs one JSON object per line for flat-playlist
                val lines = response.out.trim().split("\n").filter { it.isNotBlank() }
                val entries = JSONArray()
                var playlistTitle = ""
                var playlistThumbnail: String? = null

                for (line in lines) {
                    try {
                        val json = JSONObject(line)
                        val entry = JSONObject()
                        entry.put("id", json.optString("id", ""))
                        entry.put("title", json.optString("title", "Unknown"))
                        entry.put("thumbnail", json.optString("thumbnail", ""))
                        entry.put("duration", json.optInt("duration", 0))
                        entries.put(entry)

                        if (playlistTitle.isEmpty()) {
                            playlistTitle = json.optString("playlist_title", "")
                        }
                        if (playlistThumbnail == null) {
                            val thumbnails = json.optJSONArray("thumbnails")
                            if (thumbnails != null && thumbnails.length() > 0) {
                                playlistThumbnail = thumbnails.getJSONObject(thumbnails.length() - 1).optString("url")
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to parse playlist entry: $line", e)
                    }
                }

                val output = JSONObject()
                output.put("title", playlistTitle)
                output.put("thumbnail", playlistThumbnail ?: "")
                output.put("count", entries.length())
                output.put("entries", entries)

                withContext(Dispatchers.Main) { result.success(output.toString()) }
            } catch (e: Exception) {
                Log.e(TAG, "Playlist info failed", e)
                withContext(Dispatchers.Main) { result.error("PLAYLIST_ERROR", e.message, null) }
            }
        }
    }

    private fun handleCancelDownload(args: Map<*, *>, result: MethodChannel.Result) {
        val processId = args["processId"] as? String
        if (processId == null) {
            result.error("INVALID_ARGS", "processId required", null)
            return
        }
        try {
            YoutubeDL.getInstance().destroyProcessById(processId)
            result.success(true)
        } catch (e: Exception) {
            result.error("CANCEL_ERROR", e.message, null)
        }
    }

    private fun handleUpdateYtDlp(result: MethodChannel.Result) {
        scope.launch {
            try {
                val status = YoutubeDL.getInstance().updateYoutubeDL(
                    applicationContext,
                    YoutubeDL.UpdateChannel.NIGHTLY
                )
                withContext(Dispatchers.Main) { result.success(status?.name ?: "UNKNOWN") }
            } catch (e: Exception) {
                Log.e(TAG, "yt-dlp update failed", e)
                withContext(Dispatchers.Main) { result.error("UPDATE_ERROR", e.message, null) }
            }
        }
    }

    private suspend fun startDownload(
        url: String,
        outputPath: String,
        audioOnly: Boolean,
        embedThumbnail: Boolean,
        outputTemplate: String?,
        formatOption: String?
    ) {
        withContext(Dispatchers.Main) {
            sendProgress(mapOf("status" to "starting", "progress" to 0.0))
        }

        val request = YoutubeDLRequest(url)

        if (outputTemplate != null) {
            request.addOption("-o", outputTemplate)
        } else {
            request.addOption("-o", "$outputPath/%(title)s.%(ext)s")
        }

        if (formatOption != null) {
            request.addOption("-f", formatOption)
        } else if (audioOnly) {
            request.addOption("-f", "bestaudio[ext=m4a]/bestaudio/best")
            request.addOption("-x")
            request.addOption("--audio-format", "m4a")
        } else {
            request.addOption("-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best")
        }

        if (embedThumbnail) {
            request.addOption("--embed-thumbnail")
        }
        request.addOption("--no-mtime")
        request.addOption("--no-playlist")

        YoutubeDL.getInstance().execute(request) { progress, etaInSeconds, line ->
            scope.launch(Dispatchers.Main) {
                sendProgress(mapOf(
                    "status" to "downloading",
                    "progress" to progress.toDouble(),
                    "eta" to etaInSeconds.toLong(),
                    "line" to (line ?: "")
                ))
            }
        }
    }

    private fun sendProgress(data: Map<String, Any>) {
        progressSink?.success(data)
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
