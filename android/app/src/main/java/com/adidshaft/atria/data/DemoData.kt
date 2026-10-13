package com.adidshaft.atria.data

import com.adidshaft.atria.analytics.PersonalBaseline
import com.adidshaft.atria.analytics.SleepDetector
import com.adidshaft.atria.analytics.EvidenceMinute
import com.adidshaft.atria.domain.encodeStages
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.random.Random

/**
 * Sample-data mode (AtriaAppReviewDemo / AtriaDemoDataChrome): a clearly
 * labelled synthetic history so the app can be explored without a strap.
 * Every row is tagged Source.DEMO and removed by [clear].
 */
class DemoData(private val repo: Repository) {
    suspend fun seed(days: Int = 21) {
        val rnd = Random(7)
        val now = System.currentTimeMillis()
        val today = repo.today()
        var baseline = PersonalBaseline()
        for (i in days downTo 0) {
            val day = today.minusDays(i.toLong())
            val (dayStart, _) = repo.dayBounds(day)
            val sleepStart = dayStart - 90 * 60_000L + rnd.nextLong(-30, 30) * 60_000
            val sleepMinutes = (390 + rnd.nextInt(-60, 75))
            val sleepEnd = sleepStart + sleepMinutes * 60_000L
            val rhr = 54 + rnd.nextInt(-3, 5)
            val rmssd = 58.0 + rnd.nextDouble(-14.0, 14.0)
            val minutes = (0 until sleepMinutes).map { m ->
                val hr = rhr + 4 + 3 * sin(2 * PI * m / 90.0) + rnd.nextDouble(-1.5, 1.5)
                EvidenceMinute(sleepStart + m * 60_000L, hr, 60, 0.004, 0)
            }
            val stages = SleepDetector.stages(minutes, sleepStart, sleepEnd)
            if (sleepEnd < now) {
                repo.db.sleeps().insert(
                    SleepEntity(
                        startMs = sleepStart, endMs = sleepEnd, asleepMs = (sleepMinutes * 0.93 * 60_000).toLong(), isNap = false,
                        status = "confirmed", source = Source.DEMO, restingHr = rhr, rmssd = rmssd, respiratoryRate = 14.2 + rnd.nextDouble(-0.8, 0.8),
                        efficiency = 0.93, stagesJson = encodeStages(stages), motionValidated = true, disturbances = rnd.nextInt(1, 5),
                    ),
                )
                baseline = baseline.learn(rhr, rmssd.roundToInt(), sleepEnd, overnight = true)
            }
            if (i % 2 == 0 && i > 0) {
                val ws = dayStart + 18 * 3_600_000L
                val acts = listOf("Running", "Strength", "Cycling", "Yoga", "Walking")
                repo.db.workouts().insert(
                    WorkoutEntity(
                        activity = acts[i % acts.size], startMs = ws, endMs = ws + 45 * 60_000L, strain = 9.0 + rnd.nextDouble(0.0, 6.0),
                        avgHr = 128 + rnd.nextInt(0, 20), maxHr = 165 + rnd.nextInt(0, 15), calories = 380.0 + rnd.nextInt(0, 200),
                        steps = null, zonesJson = "[300.0,600.0,700.0,600.0,400.0,100.0]", status = "confirmed", source = Source.DEMO,
                    ),
                )
            }
            if (i > 0) repo.db.daily().upsert(
                DailyMetricsEntity(
                    epochDay = day.toEpochDay(), recovery = (45 + rnd.nextInt(0, 50)), recoveryConfidence = "sample data",
                    strain = 8.0 + rnd.nextDouble(0.0, 8.0), sleepHours = sleepMinutes * 0.93 / 60, sleepNeedHours = 8.1,
                    sleepPerformance = (sleepMinutes * 0.93 / 60 / 8.1 * 100).roundToInt().coerceAtMost(100), restingHr = rhr, hrv = rmssd,
                    respiratoryRate = 14.2, steps = 6000 + rnd.nextInt(0, 6000), activeCalories = 450.0 + rnd.nextInt(0, 300),
                    skinTempDelta = rnd.nextDouble(-0.4, 0.4), stressAverage = 0.8 + rnd.nextDouble(0.0, 1.0), updatedAt = now,
                ),
            )
        }
        repo.settings.setBaseline(baseline)
        // Today's live-looking HR at 5 s for the last 8 hours.
        val hr = ArrayList<HrSampleEntity>()
        var t = now - 8 * 3_600_000L
        var bpm = 68.0
        while (t < now) {
            bpm += rnd.nextDouble(-1.2, 1.2) + (68 - bpm) * 0.02
            hr += HrSampleEntity(t, bpm.roundToInt().coerceIn(50, 150), Source.DEMO)
            t += 5_000
        }
        repo.db.samples().insertHr(hr)
        repo.settings.update { it.copy(demoMode = true) }
    }

    suspend fun clear() {
        val db = repo.db
        db.sleeps().between(0, Long.MAX_VALUE).filter { it.source == Source.DEMO }.forEach { db.sleeps().delete(it.id) }
        db.workouts().between(0, Long.MAX_VALUE).filter { it.source == Source.DEMO }.forEach { db.workouts().delete(it.id) }
        db.samples().deleteHrBySource(Source.DEMO)
        db.daily().deleteSampleRows()
        repo.settings.setBaseline(PersonalBaseline())
        repo.settings.update { it.copy(demoMode = false) }
    }
}
