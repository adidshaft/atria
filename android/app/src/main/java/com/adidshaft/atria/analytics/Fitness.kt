package com.adidshaft.atria.analytics

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** VO2max ≈ 15.3 · HRmax / HRrest (Uth et al.), bounded 20–80. */
object Vo2Max {
    fun estimate(rest: Int, maxHr: Int): Double? = if (rest <= 0 || maxHr <= rest) null else (15.3 * maxHr / rest).coerceIn(20.0, 80.0)
}

/**
 * Fitness ("biological") age: weighted age-equivalents of VO2max, RHR, HRV,
 * sleep, activity and BMI, clamped to ±20 y. Ported from BiologicalAge.
 */
object FitnessAge {
    data class Factor(val id: String, val label: String, val ageEquivalent: Int, val weight: Double, val detail: String)
    data class Summary(val age: Int, val chronological: Int, val factors: List<Factor>, val pace: String)

    private val maleVo2 = listOf(20 to 52.0, 30 to 48.5, 40 to 45.0, 50 to 41.5, 60 to 38.0, 70 to 34.5, 80 to 31.0, 90 to 27.5)
    private val femaleVo2 = listOf(20 to 44.0, 30 to 41.0, 40 to 38.0, 50 to 35.0, 60 to 32.0, 70 to 29.0, 80 to 26.0, 90 to 23.0)
    private val rhrRef = listOf(20 to 58.0, 30 to 60.0, 40 to 62.0, 50 to 64.0, 60 to 66.0, 70 to 68.0, 80 to 70.0, 90 to 72.0)
    private val rmssdRef = listOf(20 to 70.0, 30 to 58.0, 40 to 46.0, 50 to 36.0, 60 to 28.0, 70 to 22.0, 80 to 18.0, 90 to 14.0)

    private fun interp(v: Double, ref: List<Pair<Int, Double>>, higherIsYounger: Boolean): Int {
        val y = ref.first(); val o = ref.last()
        if (higherIsYounger) { if (v >= y.second) return 18; if (v <= o.second) return 90 } else { if (v <= y.second) return 18; if (v >= o.second) return 90 }
        for (i in 1 until ref.size) {
            val p = ref[i - 1]; val n = ref[i]
            val inside = if (higherIsYounger) v <= p.second && v >= n.second else v >= p.second && v <= n.second
            if (!inside) continue
            val f = (if (higherIsYounger) p.second - v else v - p.second) / max(abs(p.second - n.second), 0.01)
            return (p.first + f * (n.first - p.first)).roundToInt().coerceIn(18, 90)
        }
        return 90
    }

    fun summary(profile: AthleteProfile, rest: Int?, rmssd: Int?, sleepHours: Double?, sleepEfficiency: Double?, consistency: Int?, chronicStrain: Double?): Summary? {
        val age = profile.age
        val f = ArrayList<Factor>()
        if (rest != null && rest > 0) {
            Vo2Max.estimate(rest, profile.estimatedMaxHr)?.let { v ->
                f += Factor("vo2", "VO2max", interp(v, if (profile.sex == BiologicalSex.FEMALE) femaleVo2 else maleVo2, true), 0.30, "≈ %.1f ml/kg/min".format(v))
            }
            f += Factor("rhr", "Resting HR", interp(rest.toDouble(), rhrRef, false), 0.20, "$rest bpm")
        }
        if (rmssd != null && rmssd > 0) f += Factor("hrv", "HRV", interp(rmssd.toDouble(), rmssdRef, true), 0.20, "$rmssd ms")
        if (sleepHours != null && sleepEfficiency != null) {
            val dur = abs(sleepHours - 7.5) * 2; val eff = max(0.0, 0.85 - sleepEfficiency) * 35
            val cons = consistency?.let { max(0.0, 80.0 - it) / 8 } ?: 0.0
            val bonus = if (dur < 1 && sleepEfficiency >= 0.88 && (consistency ?: 80) >= 85) -4.0 else 0.0
            f += Factor("sleep", "Sleep", (age + dur + eff + cons + bonus).roundToInt().coerceIn(18, 90), 0.15, formatHours(sleepHours))
        }
        chronicStrain?.let { c -> f += Factor("activity", "Activity", (age - ((c - 8.0) / 1.5).coerceIn(-8.0, 8.0)).roundToInt().coerceIn(18, 90), 0.10, "28-day strain %.1f".format(c)) }
        if (profile.bmi > 0) {
            val b = profile.bmi
            val pen = if (b < 18.5) (18.5 - b) * 1.2 else max(0.0, b - 24.9) * 0.8
            f += Factor("bmi", "BMI", (age + pen).roundToInt().coerceIn(18, 90), 0.05, "%.1f".format(b))
        }
        if (f.size < 2) return null
        val est = (f.sumOf { it.ageEquivalent * it.weight } / f.sumOf { it.weight }).roundToInt().coerceIn(age - 20, age + 20)
        val pace = when { est - age <= -3 -> "Younger pace"; est - age >= 3 -> "Older pace"; else -> "On pace" }
        return Summary(est, age, f, pace)
    }
}

/**
 * Journal behaviour impact: Welch t-test of next-morning recovery on
 * tagged vs untagged days, gated at ≥5 days each and p < 0.05, routed on the
 * tag's expected effect × observed direction (iOS 2026-10-08 design).
 */
object BehaviorImpact {
    enum class Expected { SUPPORTIVE, DISRUPTIVE, NEUTRAL }
    data class Result(val delta: Double, val pValue: Double, val withN: Int, val withoutN: Int, val headline: String, val significant: Boolean, val counterExpected: Boolean)

    fun evaluate(with: List<Double>, without: List<Double>, expected: Expected, label: String): Result? {
        if (with.size < 5 || without.size < 5) return null
        val m1 = with.average(); val m2 = without.average()
        val v1 = with.sumOf { (it - m1) * (it - m1) } / (with.size - 1)
        val v2 = without.sumOf { (it - m2) * (it - m2) } / (without.size - 1)
        val se = sqrt(v1 / with.size + v2 / without.size)
        val delta = m1 - m2
        val t = if (se > 0) delta / se else 0.0
        val df = if (se > 0) (v1 / with.size + v2 / without.size).let { it * it } /
            ((v1 / with.size).let { it * it } / (with.size - 1) + (v2 / without.size).let { it * it } / (without.size - 1)) else 1.0
        val p = twoSidedP(abs(t), df)
        val significant = p < 0.05
        val counter = when (expected) { Expected.SUPPORTIVE -> delta < 0; Expected.DISRUPTIVE -> delta > 0; Expected.NEUTRAL -> false }
        val headline = when {
            !significant -> "$label: no clear effect yet"
            counter && expected == Expected.DISRUPTIVE -> "$label isn't hurting your recovery yet"
            counter && expected == Expected.SUPPORTIVE -> "$label isn't lifting your recovery yet"
            delta > 0 -> "$label lifts recovery %+.0f%%".format(delta)
            else -> "$label lowers recovery %+.0f%%".format(delta)
        }
        return Result(delta, p, with.size, without.size, headline, significant, counter)
    }

    /** Student-t two-sided p via the regularized incomplete beta function. */
    fun twoSidedP(t: Double, df: Double): Double {
        if (!t.isFinite() || df <= 0) return 1.0
        val x = df / (df + t * t)
        return incompleteBeta(x, df / 2, 0.5).coerceIn(0.0, 1.0)
    }

    private fun incompleteBeta(x: Double, a: Double, b: Double): Double {
        if (x <= 0) return 0.0; if (x >= 1) return 1.0
        val lnBeta = lnGamma(a + b) - lnGamma(a) - lnGamma(b)
        val front = kotlin.math.exp(kotlin.math.ln(x) * a + kotlin.math.ln(1 - x) * b + lnBeta)
        return if (x < (a + 1) / (a + b + 2)) front * cf(x, a, b) / a else 1 - front * cf(1 - x, b, a) / b
    }

    private fun cf(x: Double, a: Double, b: Double): Double {
        var c = 1.0; var d = 1 - (a + b) * x / (a + 1); if (abs(d) < 1e-30) d = 1e-30; d = 1 / d
        var h = d
        for (m in 1..200) {
            val m2 = 2 * m
            var aa = m * (b - m) * x / ((a + m2 - 1) * (a + m2))
            d = 1 + aa * d; if (abs(d) < 1e-30) d = 1e-30; c = 1 + aa / c; if (abs(c) < 1e-30) c = 1e-30; d = 1 / d; h *= d * c
            aa = -(a + m) * (a + b + m) * x / ((a + m2) * (a + m2 + 1))
            d = 1 + aa * d; if (abs(d) < 1e-30) d = 1e-30; c = 1 + aa / c; if (abs(c) < 1e-30) c = 1e-30; d = 1 / d
            val del = d * c; h *= del
            if (abs(del - 1) < 3e-12) break
        }
        return h
    }

    private fun lnGamma(z: Double): Double {
        val g = doubleArrayOf(76.18009172947146, -86.50532032941677, 24.01409824083091, -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5)
        var x = z; var y = z
        var tmp = x + 5.5; tmp -= (x + 0.5) * kotlin.math.ln(tmp)
        var ser = 1.000000000190015
        for (c in g) { y += 1; ser += c / y }
        return -tmp + kotlin.math.ln(2.5066282746310005 * ser / x)
    }
}

/** Max-HR learning that ignores single-sample spikes: needs ≥ 20 s sustained. */
object MaxHrLearning {
    fun sustainedPeak(samples: List<HrSample>, sustainSeconds: Int = 20): Int? {
        if (samples.size < sustainSeconds) return null
        var best: Int? = null
        var i = 0
        for (j in samples.indices) {
            while (samples[j].t - samples[i].t > sustainSeconds * 1000L) i++
            if (samples[j].t - samples[i].t >= (sustainSeconds - 2) * 1000L) {
                val floor = samples.subList(i, j + 1).minOf { it.bpm }
                if (floor in 100..230) best = max(best ?: 0, floor)
            }
        }
        return best
    }
}

fun mean(values: List<Double>): Double? = if (values.isEmpty()) null else values.average()
fun clampInt(v: Int, lo: Int, hi: Int) = min(max(v, lo), hi)
