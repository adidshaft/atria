package com.adidshaft.atria.platform

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.R
import com.adidshaft.atria.ble.LinkStatus
import com.adidshaft.atria.ble.LiveState
import com.adidshaft.atria.widget.WidgetUpdater
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Replaces iOS `bluetooth-central` background mode + state restoration, the
 * Live Activity / Dynamic Island and the BGTask minute work:
 *
 *  - A foreground service of type connectedDevice (+health) keeps the GATT link,
 *    so the process is not frozen while the screen is off (iOS suspends but
 *    wakes on BLE events; Android needs the service to stay schedulable).
 *  - Its ongoing notification is the Live Activity: live BPM, battery, sync,
 *    with Android 16 "promoted ongoing" (Live Update) when available.
 *  - A minute ticker runs stress facts, alert checks, smart-wake and widget refresh.
 */
class StrapService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var ticker: Job? = null
    private var locationTyped = false
    private val graph get() = AtriaApp.graph

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startInForeground(buildNotification(graph.strap.state.value))
        graph.strap.resume()
        scope.launch {
            kotlinx.coroutines.flow.combine(graph.strap.state, graph.workouts.live) { s, w -> NotificationKey(s.status, s.heartRate, s.battery, s.drainActive, s.sessionSteps / 10, w?.activity, w?.isPaused, w?.let { (it.strain * 10).toInt() }) }
                .distinctUntilChanged()
                .collectLatest {
                    // A route workout needs the location FGS type while the screen is off.
                    // Started only for a workout with no strap paired: stop once the workout ends.
                    if (graph.workouts.live.value == null && graph.strap.state.value.status == LinkStatus.UNPAIRED) { stopSelf(); return@collectLatest }
                    val needsLocation = graph.workouts.live.value?.activity in com.adidshaft.atria.domain.ROUTE_ACTIVITIES
                    if (needsLocation != locationTyped) { locationTyped = needsLocation; startInForeground(buildNotification(graph.strap.state.value)) }
                    val s = graph.strap.state.value
                    runCatching { ContextCompat.getSystemService(this@StrapService, android.app.NotificationManager::class.java)?.notify(LIVE_ID, buildNotification(s)) }
                    graph.broadcaster.publish(s.heartRate, s.rrMs)
                    AlertCoordinator.onLive(this@StrapService, s)
                    delay(1_000) // at most ~1 update/s, like ActivityKit frequent updates
                }
        }
        scope.launch {
            graph.repo.settings.settings.collectLatest { st ->
                glanceSettings = st.glanceMode to st.glanceItems
                maxHr = st.profile.toAthlete().estimatedMaxHr
                restingHr = graph.repo.settings.currentBaseline().restingEma?.toInt()
                runCatching { ContextCompat.getSystemService(this@StrapService, android.app.NotificationManager::class.java)?.notify(LIVE_ID, buildNotification(graph.strap.state.value)) }
            }
        }
        scope.launch {
            graph.repo.historyEvents.collectLatest { graph.engine.refreshRange(3) }
        }
        ticker = scope.launch {
            var minute = 0
            while (isActive) {
                val now = System.currentTimeMillis()
                runCatching { graph.engine.stressTick(now) }
                runCatching { WakeAlarm.check(this@StrapService) }
                if (minute % 5 == 0) {
                    runCatching { graph.engine.refresh() }
                    runCatching { AlertCoordinator.periodic(this@StrapService) }
                    runCatching { WidgetUpdater.updateAll(this@StrapService) }
                }
                minute++
                delay(60_000)
            }
        }
        CallHaptics.start(this)
        DeviceUseJournal.register(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Every startForegroundService() must be answered with startForeground(), even when the
        // service is already running or about to stop — otherwise Android kills the process.
        startInForeground(buildNotification(graph.strap.state.value))
        when (intent?.action) {
            ACTION_STOP -> { graph.strap.disconnect(); stopSelf() }
            ACTION_SYNC -> graph.strap.requestHistorySync()
            ACTION_PAUSE -> graph.workouts.togglePause()
            ACTION_END_WORKOUT -> graph.workouts.end(true)
            else -> graph.strap.resume()
        }
        // START_STICKY: the system restarts us after a low-memory kill, like iOS state restoration relaunch.
        return START_STICKY
    }

    override fun onDestroy() {
        CallHaptics.stop(this)
        DeviceUseJournal.unregister(this)
        scope.cancel()
        super.onDestroy()
    }

    private fun startInForeground(n: Notification) {
        val loc = if (locationTyped && Build.VERSION.SDK_INT >= 29 && com.adidshaft.atria.ble.Permissions.hasLocation(this)) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
        val type = if (Build.VERSION.SDK_INT >= 34)
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH or loc
        else if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or loc else 0
        runCatching { ServiceCompat.startForeground(this, LIVE_ID, n, type) }
            .onFailure { runCatching { ServiceCompat.startForeground(this, LIVE_ID, n, if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0) } }
    }

    private fun buildNotification(s: LiveState): Notification {
        val glance = glanceSettings
        graph.workouts.live.value?.let { return if (glance.first == "off") quietNotification() else buildWorkoutNotification(s, it) }
        // The foreground service always needs a notification; "workouts"/"off" keep it generic.
        if (glance.first != "always") return quietNotification()
        val title = when (s.status) {
            LinkStatus.CONNECTED -> if (s.hrFresh) "${s.heartRate} bpm" else "Strap connected"
            LinkStatus.CONNECTING, LinkStatus.DISCONNECTED -> "Reconnecting to strap…"
            LinkStatus.BLUETOOTH_OFF -> "Bluetooth is off"
            LinkStatus.SCANNING -> "Looking for your strap…"
            LinkStatus.NO_PERMISSION -> "Bluetooth permission needed"
            LinkStatus.UNPAIRED -> "No strap paired"
        }
        val items = glance.second
        val parts = buildList {
            if ("zone" in items && s.hrFresh) add("Z" + com.adidshaft.atria.analytics.HrZone.of(s.heartRate, maxHr, restingHr).ordinal)
            if ("battery" in items) s.battery?.let { add("Battery $it%${if (s.charging) " ⚡" else ""}") }
            if (s.drainActive) add("Syncing history · ${s.drainRows} saved")
            if ("steps" in items && s.sessionSteps > 0) add("${s.sessionSteps} steps")
        }
        val b = NotificationCompat.Builder(this, NotificationKind.LIVE.channelId)
            .setSmallIcon(R.drawable.ic_stat_atria)
            .setContentTitle(title)
            .setContentText(parts.joinToString(" · ").ifEmpty { "Atria keeps your strap connected" })
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(graph.notifier.contentIntent("atria://vitals"))
            .addAction(0, "Sync", android.app.PendingIntent.getService(this, 2, Intent(this, StrapService::class.java).setAction(ACTION_SYNC), android.app.PendingIntent.FLAG_IMMUTABLE))
        if (s.drainActive) b.setProgress(0, 0, true)
        // Android 16 Live Updates: the closest analogue of a Dynamic Island chip.
        if (s.status == LinkStatus.CONNECTED && s.hrFresh) {
            b.setRequestPromotedOngoing(true)
            b.setShortCriticalText("${s.heartRate}")
        }
        return b.build()
    }

    @Volatile private var glanceSettings: Pair<String, List<String>> = "always" to listOf("zone", "steps", "battery")
    @Volatile private var maxHr = 190
    @Volatile private var restingHr: Int? = null

    private fun quietNotification(): Notification = NotificationCompat.Builder(this, NotificationKind.LIVE.channelId)
        .setSmallIcon(R.drawable.ic_stat_atria)
        .setContentTitle("Atria")
        .setContentText("Keeping your strap connected")
        .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
        .setVisibility(NotificationCompat.VISIBILITY_SECRET)
        .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        .setContentIntent(graph.notifier.contentIntent("atria://today"))
        .build()

    /** Workout Live Activity → ongoing workout notification with a chronometer and End action. */
    private fun buildWorkoutNotification(s: LiveState, w: com.adidshaft.atria.domain.LiveWorkout): Notification {
        val b = NotificationCompat.Builder(this, NotificationKind.WORKOUT_LIVE.channelId)
            .setSmallIcon(R.drawable.ic_stat_atria)
            .setContentTitle("${w.activity}${if (w.isPaused) " · paused" else ""}")
            .setContentText(listOfNotNull(if (s.hrFresh) "${s.heartRate} bpm" else null, "Strain %.1f".format(w.strain), w.steps.takeIf { it > 0 }?.let { "$it steps" }, w.distanceMeters.takeIf { it > 0 }?.let { "%.2f km".format(it / 1000) }).joinToString(" · "))
            .setOngoing(true).setOnlyAlertOnce(true)
            .setUsesChronometer(!w.isPaused).setWhen(System.currentTimeMillis() - w.elapsedMs).setShowWhen(true)
            .setCategory(NotificationCompat.CATEGORY_WORKOUT)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(graph.notifier.contentIntent("atria://workout"))
            .addAction(0, if (w.isPaused) "Resume" else "Pause", android.app.PendingIntent.getService(this, 3, Intent(this, StrapService::class.java).setAction(ACTION_PAUSE), android.app.PendingIntent.FLAG_IMMUTABLE))
            .addAction(0, "End", android.app.PendingIntent.getService(this, 4, Intent(this, StrapService::class.java).setAction(ACTION_END_WORKOUT), android.app.PendingIntent.FLAG_IMMUTABLE))
            .setRequestPromotedOngoing(true)
        if (s.hrFresh) b.setShortCriticalText("${s.heartRate}")
        return b.build()
    }

    private data class NotificationKey(val status: LinkStatus, val hr: Int, val battery: Int?, val drain: Boolean, val steps: Int, val workout: String?, val paused: Boolean?, val strainTenths: Int?)

    companion object {
        const val LIVE_ID = 42
        const val ACTION_STOP = "com.adidshaft.atria.STOP"
        const val ACTION_SYNC = "com.adidshaft.atria.SYNC"
        const val ACTION_PAUSE = "com.adidshaft.atria.PAUSE_WORKOUT"
        const val ACTION_END_WORKOUT = "com.adidshaft.atria.END_WORKOUT"

        fun start(context: Context, action: String? = null) {
            val i = Intent(context, StrapService::class.java).setAction(action)
            runCatching { ContextCompat.startForegroundService(context, i) }
        }
    }
}
