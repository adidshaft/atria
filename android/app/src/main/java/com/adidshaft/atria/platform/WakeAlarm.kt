package com.adidshaft.atria.platform

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.R
import com.adidshaft.atria.analytics.HrSample
import com.adidshaft.atria.analytics.SleepDetector
import com.adidshaft.atria.analytics.SleepStage
import com.adidshaft.atria.analytics.SmartWakePlanner
import com.adidshaft.atria.ui.AlarmActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * AlarmKit replacement. The hard "wake by" alarm is an AlarmManager
 * `setAlarmClock` (exact, shown in the status bar, survives Doze), so the user
 * is woken even if the strap or app fails. The smart window (30 min before)
 * is evaluated each minute by the foreground service with the same planner
 * as iOS and can fire early: strap motor buzz + full-screen alarm.
 */
object WakeAlarm {
    private const val REQUEST_HARD = 7001
    private const val NOTIFICATION_ID = 7002
    private var ringtone: Ringtone? = null
    private var firedForAlarmAt = 0L

    fun hardAlarmMillis(hour: Int, minute: Int, now: LocalDateTime = LocalDateTime.now()): Long {
        var t = now.withHour(hour).withMinute(minute).withSecond(0).withNano(0)
        if (!t.isAfter(now)) t = t.plusDays(1)
        return t.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
    }

    fun reschedule(context: Context) {
        CoroutineScope(Dispatchers.IO).launch {
            val s = AtriaApp.graph.repo.settings.current().wakeAlarm
            val am = context.getSystemService(AlarmManager::class.java)
            val pi = PendingIntent.getBroadcast(context, REQUEST_HARD, Intent(context, WakeAlarmReceiver::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            am.cancel(pi)
            if (!s.enabled) return@launch
            val at = hardAlarmMillis(s.hour, s.minute)
            val show = PendingIntent.getActivity(context, REQUEST_HARD + 1, Intent(context, AlarmActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            val canExact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()
            if (canExact) am.setAlarmClock(AlarmManager.AlarmClockInfo(at, show), pi)
            else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    /** Called every minute by StrapService: smart-window / sleep-need-met early wake. */
    suspend fun check(context: Context) {
        val g = AtriaApp.graph
        val s = g.repo.settings.current().wakeAlarm
        if (!s.enabled) return
        val mode = runCatching { SmartWakePlanner.Mode.valueOf(s.mode) }.getOrDefault(SmartWakePlanner.Mode.SMART_WINDOW)
        if (mode == SmartWakePlanner.Mode.EXACT) return
        val hard = hardAlarmMillis(s.hour, s.minute)
        val now = System.currentTimeMillis()
        if (hard - now > SmartWakePlanner.WINDOW_MS + 60_000 && mode == SmartWakePlanner.Mode.SMART_WINDOW) return
        if (firedForAlarmAt == hard) return
        val minutes = g.repo.evidenceMinutes(now - 8 * 3_600_000L, now)
        val sleeps = SleepDetector.detect(minutes, g.repo.settings.currentBaseline().restingEma)
        val current = sleeps.lastOrNull() ?: return
        val stages = SleepDetector.stages(minutes, current.startMs, now)
        val recent = g.repo.hr(now - 600_000, now).map { h -> h to (stages.lastOrNull { h.t in it.startMs..it.endMs }?.stage ?: SleepStage.LIGHT) }
        val need = g.repo.db.daily().get(g.repo.today().minusDays(1).toEpochDay())?.sleepNeedHours ?: 8.0
        val slept = (now - current.startMs) / 3_600_000.0
        val decision = SmartWakePlanner.decide(mode, now, hard, slept, need, recent)
        if (decision is SmartWakePlanner.Decision.Fire) {
            firedForAlarmAt = hard
            ring(context, decision.reason)
        }
    }

    fun ring(context: Context, reason: String) {
        val g = AtriaApp.graph
        CoroutineScope(Dispatchers.IO).launch { if (g.repo.settings.current().wakeAlarm.strapHaptic) repeat(3) { g.strap.haptic(4) } }
        val full = PendingIntent.getActivity(context, 7003, Intent(context, AlarmActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(context, NotificationKind.ALARM.channelId)
            .setSmallIcon(R.drawable.ic_stat_atria)
            .setContentTitle("Good morning")
            .setContentText(if (reason.startsWith("light")) "Woken in a light stage" else "Time to wake up")
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setFullScreenIntent(full, true)
            .addAction(0, "Snooze", g.notifier.actionIntent(NotificationActionReceiver.SNOOZE_ALARM, 0, 7004))
            .addAction(0, "Stop", g.notifier.actionIntent(NotificationActionReceiver.STOP_ALARM, 0, 7005))
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, n) }
        runCatching {
            ringtone?.stop()
            ringtone = RingtoneManager.getRingtone(context, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM))?.apply {
                audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
                play()
            }
        }
    }

    fun stopRinging(context: Context) {
        ringtone?.stop(); ringtone = null
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
        reschedule(context)
    }

    fun snooze(context: Context) {
        stopRinging(context)
        val am = context.getSystemService(AlarmManager::class.java)
        val pi = PendingIntent.getBroadcast(context, REQUEST_HARD + 9, Intent(context, WakeAlarmReceiver::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + 9 * 60_000, pi)
    }
}

class WakeAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = WakeAlarm.ring(context, "wake_by_reached")
}
