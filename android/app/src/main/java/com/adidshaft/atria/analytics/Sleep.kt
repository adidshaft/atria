package com.adidshaft.atria.analytics

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/** One civil minute of strap evidence. [activity] is accel-magnitude SD in g (null = no motion data). */
data class EvidenceMinute(val startMs: Long, val meanHr: Double?, val hrCount: Int, val activity: Double?, val steps: Int)

enum class SleepStage(val label: String) { AWAKE("Awake"), REM("REM"), LIGHT("Light"), DEEP("Deep") }

data class StageSegment(val startMs: Long, val endMs: Long, val stage: SleepStage)

data class SleepCandidate(
    val startMs: Long,
    val endMs: Long,
    val asleepMs: Long,
    val isNap: Boolean,
    val hrCoverage: Double,
    val motionValidated: Boolean,
    val autoConfirmable: Boolean,
    val restingHr: Int?,
) {
    val durationHours get() = asleepMs / 3_600_000.0
    val efficiency get() = if (endMs > startMs) asleepMs.toDouble() / (endMs - startMs) else 0.0
}

/**
 * Sleep detection from HR + strap motion. Constants mirror
 * AggregateSleepCandidate (Sessions.swift): 5-min fragments, 20-min gap credit,
 * naps 20 min–3 h, main sleep ≥ 3 h, auto-confirm only ≥ 5 h with ≥ 80 % HR
 * coverage — everything else is review-first. No clock-of-day gating: shifted
 * schedules (afternoon main sleep) are real and must not be penalised.
 *
 * The discriminator is relative to the wearer: minute HR well below their own
 * awake level, and wrist motion near-still (sleep ≈ 0.05–0.8 ticks/min vs
 * 8–12 awake, a 10× separation proven on device).
 */
object SleepDetector {
    const val MIN_FRAGMENT_MIN = 5
    const val GAP_CREDIT_MIN = 20
    const val NAP_MIN_MIN = 20
    const val NAP_MAX_MIN = 180
    const val MAIN_MIN_MIN = 180
    const val AUTO_CONFIRM_MIN = 300
    const val MAX_SPAN_MIN = 12 * 60
    private const val STILL_ACTIVITY_G = 0.012

    fun detect(minutes: List<EvidenceMinute>, restingHr: Double?, phoneInUse: List<LongRange> = emptyList()): List<SleepCandidate> {
        if (minutes.size < NAP_MIN_MIN) return emptyList()
        val sorted = minutes.sortedBy { it.startMs }
        val hrValues = sorted.mapNotNull { it.meanHr }
        if (hrValues.size < NAP_MIN_MIN) return emptyList()
        val q = hrValues.sorted()
        val awakeMedian = q[q.size / 2]
        val rest = restingHr ?: q[(q.size * 0.05).toInt()]
        // Asleep when HR sits in the lower part of the rest→awake span.
        val threshold = rest + max(4.0, (awakeMedian - rest) * 0.45)

        val asleep = BooleanArray(sorted.size) { i ->
            val m = sorted[i]
            val hrOk = m.meanHr != null && m.meanHr <= threshold
            val still = m.activity?.let { it <= STILL_ACTIVITY_G } ?: true
            // Sustained phone use is hard evidence of being awake (device-use journal).
            val usingPhone = phoneInUse.any { m.startMs in it }
            hrOk && still && m.steps == 0 && !usingPhone
        }
        // 5-minute majority smoothing.
        val smooth = BooleanArray(sorted.size) { i ->
            val lo = max(0, i - 2); val hi = min(sorted.lastIndex, i + 2)
            (lo..hi).count { asleep[it] } * 2 > (hi - lo + 1)
        }
        val runs = ArrayList<IntRange>()
        var s = -1
        for (i in smooth.indices) {
            val contiguous = i == 0 || sorted[i].startMs - sorted[i - 1].startMs <= 120_000
            if (smooth[i] && contiguous) { if (s < 0) s = i } else {
                if (s >= 0) runs += s until i
                s = if (smooth[i]) i else -1
            }
        }
        if (s >= 0) runs += s until sorted.size
        val fragments = runs.filter { (sorted[it.last].startMs - sorted[it.first].startMs) / 60_000 + 1 >= MIN_FRAGMENT_MIN }
        // Merge fragments separated by ≤ 20 min (brief wake credit).
        val merged = ArrayList<MutableList<IntRange>>()
        for (f in fragments) {
            val last = merged.lastOrNull()
            if (last != null && (sorted[f.first].startMs - sorted[last.last().last].startMs) / 60_000 <= GAP_CREDIT_MIN) last += f
            else merged += mutableListOf(f)
        }
        return merged.mapNotNull { group ->
            val start = sorted[group.first().first].startMs
            val end = sorted[group.last().last].startMs + 60_000
            val spanMin = (end - start) / 60_000
            val asleepMin = group.sumOf { it.last - it.first + 1 }.toLong()
            if (asleepMin < NAP_MIN_MIN || spanMin > MAX_SPAN_MIN) return@mapNotNull null
            val window = sorted.filter { it.startMs in start until end }
            val coverage = window.count { it.meanHr != null }.toDouble() / max(1, spanMin.toInt())
            val motion = window.count { it.activity != null }.toDouble() / max(1, window.size) >= 0.6
            val isNap = asleepMin < MAIN_MIN_MIN
            val sleepingHr = window.mapNotNull { it.meanHr }.sorted()
            SleepCandidate(
                start, end, asleepMin * 60_000, isNap, coverage, motion,
                autoConfirmable = !isNap && asleepMin >= AUTO_CONFIRM_MIN && coverage >= 0.80,
                restingHr = sleepingHr.takeIf { it.size >= 10 }?.let { lowestRollingMean(it) },
            )
        }
    }

    /** Sleeping resting HR: mean of the lowest 10-minute stretch (sorted values approximate it). */
    private fun lowestRollingMean(sortedHr: List<Double>): Int = sortedHr.take(10).average().roundToInt()

    /**
     * HR/HRV/motion stage estimate per minute. Labelled an estimate in UI:
     * only motion-validated nights get the full hypnogram.
     */
    fun stages(minutes: List<EvidenceMinute>, startMs: Long, endMs: Long, rmssdByMinute: Map<Long, Double> = emptyMap()): List<StageSegment> {
        val w = minutes.filter { it.startMs in startMs until endMs && it.meanHr != null }.sortedBy { it.startMs }
        if (w.size < 30) return emptyList()
        val hr = w.map { it.meanHr!! }
        val mean = hr.average()
        val sd = sqrt(hr.sumOf { (it - mean).pow(2) } / hr.size).coerceAtLeast(1.0)
        val q20 = hr.sorted()[(hr.size * 0.2).toInt()]
        val total = (endMs - startMs).toDouble()
        // Local HR variability, ranked against this night only (relative, per-wearer — never an
        // absolute constant, so steady sleepers and variable sleepers both get REM estimates).
        val localVar = hr.indices.map { i ->
            val local = hr.subList(max(0, i - 3), min(hr.size, i + 4))
            val m = local.average()
            sqrt(local.map { (it - m).pow(2) }.average())
        }
        val varSorted = localVar.sorted()
        val remVar = varSorted[(varSorted.size * 0.70).toInt().coerceAtMost(varSorted.lastIndex)]
        val deepVar = varSorted[(varSorted.size * 0.40).toInt()]
        val median = hr.sorted()[hr.size / 2]
        val labels = w.mapIndexed { i, m ->
            val h = m.meanHr!!
            val moving = (m.activity ?: 0.0) > 0.02 || m.steps > 0
            val progress = (m.startMs - startMs) / total
            val rmssd = rmssdByMinute[m.startMs]
            when {
                moving || h > mean + 1.5 * sd -> SleepStage.AWAKE
                h <= q20 && localVar[i] <= deepVar && progress < 0.65 && (rmssd == null || rmssd > 0) -> SleepStage.DEEP
                localVar[i] >= remVar && h >= median && progress > 0.20 -> SleepStage.REM
                else -> SleepStage.LIGHT
            }
        }
        // Collapse into segments, absorbing 1-minute flickers.
        val segments = ArrayList<StageSegment>()
        for (i in w.indices) {
            val st = labels[i]
            val t0 = w[i].startMs; val t1 = t0 + 60_000
            val last = segments.lastOrNull()
            if (last != null && last.stage == st && t0 - last.endMs <= 120_000) segments[segments.lastIndex] = last.copy(endMs = t1)
            else segments += StageSegment(t0, t1, st)
        }
        val cleaned = ArrayList<StageSegment>()
        for (seg in segments) {
            val prev = cleaned.lastOrNull()
            if (prev != null && seg.endMs - seg.startMs <= 60_000) cleaned[cleaned.lastIndex] = prev.copy(endMs = seg.endMs)
            else if (prev != null && prev.stage == seg.stage) cleaned[cleaned.lastIndex] = prev.copy(endMs = seg.endMs)
            else cleaned += seg
        }
        return cleaned
    }

    fun stageMinutes(segments: List<StageSegment>): Map<SleepStage, Int> =
        SleepStage.entries.associateWith { st -> segments.filter { it.stage == st }.sumOf { ((it.endMs - it.startMs) / 60_000).toInt() } }

    /** Wake-ups: awake segments ≥ 2 min inside the window. */
    fun disturbances(segments: List<StageSegment>) = segments.count { it.stage == SleepStage.AWAKE && it.endMs - it.startMs >= 120_000 }
}

/** Sleep need/debt/performance, ported from AtriaSleepBudget. */
object SleepBudget {
    const val MAX_DEBT_HOURS = 8.0

    data class Need(val base: Double, val strainAdder: Double, val debtAdder: Double, val napCredit: Double, val total: Double)

    fun typical(slept: List<Double>): Double? = slept.filter { it.isFinite() && it >= 5 }.sorted().let { if (it.isEmpty()) null else it[it.size / 2] }

    fun adaptedBase(configured: Double, typical: Double?): Double {
        val safe = configured.coerceIn(6.0, 10.0)
        return if (typical == null) safe else (safe + typical.coerceIn(6.0, 10.0)) / 2
    }

    fun need(configured: Double, yesterdayStrain: Double?, debtHours: Double, napHours: Double, typical: Double?): Need {
        val base = adaptedBase(configured, typical)
        val strain = max(0.0, min(yesterdayStrain ?: 0.0, 21.0) - 8.0) * (0.62 / 7.0)
        val debt = min(max(0.0, debtHours), MAX_DEBT_HOURS) * 0.5
        val nap = max(0.0, napHours) * 0.9
        return Need(base, strain, debt, nap, (base + strain + debt - nap).coerceIn(6.0, 10.0))
    }

    /** [nights] oldest→newest as (needed, slept); 7-night decaying shortfall. */
    fun debt(nights: List<Pair<Double, Double>>): Double {
        val recent = nights.takeLast(7)
        var acc = 0.0
        recent.forEachIndexed { i, n -> acc += max(0.0, n.first - n.second) * 0.75.pow((recent.size - i - 1).toDouble()) }
        return min(acc, MAX_DEBT_HOURS)
    }

    fun debtNights(slept: List<Double>, typical: Double): List<Pair<Double, Double>> {
        val t = typical.coerceIn(6.0, 10.0)
        return slept.filter { it.isFinite() && it >= 5 }.map { h -> (if (h >= t * 0.9) h else t) to h }
    }

    fun performance(slept: Double, needed: Double) = if (needed <= 0) 0 else ((slept / needed) * 100).roundToInt().coerceIn(0, 100)
}

/**
 * Circular-clock sleep consistency: bedtimes/wake times are angles on a 24 h
 * clock, so a 23:30/00:30 pair is 1 h apart (not 23 h) and afternoon sleepers
 * are not split by a noon anchor (the bimodal defect fixed on iOS).
 */
object SleepConsistency {
    data class Result(val percent: Int, val typicalBedMinute: Int, val typicalWakeMinute: Int, val withinHour: Int, val nights: Int)

    fun of(nights: List<Pair<Int, Int>>): Result? { // (bed minute-of-day, wake minute-of-day)
        if (nights.size < 3) return null
        val bed = circularMean(nights.map { it.first })
        val wake = circularMean(nights.map { it.second })
        val dev = nights.map { (circularDistance(it.first, bed) + circularDistance(it.second, wake)) / 2.0 }
        val meanDev = dev.average()
        val percent = (100 * (1 - meanDev / 180.0)).roundToInt().coerceIn(0, 100)
        return Result(percent, bed, wake, nights.count { circularDistance(it.first, bed) <= 60 }, nights.size)
    }

    fun circularMean(minutes: List<Int>): Int {
        var sx = 0.0; var sy = 0.0
        for (m in minutes) { val a = 2 * PI * m / 1440; sx += cos(a); sy += sin(a) }
        val a = atan2(sy, sx).let { if (it < 0) it + 2 * PI else it }
        return ((a / (2 * PI)) * 1440).roundToInt() % 1440
    }

    fun circularDistance(a: Int, b: Int): Int { val d = abs(a - b) % 1440; return min(d, 1440 - d) }
}

/** Smart-wake planner (AlarmKit replacement keeps the same decision rule). */
object SmartWakePlanner {
    enum class Mode(val title: String) { EXACT("Exact time"), SMART_WINDOW("Smart window"), SLEEP_NEED_MET("Sleep-need met") }
    const val WINDOW_MS = 30 * 60_000L
    sealed interface Decision { data class Wait(val reason: String) : Decision; data class Fire(val reason: String) : Decision }

    fun decide(mode: Mode, nowMs: Long, hardAlarmMs: Long, sleptHours: Double, neededHours: Double, recent: List<Pair<HrSample, SleepStage>>): Decision {
        if (nowMs >= hardAlarmMs) return Decision.Fire("wake_by_reached")
        return when (mode) {
            Mode.EXACT -> Decision.Wait("exact_time_waiting")
            Mode.SLEEP_NEED_MET -> if (sleptHours >= neededHours) Decision.Fire("sleep_need_met") else Decision.Wait("sleep_need_not_met")
            Mode.SMART_WINDOW -> {
                if (nowMs < hardAlarmMs - WINDOW_MS) return Decision.Wait("before_smart_window")
                val r = recent.filter { it.first.t >= nowMs - 600_000 && it.first.t <= nowMs }.sortedBy { it.first.t }
                if (r.size < 2) return Decision.Wait("insufficient_recent_samples")
                val lightOrAwake = r.any { it.second == SleepStage.LIGHT || it.second == SleepStage.AWAKE }
                if (lightOrAwake && r.last().first.bpm - r.first().first.bpm >= 0) Decision.Fire("light_stage_hr_slope_nonnegative") else Decision.Wait("not_light_or_hr_falling")
            }
        }
    }
}
