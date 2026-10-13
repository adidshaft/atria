package com.adidshaft.atria.ui.today

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import com.adidshaft.atria.analytics.HrZone
import com.adidshaft.atria.analytics.Recovery
import com.adidshaft.atria.analytics.formatHours
import com.adidshaft.atria.data.SleepEntity
import com.adidshaft.atria.data.WorkoutEntity
import com.adidshaft.atria.ui.AppViewModel
import com.adidshaft.atria.ui.components.AtriaCard
import com.adidshaft.atria.ui.components.BarChart
import com.adidshaft.atria.ui.components.BarDatum
import com.adidshaft.atria.ui.components.CircleButton
import com.adidshaft.atria.ui.components.Dot
import com.adidshaft.atria.ui.components.Eyebrow
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.components.StatTile
import com.adidshaft.atria.ui.components.TimeSeriesChart
import com.adidshaft.atria.ui.components.TriRing
import com.adidshaft.atria.ui.sheets.CustomizeSheet
import com.adidshaft.atria.ui.sheets.MetricAboutSheet
import com.adidshaft.atria.ui.sheets.ShareCardSheet
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

private val timeFmt = DateTimeFormatter.ofPattern("h:mm a")
fun clock(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).format(timeFmt).lowercase()

fun ago(ms: Long): String {
    val m = (System.currentTimeMillis() - ms) / 60_000
    return when { m < 1 -> "now"; m < 60 -> "${m}m ago"; m < 1440 -> "${m / 60}h ago"; else -> "${m / 1440}d ago" }
}

@Composable
fun TodayScreen(vm: AppViewModel, nav: NavHostController) {
    val s = LocalSurfaces.current
    val today by vm.todayMetrics.collectAsStateWithLifecycle()
    val d by vm.derived.collectAsStateWithLifecycle()
    val live by vm.live.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    val candidates by vm.sleepCandidates.collectAsStateWithLifecycle()
    val reviews by vm.workoutReviews.collectAsStateWithLifecycle()
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val sleeps by vm.sleeps.collectAsStateWithLifecycle()
    var about by remember { mutableStateOf<String?>(null) }
    var share by remember { mutableStateOf(false) }
    var customize by remember { mutableStateOf(false) }

    val hour = LocalTime.now().hour
    val greeting = when (hour) { in 5..11 -> "Good morning"; in 12..16 -> "Good afternoon"; else -> "Good evening" }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("$greeting${settings.profile.name.takeIf { it.isNotBlank() }?.let { ", $it" } ?: ""}", style = MaterialTheme.typography.bodyLarge, color = s.textSecondary, modifier = Modifier.weight(1f))
        CircleButton(Icons.Filled.Share, "Share today", size = 46.dp) { share = true }
        Spacer(Modifier.width(8.dp))
        CircleButton(Icons.Filled.Tune, "Customize Today", size = 46.dp) { customize = true }
    }
    if (settings.demoMode) {
        AtriaCard(tint = AtriaColors.stress) { Text("Sample data", style = MaterialTheme.typography.titleSmall); Text("You're exploring Atria with sample data. Pair a strap to see your own.", color = s.textSecondary, style = MaterialTheme.typography.bodySmall) }
    }

    val rec = today?.recovery
    val prev = days.dropLast(1).lastOrNull()?.recovery
    val trend = when { rec == null || prev == null -> null; rec - prev >= 5 -> "Up vs yesterday"; prev - rec >= 5 -> "Down vs yesterday"; else -> "Flat vs yesterday" }
    com.adidshaft.atria.ui.extras.SleepSettlementCard(today?.sleepHours, candidates.isNotEmpty(), live)
    for (card in settings.todayCards) when (card) {
        "rings" -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            TriRing(
                recovery = rec,
                strainFraction = ((today?.strain ?: 0.0) / d.strainTarget).toFloat(),
                sleepFraction = ((today?.sleepHours ?: 0.0) / (today?.sleepNeedHours ?: 8.0)).toFloat(),
                centerValue = rec?.let { "$it%" } ?: "--",
                centerLabel = "Recovery",
                centerCaption = listOfNotNull(Recovery.band(rec), trend).joinToString("\n"),
            )
        }
        "trio" -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            StatTile("Sleep", today?.sleepHours?.let { formatHours(it) } ?: "--", Modifier.weight(1f), AtriaColors.sleep, caption = today?.sleepNeedHours?.let { "of ${formatHours(it)} need" }, icon = Icons.Filled.Bedtime) { about = "sleep" }
            StatTile("Recovery", rec?.let { "$it%" } ?: "--", Modifier.weight(1f), AtriaColors.recoveryColor(rec), caption = today?.recoveryConfidence ?: "prev. sleep", icon = Icons.Filled.Favorite) { about = "recovery" }
            StatTile("Strain", "%.1f".format(today?.strain ?: 0.0), Modifier.weight(1f), AtriaColors.strain, caption = "of %.1f".format(d.strainTarget), icon = Icons.Filled.LocalFireDepartment) { about = "strain" }
        }
        "live" -> {
            com.adidshaft.atria.ui.extras.SameDayMainSleepCard()
            com.adidshaft.atria.ui.extras.LearningsFeed()
            candidates.firstOrNull()?.let { SleepReviewCard(it, vm) }
            reviews.firstOrNull()?.let { WorkoutReviewCard(it, vm) }
            if (candidates.isEmpty()) sleeps.firstOrNull { it.status == "confirmed" }?.let { last ->
                AtriaCard(tint = AtriaColors.sleep, onClick = { nav.navigate("sleep/${last.id}") }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Dot(AtriaColors.calm); Spacer(Modifier.width(10.dp))
                        Text(if (last.isNap) "Nap saved" else "Sleep window saved", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                        Text(ago(last.endMs), color = s.textSecondary, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                StatTile("Live", if (live.hrFresh) "${live.heartRate} bpm" else "-- bpm", Modifier.weight(1f), if (live.hrFresh) s.textPrimary else s.textTertiary, icon = Icons.Filled.Favorite) { nav.navigate("vitals") }
                val zone = if (live.hrFresh) HrZone.of(live.heartRate, settings.profile.toAthlete().estimatedMaxHr, d.restingNow) else null
                StatTile("Zone", zone?.let { "Z${it.ordinal}" } ?: "--", Modifier.weight(1f), zone?.let { AtriaColors.zones[it.ordinal] } ?: s.textTertiary, caption = zone?.label, icon = Icons.Filled.MonitorHeart)
            }
        }
        "brief" -> DailyBrief(rec, today?.strain ?: 0.0, d.strainTarget, d.training?.readiness, nav)
        "steps" -> AtriaCard(onClick = { about = "steps" }) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.material3.Icon(Icons.AutoMirrored.Filled.DirectionsWalk, null, tint = AtriaColors.steps)
                Spacer(Modifier.width(8.dp))
                Text("Steps", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                Text("${today?.steps ?: 0} / ${settings.profile.stepGoal}", style = MaterialTheme.typography.titleSmall, color = AtriaColors.steps)
            }
            Spacer(Modifier.height(8.dp))
            val week = (6 downTo 0).map { i -> val day = LocalDate.now().minusDays(i.toLong()); BarDatum(day.dayOfWeek.name.take(1), days.firstOrNull { it.epochDay == day.toEpochDay() }?.steps?.toDouble()) }
            BarChart(week, AtriaColors.steps, target = settings.profile.stepGoal.toDouble(), height = 120.dp, description = "Steps this week")
            Text(if (live.imuLive) "Counting from the strap's motion sensor" else "Steps update when the strap motion stream is live", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
        }
        "stress" -> AtriaCard(onClick = { nav.navigate("vitals") }) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Stress", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                val st = d.currentStress
                Text(st?.let { "%.1f · %s".format(it, if (it < 1) "Calm" else if (it < 2) "Moderate" else "High") } ?: "Calculating", color = st?.let { if (it < 1) AtriaColors.calm else if (it < 2) AtriaColors.recoveryFair else AtriaColors.stress } ?: s.textTertiary, style = MaterialTheme.typography.titleSmall)
            }
            Spacer(Modifier.height(8.dp))
            TimeSeriesChart(d.stressToday, height = 120.dp, color = AtriaColors.stress, yMin = 0.0, yMax = 3.0, gapMs = 3 * 60_000L, valueFormat = { "%.1f".format(it) }, description = "Stress today")
        }
        "sleep" -> AtriaCard(onClick = { nav.navigate("vitals?tab=1") }) {
            Text("Sleep this week", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(8.dp))
            val week = (6 downTo 0).map { i -> val day = LocalDate.now().minusDays(i.toLong()); BarDatum(day.dayOfWeek.name.take(1), days.firstOrNull { it.epochDay == day.toEpochDay() }?.sleepHours) }
            BarChart(week, AtriaColors.sleep, target = today?.sleepNeedHours, height = 120.dp, valueFormat = { "%.1f".format(it) }, description = "Sleep hours this week")
            d.consistency?.let { Text("Consistency ${it.percent}% · usual bedtime ${"%d:%02d".format(it.typicalBedMinute / 60, it.typicalBedMinute % 60)}", style = MaterialTheme.typography.bodySmall, color = s.textSecondary) }
        }
        "journal" -> AtriaCard(onClick = { nav.navigate("assistant") }) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.material3.Icon(Icons.Filled.AutoAwesome, null, tint = AtriaColors.hrv)
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text("Ask your coach", style = MaterialTheme.typography.titleSmall)
                    Text("Answers from your own data, computed on this phone", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
                }
            }
        }
    }
    about?.let { MetricAboutSheet(it) { about = null } }
    if (share) ShareCardSheet(today, onDismiss = { share = false })
    if (customize) CustomizeSheet(settings.todayCards, onDismiss = { customize = false }) { cards -> vm.updateSettings { it.copy(todayCards = cards) } }
}

@Composable
private fun DailyBrief(recovery: Int?, strain: Double, target: Double, readiness: String?, nav: NavHostController) {
    val s = LocalSurfaces.current
    val headline = when { recovery == null -> "Getting to know you"; recovery >= 67 -> "Room to push"; recovery >= 34 -> "Build gently"; else -> "Take it easy" }
    AtriaCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            androidx.compose.material3.Icon(Icons.Filled.WbSunny, null, tint = s.textSecondary)
            Spacer(Modifier.width(8.dp))
            Text("Daily brief", style = MaterialTheme.typography.titleSmall, color = s.textSecondary, modifier = Modifier.weight(1f))
            Text("Target %.1f · %.1f to go".format(target, (target - strain).coerceAtLeast(0.0)), color = AtriaColors.recovery, style = MaterialTheme.typography.labelLarge)
        }
        Spacer(Modifier.height(10.dp))
        Text(headline, style = MaterialTheme.typography.headlineMedium)
        Text(
            when {
                recovery == null -> "Wear the strap tonight. Recovery needs one measured sleep."
                recovery >= 67 -> "You can add strain toward today's adjusted target. Load is aligned with your base."
                recovery >= 34 -> "A moderate session fits today. Keep intensity steady."
                else -> "Prioritise rest, mobility and an early night."
            } + (readiness?.takeIf { it != "learning" }?.let { " Training: $it." } ?: ""),
            style = MaterialTheme.typography.bodyMedium, color = s.textSecondary,
        )
        Spacer(Modifier.height(12.dp))
        PillButton("Journal check-in", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 48.dp) { nav.navigate("journal") }
    }
}

@Composable
fun SleepReviewCard(c: SleepEntity, vm: AppViewModel) {
    val s = LocalSurfaces.current
    AtriaCard(tint = AtriaColors.sleep) {
        Eyebrow(if (c.isNap) "Possible nap" else "Possible sleep", color = AtriaColors.sleep)
        Spacer(Modifier.height(4.dp))
        Text("${formatHours(c.asleepMs / 3_600_000.0)} · ${clock(c.startMs)}–${clock(c.endMs)}", style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold))
        Text(if (c.motionValidated) "Low heart rate and a still wrist" else "Low heart rate · motion not confirmed", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton("Keep", Modifier.weight(1f), color = AtriaColors.sleep, height = 46.dp) { vm.confirmSleep(c.id, true) }
            PillButton("Not sleep", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 46.dp) { vm.confirmSleep(c.id, false) }
        }
    }
}

@Composable
fun WorkoutReviewCard(w: WorkoutEntity, vm: AppViewModel) {
    val s = LocalSurfaces.current
    AtriaCard(tint = AtriaColors.strain) {
        Eyebrow(if (w.source == com.adidshaft.atria.data.Source.MOTION) "Was this a walk?" else "Possible workout", color = AtriaColors.strain)
        Spacer(Modifier.height(4.dp))
        Text("${(w.endMs - w.startMs) / 60_000} min · ${clock(w.startMs)} · strain %.1f".format(w.strain), style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold))
        Text("Avg ${w.avgHr} bpm · max ${w.maxHr} bpm${w.steps?.let { " · $it steps" } ?: ""}", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton("Save as ${w.activity}", Modifier.weight(1f), color = AtriaColors.strain, height = 46.dp) { vm.reviewWorkout(w.id, true) }
            PillButton(if (w.source == com.adidshaft.atria.data.Source.MOTION) "Not a walk" else "Dismiss", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 46.dp) { vm.reviewWorkout(w.id, false) }
        }
    }
}
