package com.adidshaft.atria.analytics

import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/** One timestamped heart-rate sample; [t] is epoch milliseconds. */
data class HrSample(val t: Long, val bpm: Int)

enum class BiologicalSex { MALE, FEMALE, UNSPECIFIED }

data class AthleteProfile(
    val name: String = "",
    val age: Int = 30,
    val weightKg: Double = 70.0,
    val heightCm: Double = 175.0,
    val sex: BiologicalSex = BiologicalSex.UNSPECIFIED,
    val maxHrOverride: Int? = null,
    val sleepGoalHours: Double = 8.0,
    val stepGoal: Int = 8_000,
) {
    val hasEnergyProfile get() = sex != BiologicalSex.UNSPECIFIED && weightKg > 0 && age > 0
    /** Tanaka 208 − 0.7·age, unless measured/overridden. */
    val estimatedMaxHr get() = maxHrOverride ?: (208 - 0.7 * age).roundToInt()
    val bmi get() = if (heightCm > 0) weightKg / ((heightCm / 100) * (heightCm / 100)) else 0.0
}

/** Heart-rate-reserve zones (Z0 rest … Z5 max). */
enum class HrZone(val label: String, val lowerFraction: Double) {
    REST("Rest", 0.0), WARMUP("Warm-up", 0.50), FAT_BURN("Fat burn", 0.60),
    AEROBIC("Aerobic", 0.70), ANAEROBIC("Anaerobic", 0.80), MAX("Max", 0.90);

    companion object {
        fun of(bpm: Int, maxHr: Int, restingHr: Int?): HrZone {
            if (bpm <= 0 || maxHr <= 0) return REST
            val rest = restingHr ?: 0
            if (maxHr <= rest) return REST
            val frac = (bpm - rest).toDouble() / (maxHr - rest)
            return entries.last { frac >= it.lowerFraction }
        }

        fun lowerBpm(zone: HrZone, rest: Int, max: Int) = (rest + zone.lowerFraction * (max - rest)).roundToInt()
    }
}

/**
 * Banister-style cardiovascular load with WHOOP-like 0–21 display scale.
 * Ported from AtriaStrainLoadModel.swift (display calibration v4).
 */
object StrainLoadModel {
    enum class Mode { WORKOUT, CONTINUOUS_DAY }

    val plausibleBpm = 35.0..240.0
    const val MAXIMUM_GAP_SECONDS = 15.0
    private const val DAY_FLOOR_HRR = 0.30
    private const val DAY_FULL_WEIGHT_HRR = 0.40
    private const val DISPLAY_MAX = 21.0
    private const val LOAD_SCALE = 100.0

    data class Params(val multiplier: Double, val coefficient: Double)

    fun banister(sex: BiologicalSex) =
        if (sex == BiologicalSex.FEMALE) Params(0.86, 1.67) else Params(0.64, 1.92)

    data class Result(val load: Double, val acceptedSeconds: Double, val droppedGapSeconds: Double)

    fun calculate(samples: List<HrSample>, rest: Int, max: Int, sex: BiologicalSex, mode: Mode): Result {
        if (samples.size < 2 || max <= rest) return Result(0.0, 0.0, 0.0)
        val p = banister(sex)
        var load = 0.0; var accepted = 0.0; var dropped = 0.0
        for (i in 1 until samples.size) {
            val dt = (samples[i].t - samples[i - 1].t) / 1000.0
            if (dt <= 0) continue
            if (dt > MAXIMUM_GAP_SECONDS) { dropped += dt; continue }
            val a = samples[i - 1].bpm.toDouble(); val b = samples[i].bpm.toDouble()
            if (a !in plausibleBpm || b !in plausibleBpm) continue
            load += load((a + b) / 2, dt, rest.toDouble(), max.toDouble(), p, mode)
            accepted += dt
        }
        return Result(load, accepted, dropped)
    }

    fun load(meanBpm: Double, seconds: Double, rest: Double, max: Double, p: Params, mode: Mode): Double {
        if (max <= rest || seconds <= 0 || meanBpm !in plausibleBpm) return 0.0
        val hrr = ((meanBpm - rest) / (max - rest)).coerceIn(0.0, 1.0)
        val coefficient = p.coefficient.coerceIn(1.0, 2.5)
        val w = dayWeight(hrr, mode)
        val v = (seconds / 60) * hrr * min(p.multiplier, 2.0) * exp(coefficient * hrr) * w
        return if (v.isFinite()) v else 0.0
    }

    private fun dayWeight(hrr: Double, mode: Mode): Double = when {
        mode != Mode.CONTINUOUS_DAY -> 1.0
        hrr <= DAY_FLOOR_HRR -> 0.0
        hrr >= DAY_FULL_WEIGHT_HRR -> 1.0
        else -> (hrr - DAY_FLOOR_HRR) / (DAY_FULL_WEIGHT_HRR - DAY_FLOOR_HRR)
    }

    fun displayScore(load: Double): Double =
        if (!load.isFinite() || load <= 0) 0.0 else (DISPLAY_MAX * (1 - exp(-load / LOAD_SCALE))).coerceIn(0.0, DISPLAY_MAX)

    /** Inverse of [displayScore]: load needed to reach a target strain. */
    fun loadFor(score: Double): Double = -LOAD_SCALE * kotlin.math.ln(1 - (score / DISPLAY_MAX).coerceIn(0.0, 0.9999))

    /** Strength sets add muscular load the HR curve under-reads (capped equivalent). */
    fun muscularTrimpEquivalent(inputScore: Double?): Double {
        if (inputScore == null || inputScore <= 0) return 0.0
        return 45.0 * (inputScore / 100).coerceIn(0.0, 1.0).pow(1.6)
    }
}

object Energy {
    /** Keytel et al. gross energy (kcal/min) from HR; 0 when sex unspecified. */
    fun kcalPerMinute(hr: Int, p: AthleteProfile): Double = when (p.sex) {
        BiologicalSex.MALE -> max(0.0, (-55.0969 + 0.6309 * hr + 0.1988 * p.weightKg + 0.2017 * p.age) / 4.184)
        BiologicalSex.FEMALE -> max(0.0, (-20.4022 + 0.4472 * hr - 0.1263 * p.weightKg + 0.0740 * p.age) / 4.184)
        BiologicalSex.UNSPECIFIED -> 0.0
    }

    /** Active (above-resting) calories; null without an energy profile. */
    fun activeCalories(samples: List<HrSample>, rest: Int, p: AthleteProfile): Double? {
        if (samples.size < 2 || rest <= 0 || !p.hasEnergyProfile) return null
        val resting = kcalPerMinute(rest, p)
        var total = 0.0
        for (i in 1 until samples.size) {
            val dt = (samples[i].t - samples[i - 1].t) / 1000.0
            if (dt <= 0 || dt > StrainLoadModel.MAXIMUM_GAP_SECONDS) continue
            if (samples[i].bpm.toDouble() !in StrainLoadModel.plausibleBpm || samples[i - 1].bpm.toDouble() !in StrainLoadModel.plausibleBpm) continue
            total += max(0.0, kcalPerMinute(samples[i].bpm, p) - resting) * dt / 60
        }
        return total
    }

    /** Mifflin-St Jeor basal energy per day. */
    fun bmrPerDay(p: AthleteProfile): Double? = when (p.sex) {
        BiologicalSex.MALE -> 10 * p.weightKg + 6.25 * p.heightCm - 5 * p.age + 5
        BiologicalSex.FEMALE -> 10 * p.weightKg + 6.25 * p.heightCm - 5 * p.age - 161
        BiologicalSex.UNSPECIFIED -> null
    }
}

object Zones {
    /** Seconds spent in each HRR zone (index 0..5), dropping telemetry gaps. */
    fun seconds(samples: List<HrSample>, maxHr: Int, restingHr: Int?): DoubleArray {
        val out = DoubleArray(6)
        if (samples.size < 2 || maxHr <= 0) return out
        for (i in 1 until samples.size) {
            val dt = (samples[i].t - samples[i - 1].t) / 1000.0
            if (dt <= 0 || dt > StrainLoadModel.MAXIMUM_GAP_SECONDS) continue
            out[HrZone.of(samples[i].bpm, maxHr, restingHr).ordinal] += dt
        }
        return out
    }
}

/** Acute:chronic workload and monotony (ported TrainingLoad). */
data class TrainingLoadSummary(
    val acute: Double, val chronic: Double, val ratio: Double?, val monotony: Double?,
    val readiness: String, val targetLow: Double?, val targetHigh: Double?, val detail: String,
) {
    companion object {
        /** [dailyStrains] newest first. */
        fun of(dailyStrains: List<Double>): TrainingLoadSummary {
            if (dailyStrains.isEmpty()) return TrainingLoadSummary(0.0, 0.0, null, null, "learning", null, null, "Needs a few days of strain.")
            val acuteList = dailyStrains.take(7); val chronicList = dailyStrains.take(28)
            val acute = acuteList.average(); val chronic = chronicList.average()
            val ratio = if (chronic > 0) acute / chronic else null
            val monotony = monotony(acuteList)
            val enoughAcute = acuteList.size >= 3; val enoughChronic = chronicList.size >= 14
            val acwr = when {
                !enoughChronic || ratio == null -> "learning"
                ratio >= 1.5 || ratio < 0.6 -> "bad"
                ratio > 1.3 || ratio < 0.8 -> "watch"
                else -> "good"
            }
            val mono = when {
                !enoughAcute || monotony == null -> "learning"
                monotony >= 2.5 -> "bad"
                monotony >= 2.0 -> "watch"
                else -> "good"
            }
            val readiness = when {
                acwr == "learning" && mono == "learning" -> "learning"
                acwr == "bad" || mono == "bad" -> "rundown"
                acwr == "watch" || mono == "watch" -> "strained"
                ratio != null && ratio < 0.8 -> "primed"
                else -> "balanced"
            }
            val band: Pair<Double, Double>? = if (!enoughAcute) null else when {
                ratio != null && ratio > 1.3 -> max(0.0, acute - 4) to max(0.0, acute - 1)
                ratio != null && ratio < 0.8 -> acute to min(21.0, acute + 3)
                else -> max(0.0, acute - 1.5) to min(21.0, acute + 1.5)
            }
            val detail = when (readiness) {
                "learning" -> "Needs a few days of strain."
                "rundown" -> "Rundown: training load is either spiking or too repetitive. Keep the next session easy."
                "strained" -> "Strained: ACWR or monotony is elevated. Favor recovery or a lighter day."
                "primed" -> "Primed: recent strain is below your base, with room to add load if recovery feels good."
                else -> "Recent strain is aligned with your longer baseline."
            }
            return TrainingLoadSummary(acute, chronic, ratio, monotony, readiness, band?.first, band?.second, detail)
        }

        fun monotony(values: List<Double>): Double? {
            if (values.size < 3) return null
            val mean = values.average(); if (mean <= 0) return null
            val sd = kotlin.math.sqrt(values.sumOf { (it - mean) * (it - mean) } / values.size)
            return if (sd <= 0.05) 9.99 else min(mean / sd, 9.99)
        }
    }
}

/**
 * Today's adjusted strain target: recovery decides how much load is wise.
 * Matches the iOS "Target 13.7" daily brief behaviour (recovery-scaled band).
 */
object StrainTarget {
    fun target(recoveryPercent: Int?, training: TrainingLoadSummary?): Double {
        val r = (recoveryPercent ?: 50).coerceIn(1, 99)
        val base = 6.0 + (r / 100.0) * 12.0 // 6..18
        val bandMid = training?.let { t -> if (t.targetLow != null && t.targetHigh != null) (t.targetLow + t.targetHigh) / 2 else null }
        val blended = if (bandMid != null) (base * 0.7 + bandMid * 0.3) else base
        return (blended * 10).roundToInt() / 10.0
    }
}
