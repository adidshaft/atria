package com.adidshaft.atria.ui.breathe

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.HrvAnalyzer
import com.adidshaft.atria.ui.components.CircleButton
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.components.SegmentedTabs
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** Breathing pattern: inhale, hold, exhale, hold (seconds). */
enum class Pattern(val title: String, val phases: List<Pair<String, Int>>) {
    RESONANCE("Resonance 6/min", listOf("Breathe in" to 5, "Breathe out" to 5)),
    BOX("Box", listOf("Breathe in" to 4, "Hold" to 4, "Breathe out" to 4, "Hold" to 4)),
    RELAX("4-7-8", listOf("Breathe in" to 4, "Hold" to 7, "Breathe out" to 8)),
}

/** AtriaBreathworkSession: paced breathing with live HR and a before/after HRV read. */
@Composable
fun BreathworkScreen(onBack: () -> Unit) {
    val s = LocalSurfaces.current
    val g = AtriaApp.graph
    val live by g.strap.state.collectAsStateWithLifecycle()
    var pattern by remember { mutableIntStateOf(0) }
    var running by remember { mutableStateOf(false) }
    var phase by remember { mutableStateOf("Ready") }
    var minutes by remember { mutableIntStateOf(3) }
    var remaining by remember { mutableIntStateOf(0) }
    var strapPacing by remember { mutableStateOf(true) }
    var startHr by remember { mutableStateOf<Int?>(null) }
    var result by remember { mutableStateOf<String?>(null) }
    val scale = remember { Animatable(0.55f) }

    LaunchedEffect(running) {
        if (!running) return@LaunchedEffect
        val startedAt = System.currentTimeMillis()
        startHr = live.heartRate.takeIf { live.hrFresh }
        result = null
        remaining = minutes * 60
        val p = Pattern.entries[pattern]
        while (running && remaining > 0) {
            for ((name, secs) in p.phases) {
                if (!running) break
                phase = name
                if (strapPacing && name == "Breathe in") g.strap.haptic(1)
                val target = when (name) { "Breathe in" -> 1f; "Breathe out" -> 0.55f; else -> scale.value }
                scale.animateTo(target, tween(secs * 1000, easing = LinearEasing))
                remaining = (minutes * 60 - ((System.currentTimeMillis() - startedAt) / 1000).toInt()).coerceAtLeast(0)
                if (remaining == 0) break
            }
        }
        if (running) {
            running = false
            phase = "Done"
            val end = System.currentTimeMillis()
            val rmssd = withContext(Dispatchers.IO) { HrvAnalyzer.analyze(g.repo.rr(end - 300_000, end), end)?.takeIf { it.kept > 60 }?.rmssd }
            result = buildString {
                startHr?.let { s0 -> if (live.hrFresh) append("Heart rate $s0 → ${live.heartRate} bpm. ") }
                rmssd?.let { append("Session HRV ${it.toInt()} ms.") }
            }.ifBlank { "Session complete." }
            withContext(Dispatchers.IO) {
                g.repo.db.workouts().insert(com.adidshaft.atria.data.WorkoutEntity(activity = "Breathwork", startMs = startedAt, endMs = end, strain = 0.0, avgHr = live.heartRate, maxHr = live.heartRate, calories = null, steps = null, zonesJson = null, status = "confirmed", source = "manual"))
            }
        }
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            CircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", size = 46.dp) { running = false; onBack() }
            Spacer(Modifier.width(12.dp))
            Text("Breathwork", style = MaterialTheme.typography.titleLarge)
        }
        SegmentedTabs(Pattern.entries.map { it.title }, pattern, { if (!running) pattern = it })
        Box(Modifier.size(300.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(300.dp)) {
                drawCircle(Brush.radialGradient(listOf(AtriaColors.hrv.copy(alpha = 0.7f), AtriaColors.sleep.copy(alpha = 0.2f))), radius = size.minDimension / 2 * scale.value)
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(phase, style = MaterialTheme.typography.headlineMedium)
                if (running) Text("%d:%02d".format(remaining / 60, remaining % 60), color = s.textSecondary)
            }
        }
        Text(if (live.hrFresh) "♥ ${live.heartRate} bpm" else "Heart rate unavailable", color = AtriaColors.heart, style = MaterialTheme.typography.titleMedium)
        result?.let { Text(it, color = s.textSecondary) }
        if (!running) {
            SegmentedTabs(listOf("1 min", "3 min", "5 min", "10 min"), listOf(1, 3, 5, 10).indexOf(minutes), { minutes = listOf(1, 3, 5, 10)[it] })
            Row(verticalAlignment = Alignment.CenterVertically) { Text("Pace with strap buzz", Modifier.weight(1f)); Switch(strapPacing, { strapPacing = it }) }
        }
        Spacer(Modifier.weight(1f))
        PillButton(if (running) "Stop" else "Start", Modifier.fillMaxWidth(), color = if (running) AtriaColors.danger else AtriaColors.hrv, height = 60.dp) { running = !running; if (!running) phase = "Ready" }
    }
}
