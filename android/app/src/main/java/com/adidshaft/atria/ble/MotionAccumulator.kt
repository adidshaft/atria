package com.adidshaft.atria.ble

import com.adidshaft.atria.analytics.StrapPedometer
import com.adidshaft.atria.data.MotionMinuteEntity
import com.adidshaft.atria.protocol.Gravity
import com.adidshaft.atria.protocol.Vector3
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Turns strap IMU (compact 0x33 or R10) accelerometer samples into per-minute
 * motion facts: strap-only steps, activity (magnitude SD in g) and still
 * fraction. A gap > 2.5 s resets the pedometer's gait confirmation, matching
 * the iOS compact assembler's burst handling.
 */
class MotionAccumulator {
    private val pedometer = StrapPedometer()
    private var minuteStart = -1L
    private var stepsAtMinuteStart = 0
    private var n = 0
    private var sum = 0.0
    private var sumSq = 0.0
    private var still = 0
    private var lastSampleAt = 0L
    var sessionSteps = 0
        private set

    /** Returns completed minutes (usually 0 or 1). [receivedAtMs] stamps the packet's last sample. */
    @Synchronized
    fun ingest(acceleration: List<Vector3>, receivedAtMs: Long, sampleRateHz: Double = 100.0): List<MotionMinuteEntity> {
        if (acceleration.isEmpty()) return emptyList()
        if (lastSampleAt > 0 && receivedAtMs - lastSampleAt > 2_500) pedometer.reset().also { stepsAtMinuteStart = 0 }
        lastSampleAt = receivedAtMs
        val out = ArrayList<MotionMinuteEntity>()
        val dtMs = 1000.0 / sampleRateHz
        acceleration.forEachIndexed { i, v ->
            val t = receivedAtMs - ((acceleration.size - 1 - i) * dtMs).toLong()
            val minute = t / 60_000 * 60_000
            if (minuteStart < 0) { minuteStart = minute; stepsAtMinuteStart = pedometer.rawSteps }
            if (minute != minuteStart) { flush()?.let(out::add); minuteStart = minute; stepsAtMinuteStart = pedometer.rawSteps }
            val m = v.magnitude
            pedometer.ingest(m)
            n++; sum += m; sumSq += m * m
            if (abs(m - 1.0) < 0.02) still++
        }
        return out
    }

    @Synchronized
    fun flush(): MotionMinuteEntity? {
        if (n == 0 || minuteStart < 0) return null
        val mean = sum / n
        val sd = sqrt((sumSq / n - mean * mean).coerceAtLeast(0.0))
        val delta = (pedometer.rawSteps - stepsAtMinuteStart).coerceAtLeast(0)
        val steps = (delta * StrapPedometer.REFERENCE_GAIN).roundToInt()
        sessionSteps += steps
        val e = MotionMinuteEntity(minuteStart, steps, sd, still.toDouble() / n, n)
        n = 0; sum = 0.0; sumSq = 0.0; still = 0
        return e
    }

    /** Close the in-progress minute only once the stream has gone quiet (never split a live minute). */
    @Synchronized
    fun flushIfStale(nowMs: Long): MotionMinuteEntity? = if (lastSampleAt > 0 && nowMs - lastSampleAt > 70_000) flush() else null

    @Synchronized
    fun resetSession() { sessionSteps = 0 }
}

/**
 * Banked history carries a 1 Hz gravity vector (no certified steps — the v24
 * tick counter failed gait certification on iOS). Minute activity = SD of the
 * gravity-vector change, enough for sleep/sedentary discrimination.
 */
object HistoryMotion {
    fun minutes(rows: List<Pair<Long, Gravity>>): List<MotionMinuteEntity> =
        rows.groupBy { it.first / 60_000 * 60_000 }.map { (minute, list) ->
            val sorted = list.sortedBy { it.first }
            val deltas = sorted.zipWithNext { a, b ->
                val dx = a.second.x - b.second.x; val dy = a.second.y - b.second.y; val dz = a.second.z - b.second.z
                sqrt(dx * dx + dy * dy + dz * dz)
            }
            val activity = if (deltas.isEmpty()) 0.0 else deltas.average()
            MotionMinuteEntity(minute, 0, activity, deltas.count { it < 0.01 }.toDouble() / maxOf(1, deltas.size), sorted.size)
        }
}
