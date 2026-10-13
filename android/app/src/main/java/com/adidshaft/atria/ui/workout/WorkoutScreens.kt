package com.adidshaft.atria.ui.workout

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.HrZone
import com.adidshaft.atria.domain.ROUTE_ACTIVITIES
import com.adidshaft.atria.ui.AppViewModel
import com.adidshaft.atria.ui.components.AtriaCard
import com.adidshaft.atria.ui.components.CircleButton
import com.adidshaft.atria.ui.components.Eyebrow
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.components.ProgressBar
import com.adidshaft.atria.ui.components.StatTile
import com.adidshaft.atria.ui.components.ZoneStrip
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import kotlinx.coroutines.delay

/** AtriaWorkoutActivityType catalog with WHOOP-style categories. */
val ACTIVITY_CATALOG: Map<String, List<String>> = linkedMapOf(
    "Training" to listOf("Strength", "Functional", "HIIT", "Powerlifting", "Jump rope"),
    "Cardio & endurance" to listOf("Cardio", "Running", "Walking", "Cycling", "Rowing", "Elliptical", "Stair climber", "Spin", "Assault bike", "Triathlon", "Duathlon", "Obstacle course racing", "Track & field", "Swimming"),
    "Sports" to listOf("Sport", "Basketball", "Football / soccer", "Cricket", "Tennis", "Badminton", "Volleyball", "Golf", "Baseball", "Softball", "Rugby", "Ice hockey", "Field hockey", "Lacrosse", "Squash", "Table tennis", "Pickleball", "Padel", "Handball", "Netball", "Ultimate", "Disc golf", "Gymnastics", "Water polo", "Skateboarding", "Inline skating"),
    "Outdoor & water" to listOf("Hiking", "Climbing", "Mountain biking", "Horseback riding", "Sailing", "Kayaking", "Paddleboarding", "Surfing", "Water skiing", "Wakeboarding"),
    "Winter" to listOf("Skiing", "Snowboarding", "Cross-country skiing", "Ice skating"),
    "Combat" to listOf("Boxing", "Martial arts", "Kickboxing", "Jiu jitsu", "Wrestling", "Fencing"),
    "Mind & body" to listOf("Yoga", "Pilates", "Dance", "Barre", "Mobility", "Meditation", "Breathwork"),
    "Recovery" to listOf("Sauna", "Ice bath", "Massage"),
    "Daily life" to listOf("Manual labor", "Yard work", "Dog walking", "Other"),
)

@Composable
fun WorkoutSetupScreen(onBack: () -> Unit, onStarted: () -> Unit) {
    val s = LocalSurfaces.current
    var query by remember { mutableStateOf("") }
    var pending by remember { mutableStateOf<String?>(null) }
    val locationLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        pending?.let { AtriaApp.graph.workouts.start(it); onStarted() }
    }
    fun start(activity: String) {
        if (activity in ROUTE_ACTIVITIES && !com.adidshaft.atria.ble.Permissions.hasLocation(AtriaApp.instance)) {
            pending = activity
            locationLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        } else { AtriaApp.graph.workouts.start(activity); onStarted() }
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Row(Modifier.statusBarsPadding(), verticalAlignment = Alignment.CenterVertically) {
                CircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", size = 46.dp, onClick = onBack)
                Spacer(Modifier.width(12.dp))
                Text("Start a workout", style = MaterialTheme.typography.titleLarge)
            }
        }
        item { OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), placeholder = { Text("Search activities") }, singleLine = true, shape = RoundedCornerShape(50)) }
        ACTIVITY_CATALOG.forEach { (cat, list) ->
            val filtered = list.filter { query.isBlank() || it.contains(query, ignoreCase = true) }
            if (filtered.isNotEmpty()) {
                item { Eyebrow(cat, Modifier.padding(top = 10.dp)) }
                items(filtered) { a ->
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(s.card).clickable(role = Role.Button) { start(a) }.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(a, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                        if (a in ROUTE_ACTIVITIES) Text("GPS", style = MaterialTheme.typography.labelSmall, color = s.textTertiary)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveWorkoutScreen(vm: AppViewModel, onClose: () -> Unit) {
    val s = LocalSurfaces.current
    val w by vm.liveWorkout.collectAsStateWithLifecycle()
    val live by vm.live.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    val d by vm.derived.collectAsStateWithLifecycle()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var confirmEnd by remember { mutableStateOf(false) }
    var logSet by remember { mutableStateOf(false) }
    var pickActivity by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { while (true) { now = System.currentTimeMillis(); delay(1_000) } }
    val workout = w
    if (workout == null) { LaunchedEffect(Unit) { onClose() }; return }
    val runtime = AtriaApp.graph.workouts
    val elapsed = workout.elapsedMs.coerceAtLeast(0) / 1000
    val maxHr = settings.profile.toAthlete().estimatedMaxHr
    val zone = if (live.hrFresh) HrZone.of(live.heartRate, maxHr, d.restingNow) else HrZone.REST

    Column(
        Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Color(0xFF2A2C31), s.background))).statusBarsPadding().navigationBarsPadding()
            .verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircleButton(Icons.Filled.KeyboardArrowDown, "Minimise", size = 56.dp, onClick = onClose)
            Spacer(Modifier.width(12.dp))
            Row(Modifier.clickable { pickActivity = true }, verticalAlignment = Alignment.CenterVertically) {
                Text(workout.activity, style = MaterialTheme.typography.titleLarge)
                Text(" ⌄", color = s.textSecondary)
            }
            Spacer(Modifier.weight(1f))
            Text("%02d:%02d".format(elapsed / 60, elapsed % 60).let { if (elapsed >= 3600) "%d:%02d:%02d".format(elapsed / 3600, (elapsed / 60) % 60, elapsed % 60) else it }, style = MaterialTheme.typography.displayMedium.copy(fontSize = 40.sp))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            com.adidshaft.atria.ui.components.Dot(if (live.imuLive) AtriaColors.calm else AtriaColors.orange)
            Spacer(Modifier.width(8.dp))
            Text(if (workout.isPaused) "Paused" else if (live.imuLive) "Motion live" else "Motion syncing", color = s.textSecondary)
        }
        AtriaCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Favorite, null, tint = AtriaColors.heart, modifier = Modifier.size(40.dp))
                Spacer(Modifier.width(12.dp))
                Text(if (live.hrFresh) "${live.heartRate}" else "--", style = MaterialTheme.typography.displayLarge.copy(fontSize = 84.sp, fontWeight = FontWeight.Black))
                Text(" BPM", color = s.textSecondary, modifier = Modifier.padding(top = 30.dp))
                Spacer(Modifier.weight(1f))
                live.battery?.let { Text("$it%", style = MaterialTheme.typography.labelLarge, modifier = Modifier.clip(RoundedCornerShape(50)).background(s.inset).padding(horizontal = 14.dp, vertical = 8.dp)) }
            }
            Spacer(Modifier.height(10.dp))
            ZoneStrip(zone.ordinal)
            Spacer(Modifier.height(8.dp))
            Text("Target Z2–Z3 · ${HrZone.lowerBpm(HrZone.FAT_BURN, d.restingNow ?: 60, maxHr)}–${HrZone.lowerBpm(HrZone.ANAEROBIC, d.restingNow ?: 60, maxHr) - 1} bpm", color = s.textSecondary)
        }
        AtriaCard(tint = AtriaColors.hrv) {
            val pct = (workout.strain / workout.strainTarget).toFloat()
            Text(if (pct < 0.5f) "Build gently" else if (pct < 1f) "On track" else "Target reached", style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold))
            Text("%.1f strain · target %.1f".format(workout.strain, workout.strainTarget), color = s.textSecondary)
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatTile("Strain", "%.1f".format(workout.strain), Modifier.weight(1f), AtriaColors.strain)
                StatTile("Active", workout.calories?.let { "≈ ${it.toInt()} kcal" } ?: "--", Modifier.weight(1f), AtriaColors.heart)
                StatTile("Steps", if (workout.steps > 0) "${workout.steps}" else if (live.imuLive) "0" else "syncing", Modifier.weight(1f), AtriaColors.steps)
            }
            if (workout.distanceMeters > 0) {
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatTile("Distance", "%.2f km".format(workout.distanceMeters / 1000), Modifier.weight(1f))
                    val pace = if (workout.distanceMeters > 50) (workout.elapsedMs / 1000.0) / (workout.distanceMeters / 1000) else null
                    StatTile("Pace", pace?.let { "%d:%02d /km".format((it / 60).toInt(), (it % 60).toInt()) } ?: "--", Modifier.weight(1f))
                }
            }
            Spacer(Modifier.height(10.dp))
            ProgressBar(pct, AtriaColors.strain)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            PillButton("Log set", Modifier.weight(1f), Icons.Filled.AddCircle, AtriaColors.teal, height = 64.dp) { logSet = true }
            PillButton(if (workout.isPaused) "Resume" else "Pause", Modifier.weight(1f), if (workout.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause, AtriaColors.orange, height = 64.dp) { runtime.togglePause() }
        }
        if (workout.sets.isNotEmpty()) AtriaCard {
            Text("${workout.sets.size} sets logged", style = MaterialTheme.typography.titleSmall)
            workout.sets.takeLast(5).forEach { Text("${it.exercise} · ${it.reps} reps${it.weightKg?.let { kg -> " · $kg kg" } ?: ""}", color = s.textSecondary) }
        }
        Spacer(Modifier.height(20.dp))
        PillButton("End workout", Modifier.fillMaxWidth(), Icons.Filled.Stop, AtriaColors.danger, height = 64.dp) { confirmEnd = true }
    }

    if (confirmEnd) AlertDialog(
        onDismissRequest = { confirmEnd = false },
        title = { Text("End ${workout.activity}?") },
        text = { Text(if (workout.elapsedMs < 60_000) "Workouts under a minute are discarded." else "Strain %.1f will be saved to today.".format(workout.strain)) },
        confirmButton = { TextButton({ confirmEnd = false; runtime.end(true); onClose() }) { Text("Save") } },
        dismissButton = { TextButton({ confirmEnd = false; runtime.end(false); onClose() }) { Text("Discard", color = AtriaColors.danger) } },
    )
    if (logSet) {
        var exercise by remember { mutableStateOf(workout.sets.lastOrNull()?.exercise ?: "") }
        var reps by remember { mutableStateOf("10") }
        var kg by remember { mutableStateOf("") }
        ModalBottomSheet(onDismissRequest = { logSet = false }, containerColor = s.card) {
            Column(Modifier.padding(20.dp).padding(bottom = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Log set", style = MaterialTheme.typography.titleLarge)
                OutlinedTextField(exercise, { exercise = it }, Modifier.fillMaxWidth(), label = { Text("Exercise") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(reps, { reps = it.filter(Char::isDigit) }, Modifier.weight(1f), label = { Text("Reps") }, singleLine = true)
                    OutlinedTextField(kg, { kg = it.filter { c -> c.isDigit() || c == '.' } }, Modifier.weight(1f), label = { Text("Weight (kg)") }, singleLine = true)
                }
                PillButton("Save set", Modifier.fillMaxWidth(), color = AtriaColors.teal) {
                    runtime.logSet(exercise.ifBlank { "Set" }, reps.toIntOrNull() ?: 0, kg.toDoubleOrNull()); logSet = false
                }
            }
        }
    }
    if (pickActivity) ModalBottomSheet(onDismissRequest = { pickActivity = false }, containerColor = s.card) {
        LazyColumn(Modifier.padding(horizontal = 20.dp).height(480.dp)) {
            ACTIVITY_CATALOG.values.flatten().forEach { a -> item { Text(a, Modifier.fillMaxWidth().clickable { runtime.changeActivity(a); pickActivity = false }.padding(vertical = 14.dp), style = MaterialTheme.typography.titleSmall) } }
        }
    }
}
