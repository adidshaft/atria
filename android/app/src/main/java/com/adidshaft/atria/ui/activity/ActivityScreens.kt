package com.adidshaft.atria.ui.activity

import android.graphics.Paint
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.SleepDetector
import com.adidshaft.atria.analytics.SleepStage
import com.adidshaft.atria.analytics.formatHours
import com.adidshaft.atria.data.SleepEntity
import com.adidshaft.atria.data.WorkoutEntity
import com.adidshaft.atria.domain.WorkoutRuntime
import com.adidshaft.atria.domain.decodeStages
import com.adidshaft.atria.ui.AppViewModel
import com.adidshaft.atria.ui.components.AtriaCard
import com.adidshaft.atria.ui.components.ChartPoint
import com.adidshaft.atria.ui.components.CircleButton
import com.adidshaft.atria.ui.components.EmptyState
import com.adidshaft.atria.ui.components.Eyebrow
import com.adidshaft.atria.ui.components.Hypnogram
import com.adidshaft.atria.ui.components.KeyValueRow
import com.adidshaft.atria.ui.components.SectionTitle
import com.adidshaft.atria.ui.components.TimeSeriesChart
import com.adidshaft.atria.ui.components.ZoneBars
import com.adidshaft.atria.ui.components.stageColor
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import com.adidshaft.atria.ui.today.SleepReviewCard
import com.adidshaft.atria.ui.today.WorkoutReviewCard
import com.adidshaft.atria.ui.today.clock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.BoundingBox
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Polyline
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

private val dayFmt = DateTimeFormatter.ofPattern("EEE, MMM d")

/** Activity Monitor tab (the repurposed iOS "plan" slot): reviews + a day-by-day timeline. */
@Composable
fun ActivityScreen(vm: AppViewModel, nav: NavHostController) {
    val s = LocalSurfaces.current
    val sleeps by vm.sleeps.collectAsStateWithLifecycle()
    val workouts by vm.workouts.collectAsStateWithLifecycle()
    val candidates by vm.sleepCandidates.collectAsStateWithLifecycle()
    val reviews by vm.workoutReviews.collectAsStateWithLifecycle()
    SectionTitle("Activity")
    if (candidates.isNotEmpty() || reviews.isNotEmpty()) {
        Eyebrow("To review")
        candidates.forEach { SleepReviewCard(it, vm) }
        reviews.forEach { WorkoutReviewCard(it, vm) }
    }
    com.adidshaft.atria.ui.extras.DetectionsCard()
    val zone = ZoneId.systemDefault()
    data class Item(val start: Long, val end: Long, val title: String, val detail: String, val color: androidx.compose.ui.graphics.Color, val route: String)
    val items = sleeps.filter { it.status == "confirmed" }.map { Item(it.startMs, it.endMs, if (it.isNap) "Nap" else "Sleep", formatHours(it.asleepMs / 3_600_000.0), AtriaColors.sleep, "sleep/${it.id}") } +
        workouts.filter { it.status == "confirmed" }.map { Item(it.startMs, it.endMs, it.activity, "Strain %.1f · ${(it.endMs - it.startMs) / 60_000} min".format(it.strain), AtriaColors.strain, "workoutdetail/${it.id}") }
    if (items.isEmpty()) { AtriaCard { EmptyState("Nothing yet", "Detected sleep, naps and workouts appear here. Start a workout with the + button.") }; return }
    items.sortedByDescending { it.start }.groupBy { Instant.ofEpochMilli(it.end).atZone(zone).toLocalDate() }.forEach { (day, list) ->
        Eyebrow(if (day == LocalDate.now()) "Today" else day.format(dayFmt))
        list.forEach { it ->
            AtriaCard(onClick = { nav.navigate(it.route) }, padding = 14.dp) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    com.adidshaft.atria.ui.components.Dot(it.color, 10.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(it.title, style = MaterialTheme.typography.titleSmall)
                        Text("${clock(it.start)} – ${clock(it.end)}", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
                    }
                    Text(it.detail, style = MaterialTheme.typography.labelLarge, color = it.color)
                }
            }
        }
    }
}

@Composable
private fun DetailScaffold(title: String, onBack: () -> Unit, onDelete: (() -> Unit)? = null, content: @Composable () -> Unit) {
    val s = LocalSurfaces.current
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.statusBarsPadding(), verticalAlignment = Alignment.CenterVertically) {
                CircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", size = 46.dp, onClick = onBack)
                Spacer(Modifier.width(12.dp))
                Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                onDelete?.let { CircleButton(Icons.Filled.Delete, "Delete", size = 46.dp, tint = AtriaColors.danger, onClick = it) }
            }
        }
        item { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { content() } }
    }
}

@Composable
fun SleepDetailScreen(vm: AppViewModel, id: Long, onBack: () -> Unit) {
    val s = LocalSurfaces.current
    var sleep by remember { mutableStateOf<SleepEntity?>(null) }
    var hr by remember { mutableStateOf<List<ChartPoint>>(emptyList()) }
    LaunchedEffect(id) {
        withContext(Dispatchers.IO) {
            val g = AtriaApp.graph
            sleep = g.repo.db.sleeps().get(id)
            sleep?.let { sl -> hr = g.repo.db.samples().hrMinutes(sl.startMs, sl.endMs).map { ChartPoint(it.minute, it.meanHr) } }
        }
    }
    val sl = sleep ?: return DetailScaffold("Sleep", onBack) { Text("Loading…", color = s.textSecondary) }
    DetailScaffold(Instant.ofEpochMilli(sl.endMs).atZone(ZoneId.systemDefault()).toLocalDate().format(dayFmt), onBack, onDelete = { vm.deleteSleep(id); onBack() }) {
        AtriaCard {
            Text(formatHours(sl.asleepMs / 3_600_000.0), style = MaterialTheme.typography.displayMedium, color = AtriaColors.sleep)
            Text("${clock(sl.startMs)} – ${clock(sl.endMs)} · ${if (sl.isNap) "Nap" else "Main sleep"} · ${sl.source}", color = s.textSecondary)
            sl.efficiency?.let { KeyValueRow("Efficiency", "${(it * 100).toInt()}%") }
            sl.restingHr?.let { KeyValueRow("Resting HR", "$it bpm") }
            sl.rmssd?.let { KeyValueRow("HRV (RMSSD)", "${it.toInt()} ms") }
            sl.respiratoryRate?.let { KeyValueRow("Respiratory rate", "%.1f /min".format(it)) }
            KeyValueRow("Wake-ups", "${sl.disturbances}")
            KeyValueRow("Motion evidence", if (sl.motionValidated) "Validated" else "HR only")
        }
        val stages = decodeStages(sl.stagesJson)
        if (stages.isNotEmpty()) AtriaCard {
            Eyebrow(if (sl.motionValidated) "Stages · estimate" else "Stages · HR-only estimate")
            Spacer(Modifier.height(8.dp))
            Hypnogram(stages, sl.startMs, sl.endMs)
            val mins = SleepDetector.stageMinutes(stages)
            SleepStage.entries.forEach { st -> KeyValueRow(st.label, "${mins[st]!! / 60}h ${mins[st]!! % 60}m", valueColor = stageColor(st)) }
            Text("Stages are an estimate from heart rate and wrist motion, not a sleep study.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
        }
        if (!sl.isNap) com.adidshaft.atria.ui.extras.NightBaselineCard(sl)
        if (!sl.isNap) com.adidshaft.atria.ui.extras.NightInterruptionCard(sl.endMs)
        AtriaCard {
            Text("Heart rate", style = MaterialTheme.typography.titleSmall)
            TimeSeriesChart(hr, height = 180.dp, color = AtriaColors.heart, startMs = sl.startMs, endMs = sl.endMs, gapMs = 10 * 60_000L, unit = "bpm", description = "Heart rate during sleep")
        }
    }
}

@Composable
fun WorkoutDetailScreen(vm: AppViewModel, id: Long, onBack: () -> Unit) {
    val s = LocalSurfaces.current
    var w by remember { mutableStateOf<WorkoutEntity?>(null) }
    var hr by remember { mutableStateOf<List<ChartPoint>>(emptyList()) }
    LaunchedEffect(id) {
        withContext(Dispatchers.IO) {
            val g = AtriaApp.graph
            w = g.repo.db.workouts().get(id)
            w?.let { x -> hr = g.repo.hr(x.startMs, x.endMs).map { ChartPoint(it.t, it.bpm.toDouble()) } }
        }
    }
    val x = w ?: return DetailScaffold("Workout", onBack) { Text("Loading…", color = s.textSecondary) }
    DetailScaffold(x.activity, onBack, onDelete = { vm.deleteWorkout(id); onBack() }) {
        AtriaCard {
            Row {
                Column(Modifier.weight(1f)) { Eyebrow("Strain"); Text("%.1f".format(x.strain), style = MaterialTheme.typography.displayMedium, color = AtriaColors.strain) }
                Column(Modifier.weight(1f)) { Eyebrow("Duration"); Text("${(x.endMs - x.startMs) / 60_000} min", style = MaterialTheme.typography.headlineMedium) }
            }
            Text("${clock(x.startMs)} – ${clock(x.endMs)}", color = s.textSecondary)
            // AtriaWorkoutMetricPresentation: thin HR coverage makes strain/calories a lower bound.
            val coverage = if (x.endMs > x.startMs) (hr.size * 1000.0 * 1.0 / (x.endMs - x.startMs)).coerceAtMost(1.0) else 0.0
            if (hr.isNotEmpty() && coverage < 0.5) Text("Heart rate captured for ${(coverage * 100).toInt()}% of this workout. Strain is a lower bound.", style = MaterialTheme.typography.bodySmall, color = AtriaColors.stress)
            KeyValueRow("Average HR", "${x.avgHr} bpm")
            KeyValueRow("Max HR", "${x.maxHr} bpm")
            x.calories?.let { KeyValueRow("Active energy", "≈ ${it.toInt()} kcal") }
            x.steps?.let { KeyValueRow("Steps (strap)", "$it") }
            x.distanceMeters?.let { KeyValueRow("Distance", "%.2f km".format(it / 1000)) }
            x.elevationGainMeters?.let { KeyValueRow("Elevation gain", "${it.toInt()} m") }
            if (x.distanceMeters != null && x.distanceMeters > 100) {
                val paceSec = (x.endMs - x.startMs) / 1000.0 / (x.distanceMeters / 1000)
                KeyValueRow("Pace", "%d:%02d /km".format((paceSec / 60).toInt(), (paceSec % 60).toInt()))
            }
        }
        x.notes?.takeIf { it.contains("@") }?.let { n ->
            AtriaCard {
                Text("Segments", style = MaterialTheme.typography.titleSmall)
                n.split(";").mapNotNull { seg -> seg.split("@").takeIf { it.size == 2 }?.let { it[0] to (it[1].toLongOrNull() ?: 0L) } }
                    .forEach { (a, t) -> KeyValueRow(a, "from ${clock(t)}") }
            }
        }
        val route = WorkoutRuntime.decodeRoute(x.routeJson)
        if (route.size >= 2) AtriaCard(padding = 0.dp) {
            // One polyline per uninterrupted segment: never draw a straight line across a pause or GPS gap.
            val segs = ArrayList<MutableList<GeoPoint>>()
            route.forEachIndexed { i, p -> if (i == 0 || p.t - route[i - 1].t > 30_000) segs += mutableListOf(GeoPoint(p.lat, p.lon)) else segs.last() += GeoPoint(p.lat, p.lon) }
            RouteMap(segs)
        }
        AtriaCard {
            Text("Heart rate", style = MaterialTheme.typography.titleSmall)
            TimeSeriesChart(hr, height = 180.dp, startMs = x.startMs, endMs = x.endMs, gapMs = 60_000L, unit = "bpm", description = "Workout heart rate")
        }
        val zones = WorkoutRuntime.decodeZones(x.zonesJson)
        if (zones.size == 6) AtriaCard { Text("Heart-rate zones", style = MaterialTheme.typography.titleSmall); Spacer(Modifier.height(6.dp)); ZoneBars(zones) }
        val sets = WorkoutRuntime.decodeSets(x.setsJson)
        if (sets.isNotEmpty()) AtriaCard {
            Text("Sets", style = MaterialTheme.typography.titleSmall)
            sets.forEachIndexed { i, st -> KeyValueRow("${i + 1}. ${st.exercise}", "${st.reps} reps${st.weightKg?.let { " · ${it} kg" } ?: ""}") }
        }
    }
}

/** MapKit route → osmdroid OpenStreetMap view with the route polyline. */
@Composable
fun RouteMap(segments: List<List<GeoPoint>>, modifier: Modifier = Modifier) {
    val points = segments.flatten()
    AndroidView(
        modifier = modifier.fillMaxWidth().height(240.dp).clip(RoundedCornerShape(28.dp)),
        factory = { ctx ->
            Configuration.getInstance().userAgentValue = ctx.packageName
            MapView(ctx).apply {
                setTileSource(TileSourceFactory.MAPNIK)
                setMultiTouchControls(true)
                segments.filter { it.size >= 2 }.forEach { seg ->
                    overlays.add(Polyline(this).apply {
                        setPoints(seg)
                        outlinePaint.color = AtriaColors.strain.toArgb()
                        outlinePaint.strokeWidth = 10f
                        outlinePaint.strokeCap = Paint.Cap.ROUND
                    })
                }
                addOnFirstLayoutListener { _, _, _, _, _ -> zoomToBoundingBox(BoundingBox.fromGeoPoints(points).increaseByScale(1.3f), false) }
            }
        },
    )
}
