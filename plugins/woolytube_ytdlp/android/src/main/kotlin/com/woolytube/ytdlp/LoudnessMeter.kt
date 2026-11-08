package com.woolytube.ytdlp

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * Streaming loudness meter for interleaved float PCM.
 *
 * Measures ITU-R BS.1770-4 / EBU R128 integrated loudness, "cabin loudness"
 * (the same measurement with a 300 Hz high-pass after the K-weighting, an
 * estimate of how loud the part above engine rumble is) and the sample peak.
 * Filters and sums are in double precision. Memory grows by two doubles per
 * 100 ms, under 2 MB for three hours.
 *
 * Mono is measured as dual mono, because mpv plays it on both ears: it reads
 * 3 dB above the same signal in one channel of a stereo file.
 */
class LoudnessMeter(sampleRate: Int, channels: Int) {
    class Result(
        /** Null when no 400 ms block passes the gates (silence, or under 400 ms). */
        val integratedLufs: Double?,
        /** Like [integratedLufs], with its own gating. */
        val cabinLufs: Double?,
        /** Sample peak over all channels in dBFS; null for digital silence. */
        val peakDb: Double?,
        val durationMs: Long,
    )

    companion object {
        const val CABIN_HIGH_PASS_HZ = 300.0

        private const val ABSOLUTE_GATE_LUFS = -70.0
        private const val RELATIVE_GATE_LU = -10.0
        private const val HOPS_PER_BLOCK = 4
        private const val STATES_PER_CHANNEL = 6

        /**
         * Filter states below this are set to zero, so that a long digital
         * silence does not decay into denormals, which are slow on some CPUs.
         * It is about -500 dBFS, far below anything audible.
         */
        private const val DENORMAL_FLOOR = 1e-25

        /** Analog prototypes of the K-weighting stages, as in libebur128. */
        private const val SHELF_F0 = 1681.974450955533
        private const val SHELF_GAIN_DB = 3.999843853973347
        private const val SHELF_Q = 0.7071752369554196
        private const val SHELF_VB_EXPONENT = 0.4996667741545416
        private const val RLB_F0 = 38.13547087602444
        private const val RLB_Q = 0.5003270373238773

        private val CABIN_Q = 1.0 / sqrt(2.0)

        private fun lufsToPower(lufs: Double): Double = 10.0.pow((lufs + 0.691) / 10.0)

        private fun powerToLufs(power: Double): Double = -0.691 + 10.0 * log10(power)

        /** BS.1770 channel weights; one channel counts twice (dual mono). */
        private fun channelWeights(channels: Int): DoubleArray = when (channels) {
            1 -> doubleArrayOf(2.0)
            // Android's 5.1 order: FL FR FC LFE BL BR.
            6 -> doubleArrayOf(1.0, 1.0, 1.0, 0.0, 1.41, 1.41)
            else -> DoubleArray(channels) { 1.0 }
        }
    }

    private var sampleRate = 0
    private var channels = 0
    private var weights = DoubleArray(0)

    /** Frames per 100 ms hop at the current rate. */
    private var hopFrames = 0
    private var framesInHop = 0

    /** Both biquads of the K-weighting and the cabin high-pass, per channel. */
    private var states = DoubleArray(0)
    private var hopSquares = DoubleArray(0)
    private var hopCabinSquares = DoubleArray(0)

    private var shelfB0 = 0.0
    private var shelfB1 = 0.0
    private var shelfB2 = 0.0
    private var shelfA1 = 0.0
    private var shelfA2 = 0.0
    private var rlbA1 = 0.0
    private var rlbA2 = 0.0
    private var cabinB0 = 0.0
    private var cabinB1 = 0.0
    private var cabinB2 = 0.0
    private var cabinA1 = 0.0
    private var cabinA2 = 0.0

    /** Channel-weighted mean square of each finished 100 ms hop. */
    private var hopPowers = DoubleArray(1024)
    private var cabinHopPowers = DoubleArray(1024)
    private var hopCount = 0

    private var peak = 0.0
    private var secondsBeforeFormat = 0.0
    private var framesInFormat = 0L

    init {
        setFormat(sampleRate, channels)
    }

    /**
     * Switches to a new PCM format. A hop in progress is finished as it is,
     * and the filters are designed afresh for the new rate.
     */
    fun setFormat(sampleRate: Int, channels: Int) {
        if (sampleRate == this.sampleRate && channels == this.channels) return
        // AAC goes down to 7350 Hz; the shelf filter needs over 3.4 kHz.
        require(sampleRate in 4_000..768_000) { "Unsupported sample rate $sampleRate" }
        require(channels in 1..32) { "Unsupported channel count $channels" }
        if (framesInHop > 0) finishHop(framesInHop)
        if (this.sampleRate > 0) secondsBeforeFormat += framesInFormat.toDouble() / this.sampleRate
        framesInFormat = 0
        this.sampleRate = sampleRate
        this.channels = channels
        weights = channelWeights(channels)
        hopFrames = (sampleRate + 5) / 10
        framesInHop = 0
        states = DoubleArray(channels * STATES_PER_CHANNEL)
        hopSquares = DoubleArray(channels)
        hopCabinSquares = DoubleArray(channels)
        designFilters(sampleRate.toDouble())
    }

    private fun designFilters(rate: Double) {
        // High shelf (the head's acoustic effect).
        var k = tan(PI * SHELF_F0 / rate)
        val vh = 10.0.pow(SHELF_GAIN_DB / 20.0)
        val vb = vh.pow(SHELF_VB_EXPONENT)
        var a0 = 1.0 + k / SHELF_Q + k * k
        shelfB0 = (vh + vb * k / SHELF_Q + k * k) / a0
        shelfB1 = 2.0 * (k * k - vh) / a0
        shelfB2 = (vh - vb * k / SHELF_Q + k * k) / a0
        shelfA1 = 2.0 * (k * k - 1.0) / a0
        shelfA2 = (1.0 - k / SHELF_Q + k * k) / a0

        // RLB high-pass; its numerator is 1, -2, 1 at every rate.
        k = tan(PI * RLB_F0 / rate)
        a0 = 1.0 + k / RLB_Q + k * k
        rlbA1 = 2.0 * (k * k - 1.0) / a0
        rlbA2 = (1.0 - k / RLB_Q + k * k) / a0

        // Butterworth high-pass, the same design as FFmpeg's highpass filter.
        val w0 = 2.0 * PI * CABIN_HIGH_PASS_HZ / rate
        val alpha = sin(w0) / (2.0 * CABIN_Q)
        val cosW0 = cos(w0)
        a0 = 1.0 + alpha
        cabinB0 = (1.0 + cosW0) / 2.0 / a0
        cabinB1 = -(1.0 + cosW0) / a0
        cabinB2 = cabinB0
        cabinA1 = -2.0 * cosW0 / a0
        cabinA2 = (1.0 - alpha) / a0
    }

    /** Measures [frames] interleaved frames from the start of [samples]. */
    fun feed(samples: FloatArray, frames: Int) {
        require(frames >= 0 && frames.toLong() * channels <= samples.size) {
            "$frames frames of $channels channels do not fit ${samples.size} samples"
        }
        var done = 0
        while (done < frames) {
            val count = minOf(frames - done, hopFrames - framesInHop)
            filter(samples, done, count)
            done += count
            framesInHop += count
            if (framesInHop == hopFrames) finishHop(hopFrames)
        }
        framesInFormat += frames
    }

    /** Runs [frames] frames, all within one hop, through each channel's filters. */
    private fun filter(samples: FloatArray, firstFrame: Int, frames: Int) {
        // Copied to locals so the inner loop keeps them in registers.
        val sb0 = shelfB0
        val sb1 = shelfB1
        val sb2 = shelfB2
        val sa1 = shelfA1
        val sa2 = shelfA2
        val ra1 = rlbA1
        val ra2 = rlbA2
        val cb0 = cabinB0
        val cb1 = cabinB1
        val cb2 = cabinB2
        val ca1 = cabinA1
        val ca2 = cabinA2
        val stride = channels
        var maxMagnitude = peak
        for (c in 0 until stride) {
            val s = c * STATES_PER_CHANNEL
            var z0 = states[s]
            var z1 = states[s + 1]
            var z2 = states[s + 2]
            var z3 = states[s + 3]
            var z4 = states[s + 4]
            var z5 = states[s + 5]
            var squares = 0.0
            var cabinSquares = 0.0
            var i = firstFrame * stride + c
            val end = i + frames * stride
            while (i < end) {
                val x = samples[i].toDouble()
                val magnitude = abs(x)
                if (magnitude > maxMagnitude) maxMagnitude = magnitude
                val shelved = sb0 * x + z0
                z0 = sb1 * x - sa1 * shelved + z1
                z1 = sb2 * x - sa2 * shelved
                val weighted = shelved + z2
                z2 = -2.0 * shelved - ra1 * weighted + z3
                z3 = shelved - ra2 * weighted
                val cabin = cb0 * weighted + z4
                z4 = cb1 * weighted - ca1 * cabin + z5
                z5 = cb2 * weighted - ca2 * cabin
                squares += weighted * weighted
                cabinSquares += cabin * cabin
                i += stride
            }
            states[s] = flushDenormal(z0)
            states[s + 1] = flushDenormal(z1)
            states[s + 2] = flushDenormal(z2)
            states[s + 3] = flushDenormal(z3)
            states[s + 4] = flushDenormal(z4)
            states[s + 5] = flushDenormal(z5)
            hopSquares[c] += squares
            hopCabinSquares[c] += cabinSquares
        }
        peak = maxMagnitude
    }

    private fun flushDenormal(value: Double): Double =
        if (abs(value) < DENORMAL_FLOOR) 0.0 else value

    private fun finishHop(frames: Int) {
        var power = 0.0
        var cabinPower = 0.0
        for (c in 0 until channels) {
            power += weights[c] * hopSquares[c]
            cabinPower += weights[c] * hopCabinSquares[c]
            hopSquares[c] = 0.0
            hopCabinSquares[c] = 0.0
        }
        // A NaN or infinite sample would poison every later value.
        if (!power.isFinite() || !cabinPower.isFinite()) {
            throw IllegalArgumentException("Non-finite PCM samples")
        }
        if (hopCount == hopPowers.size) {
            hopPowers = hopPowers.copyOf(hopCount * 2)
            cabinHopPowers = cabinHopPowers.copyOf(hopCount * 2)
        }
        hopPowers[hopCount] = power / frames
        cabinHopPowers[hopCount] = cabinPower / frames
        hopCount++
        framesInHop = 0
    }

    /**
     * The measurement so far. A trailing hop shorter than 100 ms is left out,
     * as a partial 400 ms block is in BS.1770; feeding may continue afterwards.
     */
    fun result(): Result = Result(
        integratedLufs = gatedLoudness(hopPowers),
        cabinLufs = gatedLoudness(cabinHopPowers),
        peakDb = if (peak > 0.0) 20.0 * log10(peak) else null,
        durationMs = ((secondsBeforeFormat + framesInFormat.toDouble() / sampleRate) * 1000.0)
            .roundToLong(),
    )

    /**
     * Gated loudness over 400 ms blocks of four hops (75 % overlap): blocks
     * under -70 LUFS are dropped, then blocks 10 LU under the mean of the rest.
     */
    private fun gatedLoudness(powers: DoubleArray): Double? {
        val blocks = hopCount - HOPS_PER_BLOCK + 1
        if (blocks <= 0) return null
        val absoluteGate = lufsToPower(ABSOLUTE_GATE_LUFS)
        var sum = 0.0
        var count = 0
        for (b in 0 until blocks) {
            val power = blockPower(powers, b)
            if (power > absoluteGate) {
                sum += power
                count++
            }
        }
        if (count == 0) return null
        val relativeGate = sum / count * 10.0.pow(RELATIVE_GATE_LU / 10.0)
        var gatedSum = 0.0
        var gatedCount = 0
        for (b in 0 until blocks) {
            val power = blockPower(powers, b)
            if (power > absoluteGate && power > relativeGate) {
                gatedSum += power
                gatedCount++
            }
        }
        if (gatedCount == 0) return null
        return powerToLufs(gatedSum / gatedCount)
    }

    private fun blockPower(powers: DoubleArray, first: Int): Double =
        (powers[first] + powers[first + 1] + powers[first + 2] + powers[first + 3]) / HOPS_PER_BLOCK
}
