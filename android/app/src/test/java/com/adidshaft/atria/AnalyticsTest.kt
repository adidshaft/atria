package com.adidshaft.atria

import com.adidshaft.atria.analytics.BehaviorImpact
import com.adidshaft.atria.analytics.BiologicalSex
import com.adidshaft.atria.analytics.EvidenceMinute
import com.adidshaft.atria.analytics.HrSample
import com.adidshaft.atria.analytics.HrZone
import com.adidshaft.atria.analytics.HrvAnalyzer
import com.adidshaft.atria.analytics.PersonalBaseline
import com.adidshaft.atria.analytics.Recovery
import com.adidshaft.atria.analytics.RespiratoryRate
import com.adidshaft.atria.analytics.RrInterval
import com.adidshaft.atria.analytics.SleepBudget
import com.adidshaft.atria.analytics.SleepConsistency
import com.adidshaft.atria.analytics.SleepDetector
import com.adidshaft.atria.analytics.SmartWakePlanner
import com.adidshaft.atria.analytics.StrainLoadModel
import com.adidshaft.atria.analytics.StrapPedometer
import com.adidshaft.atria.analytics.StressModel
import com.adidshaft.atria.analytics.TrainingLoadSummary
import com.adidshaft.atria.analytics.WalkBoutDetector
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

class AnalyticsTest {
    private fun series(seconds: Int, bpm: Int, step: Int = 1) = (0..seconds step step).map { HrSample(it * 1000L, bpm) }

    /** Mirrors AtriaStrainLoadModelTests: load scales linearly with duration; gaps > 15 s drop. */
    @Test fun strainLoadIsLinearInDurationAndDropsGaps() {
        val ten = StrainLoadModel.calculate(series(600, 150), 60, 190, BiologicalSex.MALE, StrainLoadModel.Mode.WORKOUT)
        val twenty = StrainLoadModel.calculate(series(1200, 150), 60, 190, BiologicalSex.MALE, StrainLoadModel.Mode.WORKOUT)
        assertTrue(ten.load > 0)
        assertEquals(ten.load * 2, twenty.load, 1e-9)
        assertEquals(600.0, ten.acceptedSeconds, 1e-9)
        val gap = StrainLoadModel.calculate(listOf(HrSample(0, 150), HrSample(15_001, 150)), 60, 190, BiologicalSex.MALE, StrainLoadModel.Mode.WORKOUT)
        assertEquals(0.0, gap.load, 0.0)
        assertEquals(15.001, gap.droppedGapSeconds, 1e-9)
    }

    @Test fun continuousDayIgnoresSubFloorHeartRate() {
        val day = StrainLoadModel.calculate(series(3600, 75), 60, 190, BiologicalSex.MALE, StrainLoadModel.Mode.CONTINUOUS_DAY)
        assertEquals(0.0, day.load, 0.0)
    }

    @Test fun displayScoreIsBoundedAt21() {
        assertEquals(0.0, StrainLoadModel.displayScore(0.0), 0.0)
        assertTrue(StrainLoadModel.displayScore(10_000.0) <= 21.0)
        assertEquals(21 * (1 - kotlin.math.exp(-1.0)), StrainLoadModel.displayScore(100.0), 1e-9)
    }

    @Test fun zonesUseHeartRateReserve() {
        assertEquals(HrZone.REST, HrZone.of(100, 190, 60))      // 30 % HRR
        assertEquals(HrZone.AEROBIC, HrZone.of(155, 190, 60))   // 73 % HRR
        assertEquals(HrZone.MAX, HrZone.of(185, 190, 60))
    }

    @Test fun recoveryLogisticMatchesIos() {
        assertEquals(58, Recovery.logistic(0.0)) // 100/(1+e^(-1.6·0.2))
        assertEquals(99, Recovery.logistic(5.0))
        assertEquals(1, Recovery.logistic(-5.0))
    }

    @Test fun recoveryUsesSleepWhenHrvMissing() {
        val e = Recovery.estimate(null, null, PersonalBaseline(), 0.92, 8.0, null, null, null, System.currentTimeMillis())
        assertNotNull(e.percent)
        assertFalse(e.usesHrv)
        assertTrue(e.percent!! > 50)
    }

    @Test fun baselineIsOnePerDayAndTrustedAt14() {
        var b = PersonalBaseline()
        val now = System.currentTimeMillis()
        for (d in 0 until 14) b = b.learn(55 + (d % 3), 60, now - d * 86_400_000L, overnight = true)
        b = b.learn(70, 40, now, overnight = false) // same day, non-overnight: must not replace
        assertEquals(14, b.freshRestingDays(now))
        assertTrue(b.hasTrustedResting(now))
        assertTrue(b.hasTrustedHrv(now))
    }

    @Test fun hrvAnalyzerComputesRmssdForCleanWindow() {
        val now = 400_000L
        var t = now - 300_000
        val rr = ArrayList<RrInterval>()
        var i = 0
        while (t <= now) { val ms = if (i % 2 == 0) 1000.0 else 1040.0; rr += RrInterval(t, ms); t += ms.toLong(); i++ }
        val s = HrvAnalyzer.analyze(rr, now)!!
        assertEquals(40.0, s.rmssd, 0.5)
        assertTrue(s.isReady)
    }

    @Test fun respiratoryRateFindsSinusArrhythmia() {
        val rate = 4.0
        val x = (0 until 240).map { 1000 + 40 * sin(2 * PI * (15.0 / 60) * it / rate) }
        assertEquals(15.0, RespiratoryRate.estimateResampled(x, rate)!!, 0.6)
    }

    @Test fun pedometerCountsSyntheticWalkAndIgnoresStillness() {
        val walk = (0 until 100 * 60).map { 1.0 + 0.25 * sin(2 * PI * 1.8 * it / 100.0) }
        val steps = StrapPedometer.count(walk)
        assertTrue("steps=$steps", steps in 90..125)
        assertEquals(0, StrapPedometer.count(List(6000) { 1.0 }))
    }

    @Test fun walkBoutNeedsEightMinutes() {
        val base = 1_000_000L * 60_000
        val minutes = (0 until 10).map { WalkBoutDetector.Minute(base + it * 60_000L, 100) }
        val bout = WalkBoutDetector.latest(minutes, base + 20 * 60_000L)!!
        assertEquals(1000, bout.steps)
        assertNull(WalkBoutDetector.latest(minutes.take(5), base + 20 * 60_000L))
    }

    @Test fun sleepDetectorFindsNightAndNapIndependentOfClock() {
        val start = 1_800_000_000_000L
        val minutes = ArrayList<EvidenceMinute>()
        for (m in 0 until 24 * 60) {
            val asleep = m in 120..(120 + 420) || m in 900..960 // 7 h main + 60 min afternoon nap
            minutes += EvidenceMinute(start + m * 60_000L, if (asleep) 52.0 else 78.0, 60, if (asleep) 0.003 else 0.06, if (asleep) 0 else 5)
        }
        val c = SleepDetector.detect(minutes, 50.0)
        assertEquals(2, c.size)
        assertFalse(c[0].isNap); assertTrue(c[0].autoConfirmable)
        assertTrue(c[1].isNap); assertFalse(c[1].autoConfirmable)
    }

    @Test fun sleepNeedAndDebt() {
        val need = SleepBudget.need(8.0, 15.0, 2.0, 0.0, null)
        assertEquals(8.0 + 7 * 0.62 / 7 + 1.0, need.total, 1e-9)
        assertEquals(0.0, SleepBudget.debt(listOf(8.0 to 8.0)), 0.0)
        assertTrue(SleepBudget.debt(listOf(8.0 to 6.0, 8.0 to 6.0)) > 2.0)
    }

    @Test fun consistencyIsCircularAcrossMidnight() {
        val r = SleepConsistency.of(listOf(1410 to 420, 30 to 450, 1425 to 430, 10 to 440))!!
        assertTrue(r.percent > 85)
        assertTrue(SleepConsistency.circularDistance(1430, 10) == 20)
    }

    @Test fun trainingLoadReadiness() {
        assertEquals("learning", TrainingLoadSummary.of(emptyList()).readiness)
        val spike = TrainingLoadSummary.of(List(7) { 18.0 } + List(21) { 6.0 })
        assertEquals("rundown", spike.readiness)
    }

    @Test fun stressIsCalmAtRestAndHighUnderLoad() {
        val p = StressModel.Personalization(55.0, 190.0, 20, null, null)
        fun window(bpm: Int) = (0..300 step 5).map { HrSample(it * 1000L, bpm) }
        val calm = StressModel.evaluate(300_000, window(58), emptyList(), p, null, null)!!
        val high = StressModel.evaluate(300_000, window(120), emptyList(), p, null, null)!!
        assertEquals(StressModel.Zone.CALM, calm.zone)
        assertEquals(StressModel.Zone.HIGH, high.zone)
    }

    @Test fun smartWakeFiresInLightStageWithinWindow() {
        val hard = 10_000_000L
        val now = hard - 10 * 60_000
        val recent = listOf(HrSample(now - 300_000, 55) to com.adidshaft.atria.analytics.SleepStage.LIGHT, HrSample(now - 1000, 57) to com.adidshaft.atria.analytics.SleepStage.LIGHT)
        assertTrue(SmartWakePlanner.decide(SmartWakePlanner.Mode.SMART_WINDOW, now, hard, 7.0, 8.0, recent) is SmartWakePlanner.Decision.Fire)
        assertTrue(SmartWakePlanner.decide(SmartWakePlanner.Mode.SMART_WINDOW, hard - 3_600_000, hard, 7.0, 8.0, recent) is SmartWakePlanner.Decision.Wait)
    }

    @Test fun behaviorImpactWelchGate() {
        val with = listOf(40.0, 42.0, 38.0, 41.0, 39.0, 43.0)
        val without = listOf(70.0, 68.0, 72.0, 69.0, 71.0, 73.0)
        val r = BehaviorImpact.evaluate(with, without, BehaviorImpact.Expected.DISRUPTIVE, "Alcohol")!!
        assertTrue(r.significant)
        assertTrue(r.pValue < 0.001)
        assertNull(BehaviorImpact.evaluate(with.take(4), without, BehaviorImpact.Expected.DISRUPTIVE, "Alcohol"))
    }
}
