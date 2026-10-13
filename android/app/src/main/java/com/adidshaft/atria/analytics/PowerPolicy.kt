package com.adidshaft.atria.analytics

/**
 * AtriaWhoop4PowerPolicy: battery/thermal policy for the live motion stream and
 * history flush, with hysteresis (blocked below `minimum`, resumes at `resume`).
 * Phone inputs on Android: BatteryManager level/charging, PowerManager power-save
 * (Low Power Mode), PowerManager thermal status (ProcessInfo.thermalState).
 */
object PowerPolicy {
    const val LIVE_STRAP_MIN = 15; const val LIVE_STRAP_RESUME = 18
    const val FLUSH_STRAP_MIN = 10; const val FLUSH_STRAP_RESUME = 13
    const val STRAP_SHUTOFF = 5
    const val PHONE_MIN = 20; const val PHONE_RESUME = 25
    const val NORMAL_FLUSH_MS = 5 * 60_000L
    const val CONSERVING_FLUSH_MS = 30 * 60_000L

    enum class Thermal { NOMINAL, FAIR, SERIOUS, CRITICAL }
    sealed interface Flush { data object Asap : Flush; data object Paused : Flush; data class Periodic(val intervalMs: Long) : Flush }

    data class Inputs(val strapBattery: Int?, val strapCharging: Boolean, val phoneBattery: Int?, val phoneCharging: Boolean, val powerSave: Boolean, val thermal: Thermal)
    data class Decision(val liveMotionAllowed: Boolean, val flush: Flush, val reason: String)

    fun evaluate(i: Inputs, previous: Decision?): Decision {
        val strapLowLive = below(i.strapBattery, LIVE_STRAP_MIN, LIVE_STRAP_RESUME, previous?.let { !it.liveMotionAllowed } ?: false)
        val strapLowFlush = below(i.strapBattery, FLUSH_STRAP_MIN, FLUSH_STRAP_RESUME, previous?.flush == Flush.Paused)
        val phoneLow = below(i.phoneBattery, PHONE_MIN, PHONE_RESUME, previous?.let { !it.liveMotionAllowed } ?: false)
        val conserving = !i.phoneCharging && (phoneLow || i.powerSave || i.thermal >= Thermal.SERIOUS)
        val strap = i.strapBattery
        if (strap != null && strap <= STRAP_SHUTOFF && !i.strapCharging) return Decision(false, Flush.Paused, "strap_critical")
        if (i.thermal == Thermal.CRITICAL) return Decision(false, Flush.Paused, "phone_thermal_critical")
        if (i.strapCharging || i.phoneCharging) return Decision((i.strapCharging || !strapLowLive) && !conserving, Flush.Asap, "charging")
        if (strapLowFlush) return Decision(false, Flush.Paused, "strap_low_flush_deferred")
        if (conserving) return Decision(false, Flush.Periodic(CONSERVING_FLUSH_MS), "phone_conserving")
        if (strapLowLive) return Decision(false, Flush.Periodic(NORMAL_FLUSH_MS), "strap_low_live_off")
        return Decision(true, Flush.Periodic(NORMAL_FLUSH_MS), "normal")
    }

    private fun below(level: Int?, min: Int, resume: Int, wasBlocked: Boolean): Boolean {
        level ?: return false
        return if (wasBlocked) level < resume else level < min
    }

    /** AtriaLiveDataNote: one line telling the user why live data is paused. */
    fun note(d: Decision, i: Inputs): String? = when (d.reason) {
        "strap_critical", "strap_low_flush_deferred", "strap_low_live_off" -> "Live motion paused · strap battery ${i.strapBattery}%"
        "phone_thermal_critical" -> "Live motion paused · phone is hot"
        "phone_conserving" -> when {
            i.powerSave -> "Live motion paused · Battery Saver is on"
            i.thermal >= Thermal.SERIOUS -> "Live motion paused · phone is hot"
            else -> "Live motion paused · phone battery low"
        }
        else -> null
    }
}

/** AtriaCatchUpBoost: "catch up faster" for a strap hours behind; auto-reverts when caught up. */
object CatchUpBoost {
    enum class Decision { IDLE, SUGGEST, ACTIVE, AUTO_REVERT }
    const val SUGGEST_BEHIND_S = 4 * 3600L
    const val CAUGHT_UP_WITHIN_S = 12 * 60L

    fun decide(behindSeconds: Long?, backlogPending: Boolean, active: Boolean): Decision {
        if (active) {
            val caughtUp = behindSeconds?.let { it <= CAUGHT_UP_WITHIN_S } ?: false
            return if (!backlogPending || caughtUp) Decision.AUTO_REVERT else Decision.ACTIVE
        }
        if (!backlogPending || behindSeconds == null || behindSeconds < SUGGEST_BEHIND_S) return Decision.IDLE
        return Decision.SUGGEST
    }

    fun behindDescription(behindSeconds: Long?): String? {
        if (behindSeconds == null || behindSeconds < SUGGEST_BEHIND_S) return null
        return "~${Math.round(behindSeconds / 3600.0)}h behind"
    }
}
