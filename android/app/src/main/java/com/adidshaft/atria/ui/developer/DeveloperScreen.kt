package com.adidshaft.atria.ui.developer

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.data.AppJson
import com.adidshaft.atria.data.SensorReference
import com.adidshaft.atria.data.StepCalibration
import com.adidshaft.atria.protocol.Cmd
import com.adidshaft.atria.ui.AppViewModel
import com.adidshaft.atria.ui.components.AtriaCard
import com.adidshaft.atria.ui.components.CircleButton
import com.adidshaft.atria.ui.components.Eyebrow
import com.adidshaft.atria.ui.components.KeyValueRow
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.components.SegmentedTabs
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

fun shareFile(c: Context, f: File, mime: String) {
    val uri = FileProvider.getUriForFile(c, "${c.packageName}.files", f)
    c.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), "Share"))
}

fun shareDir(c: Context) = File(c.cacheDir, "share").apply { mkdirs() }

/** AtriaDiagnosisReport: one snapshot explaining live HR/IMU, drain, recovery inputs and widget state. */
suspend fun diagnosisReport(): String {
    val g = AtriaApp.graph
    val s = g.strap.state.value
    val strap = g.repo.settings.currentStrap()
    val base = g.repo.settings.currentBaseline()
    val now = System.currentTimeMillis()
    val today = g.repo.db.daily().get(g.repo.today().toEpochDay())
    val obj = buildJsonObject {
        put("generated_at", now)
        put("link_status", s.status.name); put("hr", s.heartRate); put("hr_age_s", if (s.heartRateAt > 0) (now - s.heartRateAt) / 1000 else -1)
        put("on_wrist", s.onWrist); put("imu_live", s.imuLive); put("battery", s.battery ?: -1); put("charging", s.charging)
        put("drain_active", s.drainActive); put("drain_rows", s.drainRows); put("pending_records", s.pendingRecords ?: -1)
        put("firmware", strap.firmware ?: ""); put("clock_offset_s", strap.clockOffsetSeconds); put("last_history_sync", strap.lastHistorySyncAt ?: -1)
        put("baseline_resting_days", base.freshRestingDays(now)); put("baseline_hrv_nights", base.freshHrvNights(now))
        put("resting_trusted", base.hasTrustedResting(now)); put("hrv_trusted", base.hasTrustedHrv(now))
        put("today_recovery", today?.recovery ?: -1); put("today_confidence", today?.recoveryConfidence ?: ""); put("today_strain", today?.strain ?: -1.0)
        put("hr_rows", g.repo.db.samples().hrCount()); put("history_hr_rows", g.repo.db.samples().countBySource(com.adidshaft.atria.data.Source.HISTORY))
        put("live_workout", g.workouts.live.value?.activity ?: "")
        put("broadcaster", g.broadcaster.status)
    }
    return AppJson.encodeToString(kotlinx.serialization.json.JsonObject.serializer(), obj)
}

@Composable
fun DeveloperScreen(vm: AppViewModel, onBack: () -> Unit) {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    val g = AtriaApp.graph
    val live by vm.live.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var frames by remember { mutableStateOf(g.strap.recentFrames()) }
    var report by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { while (isActive) { frames = g.strap.recentFrames(); report = diagnosisReport(); delay(2_000) } }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.statusBarsPadding(), verticalAlignment = Alignment.CenterVertically) {
                CircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", size = 46.dp, onClick = onBack)
                Spacer(Modifier.width(12.dp))
                Text("Developer & research", style = MaterialTheme.typography.titleLarge)
            }
        }
        item {
            AtriaCard {
                Eyebrow("Diagnosis report")
                Text(report, fontFamily = FontFamily.Monospace, fontSize = 10.sp, color = s.textSecondary)
                PillButton("Share report", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 42.dp) {
                    val f = File(shareDir(ctx), "atria-diagnosis.json").apply { writeText(report) }; shareFile(ctx, f, "application/json")
                }
            }
        }
        item {
            AtriaCard {
                Eyebrow("Strap diagnostics (read-only / reversible)")
                Text("Status ${live.status} · packets ${live.packets} · IMU ${if (live.imuLive) "live" else "idle"}", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PillButton("Clock 0B", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 40.dp) { g.strap.diagnosticCommand(Cmd.GET_CLOCK, byteArrayOf(0)) }
                    PillButton("Range 22", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 40.dp) { g.strap.diagnosticCommand(Cmd.GET_DATA_RANGE, byteArrayOf(0)) }
                    PillButton("Batt 1A", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 40.dp) { g.strap.diagnosticCommand(Cmd.GET_BATTERY_LEVEL, byteArrayOf(0)) }
                }
                Spacer(Modifier.height(6.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PillButton("IMU on", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 40.dp) { g.strap.diagnosticCommand(Cmd.TOGGLE_IMU_MODE, byteArrayOf(1)) }
                    PillButton("IMU off", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 40.dp) { g.strap.diagnosticCommand(Cmd.TOGGLE_IMU_MODE, byteArrayOf(0)) }
                    PillButton("Buzz", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 40.dp) { g.strap.haptic(1) }
                }
                Spacer(Modifier.height(6.dp))
                Text("Last frames", style = MaterialTheme.typography.labelMedium)
                frames.take(25).forEach { Text(it, fontFamily = FontFamily.Monospace, fontSize = 9.sp, color = s.textTertiary) }
            }
        }
        item { StepCalibrationCard() }
        item { SensorReferenceCard() }
    }
}

/** Guided counted-walk calibration with a metronome; exports the fit_step_calibration manifest. */
@Composable
private fun StepCalibrationCard() {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    val g = AtriaApp.graph
    val scope = rememberCoroutineScope()
    var cadence by remember { mutableIntStateOf(1) }
    var stage by remember { mutableStateOf("Ready") }
    var windows by remember { mutableStateOf<List<StepCalibration.Window>>(emptyList()) }
    var running by remember { mutableStateOf(false) }
    val spm = listOf(80, 100, 120)[cadence]
    AtriaCard {
        Eyebrow("Step calibration (research)")
        Text("Rest 30 s, then walk one step per click for 60 s with the strap streaming motion. Windows are exported for tools/fit_step_calibration.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        SegmentedTabs(listOf("80 spm", "100 spm", "120 spm"), cadence, { if (!running) cadence = it })
        Text(stage, style = MaterialTheme.typography.titleMedium, color = AtriaColors.steps)
        windows.forEach { w -> KeyValueRow(w.label, "expected ${w.expected_steps ?: 0} · strap ${w.strap_steps ?: 0}") }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PillButton(if (running) "Running…" else "Run trial", Modifier.weight(1f), color = AtriaColors.steps, height = 42.dp, enabled = !running) {
                running = true
                scope.launch {
                    g.strap.setWorkoutMotion(true)
                    val tone = runCatching { ToneGenerator(AudioManager.STREAM_MUSIC, 80) }.getOrNull()
                    stage = "Rest — stand still"; val r0 = System.currentTimeMillis(); val restSteps0 = g.strap.sessionSteps(); delay(30_000)
                    val rest = StepCalibration.Window("rest-${windows.size}", "rest", r0, System.currentTimeMillis(), 0, g.strap.sessionSteps() - restSteps0)
                    stage = "Walk — one step per click"; val w0 = System.currentTimeMillis(); val walkSteps0 = g.strap.sessionSteps()
                    val clicks = spm; val interval = 60_000L / spm
                    repeat(clicks) { tone?.startTone(ToneGenerator.TONE_PROP_BEEP, 40); delay(interval) }
                    delay(2_500) // let the last motion minute arrive
                    val walk = StepCalibration.Window("walk-${windows.size}-${spm}spm", "walk", w0, System.currentTimeMillis(), clicks, g.strap.sessionSteps() - walkSteps0)
                    tone?.release()
                    windows = windows + rest + walk
                    stage = "Done · strap counted ${walk.strap_steps} of $clicks"
                    g.strap.setWorkoutMotion(false)
                    running = false
                }
            }
            PillButton("Export", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 42.dp, enabled = windows.isNotEmpty()) {
                val f = File(shareDir(ctx), "atria-step-calibration.json").apply { writeText(AppJson.encodeToString(StepCalibration.Manifest.serializer(), StepCalibration.Manifest(cadence_spm = spm, windows = windows))) }
                shareFile(ctx, f, "application/json")
            }
        }
    }
}

/** Record readings from an external reference instrument (oximeter, skin thermometer, clock marker). */
@Composable
private fun SensorReferenceCard() {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    var kind by remember { mutableIntStateOf(0) }
    var value by remember { mutableStateOf("") }
    var device by remember { mutableStateOf("") }
    var site by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var count by remember { mutableIntStateOf(SensorReference.load(ctx).size) }
    val kinds = listOf("oxygen_reference" to "SpO₂ %", "skin_temperature_reference" to "Skin °C", "clock_marker" to "Clock mark")
    AtriaCard {
        Eyebrow("Sensor reference capture")
        Text("Readings stay research inputs only: they never change a metric or Health Connect.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        SegmentedTabs(kinds.map { it.second }, kind, { kind = it })
        if (kinds[kind].first != "clock_marker") OutlinedTextField(value, { value = it }, Modifier.fillMaxWidth(), label = { Text("Value") }, singleLine = true)
        OutlinedTextField(device, { device = it }, Modifier.fillMaxWidth(), label = { Text("Reference device") }, singleLine = true)
        if (kinds[kind].first == "skin_temperature_reference") OutlinedTextField(site, { site = it }, Modifier.fillMaxWidth(), label = { Text("Measurement site") }, singleLine = true)
        message?.let { Text(it, color = AtriaColors.stress, style = MaterialTheme.typography.bodySmall) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PillButton("Capture", Modifier.weight(1f), color = AtriaColors.hrv, height = 42.dp) {
                message = SensorReference.capture(ctx, kinds[kind].first, value.toDoubleOrNull(), if (kind == 1) "degC" else if (kind == 0) "percent" else null, device, site, null)
                if (message == null) { value = ""; count = SensorReference.load(ctx).size }
            }
            PillButton("Export CSV ($count)", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 42.dp, enabled = count > 0) {
                val f = File(shareDir(ctx), "atria-sensor-reference.csv").apply { writeText(SensorReference.csv(SensorReference.load(ctx))) }
                shareFile(ctx, f, "text/csv")
            }
        }
    }
}
