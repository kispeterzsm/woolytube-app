package com.woolytube.ytdlp

import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream

/**
 * Where every audio frame of an MPEG Layer III file starts.
 *
 * Android's MediaExtractor seeks VBR MP3s through the 100-entry Xing table of
 * contents and then labels the frame it lands on with the requested time, which
 * is seconds off on long mixes. With this index the decoder can feed exactly the
 * frames it needs and stamp them with their real times.
 *
 * Built by one sequential pass over the file. Only the byte offsets are kept
 * (4 bytes per frame, under 1 MB per hour of audio); a frame's length is the
 * distance to the next offset, or comes from its header.
 *
 * Pure JVM code (no Android classes) so it can be unit tested on the host.
 */
class Mp3FrameIndex private constructor(
    private val intOffsets: IntArray?,
    private val longOffsets: LongArray?,
    /** Audio frames in the file. A Xing/Info/VBRI frame is not counted. */
    val frameCount: Int,
    val sampleRate: Int,
    val channels: Int,
    /** 1152 for MPEG-1, 576 for MPEG-2 and 2.5. */
    val samplesPerFrame: Int,
    /** Encoder delay in samples from a LAME/Lavc/Lavf tag, or 0 without one. */
    val encoderDelay: Int,
    /** Encoder padding in samples from a LAME/Lavc/Lavf tag, or 0 without one. */
    val encoderPadding: Int,
    /**
     * Whether a LAME, Lavc or Lavf tag supplied [encoderDelay]. FFmpeg (and so
     * libmpv, which plays the file) trims the start only when one is present.
     */
    val hasEncoderTag: Boolean,
    /** "Xing", "Info", "VBRI" or null: the header frame that was skipped. */
    val vbrHeader: String?,
    /** How many times the scan skipped damaged bytes to find the next frame. */
    val resyncCount: Int,
    /**
     * Audio frames before the first resync ([frameCount] without one). In
     * joined files this is the first part, which is all that part's Xing
     * header (and so Android's extractor) counts.
     */
    val leadingRunFrames: Int = frameCount,
) {
    /** Length of the stream in samples per channel, before any trimming. */
    val totalSamples: Long get() = frameCount.toLong() * samplesPerFrame

    /** Untrimmed stream length, as Android's extractor reports it. */
    val durationUs: Long get() = totalSamples * 1_000_000L / sampleRate

    /** Untrimmed length of the frames before the first resync. */
    val leadingRunDurationUs: Long
        get() = leadingRunFrames.toLong() * samplesPerFrame * 1_000_000L / sampleRate

    /**
     * Number of samples FFmpeg drops from the start of the decoded stream: the
     * encoder delay plus the 529-sample MP3 decoder delay, but only when a
     * LAME/Lavc/Lavf tag is present. Sample 0 of the libmpv timeline is the
     * decoder's output sample [ffmpegStartSkip].
     */
    val ffmpegStartSkip: Int get() = if (hasEncoderTag) encoderDelay + MP3_DECODER_DELAY else 0

    /** Byte offset of frame [k]; [k] == [frameCount] gives the end of the last frame. */
    fun frameOffset(k: Int): Long {
        require(k in 0..frameCount) { "frame $k out of 0..$frameCount" }
        return intOffsets?.get(k)?.toLong() ?: longOffsets!![k]
    }

    /**
     * Bytes from the start of frame [k] to the start of the next one. Usually the
     * frame length; larger when damaged bytes were skipped after the frame.
     */
    fun frameSpan(k: Int): Int = (frameOffset(k + 1) - frameOffset(k)).toInt()

    /**
     * Presentation time of frame [k] when the decoder's first output sample of
     * frame 0 is stamped `-shiftSamples`: `(k * spf - shiftSamples) / sampleRate`.
     */
    fun presentationTimeUs(k: Int, shiftSamples: Int): Long =
        Math.floorDiv((k.toLong() * samplesPerFrame - shiftSamples) * 1_000_000L, sampleRate.toLong())

    /**
     * First frame to feed so that [startUs] is decoded with [leadInFrames] frames
     * of warm-up before it. MP3 frames borrow up to 511 bytes from earlier frames
     * (the bit reservoir), and the synthesis filter overlaps one frame, so a
     * decoder that starts at the target frame gets it wrong.
     */
    fun firstFrameToFeed(startUs: Long, shiftSamples: Int, leadInFrames: Int): Int {
        val startSample = Math.floorDiv(startUs * sampleRate, 1_000_000L) + shiftSamples
        val target = Math.floorDiv(startSample, samplesPerFrame.toLong())
        return (target - leadInFrames).coerceIn(0L, frameCount.toLong()).toInt()
    }

    /** Thrown when the file is not something this index can describe. */
    class UnsupportedException(message: String) : IOException(message)

    /** A Layer III frame header. */
    internal class Header(
        /** 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5. */
        val versionBits: Int,
        val sampleRate: Int,
        val bitrateKbps: Int,
        val padding: Int,
        val mono: Boolean,
    ) {
        val isMpeg1: Boolean get() = versionBits == 3
        val samplesPerFrame: Int get() = if (isMpeg1) 1152 else 576
        val frameLength: Int get() = samplesPerFrame / 8 * bitrateKbps * 1000 / sampleRate + padding
        val channels: Int get() = if (mono) 1 else 2

        /** Where a Xing/Info tag sits: after the header and the side information. */
        val xingOffset: Int
            get() = 4 + if (isMpeg1) (if (mono) 17 else 32) else (if (mono) 9 else 17)

        fun sameStream(other: Header): Boolean =
            versionBits == other.versionBits && sampleRate == other.sampleRate && mono == other.mono
    }

    companion object {
        /** Samples of delay the MP3 synthesis filter adds (FFmpeg's 528 + 1). */
        const val MP3_DECODER_DELAY = 529

        /** Largest Layer III frame: 320 kb/s at 32 kHz, padded. */
        internal const val MAX_FRAME_LENGTH = 1441

        /** How far the scan looks for the next frame after damaged bytes. */
        internal const val RESYNC_LIMIT = 64 * 1024

        /** Frames in a row that must parse before a resync is trusted. */
        private const val RESYNC_FRAMES = 3

        private val BITRATES_V1 =
            intArrayOf(0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0)
        private val BITRATES_V2 =
            intArrayOf(0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0)

        /** Sample rates by version bits (index 1 is reserved). */
        private val SAMPLE_RATES = arrayOf(
            intArrayOf(11025, 12000, 8000),
            intArrayOf(0, 0, 0),
            intArrayOf(22050, 24000, 16000),
            intArrayOf(44100, 48000, 32000),
        )

        /** Indexes the MP3 file at [path]. */
        fun build(path: String): Mp3FrameIndex {
            val file = File(path)
            return FileInputStream(file).use { build(it) }
        }

        /**
         * Indexes an MP3 stream read once from start to end. Throws
         * [UnsupportedException] for free-format files or when no Layer III
         * frames are found.
         */
        fun build(input: InputStream): Mp3FrameIndex = Scanner(input, Int.MAX_VALUE.toLong()).scan()

        /** [build] with offsets above [intOffsetLimit] kept as longs (for tests). */
        internal fun build(input: InputStream, intOffsetLimit: Long): Mp3FrameIndex =
            Scanner(input, intOffsetLimit).scan()

        /** Parses a Layer III header, or returns null if [bytes] at [at] is not one. */
        internal fun parseHeader(bytes: ByteArray, at: Int): Header? {
            if (at < 0 || at + 4 > bytes.size) return null
            val b1 = bytes[at].toInt() and 0xff
            val b2 = bytes[at + 1].toInt() and 0xff
            val b3 = bytes[at + 2].toInt() and 0xff
            val b4 = bytes[at + 3].toInt() and 0xff
            if (b1 != 0xff || (b2 and 0xe0) != 0xe0) return null
            val version = (b2 shr 3) and 3
            val layer = (b2 shr 1) and 3
            val bitrateIndex = (b3 shr 4) and 15
            val rateIndex = (b3 shr 2) and 3
            if (version == 1 || layer != 1 || rateIndex == 3) return null
            if (bitrateIndex == 0 || bitrateIndex == 15) return null
            val kbps = (if (version == 3) BITRATES_V1 else BITRATES_V2)[bitrateIndex]
            return Header(
                versionBits = version,
                sampleRate = SAMPLE_RATES[version][rateIndex],
                bitrateKbps = kbps,
                padding = (b3 shr 1) and 1,
                mono = ((b4 shr 6) and 3) == 3,
            )
        }

        /** Whether [bytes] at [at] is a valid Layer III header with a free-format bitrate. */
        internal fun isFreeFormatHeader(bytes: ByteArray, at: Int): Boolean {
            if (at < 0 || at + 4 > bytes.size) return false
            val b2 = bytes[at + 1].toInt() and 0xff
            val b3 = bytes[at + 2].toInt() and 0xff
            if ((bytes[at].toInt() and 0xff) != 0xff || (b2 and 0xe0) != 0xe0) return false
            val version = (b2 shr 3) and 3
            return version != 1 && ((b2 shr 1) and 3) == 1 &&
                ((b3 shr 2) and 3) != 3 && ((b3 shr 4) and 15) == 0
        }

        /** Length of the Layer III frame whose header is at [at], or null. */
        fun frameLengthAt(bytes: ByteArray, at: Int): Int? = parseHeader(bytes, at)?.frameLength

        private fun matches(bytes: ByteArray, at: Int, text: String): Boolean {
            if (at < 0 || at + text.length > bytes.size) return false
            for (i in text.indices) {
                if (bytes[at + i] != text[i].code.toByte()) return false
            }
            return true
        }

        private fun readInt(bytes: ByteArray, at: Int): Int =
            ((bytes[at].toInt() and 0xff) shl 24) or ((bytes[at + 1].toInt() and 0xff) shl 16) or
                ((bytes[at + 2].toInt() and 0xff) shl 8) or (bytes[at + 3].toInt() and 0xff)

        /** Whether a trailing tag (ID3v1, APE or Lyrics3) starts at [at]. */
        private fun isTrailingTag(bytes: ByteArray, at: Int): Boolean =
            matches(bytes, at, "TAG") || matches(bytes, at, "APETAGEX") ||
                matches(bytes, at, "LYRICSBEGIN")

        /** Size of the ID3v2 tag at [at] including its header and footer, or 0. */
        private fun id3v2Size(bytes: ByteArray, at: Int): Int {
            if (!matches(bytes, at, "ID3") || at + 10 > bytes.size) return 0
            var size = 0
            for (i in 6..9) {
                val b = bytes[at + i].toInt() and 0xff
                if (b and 0x80 != 0) return 0
                size = (size shl 7) or b
            }
            val footer = if ((bytes[at + 5].toInt() and 0x10) != 0) 10 else 0
            return 10 + size + footer
        }

        /**
         * What the first frame says about the stream, following FFmpeg's
         * `mp3_parse_vbr_tags` so the timeline matches libmpv's playback.
         */
        internal class VbrInfo(
            /** Whether the frame is a header rather than audio. */
            val isHeaderFrame: Boolean,
            val tag: String?,
            val encoderDelay: Int,
            val encoderPadding: Int,
            val hasEncoderTag: Boolean,
        )

        /** Reads a Xing/Info (with LAME tag) or VBRI header from the frame at [at]. */
        internal fun parseVbrHeader(bytes: ByteArray, at: Int, header: Header): VbrInfo {
            val end = minOf(bytes.size, at + header.frameLength)
            var tag: String? = null
            var hasFrameInfo = false
            var delay = 0
            var padding = 0
            var hasEncoderTag = false

            val xing = at + header.xingOffset
            if (xing + 8 <= end && (matches(bytes, xing, "Xing") || matches(bytes, xing, "Info"))) {
                tag = if (matches(bytes, xing, "Xing")) "Xing" else "Info"
                val flags = readInt(bytes, xing + 4)
                var p = xing + 8
                if (flags and 1 != 0) {
                    if (p + 4 <= end && readInt(bytes, p) != 0) hasFrameInfo = true
                    p += 4
                }
                if (flags and 2 != 0) {
                    if (p + 4 <= end && readInt(bytes, p) != 0) hasFrameInfo = true
                    p += 4
                }
                if (flags and 4 != 0) p += 100
                if (flags and 8 != 0) p += 4
                // LAME extension: 9-byte encoder name, then the delays 12 + 12
                // bits at offset 21. FFmpeg trusts it only from these encoders.
                if (p + 24 <= end &&
                    (matches(bytes, p, "LAME") || matches(bytes, p, "Lavf") || matches(bytes, p, "Lavc"))
                ) {
                    val v = ((bytes[p + 21].toInt() and 0xff) shl 16) or
                        ((bytes[p + 22].toInt() and 0xff) shl 8) or (bytes[p + 23].toInt() and 0xff)
                    delay = v shr 12
                    padding = v and 0xfff
                    hasEncoderTag = true
                }
            }
            // VBRI always sits 32 bytes after the header. FFmpeg reads its frame
            // count but ignores its delay field, so the delay stays 0 here too.
            val vbri = at + 36
            if (vbri + 26 <= end && matches(bytes, vbri, "VBRI") &&
                ((bytes[vbri + 4].toInt() and 0xff) shl 8 or (bytes[vbri + 5].toInt() and 0xff)) == 1
            ) {
                if (tag == null) tag = "VBRI"
                if (readInt(bytes, vbri + 14) != 0 || readInt(bytes, vbri + 10) != 0) hasFrameInfo = true
            }
            return VbrInfo(
                isHeaderFrame = tag != null && hasFrameInfo,
                tag = if (hasFrameInfo) tag else null,
                encoderDelay = delay,
                encoderPadding = padding,
                hasEncoderTag = hasEncoderTag,
            )
        }
    }

    /** Sliding read-ahead window over a stream that is only read forwards. */
    private class Window(private val input: InputStream) {
        var bytes = ByteArray(256 * 1024)
            private set

        /** File offset of `bytes[0]`. */
        var start = 0L
            private set
        private var length = 0
        private var eof = false

        /**
         * Makes `[pos, pos + n)` available in [bytes] (n at most half the buffer)
         * and returns how many of those bytes the stream has.
         */
        fun ensure(pos: Long, n: Int): Int {
            require(pos >= start) { "window only moves forwards" }
            if (pos + n > start + length && !eof) {
                val keep = pos - start
                if (keep < length) {
                    System.arraycopy(bytes, keep.toInt(), bytes, 0, (length - keep).toInt())
                    length -= keep.toInt()
                } else {
                    skipFully(keep - length)
                    length = 0
                }
                start = pos
                while (length < n && !eof) {
                    val read = input.read(bytes, length, bytes.size - length)
                    if (read < 0) eof = true else length += read
                }
                // Past the end, look-ahead reads see zeros, never stale bytes
                // that could pass for a frame header or a tag.
                if (eof) bytes.fill(0, length, bytes.size)
            }
            return (start + length - pos).coerceIn(0L, n.toLong()).toInt()
        }

        /** Index of [pos] in [bytes]; valid after [ensure]. */
        fun at(pos: Long): Int = (pos - start).toInt()

        private fun skipFully(count: Long) {
            var left = count
            while (left > 0) {
                val skipped = input.skip(left)
                if (skipped > 0) {
                    left -= skipped
                } else if (input.read() < 0) {
                    eof = true
                    return
                } else {
                    left--
                }
            }
        }
    }

    private class Scanner(input: InputStream, private val intOffsetLimit: Long) {
        private val window = Window(input)
        private var intOffsets: IntArray? = IntArray(1 shl 14)
        private var longOffsets: LongArray? = null
        private var count = 0
        private var resyncs = 0
        private var leadingRun = -1
        private var sawFreeFormat = false

        fun scan(): Mp3FrameIndex {
            var pos = skipId3v2(0L)
            val afterTags = pos

            // FFmpeg reads a Xing/VBRI header only right after the ID3v2 tags.
            var vbr: VbrInfo? = null
            window.ensure(pos, MAX_FRAME_LENGTH + 4)
            val firstAtStart = parseHeader(window.bytes, window.at(pos))
            if (firstAtStart != null) {
                vbr = parseVbrHeader(window.bytes, window.at(pos), firstAtStart)
            }

            val first = findChain(pos, null, RESYNC_LIMIT)
            if (first == null) {
                throw UnsupportedException(
                    if (sawFreeFormat) "free-format bitrate" else "no MPEG Layer III frames found"
                )
            }
            pos = first
            window.ensure(pos, 4)
            val stream = parseHeader(window.bytes, window.at(pos))!!
            val skipHeaderFrame = first == afterTags && vbr?.isHeaderFrame == true
            if (skipHeaderFrame) pos += stream.frameLength

            while (true) {
                val available = window.ensure(pos, MAX_FRAME_LENGTH + 16)
                if (available < 4) break
                val i = window.at(pos)
                val header = parseHeader(window.bytes, i)
                if (header != null && header.sameStream(stream)) {
                    if (header.frameLength > available) break // cut-off final frame
                    add(pos)
                    pos += header.frameLength
                    continue
                }
                // A trailing tag (ID3v1, APE, Lyrics3) normally ends the audio,
                // but in joined files more frames follow it, and FFmpeg plays
                // those too. Treat it like damaged bytes: stop only when no
                // chain of frames comes after it.
                val tagSize = id3v2Size(window.bytes, i)
                val from = if (tagSize > 0) skipId3v2(pos) else pos + 1
                val next = findChain(from, stream, RESYNC_LIMIT) ?: break
                if (resyncs++ == 0) leadingRun = count
                pos = next
                // The next part of a joined file starts with its own
                // Xing/Info/VBRI frame, which holds no audio; FFmpeg does not
                // play it either.
                window.ensure(pos, MAX_FRAME_LENGTH + 4)
                val partHeader = parseHeader(window.bytes, window.at(pos))
                if (partHeader != null &&
                    parseVbrHeader(window.bytes, window.at(pos), partHeader).isHeaderFrame
                ) {
                    pos += partHeader.frameLength
                }
            }
            add(pos) // end of the last frame
            val frames = count - 1
            if (frames <= 0) throw UnsupportedException("no MPEG Layer III audio frames")
            val tagInfo = vbr?.takeIf { it.hasEncoderTag }
            return Mp3FrameIndex(
                intOffsets = intOffsets?.copyOf(count),
                longOffsets = longOffsets?.copyOf(count),
                frameCount = frames,
                sampleRate = stream.sampleRate,
                channels = stream.channels,
                samplesPerFrame = stream.samplesPerFrame,
                encoderDelay = tagInfo?.encoderDelay ?: 0,
                encoderPadding = tagInfo?.encoderPadding ?: 0,
                hasEncoderTag = tagInfo != null,
                vbrHeader = if (skipHeaderFrame) vbr?.tag else null,
                resyncCount = resyncs,
                leadingRunFrames = if (leadingRun < 0) frames else leadingRun,
            )
        }

        /** Skips consecutive ID3v2 tags starting at [pos]. */
        private fun skipId3v2(pos: Long): Long {
            var p = pos
            while (true) {
                window.ensure(p, 10)
                val size = id3v2Size(window.bytes, window.at(p))
                if (size == 0) return p
                p += size
            }
        }

        /**
         * First position in `[from, from + limit)` where [RESYNC_FRAMES] frames
         * of one stream follow each other (or run into the end of the file or a
         * trailing tag), or null.
         */
        private fun findChain(from: Long, stream: Header?, limit: Int): Long? {
            val lookahead = RESYNC_FRAMES * MAX_FRAME_LENGTH + 16
            var p = from
            while (p < from + limit) {
                val available = window.ensure(p, lookahead)
                if (available < 4) return null
                val i = window.at(p)
                if (window.bytes[i] == 0xff.toByte()) {
                    if (chainAt(i, available, stream)) return p
                    if (stream == null && isFreeFormatHeader(window.bytes, i)) sawFreeFormat = true
                }
                p++
            }
            return null
        }

        private fun chainAt(start: Int, available: Int, stream: Header?): Boolean {
            val bytes = window.bytes
            val first = parseHeader(bytes, start) ?: return false
            if (stream != null && !first.sameStream(stream)) return false
            var at = start
            var header: Header = first
            for (n in 1..RESYNC_FRAMES) {
                at += header.frameLength
                val used = at - start
                if (used == available) return true // ends exactly at end of file
                if (used > available) return false
                if (n == RESYNC_FRAMES) return true
                if (available - used >= 3 && isTrailingTag(bytes, at)) return true
                header = parseHeader(bytes, at) ?: return false
                if (!header.sameStream(first)) return false
            }
            return true
        }

        private fun add(offset: Long) {
            val ints = intOffsets
            if (ints != null && offset > intOffsetLimit) {
                longOffsets = LongArray(ints.size) { ints[it].toLong() }
                intOffsets = null
            }
            val currentInts = intOffsets
            if (currentInts != null) {
                if (count == currentInts.size) intOffsets = currentInts.copyOf(count * 2)
                intOffsets!![count++] = offset.toInt()
            } else {
                val longs = longOffsets!!
                if (count == longs.size) longOffsets = longs.copyOf(count * 2)
                longOffsets!![count++] = offset
            }
        }
    }
}
