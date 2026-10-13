package com.adidshaft.atria

import com.adidshaft.atria.analytics.CycleTracking
import com.adidshaft.atria.analytics.FaceOff
import com.adidshaft.atria.analytics.IrregularRhythm
import com.adidshaft.atria.analytics.RrInterval
import com.adidshaft.atria.analytics.SleepPlanner
import com.adidshaft.atria.analytics.StrengthProgress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class ExtrasTest {
    /** Encoded on macOS by Foundation's NSData.compressed(using: .zlib), exactly as iOS AtriaFaceOff does. */
    private val iosLink = "Jcs7CoAwEEXRvbx6CCYaY6bWFViKRdCAjR8UBJXsXRnLC-c-GMN1gLsHKzgj3GCnCsIEtoawf6kJn9BG5YmEaWGl8j8rhFkrzKsq9YQlzBGMNswgnLLEZWy2dZjqcIFN5nKfXg"

    @Test fun decodesIosFaceOffLink() {
        val p = FaceOff.decode(iosLink)!!
        assertEquals("Sam", p.name)
        assertEquals(20739, p.endEpochDay)
        assertEquals(71, p.days[0].r)
        assertEquals(12.3, p.days[0].s!!, 1e-9)
        assertEquals(54, p.days[1].h)
    }

    @Test fun faceOffRoundTrips() {
        val p = FaceOff.makePayload("Alex", listOf(FaceOff.DayRow(100, 60, 10.04, 7.26, 50), FaceOff.DayRow(99, 70, null, 8.0, null)))!!
        val back = FaceOff.decode(FaceOff.encode(p))!!
        assertEquals(p, back)
        assertTrue(FaceOff.url(p).startsWith("atria://compare?d="))
    }

    @Test fun cyclePhaseCalendarEstimate() {
        val e = CycleTracking.estimate(listOf(CycleTracking.Period(1000, 1004)), 1002)!!
        assertEquals(CycleTracking.Phase.MENSTRUAL, e.phase)
        assertEquals(3, e.cycleDay)
        assertEquals(CycleTracking.Phase.OVULATORY, CycleTracking.estimate(listOf(CycleTracking.Period(1000, 1004)), 1013)!!.phase)
        assertEquals(CycleTracking.Phase.LUTEAL, CycleTracking.estimate(listOf(CycleTracking.Period(1000, 1004)), 1020)!!.phase)
    }

    @Test fun rhythmCheckIsFailClosed() {
        val now = 400_000L
        // Regular sinus rhythm → never "signs".
        var t = now - 300_000; val regular = ArrayList<RrInterval>()
        while (t <= now) { regular += RrInterval(t, 900.0 + (t / 1000 % 3)); t += 900 }
        assertEquals(IrregularRhythm.Outcome.INSUFFICIENT, IrregularRhythm.evaluate(regular, now).outcome)
        // Chaotic intervals within rate bounds → signs.
        val rnd = Random(3); t = now - 300_000; val chaotic = ArrayList<RrInterval>()
        while (t <= now) { val ms = 600.0 + rnd.nextDouble() * 700; chaotic += RrInterval(t, ms); t += ms.toLong() }
        val r = IrregularRhythm.evaluate(chaotic, now)
        assertNotNull(r.largeFraction)
        assertEquals(IrregularRhythm.Outcome.SIGNS, r.outcome)
    }

    @Test fun sleepPlannerWorksBackwardsFromWake() {
        val plan = SleepPlanner.plan(8.0, SleepPlanner.Goal.PEAK, 7 * 60, emptyList())
        assertEquals(8.0, plan.targetSleepHours, 1e-9)
        assertEquals(((7 * 60 - (8.0 / 0.9 * 60).toInt() + 1440) % 1440).toDouble(), plan.inBedByMinute.toDouble(), 1.0)
    }

    @Test fun epleyE1rm() {
        assertEquals(100.0 * (1 + 10 / 30.0), StrengthProgress.e1rm(100.0, 10), 1e-9)
        val lifts = StrengthProgress.summarize(listOf(Triple("Squat", 5 to 100.0, 1L), Triple("squat ", 5 to 110.0, 2L)))
        assertEquals(1, lifts.size)
        assertEquals(110.0 * (1 + 5 / 30.0) - 100.0 * (1 + 5 / 30.0), lifts[0].deltaVsFirst!!, 1e-9)
    }
}

class DeviceUseTest {
    @Test fun sustainedUseMergesShortGapsAndDropsBriefChecks() {
        val m = 60_000L
        val events = listOf(0L to true, 4 * m to false, 4 * m + 30_000 to true, 12 * m to false, 30 * m to true, 32 * m to false)
        val r = com.adidshaft.atria.platform.DeviceUseJournal.intervals(events, 0, 60 * m)
        assertEquals(1, r.size)           // 0–12 min merged; the 2-minute check is dropped
        assertEquals(12 * m, r[0].last)
    }

    @Test fun phoneUseBlocksSleepDetection() {
        val start = 1_800_000_000_000L
        val minutes = (0 until 600).map { com.adidshaft.atria.analytics.EvidenceMinute(start + it * 60_000L, if (it in 60..480) 52.0 else 78.0, 60, if (it in 60..480) 0.003 else 0.06, 0) }
        val asleep = com.adidshaft.atria.analytics.SleepDetector.detect(minutes, 50.0)
        assertEquals(1, asleep.size)
        val scrolling = com.adidshaft.atria.analytics.SleepDetector.detect(minutes, 50.0, listOf(start + 60 * 60_000L..start + 480 * 60_000L))
        assertTrue(scrolling.isEmpty())
    }
}

class PowerPolicyTest {
    private fun i(strap: Int?, strapChg: Boolean = false, phone: Int? = 80, phoneChg: Boolean = false, save: Boolean = false, t: com.adidshaft.atria.analytics.PowerPolicy.Thermal = com.adidshaft.atria.analytics.PowerPolicy.Thermal.NOMINAL) =
        com.adidshaft.atria.analytics.PowerPolicy.Inputs(strap, strapChg, phone, phoneChg, save, t)

    @Test fun hysteresisAndPriorities() {
        val P = com.adidshaft.atria.analytics.PowerPolicy
        assertEquals("normal", P.evaluate(i(60), null).reason)
        val low = P.evaluate(i(14), null); assertEquals("strap_low_live_off", low.reason)
        // Blocked below 15 stays blocked until 18 (hysteresis).
        assertEquals("strap_low_live_off", P.evaluate(i(16), low).reason)
        assertEquals("normal", P.evaluate(i(18), low).reason)
        assertEquals("strap_critical", P.evaluate(i(5), null).reason)
        assertEquals("charging", P.evaluate(i(5, strapChg = true), null).reason)
        assertEquals("phone_conserving", P.evaluate(i(60, save = true), null).reason)
        assertEquals(com.adidshaft.atria.analytics.PowerPolicy.Flush.Periodic(P.CONSERVING_FLUSH_MS), P.evaluate(i(60, phone = 15), null).flush)
    }

    @Test fun boostSuggestsAndAutoReverts() {
        val B = com.adidshaft.atria.analytics.CatchUpBoost
        assertEquals(com.adidshaft.atria.analytics.CatchUpBoost.Decision.IDLE, B.decide(3600, true, false))
        assertEquals(com.adidshaft.atria.analytics.CatchUpBoost.Decision.SUGGEST, B.decide(5 * 3600, true, false))
        assertEquals(com.adidshaft.atria.analytics.CatchUpBoost.Decision.ACTIVE, B.decide(5 * 3600, true, true))
        assertEquals(com.adidshaft.atria.analytics.CatchUpBoost.Decision.AUTO_REVERT, B.decide(0, false, true))
        assertEquals("~5h behind", B.behindDescription(5 * 3600))
    }
}

class MotionRunsAndNightTest {
    @Test fun unexplainedWalkingIsAskedButExplainedIsNot() {
        val m = 60_000L; val t0 = 1_800_000_000_000L
        val minutes = (0 until 15).map { t0 + it * m to 90 } + (0 until 3).map { t0 + (40 + it) * m to 30 }
        val runs = com.adidshaft.atria.analytics.MotionRuns.askable(minutes, emptyList())
        assertEquals(1, runs.size); assertEquals(1350, runs[0].steps); assertEquals(15, runs[0].activeMinutes) // the later 3 minutes are 26 min away: beyond the 20-min join gap
        assertTrue(com.adidshaft.atria.analytics.MotionRuns.askable(minutes, listOf(t0..t0 + 60 * m)).isEmpty())
        assertTrue(com.adidshaft.atria.analytics.MotionRuns.askable(minutes.take(8), emptyList()).isEmpty())
    }

    @Test fun nightBaselineFlagsUnusualValues() {
        val hist = listOf(55.0, 54.0, 56.0, 55.0, 54.0, 56.0)
        val f = com.adidshaft.atria.analytics.NightBaseline.compare(listOf(Triple("Resting HR", 64.0, hist), Triple("HRV", 60.0, listOf(1.0, 2.0))), { _, v -> v.toString() })!!
        assertEquals(1, f.size); assertTrue(f[0].unusual); assertTrue(f[0].label.contains("higher"))
        assertNull(com.adidshaft.atria.analytics.NightBaseline.compare(listOf(Triple("HRV", 60.0, listOf(1.0))), { _, v -> v.toString() }))
    }
}
