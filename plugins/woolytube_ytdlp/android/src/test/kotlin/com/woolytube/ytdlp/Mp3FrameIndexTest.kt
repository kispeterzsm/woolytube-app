package com.woolytube.ytdlp

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class Mp3FrameIndexTest {
    // --- Fixture helpers ---------------------------------------------------

    /** A Layer III frame header; versionBits 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5. */
    private fun header(
        versionBits: Int = 3,
        bitrateIndex: Int = 9,
        rateIndex: Int = 0,
        padding: Int = 0,
        mono: Boolean = false,
        layerBits: Int = 1,
    ): ByteArray = byteArrayOf(
        0xff.toByte(),
        (0xe0 or (versionBits shl 3) or (layerBits shl 1) or 1).toByte(),
        ((bitrateIndex shl 4) or (rateIndex shl 2) or (padding shl 1)).toByte(),
        (if (mono) 0xc0 else 0x40).toByte(),
    )

    /** A whole frame: header plus zero bytes (never a false sync). */
    private fun frame(
        versionBits: Int = 3,
        bitrateIndex: Int = 9,
        rateIndex: Int = 0,
        padding: Int = 0,
        mono: Boolean = false,
    ): ByteArray {
        val h = header(versionBits, bitrateIndex, rateIndex, padding, mono)
        val length = Mp3FrameIndex.parseHeader(h, 0)!!.frameLength
        return h.copyOf(length)
    }

    private fun id3v2(bodySize: Int, footer: Boolean = false): ByteArray {
        val out = ByteArrayOutputStream()
        out.write("ID3".toByteArray())
        out.write(byteArrayOf(4, 0, (if (footer) 0x10 else 0).toByte()))
        out.write(byteArrayOf(
            ((bodySize shr 21) and 0x7f).toByte(),
            ((bodySize shr 14) and 0x7f).toByte(),
            ((bodySize shr 7) and 0x7f).toByte(),
            (bodySize and 0x7f).toByte(),
        ))
        out.write(ByteArray(bodySize))
        if (footer) out.write("3DI".toByteArray() + ByteArray(7))
        return out.toByteArray()
    }

    /**
     * A Xing/Info header frame (MPEG-1 stereo 128 kb/s by default) with frame
     * count and byte count fields, followed by an encoder tag.
     */
    private fun xingFrame(
        tag: String = "Info",
        encoder: String = "LAME3.100",
        delay: Int = 576,
        padding: Int = 960,
        mono: Boolean = false,
        versionBits: Int = 3,
        rateIndex: Int = 0,
        bitrateIndex: Int = 9,
        frameInfo: Boolean = true,
    ): ByteArray {
        val f = frame(versionBits = versionBits, bitrateIndex = bitrateIndex, rateIndex = rateIndex, mono = mono)
        val x = Mp3FrameIndex.parseHeader(f, 0)!!.xingOffset
        tag.toByteArray().copyInto(f, x)
        f[x + 7] = if (frameInfo) 3 else 0 // flags: frames + bytes
        var p = x + 8
        if (frameInfo) {
            f[p + 3] = 100 // frames
            f[p + 7] = 100 // bytes
            p += 8
        }
        encoder.toByteArray().copyInto(f, p)
        val v = (delay shl 12) or padding
        f[p + 21] = (v shr 16).toByte()
        f[p + 22] = (v shr 8).toByte()
        f[p + 23] = v.toByte()
        return f
    }

    private fun vbriFrame(delay: Int = 576): ByteArray {
        val f = frame()
        "VBRI".toByteArray().copyInto(f, 36)
        f[41] = 1 // version 1
        f[42] = (delay shr 8).toByte()
        f[43] = delay.toByte()
        f[49] = 100 // bytes
        f[53] = 100 // frames
        return f
    }

    private fun concat(vararg parts: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        parts.forEach { out.write(it) }
        return out.toByteArray()
    }

    private fun frames(count: Int, make: (Int) -> ByteArray = { frame() }): ByteArray =
        concat(*Array(count) { make(it) })

    private fun build(bytes: ByteArray) = Mp3FrameIndex.build(ByteArrayInputStream(bytes))

    /** Delivers at most [chunk] bytes per read, like a slow stream. */
    private class TrickleStream(bytes: ByteArray, private val chunk: Int) : InputStream() {
        private val inner = ByteArrayInputStream(bytes)
        override fun read(): Int = inner.read()
        override fun read(b: ByteArray, off: Int, len: Int): Int = inner.read(b, off, minOf(len, chunk))
        override fun skip(n: Long): Long = inner.skip(minOf(n, chunk.toLong()))
    }

    // --- Header parsing ----------------------------------------------------

    @Test
    fun parsesMpeg1Header() {
        val h = Mp3FrameIndex.parseHeader(header(bitrateIndex = 9, rateIndex = 0), 0)!!
        assertEquals(44100, h.sampleRate)
        assertEquals(128, h.bitrateKbps)
        assertEquals(1152, h.samplesPerFrame)
        assertEquals(417, h.frameLength) // 144 * 128000 / 44100
        assertEquals(418, Mp3FrameIndex.parseHeader(header(padding = 1), 0)!!.frameLength)
        assertEquals(2, h.channels)
        assertEquals(36, h.xingOffset)
        assertEquals(21, Mp3FrameIndex.parseHeader(header(mono = true), 0)!!.xingOffset)
    }

    @Test
    fun parsesMpeg2AndMpeg25Headers() {
        val v2 = Mp3FrameIndex.parseHeader(header(versionBits = 2, bitrateIndex = 4, rateIndex = 0), 0)!!
        assertEquals(22050, v2.sampleRate)
        assertEquals(32, v2.bitrateKbps)
        assertEquals(576, v2.samplesPerFrame)
        assertEquals(104, v2.frameLength) // 72 * 32000 / 22050
        assertEquals(21, v2.xingOffset)
        assertEquals(13, Mp3FrameIndex.parseHeader(header(versionBits = 2, mono = true), 0)!!.xingOffset)

        val v25 = Mp3FrameIndex.parseHeader(header(versionBits = 0, bitrateIndex = 1, rateIndex = 2), 0)!!
        assertEquals(8000, v25.sampleRate)
        assertEquals(8, v25.bitrateKbps)
        assertEquals(72, v25.frameLength)
    }

    @Test
    fun largestFrameFitsTheConstant() {
        val h = Mp3FrameIndex.parseHeader(header(bitrateIndex = 14, rateIndex = 2, padding = 1), 0)!!
        assertEquals(Mp3FrameIndex.MAX_FRAME_LENGTH, h.frameLength)
    }

    @Test
    fun rejectsInvalidHeaders() {
        assertNull(Mp3FrameIndex.parseHeader(header(versionBits = 1), 0)) // reserved version
        assertNull(Mp3FrameIndex.parseHeader(header(layerBits = 2), 0)) // Layer II
        assertNull(Mp3FrameIndex.parseHeader(header(bitrateIndex = 15), 0))
        assertNull(Mp3FrameIndex.parseHeader(header(rateIndex = 3), 0))
        assertNull(Mp3FrameIndex.parseHeader(header(bitrateIndex = 0), 0))
        assertNull(Mp3FrameIndex.parseHeader(byteArrayOf(0x49, 0x44, 0x33, 4), 0))
        assertNull(Mp3FrameIndex.parseHeader(header(), 1)) // runs past the end
        assertTrue(Mp3FrameIndex.isFreeFormatHeader(header(bitrateIndex = 0), 0))
        assertFalse(Mp3FrameIndex.isFreeFormatHeader(header(), 0))
    }

    // --- Scanning ----------------------------------------------------------

    @Test
    fun indexesPlainCbrStream() {
        val ix = build(frames(20))
        assertEquals(20, ix.frameCount)
        assertEquals(44100, ix.sampleRate)
        assertEquals(2, ix.channels)
        assertEquals(1152, ix.samplesPerFrame)
        for (k in 0..20) assertEquals(417L * k, ix.frameOffset(k))
        assertEquals(417, ix.frameSpan(19))
        assertFalse(ix.hasEncoderTag)
        assertEquals(0, ix.encoderDelay)
        assertEquals(0, ix.ffmpegStartSkip)
        assertNull(ix.vbrHeader)
        assertEquals(0, ix.resyncCount)
        assertEquals(20L * 1152 * 1_000_000 / 44100, ix.durationUs)
    }

    @Test
    fun indexesVariableBitrateFrames() {
        val rates = intArrayOf(1, 5, 9, 14, 3, 11, 7)
        val bytes = frames(rates.size) { frame(bitrateIndex = rates[it], padding = it % 2) }
        val ix = build(bytes)
        assertEquals(rates.size, ix.frameCount)
        var offset = 0L
        for (k in rates.indices) {
            assertEquals(offset, ix.frameOffset(k))
            offset += Mp3FrameIndex.parseHeader(header(bitrateIndex = rates[k], padding = k % 2), 0)!!.frameLength
        }
        assertEquals(bytes.size.toLong(), ix.frameOffset(ix.frameCount))
    }

    @Test
    fun skipsId3v2TagsIncludingFooterAndRepeats() {
        val tags = concat(id3v2(1000, footer = true), id3v2(50))
        val ix = build(concat(tags, frames(5)))
        assertEquals(5, ix.frameCount)
        assertEquals(tags.size.toLong(), ix.frameOffset(0))
    }

    @Test
    fun skipsTagLargerThanTheReadWindow() {
        val tag = id3v2(700_000)
        val ix = Mp3FrameIndex.build(TrickleStream(concat(tag, frames(800)), 1000))
        assertEquals(800, ix.frameCount)
        assertEquals(tag.size.toLong(), ix.frameOffset(0))
        assertEquals(tag.size + 417L * 800, ix.frameOffset(800))
    }

    @Test
    fun readsLameTagAndSkipsInfoFrame() {
        val xing = xingFrame(delay = 576, padding = 960)
        val ix = build(concat(id3v2(10), xing, frames(10)))
        assertEquals(10, ix.frameCount)
        assertEquals("Info", ix.vbrHeader)
        assertEquals(20L + xing.size, ix.frameOffset(0))
        assertTrue(ix.hasEncoderTag)
        assertEquals(576, ix.encoderDelay)
        assertEquals(960, ix.encoderPadding)
        assertEquals(576 + 529, ix.ffmpegStartSkip)
    }

    @Test
    fun acceptsLavcTagOnMonoMpeg2() {
        val xing = xingFrame(tag = "Xing", encoder = "Lavc61.19", delay = 1105, padding = 0,
            mono = true, versionBits = 2, bitrateIndex = 8, rateIndex = 0)
        val ix = build(concat(xing, frames(6) { frame(versionBits = 2, bitrateIndex = 4, mono = true) }))
        assertEquals(6, ix.frameCount)
        assertEquals("Xing", ix.vbrHeader)
        assertEquals(1105, ix.encoderDelay)
        assertEquals(576, ix.samplesPerFrame)
        assertEquals(1, ix.channels)
    }

    @Test
    fun ignoresDelayFromUnknownEncoderLikeFfmpeg() {
        val ix = build(concat(xingFrame(encoder = "GOGO1.00", delay = 576), frames(4)))
        assertEquals(4, ix.frameCount)
        assertEquals("Info", ix.vbrHeader)
        assertFalse(ix.hasEncoderTag)
        assertEquals(0, ix.encoderDelay)
        assertEquals(0, ix.ffmpegStartSkip)
    }

    @Test
    fun keepsXingFrameWithoutFrameInfoAsAudioLikeFfmpeg() {
        val ix = build(concat(xingFrame(frameInfo = false), frames(4)))
        assertEquals(5, ix.frameCount)
        assertNull(ix.vbrHeader)
        assertEquals(576, ix.encoderDelay) // FFmpeg still applies the LAME delay
    }

    @Test
    fun skipsVbriFrameButIgnoresItsDelayLikeFfmpeg() {
        val vbri = vbriFrame(delay = 576)
        val ix = build(concat(vbri, frames(4)))
        assertEquals(4, ix.frameCount)
        assertEquals("VBRI", ix.vbrHeader)
        assertEquals(vbri.size.toLong(), ix.frameOffset(0))
        assertEquals(0, ix.encoderDelay)
        assertFalse(ix.hasEncoderTag)
    }

    @Test
    fun resyncsOverJunkBetweenFrames() {
        val junk = ByteArray(3000) { (it % 200 + 1).toByte() }
        val ix = build(concat(frames(5), junk, frames(5)))
        assertEquals(10, ix.frameCount)
        assertEquals(1, ix.resyncCount)
        assertEquals(417L * 5 + junk.size, ix.frameOffset(5))
        assertEquals(417 + junk.size, ix.frameSpan(4)) // span covers the junk
        val start = ByteArray(8)
        assertNotNull(Mp3FrameIndex.frameLengthAt(header().copyInto(start), 0))
    }

    @Test
    fun skipsFalseSyncInsideJunk() {
        // A lone valid-looking header inside junk must not be taken as a frame.
        val junk = concat(ByteArray(500), header(), ByteArray(500))
        val ix = build(concat(frames(4), junk, frames(4)))
        assertEquals(8, ix.frameCount)
        assertEquals(417L * 4 + junk.size, ix.frameOffset(4))
    }

    @Test
    fun skipsId3v2TagInTheMiddle() {
        val tag = id3v2(100_000)
        val ix = build(concat(frames(3), tag, frames(3)))
        assertEquals(6, ix.frameCount)
        assertEquals(417L * 3 + tag.size, ix.frameOffset(3))
    }

    @Test
    fun stopsWhenNoFrameFollowsJunk() {
        val ix = build(concat(frames(4), ByteArray(Mp3FrameIndex.RESYNC_LIMIT + 10) { 1 }, frames(4)))
        assertEquals(4, ix.frameCount)
        assertEquals(0, ix.resyncCount)
    }

    @Test
    fun ignoresStreamChangesAfterTheFirstFrame() {
        // Frames at another sample rate are not this stream.
        val ix = build(concat(frames(4), frames(4) { frame(rateIndex = 1) }))
        assertEquals(4, ix.frameCount)
    }

    @Test
    fun stopsAtTrailingTags() {
        val id3v1 = concat("TAG".toByteArray(), ByteArray(125) { 0xff.toByte() })
        assertEquals(6, build(concat(frames(6), id3v1)).frameCount)
        val ape = concat("APETAGEX".toByteArray(), ByteArray(200) { 0xff.toByte() })
        val withApe = build(concat(frames(6), ape, id3v1))
        assertEquals(6, withApe.frameCount)
        assertEquals(0, withApe.resyncCount)
        assertEquals(6, build(concat(frames(6), "LYRICSBEGIN".toByteArray(), ByteArray(50))).frameCount)
    }

    @Test
    fun readsOnPastTagsInTheMiddleOfJoinedFiles() {
        // a.mp3 + b.mp3, each ending in an ID3v1 tag: libmpv plays both parts.
        val id3v1 = concat("TAG".toByteArray(), ByteArray(125) { 0x20 })
        val joined = build(concat(frames(5), id3v1, frames(4), id3v1))
        assertEquals(9, joined.frameCount)
        assertEquals(417L * 5 + 128, joined.frameOffset(5))
        assertEquals(417L * 9 + 128, joined.frameOffset(9))
        assertEquals(1, joined.resyncCount)
        assertEquals(5, joined.leadingRunFrames)
        assertEquals(5L * 1152 * 1_000_000 / 44100, joined.leadingRunDurationUs)
        assertEquals(6, build(frames(6)).leadingRunFrames)

        // Each part has its own Info header frame; only the audio counts.
        val parts = build(concat(xingFrame(), frames(5), id3v1, id3v2(300), xingFrame(), frames(4), id3v1))
        assertEquals(9, parts.frameCount)
        assertEquals(5, parts.leadingRunFrames)
        assertEquals(417L * 6 + 128 + 310 + 417, parts.frameOffset(5))

        val ape = concat("APETAGEX".toByteArray(), ByteArray(200) { 0xff.toByte() })
        assertEquals(10, build(concat(frames(6), ape, frames(4))).frameCount)
    }

    @Test
    fun dropsCutOffFinalFrame() {
        val ix = build(concat(frames(6), frame().copyOf(200)))
        assertEquals(6, ix.frameCount)
        assertEquals(417L * 6, ix.frameOffset(6))
    }

    @Test
    fun findsFirstFrameAfterLeadingJunk() {
        val ix = build(concat(ByteArray(1234) { 7 }, frames(3)))
        assertEquals(3, ix.frameCount)
        assertEquals(1234L, ix.frameOffset(0))
    }

    @Test
    fun indexesTinyFiles() {
        assertEquals(1, build(frame()).frameCount)
        assertEquals(2, build(frames(2)).frameCount)
    }

    @Test
    fun handlesSmallReads() {
        val bytes = concat(id3v2(5000), xingFrame(), frames(2000) { frame(bitrateIndex = 1 + it % 14) })
        val whole = build(bytes)
        val trickled = Mp3FrameIndex.build(TrickleStream(bytes, 333))
        assertEquals(2000, trickled.frameCount)
        for (k in 0..2000) assertEquals(whole.frameOffset(k), trickled.frameOffset(k))
    }

    @Test
    fun keepsLongOffsetsPastTheIntLimit() {
        val bytes = frames(100)
        val ix = Mp3FrameIndex.build(ByteArrayInputStream(bytes), 417L * 40)
        assertEquals(100, ix.frameCount)
        for (k in 0..100) assertEquals(417L * k, ix.frameOffset(k))
    }

    @Test
    fun rejectsFreeFormat() {
        try {
            build(frames(5) { header(bitrateIndex = 0).copyOf(400) })
            fail("free format accepted")
        } catch (e: Mp3FrameIndex.UnsupportedException) {
            assertEquals("free-format bitrate", e.message)
        }
    }

    @Test
    fun rejectsNonMp3Data() {
        try {
            build(ByteArray(100_000) { (it * 7).toByte() })
            fail("garbage accepted")
        } catch (e: Mp3FrameIndex.UnsupportedException) {
            assertEquals("no MPEG Layer III frames found", e.message)
        }
        try {
            build(ByteArray(0))
            fail("empty file accepted")
        } catch (e: Mp3FrameIndex.UnsupportedException) {
            // expected
        }
    }

    // --- Timeline ----------------------------------------------------------

    private fun lameIndex(): Mp3FrameIndex {
        // 48 kHz MPEG-1 stereo, LAME delay 576, 3000 frames.
        val xing = xingFrame(delay = 576, padding = 960, rateIndex = 1)
        return build(concat(xing, frames(3000) { frame(rateIndex = 1) }))
    }

    @Test
    fun timelineShiftCountsOnlyTheEncoderDelay() {
        // Android's decoder already drops its own 529 samples; FFmpeg drops
        // delay + 529. Measured on c2.android.mp3.decoder: 0.0 ms against
        // FFmpeg with this shift, +11 ms when the 529 was counted twice.
        assertEquals(529, AudioWindowDecoder.ANDROID_MP3_DECODER_DELAY)
        assertEquals(576, AudioWindowDecoder.mp3TimelineShift(lameIndex()))
        assertEquals(-529, AudioWindowDecoder.mp3TimelineShift(build(frames(5))))
    }

    @Test
    fun computesPresentationTimes() {
        val ix = lameIndex()
        assertEquals(48000, ix.sampleRate)
        assertEquals(-12_000L, ix.presentationTimeUs(0, 576))
        assertEquals(228_000L, ix.presentationTimeUs(10, 576))
        assertEquals(24_000L * 100, ix.presentationTimeUs(100, 0))
    }

    @Test
    fun picksFirstFrameWithLeadIn() {
        val ix = lameIndex()
        // 30 s = sample 1 440 000, + 576 delay = frame 1250.5 -> 1250, minus 10.
        assertEquals(1240, ix.firstFrameToFeed(30_000_000L, 576, 10))
        assertEquals(1250, ix.firstFrameToFeed(30_000_000L, 576, 0))
        assertEquals(0, ix.firstFrameToFeed(0L, 576, 10))
        assertEquals(0, ix.firstFrameToFeed(100_000L, -529, 10))
        assertEquals(3000, ix.firstFrameToFeed(10_000_000_000L, 576, 10))
        // The frame picked with no lead-in contains the start sample.
        for (startUs in longArrayOf(1_000L, 23_999L, 24_000L, 1_234_567L, 61_000_000L)) {
            val k = ix.firstFrameToFeed(startUs, 576, 0)
            assertTrue(ix.presentationTimeUs(k, 576) <= startUs)
            assertTrue(ix.presentationTimeUs(k + 1, 576) > startUs)
        }
    }
}
