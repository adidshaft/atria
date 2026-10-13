package com.adidshaft.atria.analytics

import com.adidshaft.atria.protocol.Vector3

/**
 * Strap-only pedometer: 100 Hz accelerometer magnitude → 8-tap low-pass →
 * 29-sample extremum window → dynamic-threshold max/min crossings, with a
 * 6-step regular-gait confirmation. Ported from AtriaStrapPedometer
 * (validated 95/100, 80/80, 107/120, 100/100 locked-pocket, ≈0 at a desk).
 *
 * The iPhone pedometer was deliberately declined on iOS; the Android port
 * keeps the same strap-only rule (no Android step-counter sensor fallback).
 */
class StrapPedometer(
    filterLength: Int = 8,
    peakWindow: Int = 29,
    sensitivityG: Double = 0.06,
    confirmationSteps: Int = 6,
) {
    private val filterLen = filterLength.coerceIn(2, 32)
    private val window = peakWindow.coerceIn(9, 101).let { if (it % 2 == 0) it + 1 else it }
    private val sensitivity = sensitivityG.coerceIn(0.02, 0.30)
    private val confirm = confirmationSteps.coerceIn(1, 20)
    private val half = window / 2

    private val filter = ArrayDeque<Double>()
    private var filterSum = 0.0
    private val lowPass = ArrayDeque<Double>()
    private var sampleCount = 0
    private var mean = 0.0
    private val thresholds = ArrayDeque<Double>()
    private var dynamicThreshold: Double? = null
    private var possible = 0
    private var regular = false
    private var seekingMax = true
    private var curMax = 0.0
    private var curMaxIndex = -1
    var rawSteps = 0
        private set

    fun ingest(acceleration: List<Vector3>) = acceleration.forEach { ingest(it.magnitude) }

    fun ingest(magnitude: Double) {
        sampleCount++
        mean += (magnitude - mean) / sampleCount
        filter.addLast(magnitude); filterSum += magnitude
        if (filter.size > filterLen) filterSum -= filter.removeFirst()
        lowPass.addLast(filterSum / filter.size)
        if (lowPass.size < window) return
        val center = lowPass[half]
        var isMax = true; var isMin = true
        for (v in lowPass) {
            if (v > center) isMax = false
            if (v < center) isMin = false
            if (!isMax && !isMin) break
        }
        if (isMax || isMin) candidate(sampleCount - half - 1, isMax, center)
        lowPass.removeFirst()
    }

    private fun candidate(index: Int, isMax: Boolean, value: Double) {
        if (seekingMax) {
            if (!isMax) return
            curMax = value; curMaxIndex = index; seekingMax = false; return
        }
        if (isMax) { if (value > curMax) { curMax = value; curMaxIndex = index }; return }
        if (index - curMaxIndex > 120) { seekingMax = true; possible = 0; regular = false; return }
        val th = dynamicThreshold ?: mean
        if (curMax > th + sensitivity / 2 && value < th - sensitivity / 2) {
            if (curMax - value > sensitivity) {
                thresholds.addLast((curMax + value) / 2)
                if (thresholds.size > 4) thresholds.removeFirst()
                dynamicThreshold = thresholds.average()
            }
            possible++
            if (regular) rawSteps++ else if (possible >= confirm) { rawSteps += possible; regular = true }
        } else { possible = 0; regular = false }
        seekingMax = true
    }

    fun reset() {
        filter.clear(); filterSum = 0.0; lowPass.clear(); sampleCount = 0; mean = 0.0
        thresholds.clear(); dynamicThreshold = null; possible = 0; regular = false
        seekingMax = true; curMax = 0.0; curMaxIndex = -1; rawSteps = 0
    }

    companion object {
        /** Calibration gain from the counted-walk reference set. */
        const val REFERENCE_GAIN = 1.11
        fun count(magnitudes: List<Double>): Int = StrapPedometer().also { p -> magnitudes.forEach(p::ingest) }.rawSteps
    }
}

/** Minute step buckets → the latest sustained walk (≥8 min at ≥60 spm). */
object WalkBoutDetector {
    data class Minute(val startMs: Long, val steps: Int)
    data class Bout(val startMs: Long, val endMs: Long, val steps: Int, val ongoing: Boolean) {
        val stepsPerMinute get() = steps / maxOf(1.0, (endMs - startMs) / 60_000.0)
    }

    fun latest(minutes: List<Minute>, nowMs: Long): Bout? {
        val recent = minutes.filter { nowMs - it.startMs <= 3 * 3_600_000L }.sortedBy { it.startMs }
        if (recent.isEmpty()) return null
        val byMinute = recent.associate { it.startMs to it.steps }
        val lastMinute = nowMs / 60_000 * 60_000
        var cursor = recent.first().startMs
        val bouts = ArrayList<Bout>()
        var runStart: Long? = null; var runEnd: Long? = null; var steps = 0; var slow = 0; var slowSteps = 0
        fun close() {
            val s = runStart; val e = runEnd
            if (s != null && e != null && (e - s) / 60_000 >= 8) bouts += Bout(s, e, steps, (lastMinute - e) / 60_000 < 3)
            runStart = null; runEnd = null; steps = 0; slow = 0; slowSteps = 0
        }
        while (cursor <= lastMinute) {
            val c = byMinute[cursor] ?: 0
            if (c >= 60) {
                if (runStart == null) runStart = cursor
                runEnd = cursor + 60_000; steps += c + slowSteps; slow = 0; slowSteps = 0
            } else if (runStart != null) {
                slow++; slowSteps += c
                if (slow > 1) close()
            }
            cursor += 60_000
        }
        close()
        return bouts.lastOrNull()
    }
}

/** Per-minute motion summary used by sleep/stress/workout detection. */
data class MotionMinute(val startMs: Long, val steps: Int, val activityG: Double, val stillFraction: Double)
