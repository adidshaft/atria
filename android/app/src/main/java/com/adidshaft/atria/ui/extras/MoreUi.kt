package com.adidshaft.atria.ui.extras

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.BehaviorImpact
import com.adidshaft.atria.analytics.formatHours
import com.adidshaft.atria.data.DailyMetricsEntity
import com.adidshaft.atria.data.JournalEntity
import com.adidshaft.atria.data.SleepEntity
import com.adidshaft.atria.ui.components.AtriaCard
import com.adidshaft.atria.ui.components.ChartPoint
import com.adidshaft.atria.ui.components.Eyebrow
import com.adidshaft.atria.ui.components.KeyValueRow
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.components.SegmentedTabs
import com.adidshaft.atria.ui.components.TimeSeriesChart
import com.adidshaft.atria.ui.journal.JournalTag
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import com.adidshaft.atria.ui.today.clock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.ZoneId

/** AtriaSameDayMainSleepSheet: ask once which of two same-day sleeps is the main one. */
@Composable
fun SameDayMainSleepCard() {
    val s = LocalSurfaces.current
    val g = AtriaApp.graph
    val scope = rememberCoroutineScope()
    var options by remember { mutableStateOf<List<SleepEntity>>(emptyList()) }
    var answered by remember { mutableStateOf(true) }
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(tick) {
        withContext(Dispatchers.IO) {
            val today = g.repo.today()
            options = g.engine.sameDayMainSleeps(today)
            answered = g.engine.preferredMainSleepId(today) != null
        }
    }
    if (options.size < 2 || answered) return
    AtriaCard(tint = AtriaColors.sleep) {
        Text("You slept twice today", style = MaterialTheme.typography.titleSmall)
        Text("Which was your main sleep? It drives Recovery; the other stays saved as a second sleep.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        Spacer(Modifier.height(8.dp))
        options.forEach { sl ->
            PillButton("${clock(sl.startMs)}–${clock(sl.endMs)} · ${formatHours(sl.asleepMs / 3_600_000.0)}", Modifier.fillMaxWidth().padding(vertical = 3.dp), color = s.inset, contentColor = s.textPrimary, height = 44.dp) {
                scope.launch(Dispatchers.IO) {
                    g.repo.db.journal().upsert(JournalEntity(g.repo.today().toEpochDay(), "mainsleep", sl.id.toString(), System.currentTimeMillis()))
                    g.engine.refresh(); tick++
                }
            }
        }
    }
}

/** AtriaTodayLearningsFeed: significant findings only, stacked; tap to dismiss. */
@Composable
fun LearningsFeed() {
    val s = LocalSurfaces.current
    val g = AtriaApp.graph
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val prefs = ctx.getSharedPreferences("learnings", android.content.Context.MODE_PRIVATE)
    var findings by remember { mutableStateOf<List<Pair<String, BehaviorImpact.Result>>>(emptyList()) }
    var dismissed by remember { mutableStateOf(prefs.getStringSet("dismissed", emptySet())!!.toSet()) }
    LaunchedEffect(Unit) {
        findings = withContext(Dispatchers.IO) {
            val today = g.repo.today().toEpochDay()
            val all = g.repo.db.journal().all()
            val rec = g.repo.db.daily().range(today - 120, today).associate { it.epochDay to it.recovery }
            JournalTag.entries.filter { !it.private }.mapNotNull { t ->
                val y = all.filter { it.key == t.key && it.value == "yes" }.mapNotNull { rec[it.epochDay]?.toDouble() }
                val n = all.filter { it.key == t.key && it.value == "no" }.mapNotNull { rec[it.epochDay]?.toDouble() }
                // Today deck shows only findings that survive the significance gate.
                BehaviorImpact.evaluate(y, n, t.expected, t.label)?.takeIf { it.significant }?.let { "${t.name}:${it.withN + it.withoutN}" to it }
            } + learnedPhysiology(g.repo.db.daily().range(today - 28, today))
        }
    }
    findings.filter { it.first !in dismissed }.take(3).forEach { (key, r) ->
        AtriaCard(onClick = {
            dismissed = dismissed + key
            prefs.edit().putStringSet("dismissed", dismissed).apply()
        }) {
            Eyebrow("Learning", color = AtriaColors.hrv)
            Text(r.headline, style = MaterialTheme.typography.titleSmall)
            Text("${r.withN} days with vs ${r.withoutN} without · tap to dismiss", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
        }
    }
}

/** AtriaDetectionLog: visible record of detection decisions. */
@Composable
fun DetectionsCard() {
    val s = LocalSurfaces.current
    val entries by AtriaApp.graph.repo.db.log().observe(300).collectAsState(initial = emptyList())
    val detections = entries.filter { it.tag == "detection" }.take(10)
    if (detections.isEmpty()) return
    AtriaCard {
        Text("Detections", style = MaterialTheme.typography.titleSmall)
        detections.forEach { e -> KeyValueRow(e.message, clock(e.t)) }
        Text("What Atria noticed automatically and why it saved or asked.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
    }
}

/** AtriaCompatibleHardwareScreen: review-accurate hardware disclosure. */
@Composable
fun CompatibleHardwareCard() {
    val s = LocalSurfaces.current
    AtriaCard {
        Text("Compatible hardware", style = MaterialTheme.typography.titleSmall)
        KeyValueRow("WHOOP 4.0", "Validated", valueColor = AtriaColors.calm)
        KeyValueRow("WHOOP 5.0 / MG", "Not supported")
        KeyValueRow("Standard Bluetooth HR straps", "Heart rate only, unvalidated")
        Text("Atria is independent and not affiliated with WHOOP. Blood oxygen stays hidden until validated against a reference.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
    }
}

/** AtriaExpandedChart: a metric over 7/30/90 days with saved-event markers. */
@Composable
fun ExpandedChartDialog(title: String, color: Color, select: (DailyMetricsEntity) -> Double?, fmt: (Double) -> String, onDismiss: () -> Unit) {
    val s = LocalSurfaces.current
    val g = AtriaApp.graph
    val prefs = androidx.compose.ui.platform.LocalContext.current.getSharedPreferences("expanded_chart", android.content.Context.MODE_PRIVATE)
    var range by remember { mutableIntStateOf(prefs.getInt(title, 1)) }
    LaunchedEffect(range) { prefs.edit().putInt(title, range).apply() }
    val days = listOf(7L, 30L, 90L)[range]
    var points by remember { mutableStateOf<List<ChartPoint>>(emptyList()) }
    var events by remember { mutableStateOf<List<String>>(emptyList()) }
    LaunchedEffect(range) {
        withContext(Dispatchers.IO) {
            val today = LocalDate.now()
            val rows = g.repo.db.daily().range(today.minusDays(days - 1).toEpochDay(), today.toEpochDay())
            points = rows.mapNotNull { r -> select(r)?.let { ChartPoint(LocalDate.ofEpochDay(r.epochDay).atTime(12, 0).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli(), it) } }
            val from = today.minusDays(days - 1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            events = g.repo.db.workouts().between(from, System.currentTimeMillis()).filter { it.status == "confirmed" }.takeLast(8)
                .map { "${LocalDate.ofEpochDay(it.startMs / 86_400_000)} · ${it.activity} · strain %.1f".format(it.strain) }
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onDismiss) { Text("Done") } },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SegmentedTabs(listOf("7 D", "30 D", "90 D"), range, { range = it })
                val start = LocalDate.now().minusDays(days - 1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
                TimeSeriesChart(points, height = 220.dp, color = color, gapMs = 2 * 86_400_000L, startMs = start, endMs = System.currentTimeMillis(), valueFormat = fmt, description = "$title, $days days")
                points.map { it.v }.takeIf { it.isNotEmpty() }?.let { v -> Text("Avg ${fmt(v.average())} · low ${fmt(v.min())} · high ${fmt(v.max())}", color = s.textSecondary) }
                if (events.isNotEmpty()) { Eyebrow("Workouts in range"); events.forEach { Text(it, style = MaterialTheme.typography.bodySmall, color = s.textTertiary) } }
            }
        },
    )
}

/** AtriaSleepSettlementPresentation: say what's happening while last night is still being worked out. */
@Composable
fun SleepSettlementCard(sleptHours: Double?, reviewPending: Boolean, live: com.adidshaft.atria.ble.LiveState) {
    val s = LocalSurfaces.current
    if (sleptHours != null || java.time.LocalTime.now().hour !in 4..15) return
    val (title, body) = when {
        reviewPending -> "Last night needs a quick check" to "Confirm the possible sleep below so Recovery can be calculated."
        live.drainActive -> "Working out last night" to "Syncing the strap's stored history (${live.drainRows} saved). Sleep and Recovery appear when it finishes."
        (live.pendingRecords ?: 0) > 0 -> "Last night is still on the strap" to "Keep the strap near your phone; Atria syncs its stored history in the background."
        live.status != com.adidshaft.atria.ble.LinkStatus.CONNECTED -> "Waiting for your strap" to "Atria will check last night as soon as the strap reconnects."
        else -> "No sleep found for last night" to "If you slept without the strap or it was loose, you can log sleep with +."
    }
    AtriaCard(tint = AtriaColors.sleep) {
        Text(title, style = MaterialTheme.typography.titleSmall)
        Text(body, style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
    }
}

/** Night "ups and downs" vs the wearer's own recent nights (AtriaNightBaseline). */
@Composable
fun NightBaselineCard(sleep: SleepEntity) {
    val s = LocalSurfaces.current
    var findings by remember { mutableStateOf<List<com.adidshaft.atria.analytics.NightBaseline.Finding>?>(null) }
    LaunchedEffect(sleep.id) {
        findings = withContext(Dispatchers.IO) {
            val hist = AtriaApp.graph.repo.db.sleeps().recentConfirmed(40).filter { !it.isNap && it.id != sleep.id && it.endMs < sleep.endMs }
            com.adidshaft.atria.analytics.NightBaseline.compare(listOf(
                Triple("Sleep", sleep.asleepMs / 3_600_000.0, hist.map { it.asleepMs / 3_600_000.0 }),
                Triple("Resting HR", sleep.restingHr?.toDouble(), hist.mapNotNull { it.restingHr?.toDouble() }),
                Triple("HRV", sleep.rmssd, hist.mapNotNull { it.rmssd }),
                Triple("Respiratory rate", sleep.respiratoryRate, hist.mapNotNull { it.respiratoryRate }),
                Triple("Efficiency", sleep.efficiency, hist.mapNotNull { it.efficiency }),
                Triple("Wake-ups", sleep.disturbances.toDouble(), hist.map { it.disturbances.toDouble() }),
            )) { name, v -> when (name) { "Sleep" -> formatHours(v); "HRV" -> "${v.toInt()} ms"; "Resting HR" -> "${v.toInt()} bpm"; "Efficiency" -> "${(v * 100).toInt()}%"; "Respiratory rate" -> "%.1f /min".format(v); else -> v.toInt().toString() } }
        }
    }
    val f = findings ?: return
    AtriaCard {
        Text("Compared with your nights", style = MaterialTheme.typography.titleSmall)
        if (f.isEmpty()) Text("Everything was within your usual range.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        f.forEach { KeyValueRow("${it.metric} ${it.value}", it.label, valueColor = if (it.unusual) AtriaColors.stress else s.textSecondary) }
    }
}


/**
 * AtriaLearnedInsights: findings from saved daily metrics alone (no journal needed):
 * last 7 days vs the 21 before, for HRV, resting HR and sleep. Shown only when the
 * shift is larger than the wearer's own day-to-day spread (Welch p < 0.05, ≥ 5 days each).
 */
fun learnedPhysiology(days: List<DailyMetricsEntity>): List<Pair<String, BehaviorImpact.Result>> {
    val today = LocalDate.now().toEpochDay()
    val recent = days.filter { it.epochDay > today - 7 }
    val prior = days.filter { it.epochDay <= today - 7 }
    fun test(name: String, sel: (DailyMetricsEntity) -> Double?, fmt: (Double) -> String, higherGood: Boolean): Pair<String, BehaviorImpact.Result>? {
        val a = recent.mapNotNull(sel); val b = prior.mapNotNull(sel)
        val r = BehaviorImpact.evaluate(a, b, BehaviorImpact.Expected.NEUTRAL, name) ?: return null
        if (!r.significant) return null
        val up = r.delta > 0
        val headline = "$name ${if (up) "up" else "down"} ${fmt(kotlin.math.abs(r.delta))} this week vs your previous three" + if (up == higherGood) " · good sign" else ""
        return "learned:$name:${today / 7}" to r.copy(headline = headline)
    }
    return listOfNotNull(
        test("HRV", { it.hrv }, { "%.0f ms".format(it) }, true),
        test("Resting HR", { it.restingHr?.toDouble() }, { "%.0f bpm".format(it) }, false),
        test("Sleep", { it.sleepHours }, { formatHours(it) }, true),
    )
}

/** AtriaStrainRecoveryComboChart: daily strain bars with the recovery line over 14 days. */
@Composable
fun StrainRecoveryComboCard(days: List<DailyMetricsEntity>) {
    val s = LocalSurfaces.current
    val window = (13 downTo 0).map { LocalDate.now().minusDays(it.toLong()).toEpochDay() }.map { d -> days.firstOrNull { it.epochDay == d } }
    if (window.all { it?.strain == null && it?.recovery == null }) return
    AtriaCard {
        Text("Strain & Recovery", style = MaterialTheme.typography.titleSmall)
        androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().height(150.dp)) {
            val slot = size.width / window.size
            val h = size.height
            window.forEachIndexed { i, d ->
                d?.strain?.let { st ->
                    val bh = (st / 21.0 * h).toFloat()
                    drawRoundRect(AtriaColors.strain.copy(alpha = 0.75f), androidx.compose.ui.geometry.Offset(i * slot + slot * 0.2f, h - bh), androidx.compose.ui.geometry.Size(slot * 0.6f, bh), androidx.compose.ui.geometry.CornerRadius(6f))
                }
            }
            val pts = window.mapIndexedNotNull { i, d -> d?.recovery?.let { androidx.compose.ui.geometry.Offset(i * slot + slot / 2, h - (it / 100f) * h) to AtriaColors.recoveryColor(it) } }
            pts.zipWithNext { a, b -> drawLine(s.textSecondary, a.first, b.first, 3f) }
            pts.forEach { (o, c) -> drawCircle(c, 7f, o) }
        }
        Text("Bars: strain (0–21) · dots: recovery %", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
    }
}
