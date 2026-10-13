package com.adidshaft.atria.platform

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationChannelGroup
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.adidshaft.atria.MainActivity
import com.adidshaft.atria.R

/**
 * UNNotificationCategory → NotificationChannel. Each iOS scheduler `kind`
 * gets its own channel so users can tune them in system settings, and action
 * buttons replace UNNotificationAction (handled by [NotificationActionReceiver]).
 */
enum class NotificationKind(val channelId: String, val title: String, val importance: Int, val deepLink: String) {
    RECOVERY("recovery", "Recovery check-ins", NotificationManager.IMPORTANCE_DEFAULT, "atria://today"),
    STRAIN("strain", "Strain milestones", NotificationManager.IMPORTANCE_DEFAULT, "atria://today"),
    SLEEP_REVIEW("sleep_review", "Sleep review", NotificationManager.IMPORTANCE_DEFAULT, "atria://sleep-review"),
    WORKOUT_REVIEW("workout_review", "Workout review", NotificationManager.IMPORTANCE_DEFAULT, "atria://plan"),
    MORNING_SUMMARY("morning_summary", "Morning summary", NotificationManager.IMPORTANCE_DEFAULT, "atria://today"),
    WEEKLY_REPORT("weekly_report", "Weekly report", NotificationManager.IMPORTANCE_LOW, "atria://vitals"),
    HEALTH_DEVIATION("health_deviation", "Health monitor", NotificationManager.IMPORTANCE_HIGH, "atria://vitals"),
    BATTERY("battery", "Strap battery", NotificationManager.IMPORTANCE_DEFAULT, "atria://strap"),
    BLUETOOTH_OFF("bluetooth_off", "Bluetooth off", NotificationManager.IMPORTANCE_DEFAULT, "atria://strap"),
    FIT_CHECK("fit_check", "Strap fit", NotificationManager.IMPORTANCE_DEFAULT, "atria://strap"),
    SLEEP_LOGGED("sleep_logged", "Sleep logged", NotificationManager.IMPORTANCE_LOW, "atria://sleep"),
    EVENING_CHECKIN("evening_checkin", "Evening check-in", NotificationManager.IMPORTANCE_DEFAULT, "atria://journal"),
    SYNC_NUDGE("sync_nudge", "Sync reminders", NotificationManager.IMPORTANCE_LOW, "atria://strap"),
    BEDTIME("bedtime_reminder", "Bedtime wind-down", NotificationManager.IMPORTANCE_DEFAULT, "atria://today"),
    CATCH_UP("catchup_complete", "History catch-up", NotificationManager.IMPORTANCE_LOW, "atria://strap"),
    PARKED_INTERVAL("parked_interval", "Unrecoverable history", NotificationManager.IMPORTANCE_LOW, "atria://strap"),
    SECOND_SLEEP("second_sleep_primary", "Main sleep choice", NotificationManager.IMPORTANCE_DEFAULT, "atria://today"),
    LIVE("live_status", "Live heart rate", NotificationManager.IMPORTANCE_LOW, "atria://vitals"),
    WORKOUT_LIVE("workout_live", "Live workout", NotificationManager.IMPORTANCE_DEFAULT, "atria://workout"),
    ALARM("wake_alarm", "Wake alarm", NotificationManager.IMPORTANCE_HIGH, "atria://today"),
}

class Notifier(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    fun createChannels() {
        manager.createNotificationChannelGroup(NotificationChannelGroup("insights", "Insights"))
        manager.createNotificationChannelGroup(NotificationChannelGroup("strap", "Strap & sync"))
        val strapKinds = setOf(NotificationKind.PARKED_INTERVAL, NotificationKind.BATTERY, NotificationKind.BLUETOOTH_OFF, NotificationKind.FIT_CHECK, NotificationKind.SYNC_NUDGE, NotificationKind.CATCH_UP, NotificationKind.LIVE)
        NotificationKind.entries.forEach { k ->
            manager.createNotificationChannel(NotificationChannel(k.channelId, k.title, k.importance).apply {
                group = if (k in strapKinds) "strap" else "insights"
                if (k == NotificationKind.LIVE || k == NotificationKind.WORKOUT_LIVE) { setShowBadge(false); enableVibration(false); setSound(null, null) }
                if (k == NotificationKind.ALARM) setBypassDnd(true)
            })
        }
    }

    fun contentIntent(deepLink: String, requestCode: Int = deepLink.hashCode()): PendingIntent =
        PendingIntent.getActivity(
            context, requestCode,
            Intent(Intent.ACTION_VIEW, Uri.parse(deepLink), context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    fun actionIntent(action: String, id: Long, requestCode: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context, requestCode,
            Intent(context, NotificationActionReceiver::class.java).setAction(action).putExtra("id", id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    fun post(kind: NotificationKind, title: String, body: String, id: Int = kind.ordinal + 1000, actions: List<NotificationCompat.Action> = emptyList()) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            android.os.Build.VERSION.SDK_INT >= 33) return
        val n = NotificationCompat.Builder(context, kind.channelId)
            .setSmallIcon(R.drawable.ic_stat_atria)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(contentIntent(kind.deepLink))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
            .apply { actions.forEach { addAction(it) } }
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(id, n) }
    }

    fun cancel(id: Int) = manager.cancel(id)

    /**
     * LocalNotificationScheduler's attention budget: at most [DAILY_BUDGET] insight
     * notifications a day across kinds, plus per-event cooldowns and caps (e.g. a sleep
     * review at most twice per candidate, 4 h apart). Safety kinds bypass the budget.
     */
    fun postGated(
        kind: NotificationKind,
        eventKey: String,
        title: String,
        body: String,
        cooldownMs: Long,
        maxPerEvent: Int = 1,
        id: Int = kind.ordinal + 1000,
        actions: List<NotificationCompat.Action> = emptyList(),
    ): Boolean {
        val p = context.getSharedPreferences("notification_gate", Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val count = p.getInt("count.$eventKey", 0)
        val last = p.getLong("last.$eventKey", 0)
        if (count >= maxPerEvent || now - last < cooldownMs) return false
        val today = java.time.LocalDate.now().toEpochDay()
        val used = if (p.getLong("budget.day", -1) == today) p.getInt("budget.used", 0) else 0
        val exempt = kind in setOf(NotificationKind.ALARM, NotificationKind.BATTERY, NotificationKind.BLUETOOTH_OFF, NotificationKind.HEALTH_DEVIATION)
        if (!exempt && used >= DAILY_BUDGET) return false
        post(kind, title, body, id, actions)
        p.edit().putInt("count.$eventKey", count + 1).putLong("last.$eventKey", now)
            .putLong("budget.day", today).putInt("budget.used", if (exempt) used else used + 1).apply()
        return true
    }

    companion object { const val DAILY_BUDGET = 6 }
}
