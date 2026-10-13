package com.adidshaft.atria.diagnostics

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.adidshaft.atria.data.Repository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * MetricKit (MXCrashDiagnostic / MXHangDiagnostic / cpu_resource_fatal) →
 * ApplicationExitInfo: on launch, record why the previous process died
 * (ANR, crash, low memory, excessive CPU) into the on-device event log.
 */
object CrashDiagnostics {
    fun recordPreviousExits(context: Context, repo: Repository) {
        if (Build.VERSION.SDK_INT < 30) return
        val prefs = context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE)
        val seen = prefs.getLong("last_exit_ts", 0)
        val am = context.getSystemService(ActivityManager::class.java) ?: return
        val exits = runCatching { am.getHistoricalProcessExitReasons(context.packageName, 0, 10) }.getOrNull() ?: return
        val fresh = exits.filter { it.timestamp > seen }
        if (fresh.isEmpty()) return
        prefs.edit().putLong("last_exit_ts", fresh.maxOf { it.timestamp }).apply()
        CoroutineScope(Dispatchers.IO).launch {
            fresh.forEach { e -> repo.log("exit", "${reason(e.reason)} ${e.description ?: ""} pss=${e.pss}kB at=${e.timestamp}") }
        }
    }

    private fun reason(r: Int) = when (r) {
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "app_updated"
        ApplicationExitInfo.REASON_FREEZER -> "frozen"
        else -> "reason_$r"
    }
}

/** Port of AtriaMainThreadWatchdog: log main-thread stalls > 2 s before the system ANR (5 s). */
object MainThreadWatchdog {
    @Volatile private var lastBeat = System.currentTimeMillis()
    private var started = false

    fun start(repo: Repository) {
        if (started) return
        started = true
        val main = Handler(Looper.getMainLooper())
        fun beat() { lastBeat = System.currentTimeMillis(); main.postDelayed(::beat, 500) }
        main.post(::beat)
        Thread({
            var reported = 0L
            while (true) {
                Thread.sleep(1_000)
                val stall = System.currentTimeMillis() - lastBeat
                if (stall > 2_000 && lastBeat != reported) {
                    reported = lastBeat
                    val top = Looper.getMainLooper().thread.stackTrace.take(6).joinToString(" < ") { "${it.className.substringAfterLast('.')}.${it.methodName}" }
                    CoroutineScope(Dispatchers.IO).launch { repo.log("hang", "main thread stalled ${stall}ms: $top") }
                }
            }
        }, "atria-watchdog").apply { isDaemon = true }.start()
    }
}
