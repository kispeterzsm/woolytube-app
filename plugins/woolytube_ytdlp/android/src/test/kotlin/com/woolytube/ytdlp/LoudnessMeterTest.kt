package com.woolytube.ytdlp

import kotlin.math.PI
import kotlin.math.log10
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class LoudnessMeterTest {
    // --- Fixture helpers ---------------------------------------------------

    /**
     * A sine of [amplitude] in every channel, interleaved. [startFrame] keeps
     * the phase running across consecutive pieces.
     */
    private fun sine(
        rate: Int,
        channels: Int,
        seconds: Double,
        hz: Double,
        amplitude: Double = 0.1,
        startFrame: Int = 0,
    ): FloatArray {
        val frames = Math.round(seconds * rate).toInt()
        val out = FloatArray(frames * channels)
        for (f in 0 until frames) {
            val value = (amplitude * sin(2 * PI * hz * (startFrame + f) / rate)).toFloat()
            for (c in 0 until channels) out[f * channels + c] = value
        }
        return out
    }

    /** Feeds [samples] the way a decoder hands them over, in 4096-frame buffers. */
    private fun LoudnessMeter.feedInBuffers(samples: FloatArray, channels: Int) {
        val buffer = FloatArray(4096 * channels)
        var offset = 0
        while (offset < samples.size) {
            val count = minOf(buffer.size, samples.size - offset)
            System.arraycopy(samples, offset, buffer, 0, count)
            feed(buffer, count / channels)
            offset += count
        }
    }

    private fun measure(rate: Int, channels: Int, vararg pieces: FloatArray): LoudnessMeter.Result {
        val meter = LoudnessMeter(rate, channels)
        for (piece in pieces) meter.feedInBuffers(piece, channels)
        return meter.result()
    }

    // --- Calibration -------------------------------------------------------

    @Test
    fun stereoSineAtMinus20DbfsReadsMinus20Lufs() {
        for (rate in intArrayOf(48_000, 44_100)) {
            val result = measure(rate, 2, sine(rate, 2, 10.0, 997.0))
            assertEquals("at $rate Hz", -20.0, result.integratedLufs!!, 0.1)
            assertEquals("at $rate Hz", -20.0, result.peakDb!!, 0.01)
            assertEquals(10_000L, result.durationMs)
        }
    }

    @Test
    fun monoReadsLikeMpvsStereoUpmix() {
        // mpv plays a mono file on both ears at -3 dB each (power kept), so
        // the mono signal reads 3 dB below the same signal at full level in
        // both channels.
        val stereo = measure(48_000, 2, sine(48_000, 2, 10.0, 997.0))
        val mono = measure(48_000, 1, sine(48_000, 1, 10.0, 997.0))
        val upmixGainDb = 10.0 * log10(2.0)
        assertEquals(stereo.integratedLufs!! - upmixGainDb, mono.integratedLufs!!, 1e-9)
        assertEquals(stereo.cabinLufs!! - upmixGainDb, mono.cabinLufs!!, 1e-9)
        assertEquals(stereo.peakDb!!, mono.peakDb!!, 1e-9)
    }

    @Test
    fun silenceHasNoLoudnessAndNoPeak() {
        val result = measure(48_000, 2, FloatArray(48_000 * 2 * 10))
        assertNull(result.integratedLufs)
        assertNull(result.cabinLufs)
        assertNull(result.peakDb)
        assertEquals(10_000L, result.durationMs)
    }

    @Test
    fun underFourHundredMillisecondsHasNoLoudness() {
        val result = measure(48_000, 2, sine(48_000, 2, 0.399, 997.0))
        assertNull(result.integratedLufs)
        assertNull(result.cabinLufs)
        assertEquals(-20.0, result.peakDb!!, 0.01)
        assertEquals(399L, result.durationMs)
    }

    @Test
    fun fullScaleSquarePeaksAtZeroDbfs() {
        val rate = 48_000
        val square = FloatArray(rate * 2) { i -> if ((i / 2) % 48 < 24) 1f else -1f }
        val result = measure(rate, 2, square)
        assertEquals(0.0, result.peakDb!!, 1e-12)
    }

    // --- Cabin loudness ----------------------------------------------------

    @Test
    fun cabinHighPassCutsBassButNotMidrange() {
        // A second-order Butterworth high-pass at 300 Hz is -19.1 dB at 100 Hz.
        val bass = measure(48_000, 2, sine(48_000, 2, 10.0, 100.0))
        assertEquals(-19.1, bass.cabinLufs!! - bass.integratedLufs!!, 0.5)
        val mid = measure(48_000, 2, sine(48_000, 2, 10.0, 1000.0))
        assertEquals(0.0, mid.cabinLufs!! - mid.integratedLufs!!, 0.2)
    }

    // --- Gating ------------------------------------------------------------

    @Test
    fun relativeGateDropsTheQuietHalf() {
        val rate = 48_000
        val tenSeconds = 10 * rate
        val tone = sine(rate, 2, 10.0, 997.0)
        val quiet = sine(rate, 2, 10.0, 997.0, amplitude = 0.001, startFrame = tenSeconds)
        val toneAlone = measure(rate, 2, tone).integratedLufs!!
        val result = measure(rate, 2, tone, quiet)
        // 200 hops make 197 blocks. 97 are all tone; 3 straddle the change
        // with 3, 2 and 1 hops of tone (all within 10 LU of the -23 LUFS
        // ungated mean); 97 are all quiet (-60 LUFS) and gated out. Quiet
        // hops are 1e-4 of a tone hop's power.
        val gatedMean = (97 + 0.75 + 0.5 + 0.25 + 1.5e-4) / 100
        val expected = toneAlone + 10 * log10(gatedMean)
        assertEquals(expected, result.integratedLufs!!, 0.1)
        // The ungated mean would be about 3 dB lower.
        assertEquals(-20.07, result.integratedLufs!!, 0.1)
    }

    // --- Format handling ---------------------------------------------------

    @Test
    fun sampleRateChangeMidStreamKeepsTheMeasurement() {
        val meter = LoudnessMeter(44_100, 2)
        meter.feedInBuffers(sine(44_100, 2, 5.05, 997.0), 2)
        meter.setFormat(48_000, 2)
        meter.feedInBuffers(sine(48_000, 2, 4.95, 997.0), 2)
        val result = meter.result()
        assertEquals(-20.0, result.integratedLufs!!, 0.1)
        assertEquals(10_000L, result.durationMs)
    }

    @Test
    fun fiveOneWeightsSkipLfeAndBoostSurrounds() {
        val rate = 48_000
        val mono = sine(rate, 1, 10.0, 997.0)
        fun onlyIn(channel: Int) = FloatArray(mono.size * 6).also { out ->
            for (f in mono.indices) out[f * 6 + channel] = mono[f]
        }
        val front = measure(rate, 6, onlyIn(0))
        val lfe = measure(rate, 6, onlyIn(3))
        val surround = measure(rate, 6, onlyIn(4))
        assertNull(lfe.integratedLufs)
        assertNotNull(lfe.peakDb)
        assertEquals(10 * log10(1.41), surround.integratedLufs!! - front.integratedLufs!!, 1e-6)
        // One channel of a multichannel file is 3 dB under the same signal in both.
        assertEquals(-23.01, front.integratedLufs!!, 0.1)
    }
}
