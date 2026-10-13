package com.adidshaft.atria.work

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.health.HealthConnectExporter
import com.adidshaft.atria.platform.NotificationKind
import com.adidshaft.atria.platform.StrapService
import com.adidshaft.atria.widget.WidgetUpdater
import java.time.DayOfWeek
import java.time.LocalTime
import java.util.concurrent.TimeUnit

/**
 * BGAppRefreshTask (`com.adidshaft.atria.refresh`) and BGProcessingTask
 * (`com.adidshaft.atria.processing`) → WorkManager periodic work. WorkManager
 * survives reboots and Doze and is the sanctioned path for deferrable work.
 */
object Scheduling {
    fun schedulePeriodic(context: Context) {
        val wm = WorkManager.getInstance(context)
        wm.enqueueUniquePeriodicWork("atria.refresh", ExistingPeriodicWorkPolicy.KEEP, PeriodicWorkRequestBuilder<RefreshWorker>(15, TimeUnit.MINUTES).build())
        wm.enqueueUniquePeriodicWork(
            "atria.processing", ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<ProcessingWorker>(6, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiresBatteryNotLow(true).build()).build(),
        )
        wm.enqueueUniquePeriodicWork("atria.reports", ExistingPeriodicWorkPolicy.KEEP, PeriodicWorkRequestBuilder<ReportWorker>(1, TimeUnit.HOURS).build())
    }
}

/** Keeps the strap service alive, nudges a history catch-up and recomputes today. */
class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val g = AtriaApp.graph
        if (g.repo.settings.currentStrap().let { it.pairedAddress != null && !it.capturePaused }) StrapService.start(applicationContext, StrapService.ACTION_SYNC)
        runCatching { g.engine.refresh() }
        runCatching { WidgetUpdater.updateAll(applicationContext) }
        return Result.success()
    }
}

/** Heavier maintenance: multi-day recompute, retention pruning, Health Connect export. */
class ProcessingWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val g = AtriaApp.graph
        runCatching { g.engine.refreshRange(7) }
        val now = System.currentTimeMillis()
        // Raw 1 Hz HR/RR kept 120 days; daily metrics, sleeps and workouts are kept forever.
        g.repo.db.samples().pruneHr(now - 120L * 86_400_000)
        g.repo.db.samples().pruneRr(now - 120L * 86_400_000)
        g.repo.db.stress().prune(now - 120L * 86_400_000)
        g.repo.db.log().prune(now - 14L * 86_400_000)
        runCatching { com.adidshaft.atria.data.ResearchBundle.nightlyQueue(applicationContext) }
        if (g.repo.settings.current().healthConnectExport) runCatching { HealthConnectExporter(applicationContext, g.repo).exportPending() }
        return Result.success()
    }
}

/** Morning summary + weekly report (UNCalendarNotificationTrigger equivalents). */
class ReportWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val g = AtriaApp.graph
        val s = g.repo.settings.current()
        val now = LocalTime.now()
        val today = g.repo.today()
        val prefs = applicationContext.getSharedPreferences("reports", Context.MODE_PRIVATE)
        if (now.hour in 8..10 && s.notifications.morningSummary && prefs.getLong("morning", -1) != today.toEpochDay()) {
            val d = g.repo.db.daily().get(today.toEpochDay())
            if (d?.sleepHours != null) {
                prefs.edit().putLong("morning", today.toEpochDay()).apply()
                g.notifier.post(NotificationKind.MORNING_SUMMARY, "Your morning", buildString {
                    append("Recovery ${d.recovery?.let { "$it%" } ?: "calculating"} · ")
                    append("Slept ${com.adidshaft.atria.analytics.formatHours(d.sleepHours)}")
                    d.hrv?.let { append(" · HRV ${it.toInt()} ms") }
                })
            }
        }
        if (today.dayOfWeek == DayOfWeek.SUNDAY && now.hour in 18..20 && s.notifications.weeklyReport && prefs.getLong("weekly", -1) != today.toEpochDay()) {
            prefs.edit().putLong("weekly", today.toEpochDay()).apply()
            val week = g.repo.db.daily().range(today.minusDays(6).toEpochDay(), today.toEpochDay())
            val rec = week.mapNotNull { it.recovery }.takeIf { it.isNotEmpty() }?.average()
            val sleep = week.mapNotNull { it.sleepHours }.takeIf { it.isNotEmpty() }?.average()
            val strain = week.mapNotNull { it.strain }.takeIf { it.isNotEmpty() }?.average()
            g.notifier.post(NotificationKind.WEEKLY_REPORT, "Your week", "Avg recovery ${rec?.toInt() ?: "--"}% · sleep ${sleep?.let { com.adidshaft.atria.analytics.formatHours(it) } ?: "--"} · strain ${strain?.let { "%.1f".format(it) } ?: "--"}")
        }
        // Health deviation: resting HR far above baseline for the morning.
        val d = g.repo.db.daily().get(today.toEpochDay())
        val base = g.repo.settings.currentBaseline()
        val st = base.restingStats(System.currentTimeMillis())
        if (d?.restingHr != null && st != null && base.hasTrustedResting(System.currentTimeMillis()) && d.restingHr > st.mean + 2.5 * maxOf(st.sd, 2.0) &&
            s.notifications.healthDeviation && prefs.getLong("deviation", -1) != today.toEpochDay()) {
            prefs.edit().putLong("deviation", today.toEpochDay()).apply()
            g.notifier.post(NotificationKind.HEALTH_DEVIATION, "Resting HR is unusually high", "Last night's ${d.restingHr} bpm is well above your usual ${st.mean.toInt()} bpm. Consider an easier day. Not a diagnosis.")
        }
        return Result.success()
    }
}
