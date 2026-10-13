package com.adidshaft.atria.ui.extras

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.CycleTracking
import com.adidshaft.atria.analytics.FaceOff
import com.adidshaft.atria.analytics.IrregularRhythm
import com.adidshaft.atria.analytics.Reports
import com.adidshaft.atria.analytics.SleepPlanner
import com.adidshaft.atria.analytics.StrengthProgress
import com.adidshaft.atria.analytics.formatHours
import com.adidshaft.atria.data.JournalEntity
import com.adidshaft.atria.domain.WorkoutRuntime
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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.DateTimeFormatter

private fun hm(minute: Int) = "%d:%02d".format(minute / 60, minute % 60)

/** Cycle tracking card (Journal). Periods are stored privately as journal rows `cycle.period`. */
@Composable
fun CycleCard() {
    val s = LocalSurfaces.current
    val g = AtriaApp.graph
    val scope = rememberCoroutineScope()
    var periods by remember { mutableStateOf<List<CycleTracking.Period>>(emptyList()) }
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(tick) {
        periods = withContext(Dispatchers.IO) { g.repo.db.journal().all().filter { it.key == "cycle.period" }.map { CycleTracking.Period(it.epochDay, it.value.toLongOrNull()) } }
    }
    val today = LocalDate.now().toEpochDay()
    val est = CycleTracking.estimate(periods, today)
    val ongoing = periods.maxByOrNull { it.startDay }?.let { it.endDay == null } == true
    AtriaCard(tint = AtriaColors.heart) {
        Text("Cycle", style = MaterialTheme.typography.titleSmall)
        if (est == null) Text("Log the first day of your period to start a calendar estimate.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        else {
            Text("Day ${est.cycleDay} · ${est.phase.title}${if (!est.personalized) " (calendar estimate)" else ""}", style = MaterialTheme.typography.titleMedium, color = AtriaColors.heart)
            Text(est.phase.note, style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
            KeyValueRow("Next period (estimate)", LocalDate.ofEpochDay(est.nextStartDay).format(DateTimeFormatter.ofPattern("MMM d")))
        }
        Spacer(Modifier.height(8.dp))
        PillButton(if (ongoing) "Period ended today" else "Period started today", Modifier.fillMaxWidth(), color = AtriaColors.heart, height = 44.dp) {
            scope.launch(Dispatchers.IO) {
                val dao = g.repo.db.journal()
                val last = periods.maxByOrNull { it.startDay }
                if (ongoing && last != null) dao.upsert(JournalEntity(last.startDay, "cycle.period", maxOf(today, last.startDay).toString(), System.currentTimeMillis()))
                else {
                    if (last != null && last.endDay == null) dao.upsert(JournalEntity(last.startDay, "cycle.period", last.startDay.toString(), System.currentTimeMillis()))
                    dao.upsert(JournalEntity(today, "cycle.period", "", System.currentTimeMillis()))
                }
                tick++
            }
        }
        Text("Stays on this phone. Phases are estimates, not contraception or medical advice.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
    }
}

/** Irregular-rhythm education card with the fail-closed pulse-timing check (Vitals). */
@Composable
fun RhythmCheckCard() {
    val s = LocalSurfaces.current
    var result by remember { mutableStateOf<IrregularRhythm.Result?>(null) }
    val scope = rememberCoroutineScope()
    fun run() = scope.launch {
        val now = System.currentTimeMillis()
        result = withContext(Dispatchers.IO) { IrregularRhythm.evaluate(AtriaApp.graph.repo.rr(now - 300_000, now), now) }
    }
    AtriaCard {
        Text("Rhythm check", style = MaterialTheme.typography.titleSmall)
        Text(IrregularRhythm.CANNOT_DIAGNOSE, style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        result?.let { r ->
            Spacer(Modifier.height(6.dp))
            Text(
                if (r.outcome == IrregularRhythm.Outcome.SIGNS) "Irregular signs in the last 5 minutes · not a diagnosis. If you have symptoms or this repeats, talk to a doctor."
                else "No result: ${when (r.reason) { "beats", "window", "gap" -> "needs 5 minutes of steady, still beat-to-beat data"; "rate" -> "heart rate outside the resting range"; "noise" -> "signal too noisy"; else -> "no irregular pattern flagged" }}.",
                style = MaterialTheme.typography.bodyMedium, color = if (r.outcome == IrregularRhythm.Outcome.SIGNS) AtriaColors.stress else s.textPrimary,
            )
        }
        Spacer(Modifier.height(8.dp))
        PillButton("Check last 5 minutes", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 44.dp) { run() }
    }
}

/** Sleep planner: in-bed-by for a goal, from tonight's need and the wake alarm time. */
@Composable
fun SleepPlannerCard(vm: AppViewModel) {
    val s = LocalSurfaces.current
    val today by vm.todayMetrics.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    val sleeps by vm.sleeps.collectAsStateWithLifecycle()
    var goal by remember { mutableIntStateOf(0) }
    val need = today?.sleepNeedHours ?: settings.profile.sleepGoalHours
    val wake = settings.wakeAlarm.hour * 60 + settings.wakeAlarm.minute
    val plan = SleepPlanner.plan(need, SleepPlanner.Goal.entries[goal], wake, sleeps.filter { !it.isNap && it.status == "confirmed" }.mapNotNull { it.efficiency })
    AtriaCard {
        Text("Sleep planner", style = MaterialTheme.typography.titleSmall)
        SegmentedTabs(SleepPlanner.Goal.entries.map { it.title }, goal, { goal = it }, Modifier.padding(top = 8.dp))
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text("In bed by ${hm(plan.inBedByMinute)}", style = MaterialTheme.typography.headlineMedium, color = AtriaColors.sleep)
        }
        Text("${formatHours(plan.targetSleepHours)} of sleep to wake at ${hm(wake)} · assumes ${(plan.efficiency * 100).toInt()}% efficiency${if (plan.efficiencyIsDefault) " (default)" else ""}", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
    }
}

/** Weekly & monthly report (week vs previous week; month to date). */
@Composable
fun ReportsCard(vm: AppViewModel) {
    val s = LocalSurfaces.current
    val days by vm.recentDays.collectAsStateWithLifecycle()
    var tab by remember { mutableIntStateOf(0) }
    val today = LocalDate.now().toEpochDay()
    fun rows(from: Long, to: Long) = days.filter { it.epochDay in from..to }.map { Reports.Row(it.epochDay, it.recovery, it.strain, it.sleepHours, it.hrv, it.restingHr, it.steps) }
    val (cur, prev) = if (tab == 0) Reports.summarize(rows(today - 6, today)) to Reports.summarize(rows(today - 13, today - 7))
    else { val first = LocalDate.now().withDayOfMonth(1).toEpochDay(); Reports.summarize(rows(first, today)) to Reports.summarize(rows(first - 30, first - 1)) }
    AtriaCard {
        Text("Reports", style = MaterialTheme.typography.titleSmall)
        SegmentedTabs(listOf("This week", "This month"), tab, { tab = it }, Modifier.padding(top = 8.dp))
        @Composable
        fun row(label: String, a: Double?, b: Double?, fmt: (Double) -> String, higherBetter: Boolean = true) {
            val delta = if (a != null && b != null) a - b else null
            KeyValueRow(label, (a?.let(fmt) ?: "--") + (delta?.let { " (${if (it >= 0) "+" else ""}${fmt(it)})" } ?: ""),
                valueColor = when { delta == null || kotlin.math.abs(delta) < 1e-6 -> s.textPrimary; (delta > 0) == higherBetter -> AtriaColors.calm; else -> AtriaColors.stress })
        }
        row("Avg recovery", cur.recovery, prev.recovery, { "%.0f%%".format(it) })
        row("Avg sleep", cur.sleep, prev.sleep, { (if (it < 0) "−" else "") + formatHours(kotlin.math.abs(it)) })
        row("Avg strain", cur.strain, prev.strain, { "%.1f".format(it) })
        row("Avg HRV", cur.hrv, prev.hrv, { "%.0f ms".format(it) })
        row("Avg resting HR", cur.rhr, prev.rhr, { "%.0f".format(it) }, higherBetter = false)
        row("Avg steps", cur.steps, prev.steps, { "%.0f".format(it) })
        Text("${cur.days} days with data · compared with the previous period", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
    }
}

/** Recovery Face-Off: share a link (no server) a friend opens in Atria on iOS or Android. */
@Composable
fun FaceOffShareCard(vm: AppViewModel) {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    AtriaCard {
        Text("Recovery Face-Off", style = MaterialTheme.typography.titleSmall)
        Text("Send your last 7 days of recovery, strain and sleep to a friend as a link. No account or server; the numbers live in the link.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        Spacer(Modifier.height(8.dp))
        PillButton("Challenge a friend", Modifier.fillMaxWidth(), color = AtriaColors.recovery, height = 44.dp) {
            val p = FaceOff.makePayload(settings.profile.name, days.map { FaceOff.DayRow(it.epochDay, it.recovery, it.strain, it.sleepHours, it.restingHr) }) ?: return@PillButton
            ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "My week on Atria — compare yours: ${FaceOff.url(p)}"), "Share"))
        }
    }
}

@Composable
fun FaceOffScreen(vm: AppViewModel, encoded: String, onBack: () -> Unit) {
    val s = LocalSurfaces.current
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    val friend = remember(encoded) { FaceOff.decode(encoded) }
    val mine = FaceOff.makePayload(settings.profile.name.ifBlank { "You" }, days.map { FaceOff.DayRow(it.epochDay, it.recovery, it.strain, it.sleepHours, it.restingHr) })
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.statusBarsPadding(), verticalAlignment = Alignment.CenterVertically) {
                CircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", size = 46.dp, onClick = onBack)
                Spacer(Modifier.width(12.dp))
                Text("Face-Off", style = MaterialTheme.typography.titleLarge)
            }
        }
        item {
            if (friend == null) AtriaCard { Text("This link couldn't be read.", color = s.textSecondary) }
            else AtriaCard {
                Row { Text("", Modifier.weight(1f)); Text(mine?.name ?: "You", Modifier.weight(1f), color = AtriaColors.strain); Text(friend.name, Modifier.weight(1f), color = AtriaColors.recovery) }
                @Composable fun cmp(label: String, a: String, b: String) = Row(Modifier.fillMaxWidth().then(Modifier)) {
                    Text(label, Modifier.weight(1f), color = s.textSecondary); Text(a, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall); Text(b, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                }
                cmp("Recovery", mine?.avgRecovery?.let { "$it%" } ?: "--", friend.avgRecovery?.let { "$it%" } ?: "--")
                cmp("Strain", mine?.avgStrain?.let { "%.1f".format(it) } ?: "--", friend.avgStrain?.let { "%.1f".format(it) } ?: "--")
                cmp("Sleep", mine?.avgSleep?.let { formatHours(it) } ?: "--", friend.avgSleep?.let { formatHours(it) } ?: "--")
                cmp("Resting HR", mine?.avgRestingHr?.toString() ?: "--", friend.avgRestingHr?.toString() ?: "--")
                Text("7-day averages. Just for fun — bodies differ.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
            }
        }
    }
}

/** Strength log progress: best estimated 1RM per exercise. */
@Composable
fun StrengthProgressCard(vm: AppViewModel) {
    val s = LocalSurfaces.current
    val workouts by vm.workouts.collectAsStateWithLifecycle()
    val lifts = StrengthProgress.summarize(workouts.flatMap { w -> WorkoutRuntime.decodeSets(w.setsJson).map { Triple(it.exercise, it.reps to it.weightKg, it.at) } })
    if (lifts.isEmpty()) return
    AtriaCard {
        Text("Strength progress", style = MaterialTheme.typography.titleSmall)
        lifts.take(8).forEach { l -> KeyValueRow(l.exercise, "e1RM %.0f kg${l.deltaVsFirst?.let { d -> " (%+.0f)".format(d) } ?: ""}".format(l.bestE1rm)) }
        Text("Estimated one-rep max (Epley) from logged sets.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
    }
}

/** AtriaNightInterruptionPrompt: private "what woke you?" labels for a night. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun NightInterruptionCard(sleepEndMs: Long) {
    val s = LocalSurfaces.current
    val g = AtriaApp.graph
    val day = java.time.Instant.ofEpochMilli(sleepEndMs).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toEpochDay()
    val entries by g.repo.db.journal().observeDay(day).collectAsState(initial = emptyList())
    val chosen = entries.filter { it.key.startsWith("wake.") }.map { it.key.removePrefix("wake.") }.toSet()
    val scope = rememberCoroutineScope()
    AtriaCard {
        Text("What woke you?", style = MaterialTheme.typography.titleSmall)
        Text("Private to this phone. Helps explain disturbed nights.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        Spacer(Modifier.height(8.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("Bathroom", "Noise", "Too warm", "Partner", "Pet", "Kids", "Pain", "Stress", "Alarm", "Not sure").forEach { label ->
                val on = label in chosen
                PillButton(label, height = 38.dp, color = if (on) AtriaColors.sleep else s.inset, contentColor = if (on) Color.White else s.textPrimary) {
                    scope.launch(Dispatchers.IO) { if (on) g.repo.db.journal().delete(day, "wake.$label") else g.repo.db.journal().upsert(JournalEntity(day, "wake.$label", "yes", System.currentTimeMillis())) }
                }
            }
        }
    }
}

/** AtriaRoutineCard: this week's checkmarks for sleep need, step goal and bedtime consistency. */
@Composable
fun RoutineCard(vm: AppViewModel) {
    val s = LocalSurfaces.current
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    val week = (6 downTo 0).map { LocalDate.now().minusDays(it.toLong()) }
    AtriaCard {
        Text("Routine", style = MaterialTheme.typography.titleSmall)
        Row(Modifier.fillMaxWidth()) { Text("", Modifier.weight(1.6f)); week.forEach { Text(it.dayOfWeek.name.take(1), Modifier.weight(1f), color = s.textTertiary, style = MaterialTheme.typography.labelMedium) } }
        @Composable fun line(label: String, check: (com.adidshaft.atria.data.DailyMetricsEntity?) -> Boolean?) = Row(Modifier.fillMaxWidth().then(Modifier)) {
            Text(label, Modifier.weight(1.6f), style = MaterialTheme.typography.bodySmall)
            week.forEach { d -> val v = check(days.firstOrNull { it.epochDay == d.toEpochDay() }); Text(when (v) { true -> "●"; false -> "○"; null -> "·" }, Modifier.weight(1f), color = if (v == true) AtriaColors.calm else s.textTertiary) }
        }
        line("Sleep need met") { d -> d?.sleepHours?.let { h -> h >= (d.sleepNeedHours ?: 8.0) * 0.9 } }
        line("Step goal") { d -> d?.steps?.let { it >= settings.profile.stepGoal } }
        line("Recovery ≥ 67%") { d -> d?.recovery?.let { it >= 67 } }
        Text("● met · ○ missed · · no data (never counted as a miss)", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
    }
}
