package com.adidshaft.atria.platform

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.adidshaft.atria.ble.Permissions
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity

/**
 * CMMotionActivityManager → Activity Recognition Transition API. Used exactly
 * like iOS: on-device context so a bumpy drive with elevated HR is not offered
 * as a workout. Phone motion never contributes steps (strap-only rule).
 * Without Google Play services this silently degrades to "unknown".
 */
object MotionContext {
    private const val PREFS = "motion_context"
    private const val KEY = "vehicle_intervals"

    @SuppressLint("MissingPermission")
    fun start(context: Context) {
        if (!Permissions.granted(context, Permissions.activityRecognition())) return
        val transitions = listOf(DetectedActivity.IN_VEHICLE).flatMap { type ->
            listOf(ActivityTransition.ACTIVITY_TRANSITION_ENTER, ActivityTransition.ACTIVITY_TRANSITION_EXIT).map {
                ActivityTransition.Builder().setActivityType(type).setActivityTransition(it).build()
            }
        }
        val pi = PendingIntent.getBroadcast(context, 8101, Intent(context, MotionContextReceiver::class.java), PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        runCatching { ActivityRecognition.getClient(context).requestActivityTransitionUpdates(ActivityTransitionRequest(transitions), pi) }
    }

    fun record(context: Context, enter: Boolean, at: Long) {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val list = p.getString(KEY, "")!!.split(";").filter { it.isNotBlank() }.toMutableList()
        if (enter) list += "$at-" else if (list.isNotEmpty() && list.last().endsWith("-")) list[list.lastIndex] = list.last() + at
        p.edit().putString(KEY, list.takeLast(50).joinToString(";")).apply()
    }

    /** True when an in-vehicle interval overlaps [start, end]. */
    fun wasDriving(context: Context, start: Long, end: Long): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "")!!.split(";").filter { it.isNotBlank() }.any { s ->
            val parts = s.split("-")
            val a = parts[0].toLongOrNull() ?: return@any false
            val b = parts.getOrNull(1)?.toLongOrNull() ?: System.currentTimeMillis()
            a < end && b > start
        }
}

class MotionContextReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return
        ActivityTransitionResult.extractResult(intent)?.transitionEvents?.forEach { e ->
            if (e.activityType == DetectedActivity.IN_VEHICLE) {
                val at = System.currentTimeMillis() - (android.os.SystemClock.elapsedRealtimeNanos() - e.elapsedRealTimeNanos) / 1_000_000
                MotionContext.record(context, e.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER, at)
            }
        }
    }
}
