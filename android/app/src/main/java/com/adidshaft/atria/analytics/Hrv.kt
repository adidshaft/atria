package com.adidshaft.atria.analytics

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

/** Beat-to-beat interval; [t] epoch ms, [ms] interval length. */
data class RrInterval(val t: Long, val ms: Double, val expectedHr: Int? = null)

data class HrvSnapshot(
    val rmssd: Double,
    val sdnn: Double,
    val pnn50: Double,
    val lnRmssd: Double,
    val confidence: Double,
    val kept: Int,
    val raw: Int,
    val successiveDifferences: Int,
    val windowSeconds: Double,
    val maxGapSeconds: Double,
    val respiratoryRate: Double?,
    val measurementEnd: Long,
) {
    val minimumReadyBeats get() = ceil(max(0.0, windowSeconds) * 0.5).toInt()
    val isReady: Boolean
        get() = windowSeconds >= 300 && maxGapSeconds <= MAX_GAP && kept >= minimumReadyBeats &&
            successiveDifferences >= max(1, ceil((kept - 1).coerceAtLeast(0) * 0.70).toInt()) && confidence >= 0.75

    val readinessMessage: String
        get() = when {
            windowSeconds < 300 -> "Learning: building a 5-min window"
            maxGapSeconds > MAX_GAP -> "Learning: beat-to-beat gaps"
            kept < minimumReadyBeats -> "Learning: need enough beats"
            confidence < 0.75 -> "Learning: beat-to-beat confidence"
            else -> "Ready"
        }

    companion object { const val MAX_GAP = 3.0 }
}

/**
 * Five-minute RMSSD with artifact rejection (range 300–2000 ms, ±35 bpm vs
 * reported HR, ±20% vs local median of 5), ported from HRVAnalyzer.
 */
object HrvAnalyzer {
    fun analyze(raw: List<RrInterval>, nowMs: Long): HrvSnapshot? {
        val windowStart = nowMs - 300_000
        val window = raw.filter { it.t in windowStart..nowMs }
        if (window.size < 2) return null
        val first = window.first()
        val firstSec = if (first.ms in 300.0..2000.0) first.ms / 1000 else 0.0
        val measuredStart = max(windowStart.toDouble(), first.t - firstSec * 1000)
        val coverage = ((nowMs - measuredStart) / 1000).coerceIn(0.0, 300.0)
        val kept = ArrayList<Pair<Int, Double>>()
        var maxGap = 0.0
        for (i in window.indices) {
            val rr = window[i]
            if (i > 0) maxGap = max(maxGap, (rr.t - window[i - 1].t) / 1000.0)
            if (rr.ms !in 300.0..2000.0) continue
            val expected = rr.expectedHr
            if (expected != null && expected > 0 && abs(60_000.0 / rr.ms - expected) > 35) continue
            val median = localMedian(window, i)
            if (median != null && median > 0 && abs(rr.ms - median) / median > 0.20) continue
            kept += i to rr.ms
        }
        maxGap = max(maxGap, (nowMs - window.last().t) / 1000.0)
        val confidence = kept.size.toDouble() / window.size
        if (kept.size < 2) return HrvSnapshot(0.0, 0.0, 0.0, 0.0, confidence, kept.size, window.size, 0, coverage, maxGap, null, window.last().t)
        val diffs = adjacentDifferences(kept)
        val values = kept.map { it.second }
        val mean = values.average()
        val sdnn = sqrt(values.sumOf { (it - mean) * (it - mean) } / max(1, values.size - 1))
        val rmssd = if (diffs.isEmpty()) 0.0 else sqrt(diffs.sumOf { it * it } / diffs.size)
        val pnn50 = if (diffs.isEmpty()) 0.0 else diffs.count { abs(it) > 50 } * 100.0 / diffs.size
        val resp = RespiratoryRate.estimate(window.map { it.t to it.ms }, nowMs)
        return HrvSnapshot(rmssd, sdnn, pnn50, if (rmssd > 0) ln(rmssd) else 0.0, confidence, kept.size, window.size, diffs.size, coverage, maxGap, resp, window.last().t)
    }

    private fun localMedian(w: List<RrInterval>, i: Int): Double? {
        val local = (max(0, i - 2)..minOf(w.lastIndex, i + 2)).map { w[it].ms }.filter { it in 300.0..2000.0 }.sorted()
        if (local.size < 3) return null
        val m = local.size / 2
        return if (local.size % 2 == 0) (local[m - 1] + local[m]) / 2 else local[m]
    }

    fun adjacentDifferences(accepted: List<Pair<Int, Double>>): List<Double> {
        val out = ArrayList<Double>()
        for (i in 1 until accepted.size) if (accepted[i].first == accepted[i - 1].first + 1) out += accepted[i].second - accepted[i - 1].second
        return out
    }

    /** Overnight HRV: median of qualified 5-minute RMSSD windows across a sleep span. */
    fun overnightRmssd(rr: List<RrInterval>, startMs: Long, endMs: Long): Double? {
        val inSleep = rr.filter { it.t in startMs..endMs }
        if (inSleep.size < 200) return null
        val values = ArrayList<Double>()
        var cursor = startMs + 300_000
        while (cursor <= endMs) {
            val snap = analyze(inSleep.filter { it.t in (cursor - 300_000)..cursor }, cursor)
            if (snap != null && snap.isReady) values += snap.rmssd
            cursor += 300_000
        }
        if (values.size < 3) return null
        val s = values.sorted()
        return s[s.size / 2]
    }
}

/** Respiratory sinus arrhythmia → breaths/min (DFT over 9–30 bpm). */
object RespiratoryRate {
    fun estimate(samples: List<Pair<Long, Double>>, nowMs: Long, lookbackSec: Double = 90.0): Double? {
        val recent = samples.filter { it.first >= nowMs - (lookbackSec * 1000).toLong() && it.first <= nowMs }
        if (recent.size < 20) return null
        val duration = (recent.last().first - recent.first().first) / 1000.0
        if (duration < 45 || (nowMs - recent.last().first) / 1000.0 > 5) return null
        if (recent.any { it.second !in 300.0..2000.0 }) return null
        val origin = recent.first().first
        val rel = recent.map { (it.first - origin) / 1000.0 to it.second }
        for (i in 1 until rel.size) { val g = rel[i].first - rel[i - 1].first; if (g <= 0 || g > 5) return null }
        val rate = 4.0
        val count = (duration * rate).toInt() + 1
        val resampled = ArrayList<Double>(count)
        var s = 0
        for (k in 0 until count) {
            val t = k / rate
            while (s + 1 < rel.size && rel[s + 1].first < t) s++
            if (s + 1 >= rel.size) break
            val a = rel[s]; val b = rel[s + 1]
            val span = b.first - a.first
            if (span > 0) resampled += a.second + (b.second - a.second) * ((t - a.first) / span)
        }
        return estimateResampled(resampled, rate)
    }

    fun estimateResampled(x: List<Double>, rate: Double = 4.0): Double? {
        if (x.size < (45 * rate).toInt()) return null
        val mean = x.average()
        val c = x.map { it - mean }
        if (c.sumOf { it * it } <= 0) return null
        var best = 0.0; var bestPower = 0.0; var band = 0.0
        var bpm = 9.0
        while (bpm <= 30.0) {
            val f = bpm / 60.0
            var re = 0.0; var im = 0.0
            for (i in c.indices) { val a = 2 * PI * f * i / rate; re += c[i] * cos(a); im -= c[i] * sin(a) }
            val p = re * re + im * im
            band += p
            if (p > bestPower) { bestPower = p; best = bpm }
            bpm += 0.5
        }
        return if (bestPower > 0 && bestPower / max(band, bestPower) >= 0.18) best else null
    }
}
