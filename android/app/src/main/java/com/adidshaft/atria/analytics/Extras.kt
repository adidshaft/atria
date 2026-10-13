package com.adidshaft.atria.analytics

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.util.zip.Deflater
import java.util.zip.Inflater
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** AtriaCycleTracking: opt-in, calendar estimate until 2 cycles personalise it. */
object CycleTracking {
    enum class Phase(val title: String, val note: String) {
        MENSTRUAL("Menstrual", "Energy and RHR can run lower; an easier day is a normal response, not a bad recovery."),
        FOLLICULAR("Follicular", "Recovery capacity tends to trend upward through this window."),
        OVULATORY("Ovulatory", "Small HRV/RHR dips around ovulation are common and don't necessarily mean under-recovery."),
        LUTEAL("Luteal", "RHR and temperature typically run a little higher and recovery can read lower for physiological reasons."),
    }
    data class Period(val startDay: Long, val endDay: Long?)
    data class Estimate(val phase: Phase, val cycleDay: Int, val personalized: Boolean, val nextStartDay: Long)

    fun medianCycleLength(periods: List<Period>): Int? {
        val starts = periods.map { it.startDay }.sorted()
        if (starts.size < 3) return null
        val gaps = starts.zipWithNext { a, b -> (b - a).toInt() }.filter { it > 0 }.sorted()
        if (gaps.size < 2) return null
        return gaps[gaps.size / 2].takeIf { it in 15..60 }
    }

    private fun medianPeriodLength(periods: List<Period>): Int {
        val l = periods.mapNotNull { p -> p.endDay?.let { (it - p.startDay + 1).toInt() } }.sorted()
        return if (l.size < 2) 5 else l[l.size / 2]
    }

    fun phaseFor(dayIndex: Int, cycleLength: Int, periodLength: Int): Phase {
        val ovulation = max(periodLength + 1, cycleLength - 14)
        return when {
            dayIndex <= periodLength -> Phase.MENSTRUAL
            dayIndex < ovulation - 1 -> Phase.FOLLICULAR
            dayIndex <= ovulation + 1 -> Phase.OVULATORY
            else -> Phase.LUTEAL
        }
    }

    fun estimate(periods: List<Period>, today: Long): Estimate? {
        val last = periods.maxByOrNull { it.startDay } ?: return null
        val since = (today - last.startDay).toInt()
        if (since < 0) return null
        val personal = medianCycleLength(periods)
        val len = personal ?: 28
        val periodLen = min(medianPeriodLength(periods), len - 1)
        val day = since % len + 1
        return Estimate(phaseFor(day, len, periodLen), day, personal != null, last.startDay + ((since / len) + 1) * len)
    }
}

/** AtriaIrregularRhythm: fail-closed, education-first irregular pulse-timing check (never a diagnosis). */
object IrregularRhythm {
    enum class Outcome { INSUFFICIENT, SIGNS }
    data class Result(val outcome: Outcome, val reason: String, val largeFraction: Double? = null, val turningPointRatio: Double? = null)

    const val CANNOT_DIAGNOSE = "Atria can't detect or rule out AFib. A wrist PPG strap is not an ECG."

    fun evaluate(rr: List<RrInterval>, nowMs: Long): Result {
        val w = rr.filter { it.t in (nowMs - 300_000)..nowMs }.sortedBy { it.t }
        if (w.size < 2) return Result(Outcome.INSUFFICIENT, "window")
        var maxGap = 0.0
        for (i in 1 until w.size) maxGap = max(maxGap, (w[i].t - w[i - 1].t) / 1000.0)
        if (maxGap > 3.0) return Result(Outcome.INSUFFICIENT, "gap")
        val q = w.filter { it.ms in 300.0..2000.0 }
        if (q.size < 150) return Result(Outcome.INSUFFICIENT, "beats")
        if ((w.size - q.size).toDouble() / w.size >= 0.10) return Result(Outcome.INSUFFICIENT, "noise")
        val hr = 60_000 / q.map { it.ms }.average()
        if (hr !in 45.0..100.0) return Result(Outcome.INSUFFICIENT, "rate")
        var large = 0; var n = 0
        for (i in 1 until q.size) {
            val gap = (q[i].t - q[i - 1].t) / 1000.0
            if (gap <= 0 || gap > 3.0) continue
            n++
            if (abs(q[i].ms - q[i - 1].ms) / q[i - 1].ms > 0.20) large++
        }
        if (n < 120) return Result(Outcome.INSUFFICIENT, "differences")
        val frac = large.toDouble() / n
        val tpr = turningPointRatio(q.map { it.ms }) ?: return Result(Outcome.INSUFFICIENT, "pattern", frac)
        if (tpr !in 0.58..0.78) return Result(Outcome.INSUFFICIENT, "pattern", frac, tpr)
        if (frac < 0.25) return Result(Outcome.INSUFFICIENT, "regular", frac, tpr)
        return Result(Outcome.SIGNS, "irregular_successive_differences", frac, tpr)
    }

    fun turningPointRatio(v: List<Double>): Double? {
        if (v.size < 8) return null
        var turns = 0
        for (i in 1 until v.size - 1) if ((v[i] - v[i - 1]) * (v[i + 1] - v[i]) < 0) turns++
        return turns.toDouble() / (v.size - 2)
    }
}

/** AtriaSleepPlanner: in-bed-by time for a performance goal. */
object SleepPlanner {
    enum class Goal(val title: String, val fraction: Double) { PEAK("Peak", 1.0), PERFORM("Perform", 0.85), GET_BY("Get by", 0.70) }
    data class Plan(val targetSleepHours: Double, val inBedByMinute: Int, val efficiency: Double, val efficiencyIsDefault: Boolean)

    fun plan(needHours: Double, goal: Goal, wakeByMinute: Int, efficiencies: List<Double>): Plan {
        val usable = efficiencies.filter { it > 0.5 && it <= 1.0 }.sorted()
        val eff = if (usable.size >= 5) (if (usable.size % 2 == 0) (usable[usable.size / 2 - 1] + usable[usable.size / 2]) / 2 else usable[usable.size / 2]) else 0.90
        val target = (needHours * goal.fraction).coerceIn(3.0, 12.0)
        var bed = wakeByMinute - (target / eff * 60).roundToInt()
        while (bed < 0) bed += 1440
        return Plan(target, bed % 1440, eff, usable.size < 5)
    }
}

/**
 * Recovery Face-Off — wire-compatible with iOS AtriaFaceOff: JSON → raw DEFLATE
 * (Apple's COMPRESSION_ZLIB has no zlib header) → base64url without padding,
 * carried in `atria://compare?d=…`. No server, no account.
 */
object FaceOff {
    @Serializable data class DayStat(val o: Int, val r: Int? = null, val s: Double? = null, val z: Double? = null, val h: Int? = null)
    @Serializable data class Payload(val v: Int, val name: String, val endEpochDay: Int, val days: List<DayStat>) {
        val avgRecovery get() = days.mapNotNull { it.r }.takeIf { it.isNotEmpty() }?.let { it.sum() / it.size }
        val avgStrain get() = days.mapNotNull { it.s }.takeIf { it.isNotEmpty() }?.average()
        val avgSleep get() = days.mapNotNull { it.z }.takeIf { it.isNotEmpty() }?.average()
        val avgRestingHr get() = days.mapNotNull { it.h }.takeIf { it.isNotEmpty() }?.let { it.sum() / it.size }
    }

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    fun url(p: Payload): String = "atria://compare?d=" + encode(p)

    fun encode(p: Payload): String {
        val raw = json.encodeToString(Payload.serializer(), p).toByteArray()
        val d = Deflater(Deflater.DEFAULT_COMPRESSION, true).apply { setInput(raw); finish() }
        val out = ByteArrayOutputStream(); val buf = ByteArray(1024)
        while (!d.finished()) out.write(buf, 0, d.deflate(buf))
        d.end()
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(out.toByteArray())
    }

    fun decode(encoded: String): Payload? = runCatching {
        if (encoded.length > 4096) return null
        val bytes = java.util.Base64.getUrlDecoder().decode(encoded.trim())
        val text = inflate(bytes, true) ?: inflate(bytes, false) ?: return null
        if (text.length > 16_384) return null
        sanitize(json.decodeFromString(Payload.serializer(), text))
    }.getOrNull()

    private fun inflate(bytes: ByteArray, nowrap: Boolean): String? = runCatching {
        val i = Inflater(nowrap).apply { setInput(bytes) }
        val out = ByteArrayOutputStream(); val buf = ByteArray(1024)
        while (!i.finished()) { val n = i.inflate(buf); if (n == 0 && (i.needsInput() || i.needsDictionary())) break; out.write(buf, 0, n); if (out.size() > 16_384) break }
        i.end()
        if (out.size() == 0) null else String(out.toByteArray())
    }.getOrNull()

    private fun sanitize(p: Payload): Payload? {
        if (p.v != 1 || p.days.size !in 1..14) return null
        val name = p.name.trim().take(24).ifEmpty { "A friend" }
        return Payload(1, name, p.endEpochDay, p.days.take(14).map { d ->
            DayStat(d.o.coerceIn(0, 30), d.r?.coerceIn(1, 99), d.s?.coerceIn(0.0, 21.0), d.z?.coerceIn(0.0, 16.0), d.h?.coerceIn(25, 120))
        })
    }

    /** [days]: (epochDay, recovery, strain, sleepHours, restingHr) newest-first, ≤ 7. */
    fun makePayload(name: String, days: List<DayRow>): Payload? {
        val recent = days.sortedByDescending { it.epochDay }.take(7)
        val end = recent.firstOrNull()?.epochDay ?: return null
        val stats = recent.map { DayStat((end - it.epochDay).toInt(), it.recovery, it.strain?.let { s -> (s * 10).roundToInt() / 10.0 }, it.sleepHours?.let { h -> (h * 10).roundToInt() / 10.0 }, it.restingHr) }
        if (stats.none { it.r != null || it.s != null || it.z != null }) return null
        return Payload(1, name.trim().take(24).ifEmpty { "A friend" }, end.toInt(), stats)
    }

    data class DayRow(val epochDay: Long, val recovery: Int?, val strain: Double?, val sleepHours: Double?, val restingHr: Int?)
}

/** AtriaStrengthProgress: Epley estimated 1RM per exercise. */
object StrengthProgress {
    fun e1rm(weightKg: Double, reps: Int): Double = if (reps <= 1) weightKg else weightKg * (1 + reps / 30.0)
    data class Lift(val exercise: String, val bestE1rm: Double, val sets: Int, val lastAt: Long, val deltaVsFirst: Double?)

    fun summarize(sets: List<Triple<String, Pair<Int, Double?>, Long>>): List<Lift> =
        sets.filter { it.second.second != null && it.second.second!! > 0 }.groupBy { it.first.trim().lowercase() }.map { (_, list) ->
            val sorted = list.sortedBy { it.third }
            val values = sorted.map { e1rm(it.second.second!!, it.second.first) }
            Lift(sorted.last().first.trim(), values.max(), list.size, sorted.last().third, if (values.size >= 2) values.last() - values.first() else null)
        }.sortedByDescending { it.lastAt }
}

/** Weekly / monthly report (AtriaWeeklyReport / AtriaMonthlyReport) aggregation. */
object Reports {
    data class Row(val epochDay: Long, val recovery: Int?, val strain: Double?, val sleepHours: Double?, val hrv: Double?, val rhr: Int?, val steps: Int?)
    data class Summary(val days: Int, val recovery: Double?, val strain: Double?, val sleep: Double?, val hrv: Double?, val rhr: Double?, val steps: Double?)

    fun summarize(rows: List<Row>) = Summary(
        rows.size,
        rows.mapNotNull { it.recovery?.toDouble() }.takeIf { it.isNotEmpty() }?.average(),
        rows.mapNotNull { it.strain }.takeIf { it.isNotEmpty() }?.average(),
        rows.mapNotNull { it.sleepHours }.takeIf { it.isNotEmpty() }?.average(),
        rows.mapNotNull { it.hrv }.takeIf { it.isNotEmpty() }?.average(),
        rows.mapNotNull { it.rhr?.toDouble() }.takeIf { it.isNotEmpty() }?.average(),
        rows.mapNotNull { it.steps?.toDouble() }.takeIf { it.isNotEmpty() }?.average(),
    )
}
