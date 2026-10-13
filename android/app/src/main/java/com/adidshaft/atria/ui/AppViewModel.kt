package com.adidshaft.atria.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.Recovery
import com.adidshaft.atria.analytics.SleepConsistency
import com.adidshaft.atria.analytics.StrainTarget
import com.adidshaft.atria.analytics.TrainingLoadSummary
import com.adidshaft.atria.data.AppSettings
import com.adidshaft.atria.data.DailyMetricsEntity
import com.adidshaft.atria.data.SleepEntity
import com.adidshaft.atria.data.StrapState
import com.adidshaft.atria.data.WorkoutEntity
import com.adidshaft.atria.ui.components.ChartPoint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId

data class TodayDerived(
    val strainTarget: Double = 10.0,
    val training: TrainingLoadSummary? = null,
    val hr6h: List<ChartPoint> = emptyList(),
    val stressToday: List<ChartPoint> = emptyList(),
    val currentStress: Double? = null,
    val restingNow: Int? = null,
    val avgHr6h: Int? = null,
    val peakHr6h: Int? = null,
    val consistency: SleepConsistency.Result? = null,
    val recoveryContributors: List<Recovery.Contributor> = emptyList(),
    val hrvQualifier: String? = null,
    val restingQualifier: String? = null,
    val loading: Boolean = true,
)

class AppViewModel : ViewModel() {
    private val g = AtriaApp.graph
    private val repo = g.repo
    private val today = repo.today()

    val live = g.strap.state
    val settings: StateFlow<AppSettings> = repo.settings.settings.stateIn(viewModelScope, SharingStarted.Eagerly, AppSettings(onboardingComplete = true))
    val strap: StateFlow<StrapState> = repo.settings.strap.stateIn(viewModelScope, SharingStarted.Eagerly, StrapState())
    val todayMetrics: StateFlow<DailyMetricsEntity?> = repo.db.daily().observe(today.toEpochDay()).stateIn(viewModelScope, SharingStarted.Eagerly, null)
    val recentDays: StateFlow<List<DailyMetricsEntity>> = repo.db.daily().observeRange(today.minusDays(29).toEpochDay(), today.toEpochDay()).stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val sleeps: StateFlow<List<SleepEntity>> = repo.db.sleeps().observeRecent().stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val sleepCandidates: StateFlow<List<SleepEntity>> = repo.db.sleeps().candidates().stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val workouts: StateFlow<List<WorkoutEntity>> = repo.db.workouts().observeRecent().stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val workoutReviews: StateFlow<List<WorkoutEntity>> = repo.db.workouts().reviews().stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val liveWorkout = g.workouts.live
    val eventLog = repo.db.log().observe(200).stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

    private val _derived = MutableStateFlow(TodayDerived())
    val derived: StateFlow<TodayDerived> = _derived.asStateFlow()

    init {
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { g.engine.refresh() }
            while (isActive) {
                runCatching { loadDerived() }
                delay(30_000)
            }
        }
    }

    fun refreshNow() = viewModelScope.launch(Dispatchers.IO) { runCatching { g.engine.refresh() }; runCatching { loadDerived() } }

    private suspend fun loadDerived() {
        val now = System.currentTimeMillis()
        val training = g.engine.trainingLoad()
        val daily = repo.db.daily().get(repo.today().toEpochDay())
        val hr = repo.hr(now - 6 * 3_600_000L, now)
        val stride = maxOf(1, hr.size / 600)
        val (dayStart, _) = repo.dayBounds(repo.today())
        val stress = repo.db.stress().between(dayStart, now)
        val baseline = repo.settings.currentBaseline()
        val zone = ZoneId.systemDefault()
        val nights = repo.db.sleeps().recentConfirmed(14).filter { !it.isNap }.map {
            val b = Instant.ofEpochMilli(it.startMs).atZone(zone); val e = Instant.ofEpochMilli(it.endMs).atZone(zone)
            (b.hour * 60 + b.minute) to (e.hour * 60 + e.minute)
        }
        val main = g.engine.mainSleepFor(repo.today())
        val contributors = if (main != null) Recovery.estimate(main.rmssd, main.restingHr, baseline, main.efficiency, main.asleepMs / 3_600_000.0, null, main.respiratoryRate, null, now).contributors else emptyList()
        _derived.value = TodayDerived(
            strainTarget = StrainTarget.target(daily?.recovery, training),
            training = training,
            hr6h = hr.filterIndexed { i, _ -> i % stride == 0 }.map { ChartPoint(it.t, it.bpm.toDouble()) },
            stressToday = stress.map { ChartPoint(it.t, it.score) },
            currentStress = stress.lastOrNull()?.takeIf { now - it.t < 10 * 60_000 }?.score,
            restingNow = baseline.restingEma?.toInt(),
            avgHr6h = hr.takeIf { it.isNotEmpty() }?.map { it.bpm }?.average()?.toInt(),
            peakHr6h = hr.maxOfOrNull { it.bpm },
            consistency = SleepConsistency.of(nights),
            recoveryContributors = contributors,
            hrvQualifier = baseline.hrvQualifier(now),
            restingQualifier = baseline.restingQualifier(now),
            loading = false,
        )
    }

    // ---- actions ---------------------------------------------------------------------------
    fun confirmSleep(id: Long, keep: Boolean) = viewModelScope.launch(Dispatchers.IO) {
        repo.db.sleeps().setStatus(id, if (keep) "confirmed" else "dismissed"); g.engine.refresh(); loadDerived()
    }

    fun reviewWorkout(id: Long, keep: Boolean, activity: String? = null) = viewModelScope.launch(Dispatchers.IO) {
        val w = repo.db.workouts().get(id) ?: return@launch
        repo.db.workouts().upsert(w.copy(status = if (keep) "confirmed" else "dismissed", activity = activity ?: w.activity)); g.engine.refresh()
    }

    fun deleteWorkout(id: Long) = viewModelScope.launch(Dispatchers.IO) { repo.db.workouts().delete(id); g.engine.refresh() }
    fun deleteSleep(id: Long) = viewModelScope.launch(Dispatchers.IO) { repo.db.sleeps().delete(id); g.engine.refresh() }

    fun logManualSleep(startMs: Long, endMs: Long, isNap: Boolean) = viewModelScope.launch(Dispatchers.IO) {
        val minutes = repo.evidenceMinutes(startMs, endMs)
        val stages = com.adidshaft.atria.analytics.SleepDetector.stages(minutes, startMs, endMs)
        val sleepHr = minutes.mapNotNull { it.meanHr }.sorted()
        repo.db.sleeps().insert(
            SleepEntity(
                startMs = startMs, endMs = endMs, asleepMs = endMs - startMs, isNap = isNap, status = "confirmed", source = com.adidshaft.atria.data.Source.MANUAL,
                restingHr = sleepHr.takeIf { it.size >= 10 }?.take(10)?.average()?.toInt(), efficiency = 1.0,
                stagesJson = com.adidshaft.atria.domain.encodeStages(stages), motionValidated = minutes.count { it.activity != null } > minutes.size * 0.6,
            ),
        )
        g.engine.refresh(); loadDerived()
    }

    /** Onboarding "Start fresh": drain-and-discard the pre-pairing strap backlog (non-destructive to strap firmware). */
    fun viewModelScopeLaunchStartFresh() = viewModelScope.launch {
        repo.settings.updateStrap { it.copy(historyIgnoreBeforeMs = System.currentTimeMillis()) }
        g.strap.requestHistorySync()
    }

    fun updateSettings(transform: (AppSettings) -> AppSettings) = viewModelScope.launch { repo.settings.update(transform) }
}
