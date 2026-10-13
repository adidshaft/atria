package com.adidshaft.atria.domain

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.os.Looper
import com.adidshaft.atria.analytics.Energy
import com.adidshaft.atria.analytics.HrSample
import com.adidshaft.atria.analytics.StrainLoadModel
import com.adidshaft.atria.analytics.Zones
import com.adidshaft.atria.ble.Permissions
import com.adidshaft.atria.ble.StrapManager
import com.adidshaft.atria.data.AppJson
import com.adidshaft.atria.data.Repository
import com.adidshaft.atria.data.Source
import com.adidshaft.atria.data.WorkoutEntity
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlin.math.roundToInt

/** Activities that record a GPS route (iOS: CoreLocation only for outdoor types). */
val ROUTE_ACTIVITIES = setOf("Running", "Walking", "Hiking", "Cycling", "Mountain biking", "Cross-country skiing", "Dog walking", "Track & field", "Kayaking", "Rowing")

@Serializable data class RoutePoint(val t: Long, val lat: Double, val lon: Double, val alt: Double?, val acc: Float)
@Serializable data class StrengthSet(val exercise: String, val reps: Int, val weightKg: Double?, val at: Long)

data class LiveWorkout(
    val id: Long,
    val activity: String,
    val startMs: Long,
    val pausedMs: Long = 0,
    val pausedAt: Long? = null,
    val strain: Double = 0.0,
    val calories: Double? = null,
    val avgHr: Int = 0,
    val maxHr: Int = 0,
    val steps: Int = 0,
    val distanceMeters: Double = 0.0,
    val route: List<RoutePoint> = emptyList(),
    val sets: List<StrengthSet> = emptyList(),
    val zoneSeconds: DoubleArray = DoubleArray(6),
    val strainTarget: Double = 8.0,
    /** AtriaWorkoutSegmentAttribution: (activity, startMs) per segment of a multi-activity workout. */
    val segments: List<Pair<String, Long>> = emptyList(),
    /** Rest timer started when a set is logged (AtriaStrengthSetLogging rest ring). */
    val restStartedAt: Long? = null,
) {
    val elapsedMs get() = (pausedAt ?: System.currentTimeMillis()) - startMs - pausedMs
    val isPaused get() = pausedAt != null
}

/**
 * Manual workout lifecycle (Gate 3 on iOS): start → live strain/zones/calories,
 * strap IMU lease for steps, optional route → end persists a confirmed
 * workout. The active row is written immediately so a process death restores
 * it (ActiveSessionJournal equivalent).
 */
class WorkoutRuntime(
    private val context: Context,
    private val repo: Repository,
    private val strap: StrapManager,
    private val engine: MetricsEngine,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _live = MutableStateFlow<LiveWorkout?>(null)
    val live: StateFlow<LiveWorkout?> = _live.asStateFlow()
    private var job: Job? = null
    private var lastLocation: Location? = null
    private val fused by lazy { LocationServices.getFusedLocationProviderClient(context) }

    private val locationCallback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            val w = _live.value ?: return
            if (w.isPaused) return
            var dist = w.distanceMeters
            val points = ArrayList(w.route)
            for (loc in result.locations) {
                if (loc.accuracy > 30) continue
                lastLocation?.let { prev -> dist += prev.distanceTo(loc) }
                lastLocation = loc
                points += RoutePoint(loc.time, loc.latitude, loc.longitude, if (loc.hasAltitude()) loc.altitude else null, loc.accuracy)
            }
            _live.value = w.copy(distanceMeters = dist, route = points)
        }
    }

    init {
        scope.launch {
            // Restore an active workout after process death.
            repo.db.workouts().active()?.let { a ->
                _live.value = LiveWorkout(a.id, a.activity, a.startMs, sets = decodeSets(a.setsJson))
                startTicker()
                strap.setWorkoutMotion(true)
                com.adidshaft.atria.platform.StrapService.start(context)
            }
        }
    }

    fun start(activity: String) {
        if (_live.value != null) return
        val now = System.currentTimeMillis()
        // Publish synchronously so the live screen never observes a null workout on its first frame.
        _live.value = LiveWorkout(0, activity, now)
        com.adidshaft.atria.platform.StrapService.start(context)
        lastLocation = null
        strap.setWorkoutMotion(true)
        if (activity in ROUTE_ACTIVITIES) startLocation()
        scope.launch {
            val id = repo.db.workouts().insert(WorkoutEntity(activity = activity, startMs = now, endMs = now, strain = 0.0, avgHr = 0, maxHr = 0, calories = null, steps = null, zonesJson = null, status = "active", source = Source.MANUAL))
            val daily = repo.db.daily().get(repo.today().toEpochDay())
            val target = com.adidshaft.atria.analytics.StrainTarget.target(daily?.recovery, engine.trainingLoad())
            _live.value = _live.value?.copy(id = id, strainTarget = (target - (daily?.strain ?: 0.0)).coerceAtLeast(2.0))
            startTicker()
        }
    }

    /** Switching activity mid-workout starts a new segment (the first minute counts as a correction, not a segment). */
    fun changeActivity(activity: String) {
        val w = _live.value ?: return
        if (activity == w.activity) return
        val now = System.currentTimeMillis()
        val segs = if (w.segments.isEmpty()) listOf(w.activity to w.startMs) else w.segments
        _live.value = if (now - w.startMs < 60_000) w.copy(activity = activity, segments = emptyList())
        else w.copy(activity = activity, segments = segs + (activity to now))
    }

    fun togglePause() {
        val w = _live.value ?: return
        _live.value = if (w.pausedAt == null) w.copy(pausedAt = System.currentTimeMillis())
        else w.copy(pausedMs = w.pausedMs + (System.currentTimeMillis() - w.pausedAt), pausedAt = null)
    }

    fun logSet(exercise: String, reps: Int, weightKg: Double?) {
        val w = _live.value ?: return
        _live.value = w.copy(sets = w.sets + StrengthSet(exercise, reps, weightKg, System.currentTimeMillis()), restStartedAt = System.currentTimeMillis())
    }

    fun end(save: Boolean = true) {
        val w = _live.value ?: return
        job?.cancel()
        stopLocation()
        strap.setWorkoutMotion(false)
        _live.value = null
        scope.launch {
            val existing = (if (w.id != 0L) repo.db.workouts().get(w.id) else repo.db.workouts().active()) ?: return@launch
            if (!save || w.elapsedMs < 60_000) { repo.db.workouts().delete(existing.id); return@launch }
            val final = compute(w)
            repo.db.workouts().upsert(
                existing.copy(
                    endMs = System.currentTimeMillis(), strain = final.strain, avgHr = final.avgHr, maxHr = final.maxHr,
                    calories = final.calories, steps = final.steps.takeIf { it > 0 },
                    zonesJson = AppJson.encodeToString(ListSerializer(kotlinx.serialization.serializer<Double>()), final.zoneSeconds.toList()),
                    routeJson = final.route.takeIf { it.isNotEmpty() }?.let { AppJson.encodeToString(ListSerializer(RoutePoint.serializer()), it) },
                    distanceMeters = final.distanceMeters.takeIf { it > 0 },
                    elevationGainMeters = elevationGain(final.route),
                    setsJson = final.sets.takeIf { it.isNotEmpty() }?.let { AppJson.encodeToString(ListSerializer(StrengthSet.serializer()), it) },
                    notes = final.segments.takeIf { it.size > 1 }?.joinToString(";") { "${it.first}@${it.second}" },
                    activity = if (final.segments.size > 1) "Multi-activity" else final.activity,
                    status = "confirmed",
                ),
            )
            engine.refresh()
        }
    }

    private fun startTicker() {
        job?.cancel()
        job = scope.launch {
            while (isActive) {
                _live.value?.let { w -> if (!w.isPaused) _live.value = compute(w) }
                delay(2_000)
            }
        }
    }

    private suspend fun compute(w: LiveWorkout): LiveWorkout {
        val settings = repo.settings.current()
        val profile = settings.profile.toAthlete()
        val rest = repo.settings.currentBaseline().restingEma?.roundToInt() ?: 60
        val hr: List<HrSample> = repo.hr(w.startMs, System.currentTimeMillis()) + listOfNotNull(
            strap.state.value.takeIf { it.hrFresh }?.let { HrSample(it.heartRateAt, it.heartRate) },
        ).filter { s -> s.t > (repo.db.samples().latestHr()?.t ?: 0) }
        if (hr.isEmpty()) return w.copy(steps = strap.sessionSteps())
        val load = StrainLoadModel.calculate(hr, rest, profile.estimatedMaxHr, profile.sex, StrainLoadModel.Mode.WORKOUT).load
        val muscular = if (w.sets.isNotEmpty()) StrainLoadModel.muscularTrimpEquivalent((w.sets.size * 8.0).coerceAtMost(100.0)) else 0.0
        return w.copy(
            strain = StrainLoadModel.displayScore(load + muscular),
            calories = Energy.activeCalories(hr, rest, profile),
            avgHr = hr.map { it.bpm }.average().roundToInt(),
            maxHr = hr.maxOf { it.bpm },
            zoneSeconds = Zones.seconds(hr, profile.estimatedMaxHr, rest),
            steps = strap.sessionSteps(),
        )
    }

    @SuppressLint("MissingPermission")
    private fun startLocation() {
        if (!Permissions.hasLocation(context)) return
        val req = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 2_000).setMinUpdateDistanceMeters(3f).build()
        runCatching { fused.requestLocationUpdates(req, locationCallback, Looper.getMainLooper()) }
    }

    private fun stopLocation() { runCatching { fused.removeLocationUpdates(locationCallback) } }

    private fun elevationGain(route: List<RoutePoint>): Double? {
        val alts = route.mapNotNull { it.alt }
        if (alts.size < 2) return null
        return alts.zipWithNext { a, b -> (b - a).coerceAtLeast(0.0) }.filter { it < 15 }.sum()
    }

    companion object {
        fun decodeSets(json: String?): List<StrengthSet> = json?.let { runCatching { AppJson.decodeFromString(ListSerializer(StrengthSet.serializer()), it) }.getOrNull() } ?: emptyList()
        fun decodeRoute(json: String?): List<RoutePoint> = json?.let { runCatching { AppJson.decodeFromString(ListSerializer(RoutePoint.serializer()), it) }.getOrNull() } ?: emptyList()
        fun decodeZones(json: String?): List<Double> = json?.let { runCatching { AppJson.decodeFromString(ListSerializer(kotlinx.serialization.serializer<Double>()), it) }.getOrNull() } ?: emptyList()
    }
}
