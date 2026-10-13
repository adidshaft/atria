package com.adidshaft.atria

import android.app.Application
import android.content.Context
import com.adidshaft.atria.ble.StrapManager
import com.adidshaft.atria.coach.Coach
import com.adidshaft.atria.data.Repository
import com.adidshaft.atria.diagnostics.CrashDiagnostics
import com.adidshaft.atria.diagnostics.MainThreadWatchdog
import com.adidshaft.atria.domain.MetricsEngine
import com.adidshaft.atria.domain.WorkoutRuntime
import com.adidshaft.atria.platform.HeartRateBroadcaster
import com.adidshaft.atria.platform.Notifier
import com.adidshaft.atria.work.Scheduling

/** Process-wide object graph (the iOS app used singletons/@StateObject; this is the same, explicit). */
class AppGraph(context: Context) {
    val repo = Repository(context)
    val strap = StrapManager(context, repo)
    val engine = MetricsEngine(repo, { s, e -> com.adidshaft.atria.platform.MotionContext.wasDriving(context, s, e) }, { s, e -> com.adidshaft.atria.platform.DeviceUseJournal.sustainedUse(context, s, e) })
    val notifier = Notifier(context)
    val workouts = WorkoutRuntime(context, repo, strap, engine)
    val broadcaster = HeartRateBroadcaster(context)
    val coach = Coach(context, repo, engine)
}

class AtriaApp : Application() {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        graph = AppGraph(this)
        graph.notifier.createChannels()
        Scheduling.schedulePeriodic(this)
        CrashDiagnostics.recordPreviousExits(this, graph.repo)
        MainThreadWatchdog.start(graph.repo)
        com.adidshaft.atria.platform.MotionContext.start(this)
    }

    companion object {
        lateinit var instance: AtriaApp
            private set
        val graph get() = instance.graph
    }
}
