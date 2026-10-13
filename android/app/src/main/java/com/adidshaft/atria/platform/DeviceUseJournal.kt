package com.adidshaft.atria.platform

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter

/**
 * AtriaDeviceUseJournal: a ring of phone unlock/lock events. A low, still heart
 * rate while someone scrolls in bed looks like sleep to the HR gates; ≥ 10
 * minutes of sustained phone use is hard evidence of being awake, so those
 * minutes are excluded from sleep detection.
 *
 * iOS observed scene/lock notifications; Android uses USER_PRESENT (unlock) and
 * SCREEN_OFF (lock), which are only deliverable to a runtime-registered
 * receiver — hence registration from the long-lived StrapService.
 */
object DeviceUseJournal {
    private const val PREFS = "device_use_journal"
    private const val KEY = "events"
    private const val MAX = 800
    const val SUSTAINED_MS = 10 * 60_000L

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.action) {
                Intent.ACTION_USER_PRESENT -> note(c, true)
                Intent.ACTION_SCREEN_OFF -> note(c, false)
            }
        }
    }
    private var registered = false

    fun register(c: Context) {
        if (registered) return
        registered = true
        c.applicationContext.registerReceiver(receiver, IntentFilter().apply { addAction(Intent.ACTION_USER_PRESENT); addAction(Intent.ACTION_SCREEN_OFF) })
    }

    fun unregister(c: Context) {
        if (!registered) return
        registered = false
        runCatching { c.applicationContext.unregisterReceiver(receiver) }
    }

    fun note(c: Context, unlocked: Boolean, at: Long = System.currentTimeMillis()) {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val list = p.getString(KEY, "")!!.split(";").filter { it.isNotBlank() }.toMutableList()
        list += "$at:${if (unlocked) "u" else "l"}"
        p.edit().putString(KEY, list.takeLast(MAX).joinToString(";")).apply()
    }

    /** Merged intervals of phone use lasting at least [SUSTAINED_MS] within [from, to]. */
    fun sustainedUse(c: Context, from: Long, to: Long): List<LongRange> {
        val events = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "")!!.split(";").mapNotNull {
            val parts = it.split(":"); val t = parts.getOrNull(0)?.toLongOrNull() ?: return@mapNotNull null
            t to (parts.getOrNull(1) == "u")
        }.sortedBy { it.first }
        return intervals(events, from, to)
    }

    fun intervals(events: List<Pair<Long, Boolean>>, from: Long, to: Long): List<LongRange> {
        val out = ArrayList<LongRange>()
        var start: Long? = null
        for ((t, unlocked) in events) {
            if (unlocked && start == null) start = t
            else if (!unlocked && start != null) { out += start..t; start = null }
        }
        start?.let { out += it..System.currentTimeMillis() }
        // Merge uses separated by ≤ 60 s (iOS mergeGapMaximum), then keep sustained ones.
        val merged = ArrayList<LongRange>()
        for (r in out.sortedBy { it.first }) {
            val last = merged.lastOrNull()
            if (last != null && r.first - last.last <= 60_000) merged[merged.lastIndex] = last.first..maxOf(last.last, r.last) else merged += r
        }
        return merged.filter { it.last - it.first >= SUSTAINED_MS && it.last >= from && it.first <= to }
    }
}
