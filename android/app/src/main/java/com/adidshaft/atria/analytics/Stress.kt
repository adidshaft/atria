package com.adidshaft.atria.analytics

import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Physiological stress 0–3 (Calm < 1 ≤ Moderate < 2 ≤ High), scoring v4.
 * Five-minute windows evaluated every minute, HR/HRV weighted, motion
 * de-weighted, EMA (3-min half-life). Ported from AtriaPhysiologicalStressModel.
 */
object StressModel {
    const val SCORING_VERSION = 4
    const val WINDOW_MS = 300_000L
    private const val HALF_LIFE_S = 180.0
    private const val MAX_RAW_GAP_S = 60.0
    private const val MAX_FACT_GAP_S = 90.0
    private const val MIN_HR_SAMPLES = 5
    private const val MIN_HR_SPAN_S = 290.0
    private const val FULL_HR_SAMPLES = 10

    data class AwakeReference(val calmEdge: Double, val highEdge: Double) {
        val mid get() = (calmEdge + highEdge) / 2
        val halfWidth get() = max(4.0, (highEdge - calmEdge) / 2)
    }

    data class HrvBaseline(val medianLnRmssd: Double, val robustScale: Double, val days: Int)

    data class Personalization(
        val restingHr: Double,
        val maxHr: Double,
        val restingDays: Int,
        val hrvBaseline: HrvBaseline?,
        val awakeReference: AwakeReference?,
    )

    enum class Zone(val label: String) { CALM("Calm"), MODERATE("Moderate"), HIGH("High") }

    data class MinuteFact(val t: Long, val score: Double, val meanHr: Double, val rmssd: Double?, val confidence: String, val activity: Boolean) {
        val zone get() = when { score < 1 -> Zone.CALM; score < 2 -> Zone.MODERATE; else -> Zone.HIGH }
    }

    /** [motionIntensity] 0..1 when qualified motion is present (null = unavailable/still). */
    fun evaluate(
        endMs: Long,
        hr: List<HrSample>,
        rr: List<RrInterval>,
        p: Personalization,
        motionIntensity: Double?,
        previous: MinuteFact?,
    ): MinuteFact? {
        val start = endMs - WINDOW_MS
        val w = hr.filter { it.t in start..endMs && it.bpm in 30..240 }
        if (w.size < MIN_HR_SAMPLES) return null
        val span = (w.last().t - w.first().t) / 1000.0
        if (span < MIN_HR_SPAN_S) return null
        for (i in 1 until w.size) if ((w[i].t - w[i - 1].t) / 1000.0 > MAX_RAW_GAP_S) return null
        val meanHr = w.map { it.bpm }.average()
        if (p.maxHr <= p.restingHr || p.restingHr <= 0) return null
        val h = ((meanHr - p.restingHr) / max(1.0, p.maxHr - p.restingHr)).coerceIn(0.0, 1.0)
        val hrStress = hrCoordinate(meanHr, p)
        val weightHr = 0.5 + 0.5 * (1 - smoothstep(0.05, 0.35, h))
        val rmssd = qualifiedRmssd(rr, start, endMs)
        val hrvStress = if (rmssd != null && rmssd > 0 && p.hrvBaseline != null)
            sigmoid(1.3 * (p.hrvBaseline.medianLnRmssd - ln(rmssd)) / max(0.15, p.hrvBaseline.robustScale)) else null
        val base = if (hrvStress != null) weightHr * hrStress + (1 - weightHr) * hrvStress else hrStress
        val multiplier = motionIntensity?.let { max(0.65, 1 - 0.35 * it.coerceIn(0.0, 1.0)) } ?: 1.0
        val unsmoothed = (3 * multiplier * base).coerceIn(0.0, 3.0)
        val score = if (previous != null) {
            val dt = (endMs - previous.t) / 1000.0
            if (dt > 0 && dt <= MAX_FACT_GAP_S) previous.score + (1 - exp(-ln(2.0) * dt / HALF_LIFE_S)) * (unsmoothed - previous.score) else unsmoothed
        } else unsmoothed
        val sparse = w.size < FULL_HR_SAMPLES
        val learning = p.restingDays < 14 || (hrvStress != null && (p.hrvBaseline?.days ?: 0) < 14)
        val confidence = when {
            hrvStress == null || sparse -> "low"
            learning || motionIntensity == null -> "medium"
            else -> "high"
        }
        return MinuteFact(endMs, score, meanHr, if (hrvStress != null) rmssd else null, confidence, motionIntensity != null && motionIntensity > 0.1)
    }

    fun hrCoordinate(meanHr: Double, p: Personalization): Double {
        val ref = p.awakeReference
        if (ref == null || ref.highEdge <= ref.calmEdge || ref.calmEdge <= p.restingHr) {
            val h = ((meanHr - p.restingHr) / max(1.0, p.maxHr - p.restingHr)).coerceIn(0.0, 1.0)
            return sigmoid(8 * (h - 0.25))
        }
        return sigmoid(ln(2.0) * (meanHr - ref.mid) / ref.halfWidth)
    }

    /** Awake reference = 25th/75th percentiles of the wearer's own quiet-awake minute HRs. */
    fun awakeReference(awakeMinuteMeans: List<Double>): AwakeReference? {
        if (awakeMinuteMeans.size < 240) return null
        val s = awakeMinuteMeans.sorted()
        return AwakeReference(s[(s.size * 0.25).toInt()], s[(s.size * 0.75).toInt()]).takeIf { it.highEdge > it.calmEdge }
    }

    fun qualifiedRmssd(rr: List<RrInterval>, start: Long, end: Long): Double? {
        var sum = 0.0; var n = 0; var qualified = 0
        var prev: RrInterval? = null
        var first: Long? = null; var last: Long? = null
        for (c in rr) {
            if (c.t !in start..end || c.ms !in 300.0..2000.0) { prev = null; continue }
            qualified++
            if (first == null) first = c.t
            last = c.t
            val pv = prev
            if (pv != null && (c.t - pv.t) / 1000.0 <= 3.0 && kotlin.math.abs(c.ms - pv.ms) / pv.ms <= 0.20) {
                val d = c.ms - pv.ms; sum += d * d; n++
            }
            prev = c
        }
        if (first == null || last == null || (last - first) / 1000.0 < 90 || n < 20 || qualified < 30) return null
        return sqrt(sum / n)
    }

    fun sigmoid(v: Double) = 1 / (1 + exp(-v))
    fun smoothstep(e0: Double, e1: Double, v: Double): Double {
        val t = ((v - e0) / (e1 - e0)).coerceIn(0.0, 1.0); return t * t * (3 - 2 * t)
    }
}
