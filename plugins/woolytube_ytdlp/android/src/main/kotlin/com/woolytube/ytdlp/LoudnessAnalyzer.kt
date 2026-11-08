package com.woolytube.ytdlp

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.nio.ByteOrder

/**
 * Measures the loudness of a local media file's first audio track. All of it
 * is decoded at its own rate and channel count and streamed through a
 * [LoudnessMeter], so memory stays flat however long the file is.
 *
 * [AudioWindowDecoder]'s 16 kHz mono output is not used: it reads 3 to 5 dB
 * low, by an amount that differs from track to track.
 */
object LoudnessAnalyzer {
    private const val TAG = "LoudnessAnalyzer"
    private const val TIMEOUT_US = 10_000L

    /** A decoder that neither takes input nor gives output this long is stuck. */
    private const val STALL_TIMEOUT_US = 10_000_000L

    /**
     * Measures [path] on the calling thread, at background priority so that
     * playback and the UI keep their cores. [checkCancelled] runs between
     * decoder buffers and may throw to stop early.
     */
    fun analyze(path: String, checkCancelled: () -> Unit = {}): LoudnessMeter.Result {
        val previousPriority = Process.getThreadPriority(Process.myTid())
        setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        try {
            return measure(path, checkCancelled)
        } finally {
            setThreadPriority(previousPriority)
        }
    }

    private fun setThreadPriority(priority: Int) {
        try {
            Process.setThreadPriority(priority)
        } catch (e: Exception) {
            Log.w(TAG, "Cannot set thread priority $priority", e)
        }
    }

    private fun measure(path: String, checkCancelled: () -> Unit): LoudnessMeter.Result {
        val started = SystemClock.elapsedRealtime()
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
            extractor.selectTrack(trackIndex)
            val codec = createDecoder(mime, format)
            try {
                codec.start()
                val result = drain(codec, extractor, format, checkCancelled)
                Log.i(
                    TAG,
                    "Measured ${File(path).name} in ${SystemClock.elapsedRealtime() - started} ms: " +
                        "I ${result.integratedLufs} LUFS, cabin ${result.cabinLufs} LUFS, " +
                        "peak ${result.peakDb} dBFS, ${result.durationMs} ms of $mime"
                )
                return result
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
     * A decoder configured for float output where it accepts that: 16-bit
     * output clips at full scale, so a loud master's peak would read 0 dBFS
     * and its loudness a little low. A decoder that refuses float is
     * configured again for 16-bit.
     */
    private fun createDecoder(mime: String, format: MediaFormat): MediaCodec {
        if (mime == MediaFormat.MIMETYPE_AUDIO_RAW) {
            // WAV, and FLAC through Android's own extractor, arrive as raw PCM
            // in the encoding the extractor states. The raw "decoder" passes
            // the bytes through, so asking it for float would only relabel
            // 16-bit samples as float.
            val raw = MediaCodec.createDecoderByType(mime)
            try {
                raw.configure(format, null, null, 0)
                return raw
            } catch (e: Throwable) {
                raw.release()
                throw e
            }
        }
        format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_FLOAT)
        val codec = MediaCodec.createDecoderByType(mime)
        try {
            codec.configure(format, null, null, 0)
            return codec
        } catch (e: Exception) {
            Log.i(TAG, "$mime decoder refused float output (${e.message}); using 16-bit")
            codec.release()
        }
        // MediaFormat.removeKey needs API 29, so 16-bit is asked for by name.
        format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        val fallback = MediaCodec.createDecoderByType(mime)
        try {
            fallback.configure(format, null, null, 0)
            return fallback
        } catch (e: Throwable) {
            fallback.release()
            throw e
        }
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

    private fun drain(
        codec: MediaCodec,
        extractor: MediaExtractor,
        inputFormat: MediaFormat,
        checkCancelled: () -> Unit
    ): LoudnessMeter.Result {
        val info = MediaCodec.BufferInfo()
        var channels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val meter = LoudnessMeter(inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE), channels)
        var pcmFloat = false

        fun useOutputFormat(outputFormat: MediaFormat) {
            val encoding = if (outputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
            } else {
                AudioFormat.ENCODING_PCM_16BIT
            }
            pcmFloat = when (encoding) {
                AudioFormat.ENCODING_PCM_FLOAT -> true
                AudioFormat.ENCODING_PCM_16BIT -> false
                else -> throw IllegalStateException("Unsupported PCM encoding $encoding")
            }
            if (outputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE) &&
                outputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)
            ) {
                channels = outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                meter.setFormat(outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE), channels)
            }
        }

        // The configured output format already says whether float output was
        // accepted; a format change before the first buffer may revise it.
        useOutputFormat(codec.outputFormat)
        var floats = FloatArray(0)
        var shorts = ShortArray(0)
        var inputDone = false
        var idleUs = 0L

        while (true) {
            checkCancelled()
            // All the input the decoder takes is queued without waiting; only
            // the output is waited for, so neither side idles on a timeout.
            var queued = false
            while (!inputDone) {
                val inputIndex = codec.dequeueInputBuffer(0)
                if (inputIndex < 0) break
                val buffer = codec.getInputBuffer(inputIndex)!!
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) {
                    codec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                } else {
                    codec.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
                    extractor.advance()
                }
                queued = true
            }
            val outputIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            when {
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    idleUs = 0L
                    useOutputFormat(codec.outputFormat)
                }
                outputIndex >= 0 -> {
                    idleUs = 0L
                    if (info.size > 0) {
                        val buffer = codec.getOutputBuffer(outputIndex)!!
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        buffer.order(ByteOrder.nativeOrder())
                        val samples: Int
                        if (pcmFloat) {
                            val view = buffer.asFloatBuffer()
                            samples = view.remaining()
                            if (floats.size < samples) floats = FloatArray(samples)
                            view.get(floats, 0, samples)
                        } else {
                            val view = buffer.asShortBuffer()
                            samples = view.remaining()
                            if (shorts.size < samples) shorts = ShortArray(samples)
                            if (floats.size < samples) floats = FloatArray(samples)
                            view.get(shorts, 0, samples)
                            for (i in 0 until samples) floats[i] = shorts[i] / 32768f
                        }
                        meter.feed(floats, samples / channels)
                    }
                    codec.releaseOutputBuffer(outputIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
                queued -> idleUs = 0L
                else -> {
                    // A stuck decoder would otherwise hold the analysis lock
                    // for good.
                    idleUs += TIMEOUT_US
                    if (idleUs >= STALL_TIMEOUT_US) {
                        throw IllegalStateException("Decoder stalled")
                    }
                }
            }
        }
        return meter.result()
    }
}
