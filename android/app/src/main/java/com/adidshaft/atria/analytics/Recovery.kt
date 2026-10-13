package com.adidshaft.atria.analytics

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

data class Stats(val mean: Double, val sd: Double, val count: Int)

private fun stats(values: List<Double>): Stats? {
    if (values.isEmpty()) return null
    val mean = values.average()
    val sd = if (values.size < 2) 0.0 else sqrt(values.sumOf { (it - mean) * (it - mean) } / (values.size - 1))
    return Stats(mean, sd, values.size)
}

private fun median(values: List<Double>): Double {
    val s = values.sorted(); val m = s.size / 2
    return if (s.size % 2 == 0) (s[m - 1] + s[m]) / 2 else s[m]
}

/**
 * Personal baseline: one canonical sample per civil day (overnight preferred,
 * then the lowest resting HR), 90 retained, stale after 21 days, trusted at
 * 14 days. Ported from PersonalBaseline (Insights.swift).
 */
@Serializable
data class PersonalBaseline(val samples: List<BaselineSample> = emptyList()) {
    @Serializable
    data class BaselineSample(val dateMs: Long, val restingHr: Double, val rmssd: Double? = null, val overnight: Boolean = false) {
        val lnRmssd get() = rmssd?.takeIf { it > 0 }?.let { ln(it) }
    }

    data class Robust(val location: Double, val scale: Double, val count: Int)

    fun learn(resting: Int, rmssd: Int?, atMs: Long, overnight: Boolean, zone: ZoneId = ZoneId.systemDefault()): PersonalBaseline {
        if (resting !in 35..240) return this
        val day = dayOf(atMs, zone)
        val existing = samples.firstOrNull { dayOf(it.dateMs, zone) == day }
        val rmssdValue = rmssd?.takeIf { it > 0 }?.toDouble() ?: existing?.takeIf { it.overnight }?.rmssd
        val incoming = BaselineSample(atMs, resting.toDouble(), rmssdValue, overnight)
        val all = samples + incoming
        return PersonalBaseline(canonical(all, zone).takeLast(MAX_SAMPLES))
    }

    val restingEma: Double? get() = ema(canonical(samples).map { it.restingHr }, 2.0)
    val hrvEma: Double? get() = ema(canonical(samples).mapNotNull { it.rmssd }, 6.0)

    fun fresh(nowMs: Long) = canonical(samples).filter { val age = nowMs - it.dateMs; age in 0..STALE_MS }
    fun freshRestingDays(nowMs: Long) = fresh(nowMs).size
    fun freshHrvNights(nowMs: Long) = fresh(nowMs).count { it.overnight && it.lnRmssd != null }
    fun isStale(nowMs: Long) = samples.maxOfOrNull { it.dateMs }?.let { nowMs - it > STALE_MS } ?: true
    fun hasTrustedResting(nowMs: Long) = freshRestingDays(nowMs) >= TRUSTED && !isStale(nowMs)
    fun hasTrustedHrv(nowMs: Long) = freshHrvNights(nowMs) >= TRUSTED && !isStale(nowMs)

    fun restingStats(nowMs: Long): Stats? = stats(fresh(nowMs).map { it.restingHr })

    fun lnRmssdStats(nowMs: Long): Stats? {
        val f = fresh(nowMs)
        val overnight = f.filter { it.overnight }.mapNotNull { it.lnRmssd }
        if (overnight.size >= OVERNIGHT_PREFERENCE) return stats(overnight)
        val all = stats(f.mapNotNull { it.lnRmssd }) ?: return null
        val o = stats(overnight) ?: return all
        val w = min(overnight.size.toDouble() / OVERNIGHT_PREFERENCE, 1.0)
        val mean = w * o.mean + (1 - w) * all.mean
        val variance = w * (o.sd * o.sd + (o.mean - mean) * (o.mean - mean)) + (1 - w) * (all.sd * all.sd + (all.mean - mean) * (all.mean - mean))
        return Stats(mean, sqrt(variance), all.count)
    }

    /** 30-day median / MAD comparison used when the baseline is mature. */
    fun robustHrv(nowMs: Long): Robust? {
        val values = canonical(samples).filter { nowMs - it.dateMs in 0..30L * DAY_MS && it.overnight }.mapNotNull { it.lnRmssd }
        if (values.size < TRUSTED) return null
        val med = median(values)
        val mad = median(values.map { abs(it - med) }) * 1.4826
        return Robust(med, max(mad, 0.05), values.size)
    }

    fun restingQualifier(nowMs: Long) = if (hasTrustedResting(nowMs)) null else "Resting HR learning · ${min(freshRestingDays(nowMs), TRUSTED)} of $TRUSTED days"
    fun hrvQualifier(nowMs: Long) = if (hasTrustedHrv(nowMs)) null else "HRV calibrating · ${min(freshHrvNights(nowMs), TRUSTED)} of $TRUSTED nights"

    companion object {
        const val TRUSTED = 14
        const val OVERNIGHT_PREFERENCE = 7
        const val MAX_SAMPLES = 90
        const val DAY_MS = 86_400_000L
        const val STALE_MS = 21 * DAY_MS

        fun dayOf(ms: Long, zone: ZoneId = ZoneId.systemDefault()): LocalDate = Instant.ofEpochMilli(ms).atZone(zone).toLocalDate()

        fun canonical(samples: List<BaselineSample>, zone: ZoneId = ZoneId.systemDefault()): List<BaselineSample> {
            val byDay = LinkedHashMap<LocalDate, BaselineSample>()
            for (s in samples.sortedBy { it.dateMs }) {
                val d = dayOf(s.dateMs, zone)
                val e = byDay[d]
                if (e == null) { byDay[d] = s; continue }
                val ep = if (e.overnight) 1 else 0; val ip = if (s.overnight) 1 else 0
                if (ip > ep || (ip == ep && s.restingHr < e.restingHr)) byDay[d] = s
            }
            return byDay.values.sortedBy { it.dateMs }
        }

        /** EMA with α = 0.1 and a per-step clamp so one odd night cannot swing the baseline. */
        fun ema(values: List<Double>, maxStep: Double): Double? {
            if (values.isEmpty()) return null
            var v = values.first()
            for (x in values.drop(1)) v += (0.1 * (x - v)).coerceIn(-maxStep, maxStep)
            return v
        }
    }
}

/**
 * Recovery 1–99%: logistic of a z-blend (HRV 0.60, RHR 0.20, sleep 0.15,
 * respiration 0.05), renormalised over the evidence actually observed.
 * Ported from AtriaAnalytics.Recovery.
 */
object Recovery {
    enum class Confidence(val label: String) { LEARNING("learning"), UNVERIFIED("unverified"), PERSONAL("personal baseline") }
    enum class Kind { HRV, RESTING_HR, SLEEP, RESPIRATION }

    data class Contributor(val kind: Kind, val z: Double, val weight: Double, val display: String) {
        val direction get() = when { weight == 0.0 -> 0; z > 0.12 -> 1; z < -0.12 -> -1; else -> 0 }
    }

    data class Estimate(val percent: Int?, val confidence: Confidence, val usesHrv: Boolean, val detail: String, val contributors: List<Contributor>)

    data class SleepBaseline(val hours: Pair<Double, Double>?, val efficiency: Pair<Double, Double>?)

    fun estimate(
        rmssdNow: Double?,
        restingNow: Int?,
        baseline: PersonalBaseline,
        sleepEfficiency: Double?,
        sleepHours: Double?,
        sleepBaseline: SleepBaseline?,
        respiratoryRate: Double?,
        respiratoryBaseline: Stats?,
        nowMs: Long,
    ): Estimate {
        val sleep = sleepZ(sleepEfficiency, sleepHours, sleepBaseline)
        val respQualified = respiratoryRate != null && respiratoryRate > 0 && respiratoryBaseline != null &&
            respiratoryBaseline.count >= PersonalBaseline.TRUSTED && respiratoryBaseline.sd > 0.1
        val respZ = if (respQualified) (-(respiratoryRate!! - respiratoryBaseline!!.mean) / respiratoryBaseline.sd).coerceIn(-2.0, 2.0) else 0.0

        val restingStats = baseline.restingStats(nowMs)
        val restingBase = baseline.restingEma
        val restingZ: Double? = if (restingNow != null && restingBase != null) {
            val st = if (baseline.hasTrustedResting(nowMs) && restingStats != null) restingStats else Stats(restingBase, max(restingStats?.sd ?: 0.0, 5.0), baseline.freshRestingDays(nowMs))
            z(restingNow.toDouble(), st.mean, st.sd, 1.0)
        } else null

        val hrvZ: Double?
        var confidence: Confidence
        if (rmssdNow != null && rmssdNow > 0) {
            val robust = baseline.robustHrv(nowMs)
            val st = baseline.lnRmssdStats(nowMs)
            when {
                baseline.hasTrustedHrv(nowMs) && robust != null -> { hrvZ = z(ln(rmssdNow), robust.location, robust.scale, 0.05); confidence = if (baseline.hasTrustedResting(nowMs)) Confidence.PERSONAL else Confidence.UNVERIFIED }
                baseline.hasTrustedHrv(nowMs) && st != null -> { hrvZ = z(ln(rmssdNow), st.mean, st.sd, 0.05); confidence = if (baseline.hasTrustedResting(nowMs)) Confidence.PERSONAL else Confidence.UNVERIFIED }
                baseline.hrvEma != null -> { hrvZ = 0.25 * ln(rmssdNow / baseline.hrvEma!!).coerceIn(-2.5, 2.5); confidence = Confidence.UNVERIFIED }
                else -> { hrvZ = null; confidence = Confidence.UNVERIFIED }
            }
        } else { hrvZ = null; confidence = Confidence.UNVERIFIED }

        if (sleep == null && hrvZ == null && restingZ == null) {
            return Estimate(null, Confidence.LEARNING, true, "Learning: need a saved sleep", emptyList())
        }
        if (sleep != null && !sleep.second && confidence == Confidence.PERSONAL) confidence = Confidence.UNVERIFIED
        if (restingZ == null && confidence == Confidence.PERSONAL) confidence = Confidence.UNVERIFIED

        val parts = ArrayList<Triple<Kind, Double, Double>>() // kind, contribution z (positive = good), weight
        hrvZ?.let { parts += Triple(Kind.HRV, it, if (sleep == null) 0.60 else 0.60) }
        restingZ?.let { parts += Triple(Kind.RESTING_HR, -it, 0.20) }
        sleep?.let { parts += Triple(Kind.SLEEP, it.first, if (hrvZ == null) 0.75 else 0.15) }
        if (respQualified) parts += Triple(Kind.RESPIRATION, respZ, 0.05)
        val total = parts.sumOf { it.third }
        val blended = parts.sumOf { it.second * it.third } / max(total, 0.01)
        val percent = logistic(blended)
        val contributors = Kind.entries.map { k ->
            val p = parts.firstOrNull { it.first == k }
            if (p == null) Contributor(k, 0.0, 0.0, "${label(k)} unavailable")
            else Contributor(k, p.second, p.third / total, when (k) {
                Kind.SLEEP -> sleepHours?.let { "${formatHours(it)} slept" } ?: "Sleep %+.1fσ".format(p.second)
                Kind.RESTING_HR -> "Resting HR ${restingNow ?: "--"} bpm"
                else -> "${label(k)} %+.1fσ".format(p.second)
            })
        }
        val detail = when {
            hrvZ == null && sleep != null -> "Sleep-led estimate · HRV unavailable"
            sleep == null -> "Sleep missing · renormalized"
            else -> "HRV, resting HR and sleep vs your baseline"
        }
        return Estimate(percent, if (hrvZ == null) Confidence.UNVERIFIED else confidence, hrvZ != null, detail, contributors)
    }

    private fun label(k: Kind) = when (k) { Kind.HRV -> "HRV"; Kind.RESTING_HR -> "Resting HR"; Kind.SLEEP -> "Sleep"; Kind.RESPIRATION -> "Respiration" }

    private fun z(v: Double, mean: Double, sd: Double, minSd: Double): Double {
        val e = max(sd, minSd); return ((v - mean) / e).coerceIn(-2.5, 2.5)
    }

    fun logistic(z: Double): Int = (100.0 / (1 + exp(-1.6 * (z + 0.20)))).coerceIn(1.0, 99.0).roundToInt()

    private fun sleepZ(eff: Double?, hours: Double?, b: SleepBaseline?): Pair<Double, Boolean>? {
        if (b != null) {
            val c = ArrayList<Double>()
            if (hours != null && hours > 0 && b.hours != null) c += (hours - b.hours.first) / max(b.hours.second, 0.75)
            if (eff != null && b.efficiency != null) c += (eff.coerceIn(0.0, 1.0) - b.efficiency.first) / max(b.efficiency.second, 0.05)
            if (c.isNotEmpty()) return c.average().coerceIn(-2.0, 2.0) to true
        }
        val c = ArrayList<Double>()
        if (eff != null) c += (eff.coerceIn(0.0, 1.0) - 0.85) / 0.10
        if (hours != null && hours > 0) c += (hours.coerceIn(0.0, 9.0) - 7.0) / 1.5
        return if (c.isEmpty()) null else c.average().coerceIn(-2.0, 2.0) to false
    }

    fun band(percent: Int?): String = when {
        percent == null -> "Calculating"
        percent >= 67 -> "Good"
        percent >= 34 -> "Fair"
        else -> "Low"
    }
}

fun formatHours(hours: Double): String {
    val m = (hours * 60).roundToInt()
    return "${m / 60}h ${m % 60}m"
}
