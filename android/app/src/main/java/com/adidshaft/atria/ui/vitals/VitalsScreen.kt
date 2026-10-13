package com.adidshaft.atria.ui.vitals

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.FitnessAge
import com.adidshaft.atria.analytics.SleepDetector
import com.adidshaft.atria.analytics.SleepStage
import com.adidshaft.atria.analytics.Vo2Max
import com.adidshaft.atria.analytics.formatHours
import com.adidshaft.atria.data.DailyMetricsEntity
import com.adidshaft.atria.domain.decodeStages
import com.adidshaft.atria.ui.AppViewModel
import com.adidshaft.atria.ui.components.AtriaCard
import com.adidshaft.atria.ui.components.Band
import com.adidshaft.atria.ui.components.ChartPoint
import com.adidshaft.atria.ui.components.EmptyState
import com.adidshaft.atria.ui.components.Eyebrow
import com.adidshaft.atria.ui.components.Hypnogram
import com.adidshaft.atria.ui.components.KeyValueRow
import com.adidshaft.atria.ui.components.SectionTitle
import com.adidshaft.atria.ui.components.SegmentedTabs
import com.adidshaft.atria.ui.components.StatTile
import com.adidshaft.atria.ui.components.TimeSeriesChart
import com.adidshaft.atria.ui.components.stageColor
import com.adidshaft.atria.ui.sheets.MetricAboutSheet
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import com.adidshaft.atria.ui.today.clock
import java.time.LocalDate
import java.time.ZoneId

@Composable
fun VitalsScreen(vm: AppViewModel, nav: NavHostController, initialTab: Int) {
    var tab by rememberSaveable { mutableIntStateOf(initialTab) }
    SegmentedTabs(listOf("Live", "Sleep", "Trends"), tab, { tab = it })
    when (tab) {
        0 -> LiveTab(vm)
        1 -> SleepTab(vm, nav)
        else -> TrendsTab(vm)
    }
}

@Composable
private fun LiveTab(vm: AppViewModel) {
    val s = LocalSurfaces.current
    val d by vm.derived.collectAsStateWithLifecycle()
    val live by vm.live.collectAsStateWithLifecycle()
    val today by vm.todayMetrics.collectAsStateWithLifecycle()
    val days by vm.recentDays.collectAsStateWithLifecycle()
    var mode by rememberSaveable { mutableIntStateOf(1) }
    var about by remember { mutableStateOf<String?>(null) }
    SectionTitle("Live monitor")
    SegmentedTabs(listOf("Stress", "Heart rate"), mode, { mode = it })
    if (mode == 1) {
        AtriaCard {
            Row {
                listOf(
                    "Now" to (if (live.hrFresh) "${live.heartRate}" else "--"),
                    "Average" to (d.avgHr6h?.toString() ?: "--"),
                    "Peak" to (d.peakHr6h?.toString() ?: "--"),
                    "Resting" to (d.restingNow?.toString() ?: "--"),
                ).forEach { (k, v) ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(k, style = MaterialTheme.typography.labelMedium, color = s.textSecondary)
                        Text(v, style = MaterialTheme.typography.headlineMedium, color = AtriaColors.calm)
                    }
                }
            }
        }
        AtriaCard {
            Row { Text("Heart-rate timeline", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f)); Text("Last 6 hr", color = s.textSecondary, style = MaterialTheme.typography.bodyMedium) }
            Spacer(Modifier.height(8.dp))
            TimeSeriesChart(d.hr6h, unit = "bpm", startMs = System.currentTimeMillis() - 6 * 3_600_000L, endMs = System.currentTimeMillis(), description = "Heart rate, last 6 hours")
        }
    } else {
        AtriaCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Stress", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                Text(d.currentStress?.let { "%.1f".format(it) } ?: "--", style = MaterialTheme.typography.headlineMedium, color = AtriaColors.stress)
            }
            Text("0–3 scale from heart rate and HRV vs your own baseline. Motion is de-weighted.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
            Spacer(Modifier.height(8.dp))
            TimeSeriesChart(
                d.stressToday, yMin = 0.0, yMax = 3.0, gapMs = 3 * 60_000L, color = AtriaColors.stress, valueFormat = { "%.1f".format(it) },
                bands = listOf(Band(0.0, 1.0, AtriaColors.calm), Band(1.0, 2.0, AtriaColors.recoveryFair), Band(2.0, 3.0, AtriaColors.heart)), description = "Stress today",
            )
        }
    }
    SectionTitle("Health Monitor") { Text("Current cycle", color = AtriaColors.hrv, style = MaterialTheme.typography.labelLarge) }
    Eyebrow("Recovery")
    val baselineDays = days.dropLast(1)
    fun range(sel: (DailyMetricsEntity) -> Double?): String? {
        val v = baselineDays.mapNotNull(sel); if (v.size < 7) return null
        val m = v.average(); val sd = kotlin.math.sqrt(v.sumOf { (it - m) * (it - m) } / v.size)
        return "usual %.0f–%.0f".format(m - sd, m + sd)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        StatTile("Recovery", today?.recovery?.let { "$it%" } ?: "--", Modifier.weight(1f), AtriaColors.recoveryColor(today?.recovery)) { about = "recovery" }
        StatTile("Resting HR", today?.restingHr?.let { "$it" } ?: "--", Modifier.weight(1f), AtriaColors.heart, caption = d.restingQualifier ?: range { it.restingHr?.toDouble() }) { about = "rhr" }
        StatTile("HRV", today?.hrv?.let { "${it.toInt()} ms" } ?: "--", Modifier.weight(1f), AtriaColors.hrv, caption = d.hrvQualifier ?: range { it.hrv }) { about = "hrv" }
    }
    Eyebrow("Body")
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        StatTile("Respiratory", today?.respiratoryRate?.let { "%.1f".format(it) } ?: "--", Modifier.weight(1f), AtriaColors.rem, caption = "breaths/min") { about = "resp" }
        StatTile("Skin signal", today?.skinTempDelta?.let { if (it > 0.15) "Higher" else if (it < -0.15) "Lower" else "Typical" } ?: "--", Modifier.weight(1f), AtriaColors.awake, caption = "vs your own nights · not a temperature") { about = "skin" }
        StatTile("Blood O₂", "Research", Modifier.weight(1f), s.textTertiary, caption = "hidden until validated") { about = "spo2" }
    }
    if (d.recoveryContributors.any { it.weight > 0 }) AtriaCard {
        Text("What moved recovery", style = MaterialTheme.typography.titleSmall)
        d.recoveryContributors.filter { it.weight > 0 }.forEach { c ->
            KeyValueRow(c.display, when (c.direction) { 1 -> "▲ helping"; -1 -> "▼ holding back"; else -> "· neutral" }, valueColor = when (c.direction) { 1 -> AtriaColors.calm; -1 -> AtriaColors.heart; else -> s.textSecondary })
        }
    }
    com.adidshaft.atria.ui.extras.RhythmCheckCard()
    about?.let { MetricAboutSheet(it) { about = null } }
}

@Composable
private fun SleepTab(vm: AppViewModel, nav: NavHostController) {
    val s = LocalSurfaces.current
    val sleeps by vm.sleeps.collectAsStateWithLifecycle()
    val today by vm.todayMetrics.collectAsStateWithLifecycle()
    val d by vm.derived.collectAsStateWithLifecycle()
    val main = sleeps.firstOrNull { !it.isNap && it.status == "confirmed" }
    SectionTitle("Last sleep")
    if (main == null) {
        AtriaCard { EmptyState("No sleep yet", "Wear the strap overnight. Atria detects sleep from a still wrist and a low heart rate, then asks you to confirm.") }
    } else {
        AtriaCard(onClick = { nav.navigate("sleep/${main.id}") }) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(formatHours(main.asleepMs / 3_600_000.0), style = MaterialTheme.typography.displayMedium, color = AtriaColors.sleep)
                Spacer(Modifier.width(10.dp))
                Text("${clock(main.startMs)} – ${clock(main.endMs)}", color = s.textSecondary, modifier = Modifier.padding(bottom = 10.dp))
            }
            today?.sleepPerformance?.let { KeyValueRow("Sleep performance", "$it%") }
            today?.sleepNeedHours?.let { KeyValueRow("Tonight's need", formatHours(it)) }
            main.efficiency?.let { KeyValueRow("Efficiency", "${(it * 100).toInt()}%") }
            main.restingHr?.let { KeyValueRow("Sleeping resting HR", "$it bpm") }
            main.rmssd?.let { KeyValueRow("Overnight HRV", "${it.toInt()} ms") }
            main.respiratoryRate?.let { KeyValueRow("Respiratory rate", "%.1f /min".format(it)) }
            KeyValueRow("Wake-ups", "${main.disturbances}")
            val stages = decodeStages(main.stagesJson)
            if (stages.isNotEmpty()) {
                Spacer(Modifier.height(10.dp))
                Eyebrow(if (main.motionValidated) "Stages · estimate" else "Stages · HR-only estimate")
                Spacer(Modifier.height(6.dp))
                Hypnogram(stages, main.startMs, main.endMs)
                val mins = SleepDetector.stageMinutes(stages)
                Row { SleepStage.entries.forEach { st -> Text("● ${st.label} ${mins[st]?.let { "${it / 60}h ${it % 60}m" }}", color = stageColor(st), style = MaterialTheme.typography.labelMedium, modifier = Modifier.weight(1f)) } }
            }
        }
    }
    com.adidshaft.atria.ui.extras.SleepPlannerCard(vm)
    d.consistency?.let { c ->
        AtriaCard {
            Text("Sleep consistency", style = MaterialTheme.typography.titleSmall)
            Text("${c.percent}%", style = MaterialTheme.typography.headlineLarge, color = AtriaColors.sleep)
            Text("Usual bedtime ${"%d:%02d".format(c.typicalBedMinute / 60, c.typicalBedMinute % 60)} · wake ${"%d:%02d".format(c.typicalWakeMinute / 60, c.typicalWakeMinute % 60)} · ${c.withinHour}/${c.nights} nights within an hour", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        }
    }
    SectionTitle("History")
    sleeps.filter { it.status == "confirmed" }.take(20).forEach { sl ->
        AtriaCard(onClick = { nav.navigate("sleep/${sl.id}") }, padding = 14.dp) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(java.time.Instant.ofEpochMilli(sl.endMs).atZone(ZoneId.systemDefault()).toLocalDate().let { if (it == LocalDate.now()) "Today" else it.toString() } + if (sl.isNap) " · Nap" else "", style = MaterialTheme.typography.titleSmall)
                    Text("${clock(sl.startMs)} – ${clock(sl.endMs)}${if (sl.source == "manual") " · logged" else ""}", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
                }
                Text(formatHours(sl.asleepMs / 3_600_000.0), style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold), color = AtriaColors.sleep)
            }
        }
    }
}

@Composable
private fun TrendsTab(vm: AppViewModel) {
    val s = LocalSurfaces.current
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val d by vm.derived.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    fun series(sel: (DailyMetricsEntity) -> Double?) = days.mapNotNull { day -> sel(day)?.let { ChartPoint(LocalDate.ofEpochDay(day.epochDay).atTime(12, 0).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli(), it) } }
    val start = LocalDate.now().minusDays(29).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
    val end = System.currentTimeMillis()
    var expanded by remember { mutableStateOf<Triple<String, Color, Pair<(DailyMetricsEntity) -> Double?, (Double) -> String>>?>(null) }
    @Composable
    fun trend(title: String, color: Color, sel: (DailyMetricsEntity) -> Double?, fmt: (Double) -> String = { "%.0f".format(it) }, unit: String = "") {
        AtriaCard(onClick = { expanded = Triple(title, color, sel to { v: Double -> fmt(v) + unit }) }) {
            val pts = series(sel)
            Row { Text(title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f)); pts.lastOrNull()?.let { Text(fmt(it.v) + unit, color = color, style = MaterialTheme.typography.titleSmall) } }
            Spacer(Modifier.height(6.dp))
            TimeSeriesChart(pts, height = 140.dp, color = color, gapMs = 2 * 86_400_000L, startMs = start, endMs = end, valueFormat = fmt, unit = unit, description = "$title, 30 days")
        }
    }
    SectionTitle("30-day trends")
    trend("Recovery", AtriaColors.recovery, { it.recovery?.toDouble() }, unit = "%")
    trend("HRV", AtriaColors.hrv, { it.hrv }, unit = " ms")
    trend("Resting HR", AtriaColors.heart, { it.restingHr?.toDouble() }, unit = " bpm")
    trend("Sleep", AtriaColors.sleep, { it.sleepHours }, { "%.1f".format(it) }, " h")
    trend("Strain", AtriaColors.strain, { it.strain }, { "%.1f".format(it) })
    trend("Steps", AtriaColors.steps, { it.steps?.toDouble() })
    d.training?.let { t ->
        AtriaCard {
            Text("Training load", style = MaterialTheme.typography.titleSmall)
            Text(t.readiness.replaceFirstChar { it.uppercase() }, style = MaterialTheme.typography.headlineMedium, color = AtriaColors.strain)
            Text(t.detail, style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
            KeyValueRow("7-day load", "%.1f".format(t.acute))
            KeyValueRow("28-day base", "%.1f".format(t.chronic))
            t.ratio?.let { KeyValueRow("Acute : chronic", "%.2f".format(it)) }
            t.monotony?.let { KeyValueRow("Monotony", "%.2f".format(it)) }
        }
    }
    com.adidshaft.atria.ui.extras.ReportsCard(vm)
    com.adidshaft.atria.ui.extras.StrengthProgressCard(vm)
    com.adidshaft.atria.ui.extras.FaceOffShareCard(vm)
    val profile = settings.profile.toAthlete()
    val lastRhr = days.lastOrNull { it.restingHr != null }?.restingHr
    val fitness = FitnessAge.summary(profile, lastRhr, days.lastOrNull { it.hrv != null }?.hrv?.toInt(), days.lastOrNull { it.sleepHours != null }?.sleepHours, 0.9, d.consistency?.percent, d.training?.chronic)
    AtriaCard {
        Text("Fitness", style = MaterialTheme.typography.titleSmall)
        lastRhr?.let { Vo2Max.estimate(it, profile.estimatedMaxHr) }?.let { KeyValueRow("VO₂max estimate", "%.1f ml/kg/min".format(it)) }
        KeyValueRow("Max HR", "${profile.estimatedMaxHr} bpm${if (settings.profile.learnedMaxHr != null) " (measured)" else " (age-based)"}")
        if (fitness != null) {
            KeyValueRow("Fitness age", "${fitness.age} (${fitness.pace})", valueColor = if (fitness.age <= fitness.chronological) AtriaColors.calm else AtriaColors.stress)
            fitness.factors.forEach { f -> KeyValueRow("· ${f.label}", "${f.ageEquivalent} y · ${f.detail}") }
        } else Text("Fitness age needs a resting-HR baseline and profile details.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
    }
    expanded?.let { (t, c, f) -> com.adidshaft.atria.ui.extras.ExpandedChartDialog(t, c, f.first, f.second) { expanded = null } }
}
