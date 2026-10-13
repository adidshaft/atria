package com.adidshaft.atria.widget

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.MainActivity
import com.adidshaft.atria.ble.LinkStatus
import com.adidshaft.atria.platform.StrapService

/**
 * iOS 18 Control Center controls (AtriaControlIntents) → Quick Settings tiles.
 */
class LiveHeartRateTile : TileService() {
    override fun onStartListening() {
        val s = AtriaApp.graph.strap.state.value
        qsTile?.apply {
            state = if (s.status == LinkStatus.CONNECTED) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            label = if (s.hrFresh) "${s.heartRate} bpm" else "Atria"
            if (Build.VERSION.SDK_INT >= 29) subtitle = s.battery?.let { "Strap $it%" } ?: "Strap"
            updateTile()
        }
    }

    override fun onClick() {
        StrapService.start(this, StrapService.ACTION_SYNC)
        openApp("atria://vitals")
    }

    private fun openApp(link: String) {
        val i = Intent(Intent.ACTION_VIEW, Uri.parse(link), this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE))
        else @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated") startActivityAndCollapse(i)
    }
}

/** AtriaLiveWorkoutControlIntent → start/end a workout from Quick Settings. */
class WorkoutTile : TileService() {
    override fun onStartListening() {
        val active = AtriaApp.graph.workouts.live.value
        qsTile?.apply {
            state = if (active != null) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            label = if (active != null) "End ${active.activity}" else "Start workout"
            updateTile()
        }
    }

    override fun onClick() {
        val i = Intent(Intent.ACTION_VIEW, Uri.parse("atria://workout"), this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 1, i, PendingIntent.FLAG_IMMUTABLE))
        else @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated") startActivityAndCollapse(i)
    }
}

/** AtriaStartCaptureControl / AtriaStopCaptureControl → one toggle tile for strap capture. */
class CaptureTile : TileService() {
    override fun onStartListening() {
        val s = AtriaApp.graph.strap.state.value
        qsTile?.apply {
            state = if (s.status == LinkStatus.CONNECTED || s.status == LinkStatus.CONNECTING) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            label = "Strap capture"
            if (Build.VERSION.SDK_INT >= 29) subtitle = if (state == Tile.STATE_ACTIVE) "On" else "Off"
            updateTile()
        }
    }

    override fun onClick() {
        val g = AtriaApp.graph
        if (qsTile?.state == Tile.STATE_ACTIVE) {
            g.strap.disconnect()
            kotlinx.coroutines.runBlocking { g.repo.settings.updateStrap { it.copy(capturePaused = true) } }
            stopService(Intent(this, StrapService::class.java))
        } else {
            // Starting the FGS needs a foreground context on Android 12+: open the app, which starts capture.
            val i = Intent(Intent.ACTION_VIEW, Uri.parse("atria://strap"), this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            kotlinx.coroutines.runBlocking { g.repo.settings.updateStrap { it.copy(capturePaused = false) } }
            g.strap.resume()
            if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 2, i, PendingIntent.FLAG_IMMUTABLE))
            else @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated") startActivityAndCollapse(i)
        }
        onStartListening()
    }
}
