package com.woolytube.ytdlp

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Decodes a window of a local media file to 16 kHz mono signed 16-bit PCM.
 *
 * Only the requested stretch is decoded; nothing is written back to the file.
 */
object AudioWindowDecoder {
    private const val TAG = "AudioWindowDecoder"
    private const val TARGET_RATE = 16000
    private const val TIMEOUT_US = 10_000L

    /**
     * Input queued past the end of the window, so the decoder's output (which
     * lags its input) covers the window to its last sample.
     */
    private const val LEAD_OUT_US = 100_000L

    /**
     * MP3 frames decoded before the window. A frame can borrow up to 511 bytes
     * from earlier frames (about 6 frames at 32 kb/s and 48 kHz), plus one frame
     * of filter overlap; costs about 0.24 s of extra decoding at 48 kHz.
     */
    private const val MP3_LEAD_IN_FRAMES = 10

    /**
     * Samples Android's MP3 decoder (c2.android.mp3.decoder) drops from its first
     * output after a start: its own synthesis delay. With this, windows of mix5
     * matched an FFmpeg decode to 0.0 ms; counting it twice gave +11 ms.
     */
    internal const val ANDROID_MP3_DECODER_DELAY = Mp3FrameIndex.MP3_DECODER_DELAY

    /** Index and extractor durations further apart than this mean the scan went wrong. */
    private const val MAX_INDEX_DURATION_MISMATCH_US = 2_000_000L

    /** MP3 indexes kept in memory (under 1 MB per hour of audio each). */
    private const val MP3_INDEX_CACHE_SIZE = 3

    /**
     * Longest window one call decodes. The PCM is held in memory (32 KB per
     * second); the Dart side asks for 12 s fingerprint windows and silence
     * chunks of about a minute.
     */
    const val MAX_WINDOW_MS = 5 * 60 * 1000L

    fun probeDurationMs(path: String): Long {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            return retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
        } finally {
            retriever.release()
        }
    }

    fun decodeWindow(path: String, startMs: Long, durationMs: Long): ByteArray {
        require(durationMs in 1..MAX_WINDOW_MS) { "durationMs $durationMs out of range" }
        val startUs = startMs * 1000
        val endUs = (startMs + durationMs) * 1000
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val candidate = extractor.getTrackFormat(i)
                if (candidate.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    trackIndex = i
                    format = candidate
                    break
                }
            }
            if (trackIndex < 0 || format == null) {
                throw IllegalArgumentException("No audio track in $path")
            }
            val mime = format.getString(MediaFormat.KEY_MIME)!!

            if (mime == MediaFormat.MIMETYPE_AUDIO_MPEG) {
                val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                    format.getLong(MediaFormat.KEY_DURATION)
                } else {
                    -1L
                }
                // An indexed file is decoded exactly or not at all: falling
                // back here would hand out audio from seconds away, which the
                // caller would store as exact. A failure is reported instead.
                val index = mp3Index(path, durationUs)
                if (index != null) {
                    return decodeMp3(path, index, startUs, endUs, durationMs)
                }
            }

            extractor.selectTrack(trackIndex)
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val codec = MediaCodec.createDecoderByType(mime)
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                // Only Android's Ogg extractor takes the pre-skip off its
                // timestamps; its Matroska extractor passes block times through
                // (raw, pre-skip included), which already line up with what a
                // freshly started decoder outputs.
                val restartTrimUs =
                    if (mime == MediaFormat.MIMETYPE_AUDIO_OPUS && isOggFile(path)) {
                        opusPreSkipUs(format)
                    } else {
                        0L
                    }
                val input = ExtractorInput(extractor, endUs + LEAD_OUT_US, restartTrimUs)
                return drain(codec, input, startUs, endUs, durationMs, format)
            } finally {
                stopAndRelease(codec)
            }
        } finally {
            try {
                extractor.release()
            } catch (ignored: Exception) {
            }
        }
    }

    /**
     * Decodes an MP3 window from frames read at the offsets in [index], stamped
     * with their real times, instead of trusting MediaExtractor's seek.
     */
    private fun decodeMp3(
        path: String,
        index: Mp3FrameIndex,
        startUs: Long,
        endUs: Long,
        durationMs: Long
    ): ByteArray {
        val shift = mp3TimelineShift(index)
        val firstFrame = index.firstFrameToFeed(startUs, shift, MP3_LEAD_IN_FRAMES)
        // Only rate and channels: the extractor's encoder-delay/padding keys
        // would make the decoder trim again.
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_MPEG, index.sampleRate, index.channels
        )
        Mp3FrameInput(path, index, firstFrame, shift, endUs + LEAD_OUT_US).use { input ->
            val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_MPEG)
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                return drain(codec, input, startUs, endUs, durationMs, format)
            } finally {
                stopAndRelease(codec)
            }
        }
    }

    /**
     * Samples to subtract from `frame * samplesPerFrame` to get the time of a
     * frame's first decoded sample on libmpv's timeline. FFmpeg drops
     * [Mp3FrameIndex.ffmpegStartSkip] samples from the start; Android's decoder
     * has already dropped its own [ANDROID_MP3_DECODER_DELAY] from its first
     * output after a start.
     */
    internal fun mp3TimelineShift(index: Mp3FrameIndex): Int =
        index.ffmpegStartSkip - ANDROID_MP3_DECODER_DELAY

    private data class Mp3IndexKey(val path: String, val length: Long, val modified: Long)

    /**
     * The last few MP3 indexes, keyed so that a re-downloaded file is indexed
     * again. A null value means the file's content cannot be indexed, so
     * MediaExtractor seeking (the best there is for it) is used. Values are
     * lazy so that parallel window decodes of one file share a single scan; a
     * scan that fails to read the file is not stored, and the next decode
     * tries again.
     */
    private val mp3Indexes =
        object : LinkedHashMap<Mp3IndexKey, Lazy<Mp3FrameIndex?>>(MP3_INDEX_CACHE_SIZE + 1, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Mp3IndexKey, Lazy<Mp3FrameIndex?>>?) =
                size > MP3_INDEX_CACHE_SIZE
        }

    /**
     * The index of the MP3 at [path], null when its content cannot be indexed
     * (decoded through MediaExtractor then). Throws when the file could not be
     * read, rather than settling for inexact seeking.
     */
    private fun mp3Index(path: String, extractorDurationUs: Long): Mp3FrameIndex? {
        val file = File(path)
        val key = Mp3IndexKey(file.absolutePath, file.length(), file.lastModified())
        val entry = synchronized(mp3Indexes) {
            mp3Indexes.getOrPut(key) {
                lazy(LazyThreadSafetyMode.SYNCHRONIZED) { buildMp3Index(file, extractorDurationUs) }
            }
        }
        return entry.value
    }

    private fun buildMp3Index(file: File, extractorDurationUs: Long): Mp3FrameIndex? {
        val started = System.nanoTime()
        val index = try {
            Mp3FrameIndex.build(file.path)
        } catch (e: Mp3FrameIndex.UnsupportedException) {
            Log.w(TAG, "Cannot index ${file.name} (${e.message}); using MediaExtractor seeking")
            return null
        }
        // Any other failure (a read error) propagates: the lazy value stays
        // unset, so the next decode scans again.
        val tookMs = (System.nanoTime() - started) / 1_000_000
        // In joined files (a.mp3 + b.mp3) the extractor goes by the first
        // part's Xing header, so its length is that of the frames before the
        // first resync; FFmpeg, like the index, plays on through every part.
        if (extractorDurationUs > 0 &&
            abs(index.durationUs - extractorDurationUs) > MAX_INDEX_DURATION_MISMATCH_US &&
            (index.resyncCount == 0 ||
                abs(index.leadingRunDurationUs - extractorDurationUs) > MAX_INDEX_DURATION_MISMATCH_US)
        ) {
            Log.w(
                TAG,
                "MP3 index of ${file.name} lasts ${index.durationUs / 1000} ms but MediaExtractor " +
                    "says ${extractorDurationUs / 1000} ms; using MediaExtractor seeking"
            )
            return null
        }
        Log.i(
            TAG,
            "Indexed ${index.frameCount} MP3 frames of ${file.name} in $tookMs ms " +
                "(${index.vbrHeader ?: "no VBR header"}, delay ${index.encoderDelay}" +
                (if (index.hasEncoderTag) "" else " untagged") +
                ", ${index.resyncCount} resyncs)"
        )
        return index
    }

    private fun stopAndRelease(codec: MediaCodec) {
        try {
            codec.stop()
        } catch (ignored: Exception) {
        }
        try {
            codec.release()
        } catch (ignored: Exception) {
        }
    }

    /** Supplies compressed input to the decoder. */
    private interface CodecInput {
        /** Fills input buffer [bufferIndex]; returns false once end of stream was queued. */
        fun queue(codec: MediaCodec, bufferIndex: Int): Boolean

        /** Correction added to every output timestamp. */
        val outputTimeOffsetUs: Long
            get() = 0L
    }

    /**
     * Opus pre-skip from the OpusHead in csd-0, in microseconds (Opus always
     * decodes at 48 kHz), or 0 if the header is missing.
     */
    private fun opusPreSkipUs(format: MediaFormat): Long {
        val csd = format.getByteBuffer("csd-0")?.duplicate() ?: return 0L
        if (csd.remaining() < 12) return 0L
        val head = ByteArray(12)
        csd.get(head)
        if (String(head, 0, 8, Charsets.US_ASCII) != "OpusHead") return 0L
        val preSkip = (head[10].toInt() and 0xff) or ((head[11].toInt() and 0xff) shl 8)
        return preSkip * 1_000_000L / 48_000
    }

    /** Whether the file starts with an Ogg page ("OggS"). */
    private fun isOggFile(path: String): Boolean = try {
        FileInputStream(path).use { stream ->
            val magic = ByteArray(4)
            var read = 0
            while (read < magic.size) {
                val n = stream.read(magic, read, magic.size - read)
                if (n < 0) break
                read += n
            }
            read == magic.size && String(magic, Charsets.US_ASCII) == "OggS"
        }
    } catch (e: IOException) {
        false
    }

    /**
     * Samples straight from MediaExtractor, up to [stopUs].
     *
     * [restartTrimUs] is audio the decoder drops from its first output whenever
     * it starts, without moving the timestamps: c2.android.opus.decoder drops the
     * Opus pre-skip again after every seek, so everything it returns is labelled
     * that much too early (+6.5 ms for the usual 312 samples) when the extractor
     * has taken the pre-skip off its timestamps, as the Ogg one does. At the true
     * start of the stream the extractor's timestamps already allow for it.
     */
    private class ExtractorInput(
        private val extractor: MediaExtractor,
        private val stopUs: Long,
        private val restartTrimUs: Long
    ) : CodecInput {
        private var firstTimeUs: Long? = null

        override val outputTimeOffsetUs: Long
            get() = if ((firstTimeUs ?: 0L) > 0L) restartTrimUs else 0L

        override fun queue(codec: MediaCodec, bufferIndex: Int): Boolean {
            val buffer = codec.getInputBuffer(bufferIndex)!!
            val size = extractor.readSampleData(buffer, 0)
            val timeUs = extractor.sampleTime
            if (size < 0 || timeUs > stopUs) {
                codec.queueInputBuffer(bufferIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                return false
            }
            if (firstTimeUs == null) firstTimeUs = timeUs
            codec.queueInputBuffer(bufferIndex, 0, size, timeUs, 0)
            extractor.advance()
            return true
        }
    }

    /** MP3 frames read in order from the offsets in an [Mp3FrameIndex]. */
    private class Mp3FrameInput(
        path: String,
        private val frames: Mp3FrameIndex,
        firstFrame: Int,
        private val shiftSamples: Int,
        private val stopUs: Long
    ) : CodecInput, Closeable {
        private val file = FileInputStream(path)
        private val stream: DataInputStream
        private var frame = firstFrame
        private var scratch = ByteArray(Mp3FrameIndex.MAX_FRAME_LENGTH)

        init {
            try {
                file.channel.position(frames.frameOffset(firstFrame))
                stream = DataInputStream(BufferedInputStream(file, 64 * 1024))
            } catch (e: Exception) {
                file.close()
                throw e
            }
        }

        override fun queue(codec: MediaCodec, bufferIndex: Int): Boolean {
            val timeUs = frames.presentationTimeUs(frame, shiftSamples)
            if (frame >= frames.frameCount || timeUs > stopUs) {
                codec.queueInputBuffer(bufferIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                return false
            }
            // The span runs to the next frame and can include damaged bytes the
            // index skipped; only the frame itself goes to the decoder.
            val span = frames.frameSpan(frame)
            if (span > scratch.size) scratch = ByteArray(span)
            stream.readFully(scratch, 0, span)
            val length = Mp3FrameIndex.frameLengthAt(scratch, 0)
                ?: throw IOException("No MP3 frame header at frame $frame; the file changed?")
            val size = minOf(length, span)
            val buffer = codec.getInputBuffer(bufferIndex)!!
            buffer.clear()
            if (size > buffer.remaining()) {
                throw IOException("MP3 frame of $size bytes does not fit the decoder's input buffer")
            }
            buffer.put(scratch, 0, size)
            codec.queueInputBuffer(bufferIndex, 0, size, timeUs, 0)
            frame++
            return true
        }

        override fun close() {
            file.close()
        }
    }

    private fun drain(
        codec: MediaCodec,
        input: CodecInput,
        startUs: Long,
        endUs: Long,
        durationMs: Long,
        inputFormat: MediaFormat
    ): ByteArray {
        // Sized for the whole window up front (2 bytes per 16 kHz sample),
        // so the buffer does not grow by doubling.
        val output = ByteArrayOutputStream((durationMs * TARGET_RATE / 1000 * 2).toInt() + 1024)
        val info = MediaCodec.BufferInfo()
        var sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var pcmFloat = false
        var inputDone = false
        var outputDone = false
        var wroteAny = false
        val resampler = LinearResampler(sampleRate, TARGET_RATE)

        while (!outputDone) {
            if (!inputDone) {
                val inputIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inputIndex >= 0) {
                    inputDone = !input.queue(codec, inputIndex)
                }
            }
            val outputIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            when {
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val outputFormat = codec.outputFormat
                    sampleRate = outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    pcmFloat = outputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) ==
                        android.media.AudioFormat.ENCODING_PCM_FLOAT
                    resampler.reset(sampleRate)
                }
                outputIndex >= 0 -> {
                    val buffer = codec.getOutputBuffer(outputIndex)!!
                    if (info.size > 0) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val mono = toMono(buffer, channels, pcmFloat)
                        // Trim decoded audio that precedes the requested start
                        // (the seek lands on an earlier sync frame) or follows
                        // the end.
                        val frameUs = 1_000_000.0 / sampleRate
                        val timeUs = info.presentationTimeUs + input.outputTimeOffsetUs
                        var first = 0
                        var last = mono.size
                        if (timeUs < startUs) {
                            first = ((startUs - timeUs) / frameUs).toInt().coerceIn(0, mono.size)
                        }
                        val bufferEndUs = timeUs + (mono.size * frameUs).toLong()
                        if (bufferEndUs > endUs) {
                            last = ((endUs - timeUs) / frameUs).toInt().coerceIn(first, mono.size)
                        }
                        if (last > first) {
                            if (!wroteAny) {
                                wroteAny = true
                                // The caller reads sample 0 as startUs, so a
                                // late first sample (an untagged MP3 at time 0
                                // starts 11 ms in) gets silence in front.
                                val gapUs = timeUs + first * frameUs - startUs
                                val gap = (gapUs * TARGET_RATE / 1_000_000.0).roundToInt()
                                    .coerceAtMost((durationMs * TARGET_RATE / 1000).toInt())
                                repeat(gap) {
                                    output.write(0)
                                    output.write(0)
                                }
                            }
                            resampler.push(mono, first, last, output)
                        }
                    }
                    codec.releaseOutputBuffer(outputIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                }
            }
        }
        // Resampling odd rates (11025 Hz) can round one sample over the window.
        val pcm = output.toByteArray()
        val maxBytes = (durationMs * TARGET_RATE / 1000 * 2).toInt()
        return if (pcm.size > maxBytes) pcm.copyOf(maxBytes) else pcm
    }

    private fun toMono(buffer: ByteBuffer, channels: Int, pcmFloat: Boolean): FloatArray {
        val ordered = buffer.order(ByteOrder.nativeOrder())
        val frameCount: Int
        val mono: FloatArray
        if (pcmFloat) {
            val floats = ordered.asFloatBuffer()
            frameCount = floats.remaining() / channels
            mono = FloatArray(frameCount)
            for (frame in 0 until frameCount) {
                var sum = 0f
                for (c in 0 until channels) sum += floats.get(frame * channels + c)
                mono[frame] = sum / channels
            }
        } else {
            val shorts = ordered.asShortBuffer()
            frameCount = shorts.remaining() / channels
            mono = FloatArray(frameCount)
            for (frame in 0 until frameCount) {
                var sum = 0f
                for (c in 0 until channels) sum += shorts.get(frame * channels + c) / 32768f
                mono[frame] = sum / channels
            }
        }
        return mono
    }

    /** Linear interpolation resampler writing little-endian 16-bit output. */
    private class LinearResampler(private var sourceRate: Int, private val targetRate: Int) {
        private var position = 0.0
        private var previous = 0f
        private var hasPrevious = false

        fun reset(rate: Int) {
            sourceRate = rate
            position = 0.0
            hasPrevious = false
        }

        fun push(mono: FloatArray, first: Int, last: Int, output: ByteArrayOutputStream) {
            val step = sourceRate.toDouble() / targetRate
            // Work on a virtual array that starts with the carried sample.
            val count = last - first
            if (count <= 0) return
            val samples = FloatArray(count + 1)
            samples[0] = if (hasPrevious) previous else mono[first]
            System.arraycopy(mono, first, samples, 1, count)
            val maxIndex = samples.size - 1
            while (position < maxIndex) {
                val index = position.toInt()
                val fraction = (position - index).toFloat()
                val value = samples[index] + (samples[index + 1] - samples[index]) * fraction
                val pcm = (value * 32767f).toInt().coerceIn(-32768, 32767)
                output.write(pcm and 0xff)
                output.write((pcm shr 8) and 0xff)
                position += step
            }
            position -= maxIndex
            previous = samples[maxIndex]
            hasPrevious = true
        }
    }
}
