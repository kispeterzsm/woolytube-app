package com.woolytube.ytdlp

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * yt-dlp bridge. One instance exists per Flutter engine (the app's engine
 * and, rarely, the background worker's headless engine), while yt-dlp, the
 * download service and the process ids are shared by the whole process.
 *
 * With Flutter 3.29's merged threads the Android main thread is also the
 * Dart UI thread, so everything here keeps main-thread work small: progress
 * is throttled before it is posted, and the notification is updated
 * without a service IPC per progress line.
 */
class YtDlpPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val METHOD_CHANNEL = "com.woolytube/ytdlp"
        private const val EVENT_CHANNEL = "com.woolytube/ytdlp_progress"
        private const val MEDIA_METADATA_CHANNEL = "com.woolytube/media_metadata"
        private const val CONTROL_CHANNEL = "com.woolytube/ytdlp_control"
        private const val TAG = "WoolyTube"

        /** At most this often a 'downloading' event crosses to Dart. */
        private const val PROGRESS_INTERVAL_MS = 250L

        /** How long Dart gets to stop a run cleanly before native kills it. */
        private const val CANCEL_FALLBACK_MS = 3_000L
        private const val TASK_REMOVED_FALLBACK_MS = 1_500L

        private val activeProcessIds = ConcurrentHashMap.newKeySet<String>()

        /** Engines that have asked for the download notification. */
        private val serviceRequesters = ConcurrentHashMap.newKeySet<YtDlpPlugin>()

        /** Every attached engine's plugin instance. */
        private val instances = CopyOnWriteArraySet<YtDlpPlugin>()

        /**
         * Downloads and info calls hold the read side, the self-update holds
         * the write side, so the binary is never swapped under a running
         * yt-dlp process.
         */
        private val runtimeLock = ReentrantReadWriteLock()

        private val initLock = Any()

        @Volatile
        private var runtimeInitialized = false

        private val mainHandler = Handler(Looper.getMainLooper())

        fun hasActiveDownloads(): Boolean = activeProcessIds.isNotEmpty()

        /**
         * Whether an engine with a run in progress can stop it cleanly. The
         * notification shows its Cancel button only then; otherwise Cancel
         * could only kill the process, and Dart would record a failed track
         * and carry on with the next one.
         */
        fun isCancelAvailable(): Boolean = serviceRequesters.any { it.cancelSupported }

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

        /**
         * The user asked to stop downloading (notification Cancel, or the
         * app was swiped away). Each engine's Dart side is asked to stop its
         * run, so the interrupted track goes back to the queue and the run
         * ends instead of moving on to the next track. Native kills the
         * processes itself only when no engine handled the request.
         */
        fun requestCancelFromUser(context: Context, reason: String) {
            mainHandler.post {
                val appContext = context.applicationContext
                val targets = serviceRequesters.toList().ifEmpty { instances.toList() }
                val handled = AtomicBoolean(false)
                for (plugin in targets) {
                    plugin.sendCancelRequest(reason) { accepted ->
                        if (accepted) handled.set(true)
                    }
                }
                val delay = if (reason == "taskRemoved") {
                    TASK_REMOVED_FALLBACK_MS
                } else {
                    CANCEL_FALLBACK_MS
                }
                mainHandler.postDelayed({
                    if (!handled.get() || reason == "taskRemoved") {
                        val killed = cancelAllActiveDownloads()
                        if (killed > 0) {
                            Log.i(TAG, "Cancelled $killed yt-dlp process(es) ($reason)")
                        }
                    }
                    if (!handled.get()) {
                        // Nobody stopped a run. Keep the notification and its
                        // wake lock for an engine that still has one going
                        // (its stopDownloadService ends it); stop the service
                        // only when no run is left.
                        if (serviceRequesters.isEmpty()) {
                            stopDownloadService(appContext)
                        } else {
                            DownloadForegroundService.cancelNotHandled()
                        }
                    }
                }, delay)
            }
        }

        private fun stopDownloadService(context: Context) {
            // stopService never creates the service and has no background
            // start restriction, unlike startService(ACTION_STOP).
            try {
                context.stopService(Intent(context, DownloadForegroundService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "Failed to stop download service", e)
            }
        }
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var mediaMetadataChannel: MethodChannel
    private lateinit var controlChannel: MethodChannel
    private lateinit var context: Context
    @Volatile
    private var progressSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val ownedProcessIds = ConcurrentHashMap.newKeySet<String>()

    /** Info calls of this engine; killed when the engine goes away. */
    private val ownedInfoProcessIds = ConcurrentHashMap.newKeySet<String>()

    /** This engine's Dart side answers "cancelRequestedByUser". */
    @Volatile
    private var cancelSupported = false

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

        controlChannel = MethodChannel(binding.binaryMessenger, CONTROL_CHANNEL)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }
            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })

        instances.add(this)
        Log.i(TAG, "yt-dlp channels attached to Flutter engine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        instances.remove(this)
        methodChannel.setMethodCallHandler(null)
        mediaMetadataChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        progressSink = null
        cancelOwnedDownloads()
        cancelOwnedInfoCalls()
        // The engine may go away between two tracks, when no process runs
        // but its run still holds the notification and wake lock.
        val requested = serviceRequesters.remove(this)
        if (requested && serviceRequesters.isEmpty() && !hasActiveDownloads()) {
            stopDownloadService(context)
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

    /**
     * Asks this engine's Dart side whether it handles the notification's
     * Cancel ("ping" on the control channel), and shows the button once it
     * does. Called on the main thread.
     */
    private fun probeCancelSupport() {
        if (cancelSupported) return
        try {
            controlChannel.invokeMethod(
                "ping",
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        cancelSupported = true
                        DownloadForegroundService.cancelAvailabilityChanged()
                    }

                    override fun error(code: String, message: String?, details: Any?) {}

                    override fun notImplemented() {}
                }
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not ask whether downloads can be cancelled", e)
        }
    }

    /** Asks this engine's Dart side to stop; [onReply] gets true if it did. */
    private fun sendCancelRequest(reason: String, onReply: (Boolean) -> Unit) {
        try {
            controlChannel.invokeMethod(
                "cancelRequestedByUser",
                mapOf("reason" to reason),
                object : MethodChannel.Result {
                    override fun success(result: Any?) = onReply(true)
                    override fun error(code: String, message: String?, details: Any?) =
                        onReply(false)
                    override fun notImplemented() = onReply(false)
                }
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not forward cancel request", e)
            onReply(false)
        }
    }

    private fun handleInitialize(result: MethodChannel.Result) {
        if (runtimeInitialized) {
            // The other engine already started yt-dlp in this process.
            result.success(true)
            return
        }
        scope.launch {
            try {
                synchronized(initLock) {
                    if (!runtimeInitialized) {
                        YoutubeDL.getInstance().init(context)
                        FFmpeg.getInstance().init(context)
                        runtimeInitialized = true
                    }
                }
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
        if (!runtimeInitialized) {
            result.error("NOT_INITIALIZED", "Call initialize first", null)
            return
        }

        // Registered before the coroutine starts, so a cancelDownloads or
        // hasActiveDownloads call right after this one already sees it.
        val processId = UUID.randomUUID().toString()
        ownedProcessIds.add(processId)
        activeProcessIds.add(processId)
        scope.launch {
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
                withContext(NonCancellable + Dispatchers.Main) {
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

    /**
     * Runs a yt-dlp call that only reads information. It is killed when this
     * engine goes away, and never overlaps a yt-dlp self-update.
     */
    private fun executeInfoRequest(request: YoutubeDLRequest): String {
        val processId = UUID.randomUUID().toString()
        ownedInfoProcessIds.add(processId)
        try {
            return runtimeLock.read {
                YoutubeDL.getInstance().execute(request, processId).out
            }
        } finally {
            ownedInfoProcessIds.remove(processId)
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
                val out = executeInfoRequest(request)
                // The full info is hundreds of KB (every format, thumbnail
                // and caption URL). Dart only reads these fields, so only
                // these cross the channel and get decoded on the UI thread.
                val full = org.json.JSONObject(out.trim().lineSequence().first { it.isNotBlank() })
                val trimmed = org.json.JSONObject()
                for (key in listOf("id", "title", "duration", "chapters", "uploader", "channel")) {
                    if (full.has(key) && !full.isNull(key)) trimmed.put(key, full.get(key))
                }
                val json = trimmed.toString()
                withContext(Dispatchers.Main) { result.success(json) }
            } catch (e: Exception) {
                withContext(NonCancellable + Dispatchers.Main) {
                    result.error("INFO_ERROR", e.message, null)
                }
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
                val out = executeInfoRequest(request)

                val lines = out.trim().split("\n").filter { it.isNotBlank() }
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
                        // Flat entries often lack a thumbnail or a duration
                        // (live streams, premieres). Leave them out so Dart
                        // stores null instead of "" and 0:00.
                        val thumbnail = json.optString("thumbnail", "")
                        if (thumbnail.isNotBlank()) entry.put("thumbnail", thumbnail)
                        val duration = json.optDouble("duration", Double.NaN)
                        if (!duration.isNaN() && duration > 0) {
                            entry.put("duration", Math.round(duration).toInt())
                        }
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
                                playlistThumbnail = thumbnails.getJSONObject(thumbnails.length() - 1)
                                    .optString("url")
                                    .takeIf { it.isNotBlank() }
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
                playlistThumbnail?.let { output.put("thumbnail", it) }
                output.put("count", entries.length())
                output.put("entries", entries)

                val json = output.toString()
                withContext(Dispatchers.Main) { result.success(json) }
            } catch (e: Exception) {
                Log.e(TAG, "Playlist info failed", e)
                withContext(NonCancellable + Dispatchers.Main) {
                    result.error("PLAYLIST_ERROR", e.message, null)
                }
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

    private fun cancelOwnedInfoCalls() {
        for (processId in ownedInfoProcessIds.toList()) {
            try {
                YoutubeDL.getInstance().destroyProcessById(processId)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to cancel yt-dlp info call $processId", e)
            } finally {
                ownedInfoProcessIds.remove(processId)
            }
        }
    }

    private fun handleUpdateYtDlp(result: MethodChannel.Result) {
        scope.launch {
            try {
                val status = runtimeLock.write {
                    YoutubeDL.getInstance().updateYoutubeDL(
                        context,
                        YoutubeDL.UpdateChannel.NIGHTLY
                    )
                }
                withContext(Dispatchers.Main) { result.success(status?.name ?: "UNKNOWN") }
            } catch (e: Exception) {
                Log.e(TAG, "yt-dlp update failed", e)
                withContext(NonCancellable + Dispatchers.Main) {
                    result.error("UPDATE_ERROR", e.message, null)
                }
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
        // No --restrict-filenames: Unicode titles stay readable outside the
        // app. yt-dlp's default already swaps characters Windows, FAT and
        // exFAT reject for look-alikes in the title. (--windows-filenames
        // must not be used: it also rewrites the folder part of -o, so a
        // folder named "Vol. 2." would be saved outside the staging folder.)
        request.addOption("--no-mtime")
        request.addOption("--no-playlist")
        request.addOption("--write-info-json")

        // yt-dlp prints a progress line for every block it reads, often tens
        // per second, and the library calls back for each line. Only whole
        // percent changes, at most every PROGRESS_INTERVAL_MS, cross to the
        // main (= Dart UI) thread. --progress-delta is not used: an older
        // bundled yt-dlp would reject the unknown option.
        val throttle = ProgressThrottle(PROGRESS_INTERVAL_MS)
        runtimeLock.read {
            YoutubeDL.getInstance().execute(request, processId) { progress, _, _ ->
                val percent = throttle.accept(progress)
                if (percent != null) {
                    mainHandler.post {
                        sendProgress(mapOf(
                            "status" to "downloading",
                            "progress" to percent.toDouble()
                        ))
                    }
                }
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
            val mediaFile = File(mediaPath)
            // A file known to have no cover is not opened again until it
            // changes; the backfill asks for every cover-less track on each
            // start, and each attempt parses the whole container.
            val marker = noCoverMarker(mediaPath)
            val signature = "${mediaFile.lastModified()}:${mediaFile.length()}"
            if (mediaFile.exists() && marker.exists() &&
                runCatching { marker.readText() }.getOrNull() == signature
            ) {
                withContext(Dispatchers.Main) { result.success(null) }
                return@launch
            }
            val retriever = android.media.MediaMetadataRetriever()
            try {
                retriever.setDataSource(mediaPath)
                val artwork = retriever.embeddedPicture
                if (artwork == null || artwork.isEmpty()) {
                    runCatching {
                        marker.parentFile?.mkdirs()
                        marker.writeText(signature)
                    }
                    withContext(Dispatchers.Main) { result.success(null) }
                    return@launch
                }
                marker.delete()
                val directory = File(targetStem).parentFile
                if (directory != null && !directory.exists() && !directory.mkdirs()) {
                    throw IllegalStateException("Could not create thumbnail directory")
                }
                val target = File("$targetStem.${imageExtension(artwork)}")
                val temporary = File("${target.path}.tmp")
                temporary.writeBytes(artwork)
                for (ext in listOf("jpg", "png", "webp", "gif")) {
                    val stale = File("$targetStem.$ext")
                    if (stale.path != target.path && stale.exists()) stale.delete()
                }
                if (!temporary.renameTo(target)) {
                    target.writeBytes(artwork)
                    temporary.delete()
                }
                withContext(Dispatchers.Main) { result.success(target.absolutePath) }
            } catch (e: Exception) {
                Log.w(TAG, "Could not extract embedded artwork from $mediaPath: ${e.message}")
                withContext(NonCancellable + Dispatchers.Main) { result.success(null) }
            } finally {
                try {
                    retriever.release()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun noCoverMarker(mediaPath: String): File {
        val digest = MessageDigest.getInstance("SHA-1")
            .digest(mediaPath.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return File(File(context.noBackupFilesDir, "no_cover"), digest)
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
        serviceRequesters.add(this)
        probeCancelSupport()
        DownloadForegroundService.publishState(
            playlistName = playlistName,
            currentTrack = 0,
            totalTracks = 0,
            progress = 0,
            trackTitle = null
        )
        val intent = Intent(context, DownloadForegroundService::class.java).apply {
            action = DownloadForegroundService.ACTION_START
        }
        try {
            ContextCompat.startForegroundService(context, intent)
            result.success(null)
        } catch (e: Exception) {
            // Android 12+ refuses to start a foreground service from the
            // background. The download still runs; it just has no
            // notification.
            Log.w(TAG, "Failed to start download service: ${e.message}")
            result.error("FG_SERVICE_ERROR", e.message, null)
        }
    }

    private fun handleUpdateDownloadServiceProgress(args: Map<*, *>, result: MethodChannel.Result) {
        // Updates go to the running service directly. Starting the service
        // again for every progress line cost a binder call on the main
        // thread each time.
        DownloadForegroundService.publishState(
            playlistName = args["playlistName"] as? String ?: "playlist",
            currentTrack = (args["currentTrack"] as? Number)?.toInt() ?: 0,
            totalTracks = (args["totalTracks"] as? Number)?.toInt() ?: 0,
            progress = (args["progress"] as? Number)?.toInt() ?: 0,
            trackTitle = args["trackTitle"] as? String
        )
        result.success(null)
    }

    private fun handleStopDownloadService(result: MethodChannel.Result) {
        serviceRequesters.remove(this)
        // The foreground and background engines share one service. Keep it (and
        // its wake lock) alive while any engine still has a yt-dlp process or
        // a run in progress.
        if (hasActiveDownloads() || serviceRequesters.isNotEmpty()) {
            Log.i(TAG, "Not stopping download service: another run is active")
            DownloadForegroundService.cancelAvailabilityChanged()
            result.success(null)
            return
        }
        stopDownloadService(context)
        result.success(null)
    }
}

/**
 * Lets a progress value through when its whole percent changed and at least
 * [intervalMs] passed since the last one; 100 always passes once.
 * yt-dlp calls back from a single reader thread per process.
 */
internal class ProgressThrottle(private val intervalMs: Long) {
    private var lastPercent = -1
    private var lastAtMs = 0L

    fun accept(progress: Float): Int? {
        if (progress.isNaN()) return null
        val percent = progress.toInt().coerceIn(0, 100)
        if (percent == lastPercent) return null
        val now = SystemClock.elapsedRealtime()
        if (percent < 100 && lastPercent >= 0 && now - lastAtMs < intervalMs) return null
        lastPercent = percent
        lastAtMs = now
        return percent
    }
}
