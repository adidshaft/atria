package com.adidshaft.atria.domain

import com.adidshaft.atria.analytics.Energy
import com.adidshaft.atria.analytics.HrSample
import com.adidshaft.atria.analytics.HrvAnalyzer
import com.adidshaft.atria.analytics.MaxHrLearning
import com.adidshaft.atria.analytics.PersonalBaseline
import com.adidshaft.atria.analytics.Recovery
import com.adidshaft.atria.analytics.RespiratoryRate
import com.adidshaft.atria.analytics.SleepBudget
import com.adidshaft.atria.analytics.SleepDetector
import com.adidshaft.atria.analytics.StageSegment
import com.adidshaft.atria.analytics.Stats
import com.adidshaft.atria.analytics.StrainLoadModel
import com.adidshaft.atria.analytics.StressModel
import com.adidshaft.atria.analytics.TrainingLoadSummary
import com.adidshaft.atria.analytics.HrZone
import com.adidshaft.atria.data.AppJson
import com.adidshaft.atria.data.DailyMetricsEntity
import com.adidshaft.atria.data.Repository
import com.adidshaft.atria.data.SleepEntity
import com.adidshaft.atria.data.Source
import com.adidshaft.atria.data.StressFactEntity
import com.adidshaft.atria.data.WorkoutEntity
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.roundToInt
import kotlin.math.sqrt

@Serializable
data class StoredStage(val s: Long, val e: Long, val k: String)

fun encodeStages(segments: List<StageSegment>) = AppJson.encodeToString(kotlinx.serialization.builtins.ListSerializer(StoredStage.serializer()), segments.map { StoredStage(it.startMs, it.endMs, it.stage.name) })
fun decodeStages(json: String?): List<StageSegment> = json?.let {
    runCatching { AppJson.decodeFromString(kotlinx.serialization.builtins.ListSerializer(StoredStage.serializer()), it) }.getOrNull()
        ?.map { s -> StageSegment(s.s, s.e, com.adidshaft.atria.analytics.SleepStage.valueOf(s.k)) }
} ?: emptyList()

/**
 * Recomputes the physiological day: detected sleep → recovery, continuous-day
 * strain, steps, calories, stress facts and the personal baseline. Equivalent of
 * the iOS rollup/projection coordinators, without their multi-store fences
 * (Room transactions give one authority).
 */
class MetricsEngine(
    private val repo: Repository,
    /** Motion-context gate (Activity Recognition): driving is never a workout. */
    private val wasDriving: (Long, Long) -> Boolean = { _, _ -> false },
    /** Device-use journal: intervals of sustained phone use (awake evidence). */
    private val phoneInUse: (Long, Long) -> List<LongRange> = { _, _ -> emptyList() },
) {
    private val mutex = Mutex()
    private val zone: ZoneId get() = ZoneId.systemDefault()

    suspend fun refresh(day: LocalDate = repo.today()) = mutex.withLock {
        val settings = repo.settings.current()
        val profile = settings.profile.toAthlete()
        val now = System.currentTimeMillis()
        val (dayStart, dayEnd) = repo.dayBounds(day)

        if (settings.autoDetectSleep) detectSleep(now)
        learnMaxHr(now)

        var baseline = repo.settings.currentBaseline()
        val main = mainSleepFor(day)
        val rest = baseline.restingEma?.roundToInt() ?: main?.restingHr ?: 60
        val maxHr = repo.settings.current().profile.toAthlete().estimatedMaxHr

        // --- Recovery from the main sleep that ended on this day ---
        var recovery: Recovery.Estimate? = null
        var rmssd: Double? = null
        var resp: Double? = null
        if (main != null) {
            val rr = repo.rr(main.startMs, main.endMs)
            rmssd = main.rmssd ?: HrvAnalyzer.overnightRmssd(rr, main.startMs, main.endMs)
            resp = main.respiratoryRate ?: rr.takeLast(400).takeIf { it.size > 60 }?.let { tail ->
                RespiratoryRate.estimate(tail.map { it.t to it.ms }, tail.last().t)
            }
            if (main.rmssd == null && rmssd != null || main.respiratoryRate == null && resp != null) {
                repo.db.sleeps().upsert(main.copy(rmssd = rmssd, respiratoryRate = resp))
            }
            val history = repo.db.sleeps().recentConfirmed(30).filter { !it.isNap && it.id != main.id }
            val sleepBaseline = if (history.size >= 7) Recovery.SleepBaseline(
                hours = medianScale(history.map { it.asleepMs / 3_600_000.0 }),
                efficiency = medianScale(history.mapNotNull { it.efficiency }),
            ) else null
            val respBaseline = history.mapNotNull { it.respiratoryRate }.takeIf { it.size >= 2 }?.let { v ->
                val m = v.average(); Stats(m, sqrt(v.sumOf { (it - m) * (it - m) } / (v.size - 1)), v.size)
            }
            recovery = Recovery.estimate(rmssd, main.restingHr, baseline, main.efficiency, main.asleepMs / 3_600_000.0, sleepBaseline, resp, respBaseline, now)
            main.restingHr?.let { baseline = baseline.learn(it, rmssd?.roundToInt(), main.endMs, overnight = true) }
            repo.settings.setBaseline(baseline)
        }

        // --- Strain: continuous-day TRIMP + strength muscular equivalent ---
        val hr = repo.hr(dayStart, minOf(dayEnd, now))
        val dayLoad = StrainLoadModel.calculate(hr, rest, maxHr, profile.sex, StrainLoadModel.Mode.CONTINUOUS_DAY).load
        val workouts = repo.db.workouts().between(dayStart, dayEnd).filter { it.status == "confirmed" || it.status == "active" }
        val strain = StrainLoadModel.displayScore(dayLoad)

        // --- Steps, calories, stress, skin temperature ---
        val steps = repo.db.samples().steps(dayStart, dayEnd)
        val calories = Energy.activeCalories(hr, rest, profile)
        val stressFacts = repo.db.stress().between(dayStart, dayEnd)
        val skin = skinDelta(day)

        // --- Sleep need for tonight ---
        val nights = repo.db.sleeps().recentConfirmed(14).filter { !it.isNap }.map { it.asleepMs / 3_600_000.0 }.reversed()
        val typical = SleepBudget.typical(nights)
        val debt = SleepBudget.debt(SleepBudget.debtNights(nights, typical ?: profile.sleepGoalHours))
        val yesterday = repo.db.daily().get(day.minusDays(1).toEpochDay())
        val naps = repo.db.sleeps().between(dayStart, dayEnd).filter { it.isNap && it.status == "confirmed" }.sumOf { it.asleepMs } / 3_600_000.0
        val need = SleepBudget.need(profile.sleepGoalHours, yesterday?.strain, debt, naps, typical)
        val sleptHours = main?.asleepMs?.div(3_600_000.0)
        val performance = sleptHours?.let { SleepBudget.performance(it, main.needHours ?: need.total) }

        repo.db.daily().upsert(
            DailyMetricsEntity(
                epochDay = day.toEpochDay(),
                recovery = recovery?.percent,
                recoveryConfidence = recovery?.confidence?.label,
                strain = (strain * 10).roundToInt() / 10.0,
                sleepHours = sleptHours,
                sleepNeedHours = need.total,
                sleepPerformance = performance,
                restingHr = main?.restingHr,
                hrv = rmssd,
                respiratoryRate = resp,
                steps = steps,
                activeCalories = calories,
                skinTempDelta = skin,
                stressAverage = stressFacts.takeIf { it.isNotEmpty() }?.map { it.score }?.average(),
                updatedAt = now,
            ),
        )
        if (settings.autoDetectWorkouts) detectWorkouts(hr, rest, maxHr, workouts, now)
        if (settings.autoDetectWorkouts) detectMotionRuns(dayStart, now)
        recovery
    }

    /** Recompute every day touched by a drained-history window. */
    suspend fun refreshRange(days: Int = 7) { for (i in days - 1 downTo 0) refresh(repo.today().minusDays(i.toLong())) }

    fun mainSleepEndingOn(sleeps: List<SleepEntity>, day: LocalDate, preferredId: Long? = null): SleepEntity? {
        val sameDay = sleeps.filter { !it.isNap && it.status == "confirmed" && Instant.ofEpochMilli(it.endMs).atZone(zone).toLocalDate() == day }
        return sameDay.firstOrNull { it.id == preferredId } ?: sameDay.maxByOrNull { it.asleepMs }
    }

    /** AtriaSameDayMainSleepSheet: the user's choice when two main sleeps end on one day. */
    suspend fun preferredMainSleepId(day: LocalDate): Long? =
        repo.db.journal().day(day.toEpochDay()).firstOrNull { it.key == "mainsleep" }?.value?.toLongOrNull()

    suspend fun sameDayMainSleeps(day: LocalDate): List<SleepEntity> {
        val (s, e) = repo.dayBounds(day)
        return repo.db.sleeps().between(s - 86_400_000L, e).filter { !it.isNap && it.status == "confirmed" && Instant.ofEpochMilli(it.endMs).atZone(zone).toLocalDate() == day }
    }

    suspend fun mainSleepFor(day: LocalDate): SleepEntity? {
        val (s, e) = repo.dayBounds(day)
        return mainSleepEndingOn(repo.db.sleeps().between(s - 86_400_000L, e), day, preferredMainSleepId(day))
    }

    private suspend fun detectSleep(now: Long) {
        val from = now - 36 * 3_600_000L
        val minutes = repo.evidenceMinutes(from, now)
        val baseline = repo.settings.currentBaseline()
        val candidates = SleepDetector.detect(minutes, baseline.restingEma, phoneInUse(from, now))
        val existing = repo.db.sleeps().between(from - 12 * 3_600_000L, now)
        for (c in candidates) {
            // Ignore a candidate still "open" at the edge of data — it may be ongoing.
            if (now - c.endMs < 20 * 60_000) continue
            val overlap = existing.firstOrNull { overlapFraction(it.startMs, it.endMs, c.startMs, c.endMs) > 0.3 }
            if (overlap != null) {
                if (overlap.status == "candidate" && overlap.source == Source.DETECTED) {
                    repo.db.sleeps().upsert(overlap.copy(startMs = c.startMs, endMs = c.endMs, asleepMs = c.asleepMs, restingHr = c.restingHr, efficiency = c.efficiency, motionValidated = c.motionValidated))
                }
                continue
            }
            val stages = SleepDetector.stages(minutes, c.startMs, c.endMs)
            repo.db.sleeps().insert(
                SleepEntity(
                    startMs = c.startMs, endMs = c.endMs, asleepMs = c.asleepMs, isNap = c.isNap,
                    status = if (c.autoConfirmable) "confirmed" else "candidate",
                    source = Source.DETECTED, restingHr = c.restingHr, efficiency = c.efficiency,
                    stagesJson = encodeStages(stages), motionValidated = c.motionValidated,
                    disturbances = SleepDetector.disturbances(stages),
                ),
            )
            repo.log("detection", "${if (c.autoConfirmable) "auto-confirmed" else "review"} ${if (c.isNap) "nap" else "sleep"} ${c.durationHours.format1()}h · HR coverage ${(c.hrCoverage * 100).toInt()}%${if (c.motionValidated) " · motion" else ""}")
            repo.log("sleep", "detected ${if (c.isNap) "nap" else "sleep"} ${c.durationHours.format1()}h auto=${c.autoConfirmable}")
        }
    }

    /** Review-first workout detection: ≥ 10 min of sustained HRR ≥ 50 %. */
    private suspend fun detectWorkouts(hr: List<HrSample>, rest: Int, maxHr: Int, known: List<WorkoutEntity>, now: Long) {
        if (hr.size < 600 || maxHr <= rest) return
        val threshold = HrZone.lowerBpm(HrZone.WARMUP, rest, maxHr)
        var start = -1
        val bouts = ArrayList<IntRange>()
        for (i in hr.indices) {
            val elevated = hr[i].bpm >= threshold
            val gap = i > 0 && hr[i].t - hr[i - 1].t > 60_000
            if (elevated && !gap) { if (start < 0) start = i } else {
                if (start >= 0) bouts += start until i
                start = if (elevated) i else -1
            }
        }
        if (start >= 0) bouts += start until hr.size
        val merged = ArrayList<IntRange>()
        for (b in bouts) {
            val last = merged.lastOrNull()
            if (last != null && hr[b.first].t - hr[last.last].t < 3 * 60_000) merged[merged.lastIndex] = last.first..b.last else merged += b
        }
        val all = repo.db.workouts().between(hr.first().t, now)
        for (b in merged) {
            val s = hr[b.first].t; val e = hr[b.last].t
            if (e - s < 10 * 60_000 || now - e < 5 * 60_000) continue
            if (wasDriving(s, e)) continue
            if (all.any { overlapFraction(it.startMs, it.endMs, s, e) > 0.2 } || known.any { overlapFraction(it.startMs, it.endMs, s, e) > 0.2 }) continue
            val slice = hr.subList(b.first, b.last + 1)
            val sex = repo.settings.current().profile.toAthlete().sex
            val load = StrainLoadModel.calculate(slice, rest, maxHr, sex, StrainLoadModel.Mode.WORKOUT).load
            val steps = repo.db.samples().steps(s, e)
            repo.db.workouts().insert(
                WorkoutEntity(
                    activity = if (steps > (e - s) / 60_000 * 60) "Walking" else "Other",
                    startMs = s, endMs = e, strain = StrainLoadModel.displayScore(load),
                    avgHr = slice.map { it.bpm }.average().roundToInt(), maxHr = slice.maxOf { it.bpm },
                    calories = Energy.activeCalories(slice, rest, repo.settings.current().profile.toAthlete()),
                    steps = steps.takeIf { it > 0 }, zonesJson = null, status = "review", source = Source.DETECTED,
                ),
            )
            repo.log("detection", "possible workout ${(e - s) / 60_000} min · strain ${"%.1f".format(StrainLoadModel.displayScore(load))}")
            repo.log("workout", "possible workout ${(e - s) / 60_000} min")
        }
    }

    /** Unattributed walking (strap steps) → "Was this a walk?" review, max 3 per day. */
    private suspend fun detectMotionRuns(dayStart: Long, now: Long) {
        val minutes = repo.db.samples().motion(dayStart, now).map { it.startMs to it.steps }
        val explained = repo.db.workouts().between(dayStart - 3_600_000L, now).map { it.startMs..it.endMs } +
            repo.db.sleeps().between(dayStart - 12 * 3_600_000L, now).filter { it.status != "dismissed" }.map { it.startMs..it.endMs }
        val askedToday = repo.db.workouts().between(dayStart, now).count { it.source == Source.MOTION }
        com.adidshaft.atria.analytics.MotionRuns.askable(minutes, explained)
            .filter { now - it.endMs > 5 * 60_000 }
            .take((com.adidshaft.atria.analytics.MotionRuns.MAX_QUESTIONS_PER_DAY - askedToday).coerceAtLeast(0))
            .forEach { r ->
                val hr = repo.hr(r.startMs, r.endMs)
                repo.db.workouts().insert(WorkoutEntity(
                    activity = "Walking", startMs = r.startMs, endMs = r.endMs, strain = 0.0,
                    avgHr = hr.takeIf { it.isNotEmpty() }?.map { it.bpm }?.average()?.roundToInt() ?: 0, maxHr = hr.maxOfOrNull { it.bpm } ?: 0,
                    calories = null, steps = r.steps, zonesJson = null, status = "review", source = Source.MOTION,
                ))
                repo.log("detection", "unexplained walking ${r.activeMinutes} min · ${r.steps} steps · asking")
            }
    }

    private suspend fun learnMaxHr(now: Long) {
        val peak = MaxHrLearning.sustainedPeak(repo.hr(now - 6 * 3_600_000L, now)) ?: return
        repo.settings.update { s -> if (peak > (s.profile.learnedMaxHr ?: 0) && peak > s.profile.toAthlete().estimatedMaxHr) s.copy(profile = s.profile.copy(learnedMaxHr = peak)) else s }
    }

    /** Minute stress fact for the live window (called once a minute by the service). */
    suspend fun stressTick(now: Long) {
        val hr = repo.hr(now - StressModel.WINDOW_MS, now)
        if (hr.size < 5) return
        val rr = repo.rr(now - StressModel.WINDOW_MS, now)
        val baseline = repo.settings.currentBaseline()
        val rest = baseline.restingEma ?: return
        val profile = repo.settings.current().profile.toAthlete()
        val robust = baseline.robustHrv(now)
        val p = StressModel.Personalization(
            rest, profile.estimatedMaxHr.toDouble(), baseline.freshRestingDays(now),
            robust?.let { StressModel.HrvBaseline(it.location, it.scale, it.count) }, null,
        )
        val motion = repo.db.samples().motion(now - 5 * 60_000, now)
        val intensity = motion.takeIf { it.isNotEmpty() }?.let { m -> (m.map { it.activityG }.average() / 0.15).coerceIn(0.0, 1.0) }
        val prev = repo.db.stress().latest()?.let { StressModel.MinuteFact(it.t, it.score, it.meanHr, null, it.confidence, false) }
        val fact = StressModel.evaluate(now, hr, rr, p, intensity, prev) ?: return
        repo.db.stress().insert(StressFactEntity(fact.t, fact.score, fact.confidence, fact.meanHr))
    }

    private suspend fun skinDelta(day: LocalDate): Double? {
        val sleep = mainSleepFor(day) ?: return null
        val tonight = repo.db.samples().skin(sleep.startMs, sleep.endMs).map { it.celsius }.takeIf { it.size >= 10 }?.average() ?: return null
        val prior = repo.db.sleeps().recentConfirmed(30).filter { !it.isNap && it.id != sleep.id }.mapNotNull { s ->
            repo.db.samples().skin(s.startMs, s.endMs).map { it.celsius }.takeIf { it.size >= 10 }?.average()
        }
        if (prior.size < 3) return null
        return ((tonight - prior.sorted()[prior.size / 2]) * 100).roundToInt() / 100.0
    }

    suspend fun trainingLoad(): TrainingLoadSummary {
        val today = repo.today()
        val days = repo.db.daily().range(today.minusDays(27).toEpochDay(), today.toEpochDay())
        return TrainingLoadSummary.of(days.sortedByDescending { it.epochDay }.mapNotNull { it.strain })
    }

    private fun medianScale(v: List<Double>): Pair<Double, Double>? {
        if (v.size < 3) return null
        val s = v.sorted(); val med = s[s.size / 2]
        val mad = v.map { kotlin.math.abs(it - med) }.sorted()[v.size / 2] * 1.4826
        return med to mad
    }

    companion object {
        fun overlapFraction(a0: Long, a1: Long, b0: Long, b1: Long): Double {
            val o = minOf(a1, b1) - maxOf(a0, b0)
            if (o <= 0) return 0.0
            return o.toDouble() / maxOf(1L, minOf(a1 - a0, b1 - b0))
        }
    }
}

fun Double.format1() = "%.1f".format(this)
