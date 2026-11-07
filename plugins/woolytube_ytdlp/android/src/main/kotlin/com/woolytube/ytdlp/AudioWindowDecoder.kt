package com.woolytube.ytdlp

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes a window of a local media file to 16 kHz mono signed 16-bit PCM.
 *
 * Only the requested stretch is decoded; nothing is written back to the file.
 */
object AudioWindowDecoder {
    private const val TARGET_RATE = 16000
    private const val TIMEOUT_US = 10_000L

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
            extractor.selectTrack(trackIndex)
            val startUs = startMs * 1000
            val endUs = (startMs + durationMs) * 1000
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val codec = MediaCodec.createDecoderByType(mime)
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                return drain(codec, extractor, startUs, endUs, durationMs, format)
            } finally {
                try {
                    codec.stop()
                } catch (ignored: Exception) {
                }
                try {
                    codec.release()
                } catch (ignored: Exception) {
                }
            }
        } finally {
            try {
                extractor.release()
            } catch (ignored: Exception) {
            }
        }
    }

    private fun drain(
        codec: MediaCodec,
        extractor: MediaExtractor,
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
        val resampler = LinearResampler(sampleRate, TARGET_RATE)

        while (!outputDone) {
            if (!inputDone) {
                val inputIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inputIndex >= 0) {
                    val buffer = codec.getInputBuffer(inputIndex)!!
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0 || extractor.sampleTime > endUs) {
                        codec.queueInputBuffer(
                            inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                        )
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
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
                        var first = 0
                        var last = mono.size
                        if (info.presentationTimeUs < startUs) {
                            first = ((startUs - info.presentationTimeUs) / frameUs).toInt()
                                .coerceIn(0, mono.size)
                        }
                        val bufferEndUs = info.presentationTimeUs + (mono.size * frameUs).toLong()
                        if (bufferEndUs > endUs) {
                            last = ((endUs - info.presentationTimeUs) / frameUs).toInt()
                                .coerceIn(first, mono.size)
                        }
                        if (last > first) {
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
        return output.toByteArray()
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
