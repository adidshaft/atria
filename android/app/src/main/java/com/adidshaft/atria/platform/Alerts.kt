package com.adidshaft.atria.platform

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.HrZone
import com.adidshaft.atria.ble.LinkStatus
import com.adidshaft.atria.ble.LiveState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.LocalTime

/** UIImpactFeedbackGenerator / UINotificationFeedbackGenerator → Vibrator effects. */
object PhoneHaptics {
    private fun vibrator(c: Context): Vibrator? = if (Build.VERSION.SDK_INT >= 31)
        c.getSystemService(VibratorManager::class.java)?.defaultVibrator else @Suppress("DEPRECATION") c.getSystemService(Vibrator::class.java)

    fun tick(c: Context) = runCatching { vibrator(c)?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)) }
    fun click(c: Context) = runCatching { vibrator(c)?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)) }
    fun warning(c: Context) = runCatching { vibrator(c)?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 60, 80, 60), -1)) }
}

/**
 * Port of AtriaHapticAlertCoordinator + LocalNotificationScheduler triggers.
 * Unlike iOS (phone-side haptics only), Android can buzz the strap motor
 * directly via 0x4F, so alerts reach the wrist even with the phone in a bag.
 */
object AlertCoordinator {
    private var lastZone: HrZone? = null
    private var lastZoneAt = 0L
    private var lastBatteryLow = false
    private var lastStatus: LinkStatus? = null
    private var strainLatchDay = -1L
    private var recoveryNotifiedDay = -1L
    private val scope = CoroutineScope(Dispatchers.Default)

    private var offWristSince = 0L
    private var drainWasActive = false
    private var drainStartPending: Long? = null

    fun onLive(context: Context, s: LiveState) {
        val graph = AtriaApp.graph
        scope.launch {
            val settings = graph.repo.settings.current()
            val h = settings.haptics
            val profile = settings.profile.toAthlete()
            val rest = graph.repo.settings.currentBaseline().restingEma?.toInt() ?: 60
            val active = s.status == LinkStatus.CONNECTED
            val now = System.currentTimeMillis()
            // Heart-rate zone change (30 s cooldown).
            if (h.heartRateZones && active && s.hrFresh) {
                val zone = HrZone.of(s.heartRate, profile.estimatedMaxHr, rest)
                val prev = lastZone
                lastZone = zone
                if (prev != null && prev != zone && now - lastZoneAt >= 30_000) {
                    lastZoneAt = now
                    if (h.useStrapMotor) graph.strap.haptic(if (zone.ordinal > prev.ordinal) 2 else 1) else PhoneHaptics.click(context)
                }
            }
            // Low battery edge (≤ 20 %), once per drain cycle.
            val low = (s.battery ?: 100) <= 20
            if (low && !lastBatteryLow) {
                if (h.lowBattery) PhoneHaptics.warning(context)
                if (settings.notifications.strapBattery) graph.notifier.postGated(NotificationKind.BATTERY, "battery.cycle.${s.battery?.div(10)}", "Strap battery ${s.battery}%", "Charge soon so overnight sleep and recovery aren't missed.", 6 * 3_600_000L, maxPerEvent = 1)
            }
            lastBatteryLow = low
            // Bluetooth turned off while paired.
            if (s.status == LinkStatus.BLUETOOTH_OFF && lastStatus != LinkStatus.BLUETOOTH_OFF && settings.notifications.bluetoothOff) {
                graph.notifier.postGated(NotificationKind.BLUETOOTH_OFF, "bt.${now / 3_600_000}", "Bluetooth is off", "Atria can't reach your strap. Turn Bluetooth on to keep heart rate and sleep tracking.", 3_600_000L)
            }
            lastStatus = s.status
            // Fit check: connected but no skin contact for 10 minutes (2/day, 4 h apart).
            offWristSince = if (active && !s.onWrist && !s.charging) (if (offWristSince == 0L) now else offWristSince) else 0L
            if (offWristSince > 0 && now - offWristSince > 10 * 60_000 && settings.notifications.fitCheck) {
                graph.notifier.postGated(NotificationKind.FIT_CHECK, "fit.${java.time.LocalDate.now()}", "Fit check needed", "The strap can't read your pulse. Tighten it a finger's width above the wrist bone.", 4 * 3_600_000L, maxPerEvent = 2)
            }
            // Catch-up complete: a history drain that saved rows and finished caught up.
            if (s.drainActive && !drainWasActive) drainStartPending = s.pendingRecords
            if (!s.drainActive && drainWasActive && s.drainRows > 0 && (s.pendingRecords ?: 1) == 0L && (drainStartPending ?: 0) > 3_600 && settings.notifications.catchUpComplete) {
                graph.notifier.postGated(NotificationKind.CATCH_UP, "catchup.$now", "Catch-up complete", "Strap history finished syncing and is current through now.", 0)
            }
            drainWasActive = s.drainActive
        }
    }

    /** Every ~5 minutes from the service: recovery ready, strain target, reviews, evening prompts. */
    suspend fun periodic(context: Context) {
        val graph = AtriaApp.graph
        val settings = graph.repo.settings.current()
        val n = settings.notifications
        val today = graph.repo.today()
        val daily = graph.repo.db.daily().get(today.toEpochDay())
        val now = LocalTime.now()
        val nowMs = System.currentTimeMillis()

        if (daily?.recovery != null && recoveryNotifiedDay != today.toEpochDay() && now.hour in 4..13) {
            recoveryNotifiedDay = today.toEpochDay()
            if (n.recoveryReady) graph.notifier.postGated(NotificationKind.RECOVERY, "recovery.$today", "Recovery ${daily.recovery}%", "${com.adidshaft.atria.analytics.Recovery.band(daily.recovery)} · ${daily.sleepHours?.let { com.adidshaft.atria.analytics.formatHours(it) } ?: "sleep pending"} slept.", 0)
            if (settings.haptics.recoveryReady) graph.strap.haptic(1)
        }
        val target = com.adidshaft.atria.analytics.StrainTarget.target(daily?.recovery, graph.engine.trainingLoad())
        if ((daily?.strain ?: 0.0) >= target && strainLatchDay != today.toEpochDay()) {
            strainLatchDay = today.toEpochDay()
            if (n.strainTarget) graph.notifier.postGated(NotificationKind.STRAIN, "strain.$today", "Strain target reached", "You hit %.1f of today's %.1f target.".format(daily?.strain ?: 0.0, target), 0)
            if (settings.haptics.strainTarget) graph.strap.haptic(3)
        }
        val recent = graph.repo.db.sleeps().between(nowMs - 36 * 3_600_000L, nowMs)
        // Sleep review: at most twice per candidate, 4 h apart (iOS sleepReview caps).
        recent.firstOrNull { it.status == "candidate" }?.takeIf { n.sleepReview }?.let { c ->
            graph.notifier.postGated(
                NotificationKind.SLEEP_REVIEW, "sleepreview.${c.startMs}", if (c.isNap) "Possible nap" else "Possible sleep",
                "${com.adidshaft.atria.analytics.formatHours(c.asleepMs / 3_600_000.0)} detected. Keep it?", 4 * 3_600_000L, maxPerEvent = 2,
                id = 5000 + c.id.toInt(),
                actions = listOf(
                    NotificationCompat.Action(0, "Keep", graph.notifier.actionIntent(NotificationActionReceiver.CONFIRM_SLEEP, c.id, 1 + c.id.toInt() * 4)),
                    NotificationCompat.Action(0, "Not sleep", graph.notifier.actionIntent(NotificationActionReceiver.DISMISS_SLEEP, c.id, 2 + c.id.toInt() * 4)),
                ),
            )
        }
        // Sleep logged: an auto-confirmed detected night, once (deduplicated by start time).
        recent.filter { it.status == "confirmed" && it.source == com.adidshaft.atria.data.Source.DETECTED }.maxByOrNull { it.endMs }?.takeIf { n.sleepReview }?.let { sl ->
            graph.notifier.postGated(NotificationKind.SLEEP_LOGGED, "sleeplogged.${sl.startMs}", if (sl.isNap) "Nap logged" else "Sleep logged",
                "${com.adidshaft.atria.analytics.formatHours(sl.asleepMs / 3_600_000.0)} saved. Tap to edit.", 0)
        }
        // Workout review: once per candidate.
        graph.repo.db.workouts().between(nowMs - 36 * 3_600_000L, nowMs).firstOrNull { it.status == "review" }?.takeIf { n.workoutReview }?.let { w ->
            graph.notifier.postGated(
                NotificationKind.WORKOUT_REVIEW, "workoutreview.${w.startMs}", "Possible workout",
                "${(w.endMs - w.startMs) / 60_000} min · strain %.1f. Save it?".format(w.strain), 0, id = 6000 + w.id.toInt(),
                actions = listOf(
                    NotificationCompat.Action(0, "Save", graph.notifier.actionIntent(NotificationActionReceiver.CONFIRM_WORKOUT, w.id, 3 + w.id.toInt() * 4)),
                    NotificationCompat.Action(0, "Dismiss", graph.notifier.actionIntent(NotificationActionReceiver.DISMISS_WORKOUT, w.id, 4 + w.id.toInt() * 4)),
                ),
            )
        }
        // Charge reminder near the learned usual charge hour (≥ 5 observations, ±1 h, battery ≤ 30 %).
        val strap = graph.repo.settings.currentStrap()
        if (n.strapBattery && (strap.batteryLevel ?: 100) <= 30 && !strap.charging && strap.chargeHours.size >= 5) {
            val usual = strap.chargeHours.groupingBy { it }.eachCount().maxBy { it.value }.key
            val d = kotlin.math.abs(now.hour - usual).let { minOf(it, 24 - it) }
            if (d <= 1) graph.notifier.postGated(NotificationKind.BATTERY, "charge.$today", "Good time to charge", "You usually charge around ${usual}:00 and the strap is at ${strap.batteryLevel}%.", 20 * 3_600_000L)
        }
        // Parked interval: an older stretch could not be recovered (once per park).
        strap.parkedAt?.let { at ->
            graph.notifier.postGated(NotificationKind.PARKED_INTERVAL, "parked.$at", "Older interval unavailable",
                "One older stretch of strap history could not be recovered after repeated attempts. The gap stays visible in Atria; new strap data can reopen recovery.", 0)
        }
        // Sync nudge (LocalNotificationScheduler.syncNudgeContent): ≥ 30 min of strap data waiting, no progress for 2 h, app in background.
        val foreground = androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)
        val pending = strap.pendingRecords ?: 0
        val progressing = strap.lastProductiveSliceAt?.let { nowMs - it < 2 * 3_600_000L } ?: false
        if (n.syncNudge && !foreground && pending >= 30 * 60 && !progressing && strap.parkedAt == null) {
            val linked = graph.strap.state.value.status == com.adidshaft.atria.ble.LinkStatus.CONNECTED
            val (t, b) = if (!linked) "Strap out of range" to "Hours of strap data are waiting. Bring your strap near your phone and open Atria to catch up."
            else "Strap data waiting to sync" to "Background catch-up hasn't kept pace. Open Atria on a charger for a few minutes — it catches up fastest plugged in and in the foreground."
            graph.notifier.postGated(NotificationKind.SYNC_NUDGE, "syncnudge.$today", t, b, 6 * 3_600_000L, maxPerEvent = 2)
        }
        // Second sleep today: ask which is the main one (AtriaSameDayMainSleepSheet).
        if (graph.engine.sameDayMainSleeps(today).size >= 2 && graph.engine.preferredMainSleepId(today) == null) {
            graph.notifier.postGated(NotificationKind.SECOND_SLEEP, "secondsleep.$today", "You slept twice today", "Which was your main sleep? It decides today's Recovery.", 0)
        }
        if (now.hour == 21 && n.eveningCheckIn) {
            graph.notifier.postGated(NotificationKind.EVENING_CHECKIN, "evening.$today", "Evening check-in", "Log today's habits so Atria can learn what moves your recovery.", 0)
        }
        if (n.bedtimeWindDown && daily?.sleepNeedHours != null) {
            val wake = settings.wakeAlarm.let { LocalTime.of(it.hour, it.minute) }
            val bed = wake.minusMinutes((daily.sleepNeedHours * 60).toLong() + 30)
            if (now.hour == bed.hour && now.minute / 5 == bed.minute / 5) {
                graph.notifier.postGated(NotificationKind.BEDTIME, "bedtime.$today", "Wind down", "Head to bed in 30 min to meet tonight's %.1f h sleep need.".format(daily.sleepNeedHours), 0)
            }
        }
    }
}

/** CallKit's CXCallObserver → TelephonyCallback: buzz the strap on an incoming call. */
object CallHaptics {
    private var callback: Any? = null

    fun start(context: Context) {
        if (Build.VERSION.SDK_INT < 31) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return
        val tm = context.getSystemService(TelephonyManager::class.java) ?: return
        val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
            override fun onCallStateChanged(state: Int) {
                if (state != TelephonyManager.CALL_STATE_RINGING) return
                CoroutineScope(Dispatchers.Default).launch {
                    val g = AtriaApp.graph
                    if (g.repo.settings.current().haptics.incomingCalls && g.strap.state.value.status == LinkStatus.CONNECTED) g.strap.haptic(3)
                }
            }
        }
        runCatching { tm.registerTelephonyCallback(context.mainExecutor, cb); callback = cb }
    }

    fun stop(context: Context) {
        if (Build.VERSION.SDK_INT < 31) return
        val cb = callback as? TelephonyCallback ?: return
        runCatching { context.getSystemService(TelephonyManager::class.java)?.unregisterTelephonyCallback(cb) }
        callback = null
    }
}

/** UNNotificationAction handling. */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getLongExtra("id", -1)
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            val g = AtriaApp.graph
            when (intent.action) {
                CONFIRM_SLEEP -> g.repo.db.sleeps().setStatus(id, "confirmed")
                DISMISS_SLEEP -> g.repo.db.sleeps().setStatus(id, "dismissed")
                CONFIRM_WORKOUT -> g.repo.db.workouts().setStatus(id, "confirmed")
                DISMISS_WORKOUT -> g.repo.db.workouts().setStatus(id, "dismissed")
                SNOOZE_ALARM -> WakeAlarm.snooze(context)
                STOP_ALARM -> WakeAlarm.stopRinging(context)
            }
            if (intent.action == CONFIRM_SLEEP || intent.action == DISMISS_SLEEP) g.notifier.cancel(5000 + id.toInt())
            runCatching { g.engine.refresh() }
            pending.finish()
        }
    }

    companion object {
        const val CONFIRM_SLEEP = "com.adidshaft.atria.CONFIRM_SLEEP"
        const val DISMISS_SLEEP = "com.adidshaft.atria.DISMISS_SLEEP"
        const val CONFIRM_WORKOUT = "com.adidshaft.atria.CONFIRM_WORKOUT"
        const val DISMISS_WORKOUT = "com.adidshaft.atria.DISMISS_WORKOUT"
        const val SNOOZE_ALARM = "com.adidshaft.atria.SNOOZE_ALARM"
        const val STOP_ALARM = "com.adidshaft.atria.STOP_ALARM"
    }
}

/** Re-establish the standing strap connection after reboot / app update (iOS relaunches via restoration). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            val st = AtriaApp.graph.repo.settings.currentStrap()
            val paired = st.pairedAddress != null && !st.capturePaused
            if (paired) StrapService.start(context)
            WakeAlarm.reschedule(context)
            pending.finish()
        }
    }
}
