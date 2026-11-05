package com.woolytube.ytdlp

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDLRequest
import kotlinx.coroutines.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class YtDlpPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val METHOD_CHANNEL = "com.woolytube/ytdlp"
        private const val EVENT_CHANNEL = "com.woolytube/ytdlp_progress"
        private const val MEDIA_METADATA_CHANNEL = "com.woolytube/media_metadata"
        private const val TAG = "WoolyTube"

        private val activeProcessIds = ConcurrentHashMap.newKeySet<String>()

        fun hasActiveDownloads(): Boolean = activeProcessIds.isNotEmpty()

        fun cancelAllActiveDownloads(): Int {
            val ids = activeProcessIds.toList()
            for (processId in ids) {
                try {
                    YoutubeDL.getInstance().destroyProcessById(processId)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to cancel yt-dlp process $processId", e)
                } finally {
                    activeProcessIds.remove(processId)
                }
            }
            return ids.size
        }
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var mediaMetadataChannel: MethodChannel
    private lateinit var context: Context
    private var progressSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val ownedProcessIds = ConcurrentHashMap.newKeySet<String>()
    private var isInitialized = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        // Registered here rather than in MainActivity so that the background
        // worker's headless engine can extract artwork too.
        mediaMetadataChannel = MethodChannel(binding.binaryMessenger, MEDIA_METADATA_CHANNEL)
        mediaMetadataChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "extractEmbeddedThumbnail" ->
                    handleExtractEmbeddedThumbnail(call.arguments as? Map<*, *>, result)
                else -> result.notImplemented()
            }
        }

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }
            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })

        Log.i(TAG, "yt-dlp channels attached to Flutter engine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        mediaMetadataChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        progressSink = null
        val hadActiveDownloads = ownedProcessIds.isNotEmpty()
        cancelOwnedDownloads()
        // Another engine (foreground app or background worker) may still be
        // downloading through the same service.
        if (hadActiveDownloads && !hasActiveDownloads()) {
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> handleInitialize(result)
            "download" -> handleDownload(call.arguments as Map<*, *>, result)
            "getVideoInfo" -> handleGetVideoInfo(call.arguments as Map<*, *>, result)
            "getPlaylistInfo" -> handleGetPlaylistInfo(call.arguments as Map<*, *>, result)
            "cancelDownloads" -> result.success(cancelOwnedDownloads())
            "hasActiveDownloads" -> result.success(hasActiveDownloads())
            "updateYtDlp" -> handleUpdateYtDlp(result)
            "startDownloadService" -> handleStartDownloadService(call.arguments as Map<*, *>, result)
            "updateDownloadServiceProgress" -> handleUpdateDownloadServiceProgress(call.arguments as Map<*, *>, result)
            "stopDownloadService" -> handleStopDownloadService(result)
            else -> result.notImplemented()
        }
    }

    private fun handleInitialize(result: MethodChannel.Result) {
        scope.launch {
            try {
                YoutubeDL.getInstance().init(context)
                FFmpeg.getInstance().init(context)
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
        val writeThumbnail = args["writeThumbnail"] as? Boolean ?: false
        val embedMetadata = args["embedMetadata"] as? Boolean ?: false
        val metadataAlbum = args["metadataAlbum"] as? String
        val metadataTrackNumber = (args["metadataTrackNumber"] as? Number)?.toInt()
        val downloadSubtitles = args["downloadSubtitles"] as? Boolean ?: false
        val subtitleLanguages = args["subtitleLanguages"] as? String ?: "en"
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
            val processId = UUID.randomUUID().toString()
            ownedProcessIds.add(processId)
            activeProcessIds.add(processId)
            try {
                startDownload(
                    url,
                    outputPath,
                    audioOnly,
                    embedThumbnail,
                    writeThumbnail,
                    embedMetadata,
                    metadataAlbum,
                    metadataTrackNumber,
                    downloadSubtitles,
                    subtitleLanguages,
                    outputTemplate,
                    formatOption,
                    processId
                )
                // Drop the ids before replying so a stopDownloadService call
                // that follows the reply does not see this run as active.
                ownedProcessIds.remove(processId)
                activeProcessIds.remove(processId)
                withContext(Dispatchers.Main) {
                    sendProgress(mapOf("status" to "complete", "progress" to 100.0))
                    result.success(null)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Download failed", e)
                ownedProcessIds.remove(processId)
                activeProcessIds.remove(processId)
                withContext(Dispatchers.Main) {
                    sendProgress(mapOf(
                        "status" to "error",
                        "progress" to 0.0,
                        "error" to (e.message ?: "Unknown error")
                    ))
                    result.error("DOWNLOAD_ERROR", e.message, null)
                }
            } finally {
                ownedProcessIds.remove(processId)
                activeProcessIds.remove(processId)
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
                request.addOption("--no-playlist")
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

                val lines = response.out.trim().split("\n").filter { it.isNotBlank() }
                val entries = org.json.JSONArray()
                var playlistTitle = ""
                var playlistThumbnail: String? = null
                var isPlaylistResult = false

                for ((index, line) in lines.withIndex()) {
                    try {
                        val json = org.json.JSONObject(line)
                        val entry = org.json.JSONObject()
                        entry.put("id", json.optString("id", ""))
                        entry.put("title", json.optString("title", "Unknown"))
                        entry.put("thumbnail", json.optString("thumbnail", ""))
                        entry.put("duration", json.optInt("duration", 0))
                        entry.put("playlist_index", json.optInt("playlist_index", index + 1))
                        entry.put("availability", json.optString("availability", ""))
                        entries.put(entry)

                        if (playlistTitle.isEmpty()) {
                            playlistTitle = json.optString("playlist_title", "")
                        }
                        if (json.has("playlist_id") || json.has("playlist_title")) {
                            isPlaylistResult = true
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

                // A single-video URL has no playlist title. Never hand back an
                // empty name: it would become an empty folder name.
                if (playlistTitle.isBlank() && entries.length() > 0) {
                    playlistTitle = entries.getJSONObject(0).optString("title", "")
                }
                val output = org.json.JSONObject()
                output.put("title", playlistTitle)
                output.put("isPlaylist", isPlaylistResult)
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

    private fun cancelOwnedDownloads(): Int {
        val ids = ownedProcessIds.toList()
        for (processId in ids) {
            try {
                YoutubeDL.getInstance().destroyProcessById(processId)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to cancel owned yt-dlp process $processId", e)
            } finally {
                ownedProcessIds.remove(processId)
                activeProcessIds.remove(processId)
            }
        }
        return ids.size
    }

    private fun handleUpdateYtDlp(result: MethodChannel.Result) {
        scope.launch {
            try {
                val status = YoutubeDL.getInstance().updateYoutubeDL(
                    context,
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
        writeThumbnail: Boolean,
        embedMetadata: Boolean,
        metadataAlbum: String?,
        metadataTrackNumber: Int?,
        downloadSubtitles: Boolean,
        subtitleLanguages: String,
        outputTemplate: String?,
        formatOption: String?,
        processId: String
    ) {
        withContext(Dispatchers.Main) {
            sendProgress(mapOf("status" to "starting", "progress" to 0.0))
        }

        val request = YoutubeDLRequest(url)

        if (outputTemplate != null) {
            request.addOption("-o", outputTemplate)
        } else {
            // yt-dlp reads "%" in -o as a format field; escape literal path parts.
            request.addOption("-o", "${outputPath.replace("%", "%%")}/%(title)s.%(ext)s")
        }

        if (formatOption != null) {
            request.addOption("-f", formatOption)
        } else if (audioOnly) {
            request.addOption("-f", "bestaudio[ext=m4a]/bestaudio/best")
            request.addOption("-x")
            request.addOption("--audio-format", "m4a")
        } else {
            request.addOption("-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best")
            // Prefer H.264 within those formats. yt-dlp's default order picks
            // AV1 (often 4K) or VP9, which many TVs, car screens, older phones
            // and PCs cannot play; the library must play on any device.
            request.addOption("-S", "vcodec:h264")
            // A single-file webm fallback cannot hold embedded artwork; mkv can.
            request.addOption("--remux-video", "webm>mkv")
        }

        if (downloadSubtitles && !audioOnly) {
            // Embedding keeps captions with the media through renames/imports.
            // yt-dlp prefers manual captions over automatic ones for each language.
            request.addOption("--embed-subs")
            request.addOption("--write-subs")
            request.addOption("--write-auto-subs")
            request.addOption("--sub-langs", subtitleLanguages)
            request.addOption("--sub-format", "vtt/best")
            request.addOption("--compat-options", "no-keep-subs")
        }

        if (embedThumbnail) {
            request.addOption("--embed-thumbnail")
        }
        if (writeThumbnail) {
            // Keep the cover as a JPEG beside the media so the app has it
            // offline even when it is not embedded, or YouTube deletes it.
            request.addOption("--write-thumbnail")
            request.addOption("--convert-thumbnails", "jpg")
        }
        if (embedMetadata) {
            // Title, artist, date and source URL go into the file so other
            // players show them. Chapters stay out: yt-dlp's ffmpeg-based
            // thumbnail embedding fails on the chapter data stream, and the
            // app keeps chapters in its own metadata.
            request.addOption("--embed-metadata")
            request.addOption("--no-embed-chapters")
            val extraTags = mutableListOf<String>()
            if (!metadataAlbum.isNullOrBlank()) {
                extraTags.add("-metadata")
                extraTags.add("album=$metadataAlbum")
            }
            if (metadataTrackNumber != null && metadataTrackNumber > 0) {
                extraTags.add("-metadata")
                extraTags.add("track=$metadataTrackNumber")
            }
            if (extraTags.isNotEmpty()) {
                request.addOption(
                    "--postprocessor-args",
                    "Metadata+ffmpeg_o:" + extraTags.joinToString(" ") { shellQuote(it) }
                )
            }
        }
        // Unicode titles stay readable outside the app; names stay valid on
        // Windows, FAT and exFAT so the library can be copied anywhere.
        request.addOption("--windows-filenames")
        request.addOption("--no-mtime")
        request.addOption("--no-playlist")
        request.addOption("--write-info-json")

        YoutubeDL.getInstance().execute(request, processId) { progress, etaInSeconds, line ->
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

    /** Quotes [value] for yt-dlp's shlex-based --postprocessor-args parsing. */
    private fun shellQuote(value: String): String =
        "'" + value.replace("'", "'\"'\"'") + "'"

    /**
     * Writes the cover art embedded in a media file to `<targetStem>.<ext>`.
     * Only files with that exact stem are replaced. The caller passes a stem
     * that belongs to one track, so no other track's artwork can be touched.
     */
    private fun handleExtractEmbeddedThumbnail(args: Map<*, *>?, result: MethodChannel.Result) {
        val mediaPath = args?.get("mediaPath") as? String
        val targetStem = args?.get("targetStem") as? String
        if (mediaPath.isNullOrBlank() || targetStem.isNullOrBlank()) {
            result.error("INVALID_ARGS", "mediaPath and targetStem are required", null)
            return
        }
        scope.launch {
            val retriever = android.media.MediaMetadataRetriever()
            try {
                retriever.setDataSource(mediaPath)
                val artwork = retriever.embeddedPicture
                if (artwork == null || artwork.isEmpty()) {
                    withContext(Dispatchers.Main) { result.success(null) }
                    return@launch
                }
                val directory = java.io.File(targetStem).parentFile
                if (directory != null && !directory.exists() && !directory.mkdirs()) {
                    throw IllegalStateException("Could not create thumbnail directory")
                }
                val target = java.io.File("$targetStem.${imageExtension(artwork)}")
                val temporary = java.io.File("${target.path}.tmp")
                temporary.writeBytes(artwork)
                for (ext in listOf("jpg", "png", "webp", "gif")) {
                    val stale = java.io.File("$targetStem.$ext")
                    if (stale.path != target.path && stale.exists()) stale.delete()
                }
                if (!temporary.renameTo(target)) {
                    target.writeBytes(artwork)
                    temporary.delete()
                }
                withContext(Dispatchers.Main) { result.success(target.absolutePath) }
            } catch (e: Exception) {
                Log.w(TAG, "Could not extract embedded artwork from $mediaPath", e)
                withContext(Dispatchers.Main) { result.success(null) }
            } finally {
                try {
                    retriever.release()
                } catch (_: Exception) {
                }
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

    private fun sendProgress(data: Map<String, Any>) {
        progressSink?.success(data)
    }

    private fun handleStartDownloadService(args: Map<*, *>, result: MethodChannel.Result) {
        val playlistName = args["playlistName"] as? String ?: "playlist"
        val intent = Intent(context, DownloadForegroundService::class.java).apply {
            action = DownloadForegroundService.ACTION_START_OR_UPDATE
            putExtra(DownloadForegroundService.EXTRA_PLAYLIST_NAME, playlistName)
            putExtra(DownloadForegroundService.EXTRA_CURRENT_TRACK, 0)
            putExtra(DownloadForegroundService.EXTRA_TOTAL_TRACKS, 0)
            putExtra(DownloadForegroundService.EXTRA_PROGRESS, 0)
        }
        try {
            ContextCompat.startForegroundService(context, intent)
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start download service", e)
            result.error("FG_SERVICE_ERROR", e.message, null)
        }
    }

    private fun handleUpdateDownloadServiceProgress(args: Map<*, *>, result: MethodChannel.Result) {
        val playlistName = args["playlistName"] as? String ?: "playlist"
        val currentTrack = (args["currentTrack"] as? Number)?.toInt() ?: 0
        val totalTracks = (args["totalTracks"] as? Number)?.toInt() ?: 0
        val progress = (args["progress"] as? Number)?.toInt() ?: 0
        val intent = Intent(context, DownloadForegroundService::class.java).apply {
            action = DownloadForegroundService.ACTION_START_OR_UPDATE
            putExtra(DownloadForegroundService.EXTRA_PLAYLIST_NAME, playlistName)
            putExtra(DownloadForegroundService.EXTRA_CURRENT_TRACK, currentTrack)
            putExtra(DownloadForegroundService.EXTRA_TOTAL_TRACKS, totalTracks)
            putExtra(DownloadForegroundService.EXTRA_PROGRESS, progress)
        }
        try {
            ContextCompat.startForegroundService(context, intent)
            result.success(null)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update download service progress", e)
            result.success(null)
        }
    }

    private fun handleStopDownloadService(result: MethodChannel.Result) {
        // The foreground and background engines share one service. Keep it (and
        // its wake lock) alive while any engine still has a yt-dlp process.
        if (hasActiveDownloads()) {
            Log.i(TAG, "Not stopping download service: downloads still active")
            result.success(null)
            return
        }
        val intent = Intent(context, DownloadForegroundService::class.java).apply {
            action = DownloadForegroundService.ACTION_STOP
        }
        try {
            context.startService(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to stop download service", e)
        }
        result.success(null)
    }
}
