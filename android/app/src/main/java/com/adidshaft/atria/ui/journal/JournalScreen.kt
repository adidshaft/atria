package com.adidshaft.atria.ui.journal

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.BehaviorImpact
import com.adidshaft.atria.data.JournalEntity
import com.adidshaft.atria.ui.AppViewModel
import com.adidshaft.atria.ui.components.AtriaCard
import com.adidshaft.atria.ui.components.EmptyState
import com.adidshaft.atria.ui.components.Eyebrow
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.components.ProgressBar
import com.adidshaft.atria.ui.components.SectionTitle
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** BehaviorJournalEntry.Tag — labels, prompts and expected effects ported 1:1. */
enum class JournalTag(val label: String, val prompt: String, val expected: BehaviorImpact.Expected, val group: String, val private: Boolean = false) {
    sleep("Sleep", "Did you get to bed on time last night?", BehaviorImpact.Expected.SUPPORTIVE, "Sleep & recovery"),
    alcohol("Alcohol", "Any alcohol yesterday?", BehaviorImpact.Expected.DISRUPTIVE, "Substances"),
    caffeine("Caffeine", "Coffee, tea, or caffeine after mid-afternoon?", BehaviorImpact.Expected.DISRUPTIVE, "Activity & nutrition"),
    protein("Protein target", "Did you hit your protein target yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Activity & nutrition"),
    training("Training", "Did you train yesterday?", BehaviorImpact.Expected.NEUTRAL, "Activity & nutrition"),
    stress("Stress", "Was yesterday unusually stressful?", BehaviorImpact.Expected.DISRUPTIVE, "Mind & lifestyle"),
    hydration("Hydration", "Did you stay well hydrated yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Activity & nutrition"),
    lateMeal("Late meal", "Did you eat within two hours of bed?", BehaviorImpact.Expected.DISRUPTIVE, "Activity & nutrition"),
    morningLight("Morning light", "Did you get outdoor light yesterday morning?", BehaviorImpact.Expected.SUPPORTIVE, "Mind & lifestyle"),
    meditation("Meditation", "Did you meditate or do breathwork yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Mind & lifestyle"),
    nicotine("Nicotine", "Any nicotine yesterday?", BehaviorImpact.Expected.DISRUPTIVE, "Substances"),
    cannabis("Cannabis", "Any cannabis yesterday?", BehaviorImpact.Expected.DISRUPTIVE, "Substances"),
    bigMeal("Large meal", "A large or heavy meal yesterday?", BehaviorImpact.Expected.DISRUPTIVE, "Activity & nutrition"),
    addedSugar("Added sugar", "A lot of added sugar yesterday?", BehaviorImpact.Expected.DISRUPTIVE, "Activity & nutrition"),
    vegetables("Vegetables", "Plenty of vegetables yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Activity & nutrition"),
    fasted("Fasted", "Did you fast for a long stretch yesterday?", BehaviorImpact.Expected.NEUTRAL, "Activity & nutrition"),
    supplements("Supplements", "Took your supplements yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Activity & nutrition"),
    melatonin("Melatonin", "Melatonin or a sleep aid last night?", BehaviorImpact.Expected.NEUTRAL, "Sleep & recovery"),
    magnesium("Magnesium", "Magnesium before bed last night?", BehaviorImpact.Expected.SUPPORTIVE, "Sleep & recovery"),
    medication("Medication", "Took your medication yesterday?", BehaviorImpact.Expected.NEUTRAL, "Activity & nutrition"),
    sauna("Sauna", "Sauna or heat session yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Sleep & recovery"),
    coldExposure("Cold exposure", "Cold plunge or cold shower yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Sleep & recovery"),
    stretching("Stretching", "Did you stretch or do mobility yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Sleep & recovery"),
    massage("Massage", "Massage or bodywork yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Sleep & recovery"),
    soreness("Soreness", "Waking up sore today?", BehaviorImpact.Expected.DISRUPTIVE, "Sleep & recovery"),
    activeDay("Active day", "Were you active on your feet yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Activity & nutrition"),
    nap("Nap", "Did you nap yesterday?", BehaviorImpact.Expected.NEUTRAL, "Sleep & recovery"),
    screenInBed("Screen in bed", "Screens in bed last night?", BehaviorImpact.Expected.DISRUPTIVE, "Sleep & recovery"),
    readBeforeBed("Read before bed", "Did you read before bed?", BehaviorImpact.Expected.SUPPORTIVE, "Sleep & recovery"),
    sharedBed("Shared bed", "Shared your bed (partner or pet) last night?", BehaviorImpact.Expected.NEUTRAL, "Sleep & recovery"),
    warmRoom("Warm room", "Was your room too warm last night?", BehaviorImpact.Expected.DISRUPTIVE, "Sleep & recovery"),
    consistentBedtime("Consistent bedtime", "A consistent bedtime last night?", BehaviorImpact.Expected.SUPPORTIVE, "Sleep & recovery"),
    socialTime("Social time", "Meaningful social time yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Mind & lifestyle"),
    anxious("Anxious", "Feeling anxious yesterday?", BehaviorImpact.Expected.DISRUPTIVE, "Mind & lifestyle"),
    gratitude("Gratitude", "Practice gratitude or journaling yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Mind & lifestyle"),
    outdoors("Time outdoors", "Time outdoors in nature yesterday?", BehaviorImpact.Expected.SUPPORTIVE, "Mind & lifestyle"),
    travel("Travel", "Travel or a time-zone change yesterday?", BehaviorImpact.Expected.DISRUPTIVE, "Mind & lifestyle"),
    unwell("Feeling unwell", "Feeling unwell or run down today?", BehaviorImpact.Expected.DISRUPTIVE, "Mind & lifestyle"),
    sexualActivity("Sexual activity", "Sexual activity yesterday?", BehaviorImpact.Expected.NEUTRAL, "Intimacy", private = true),
    selfPleasure("Self-pleasure", "Self-pleasure yesterday?", BehaviorImpact.Expected.NEUTRAL, "Intimacy", private = true);

    val key get() = "tag.$name"
}

/** AtriaJournalTypedQuestion. */
enum class ScaleQuestion(val key: String, val title: String, val low: String, val high: String) {
    MOOD("mood.scale", "Mood", "Low", "Great"), STRESS("stress.scale", "Stress", "Calm", "Very stressed"), ENERGY("energy.scale", "Energy", "Drained", "Energised"),
    FOCUS("focus.scale", "Focus", "Scattered", "Sharp"), WINDDOWN("winddown.scale", "Wind-down", "Rushed", "Well wound down"),
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
fun JournalScreen(vm: AppViewModel) {
    val s = LocalSurfaces.current
    val g = AtriaApp.graph
    val today = g.repo.today().toEpochDay()
    val entries by g.repo.db.journal().observeDay(today).collectAsState(initial = emptyList())
    val settings by vm.settings.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var editTags by remember { mutableStateOf(false) }
    val answers = entries.associate { it.key to it.value }
    val tracked = settings.trackedTags.mapNotNull { k -> runCatching { JournalTag.valueOf(k) }.getOrNull() }

    fun record(key: String, value: String?) = scope.launch(Dispatchers.IO) {
        if (value == null) g.repo.db.journal().delete(today, key) else g.repo.db.journal().upsert(JournalEntity(today, key, value, System.currentTimeMillis()))
    }

    SectionTitle("Journal") { Text("Edit", color = AtriaColors.strain, style = MaterialTheme.typography.labelLarge, modifier = Modifier.clickable { editTags = true }.padding(8.dp)) }
    val answered = tracked.count { answers[it.key] != null } + ScaleQuestion.entries.count { answers[it.key] != null }
    val total = tracked.size + ScaleQuestion.entries.size
    AtriaCard {
        Row { Text("Morning check-in", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f)); Text("$answered of $total", color = s.textSecondary) }
        Spacer(Modifier.height(8.dp))
        ProgressBar(answered.toFloat() / maxOf(1, total), AtriaColors.recovery)
    }
    tracked.forEach { tag ->
        val a = answers[tag.key]
        AtriaCard(padding = 14.dp) {
            Text(tag.prompt, style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Choice("Yes", a == "yes", AtriaColors.recovery, Modifier.weight(1f)) { record(tag.key, if (a == "yes") null else "yes") }
                Choice("No", a == "no", s.textSecondary, Modifier.weight(1f)) { record(tag.key, if (a == "no") null else "no") }
            }
        }
    }
    Eyebrow("How do you feel?")
    ScaleQuestion.entries.forEach { q ->
        val v = answers[q.key]?.toIntOrNull()
        AtriaCard(padding = 14.dp) {
            Row { Text(q.title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f)); Text(v?.toString() ?: "–", color = AtriaColors.hrv) }
            Slider(value = (v ?: 3).toFloat(), onValueChange = { record(q.key, it.toInt().toString()) }, valueRange = 1f..5f, steps = 3)
            Row { Text(q.low, style = MaterialTheme.typography.bodySmall, color = s.textTertiary, modifier = Modifier.weight(1f)); Text(q.high, style = MaterialTheme.typography.bodySmall, color = s.textTertiary) }
        }
    }
    AtriaCard(padding = 14.dp) {
        Text("Drinks yesterday", style = MaterialTheme.typography.titleSmall)
        val n = answers["alcohol.drinks"]?.toIntOrNull() ?: 0
        Row(verticalAlignment = Alignment.CenterVertically) {
            PillButton("−", height = 40.dp, color = s.inset, contentColor = s.textPrimary) { record("alcohol.drinks", (n - 1).coerceAtLeast(0).toString()) }
            Text("$n", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(horizontal = 20.dp))
            PillButton("+", height = 40.dp, color = s.inset, contentColor = s.textPrimary) { record("alcohol.drinks", (n + 1).toString()) }
        }
    }

    if (settings.cycleTracking) com.adidshaft.atria.ui.extras.CycleCard()
    com.adidshaft.atria.ui.extras.RoutineCard(vm)
    SectionTitle("What moves your recovery")
    var insights by remember { mutableStateOf<List<Pair<JournalTag, BehaviorImpact.Result>>?>(null) }
    LaunchedEffect(entries.size) {
        insights = withContext(Dispatchers.IO) {
            val all = g.repo.db.journal().all()
            val recovery = g.repo.db.daily().range(today - 120, today).associate { it.epochDay to it.recovery }
            JournalTag.entries.filter { !it.private }.mapNotNull { tag ->
                val yes = all.filter { it.key == tag.key && it.value == "yes" }.mapNotNull { recovery[it.epochDay]?.toDouble() }
                val no = all.filter { it.key == tag.key && it.value == "no" }.mapNotNull { recovery[it.epochDay]?.toDouble() }
                BehaviorImpact.evaluate(yes, no, tag.expected, tag.label)?.let { tag to it }
            }.sortedByDescending { kotlin.math.abs(it.second.delta) }
        }
    }
    val list = insights
    if (list.isNullOrEmpty()) AtriaCard { EmptyState("Still learning", "After at least 5 days with and 5 without a habit, Atria shows how it relates to your next-morning recovery.") }
    else list.forEach { (tag, r) ->
        AtriaCard(padding = 14.dp) {
            Text(r.headline, style = MaterialTheme.typography.titleSmall, color = if (!r.significant || r.counterExpected) s.textPrimary else if (r.delta > 0) AtriaColors.calm else AtriaColors.heart)
            Text("${r.withN} days with · ${r.withoutN} without · p = ${"%.2f".format(r.pValue)}", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
        }
    }

    if (editTags) ModalBottomSheet(onDismissRequest = { editTags = false }, containerColor = s.card) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 30.dp).verticalScroll(rememberScrollState())) {
            Text("Tracked habits", style = MaterialTheme.typography.titleLarge)
            JournalTag.entries.groupBy { it.group }.forEach { (group, tags) ->
                Spacer(Modifier.height(14.dp)); Eyebrow(group); Spacer(Modifier.height(6.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    tags.forEach { t ->
                        val on = t.name in settings.trackedTags
                        Choice(t.label, on, AtriaColors.strain) {
                            vm.updateSettings { st -> st.copy(trackedTags = if (on) st.trackedTags - t.name else st.trackedTags + t.name) }
                        }
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            Text("Intimacy answers stay private: they are never shown on Today or in insights.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
        }
    }
}

@Composable
private fun Choice(label: String, selected: Boolean, color: Color, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val s = LocalSurfaces.current
    Row(
        modifier.clip(RoundedCornerShape(50)).background(if (selected) color.copy(alpha = 0.22f) else s.inset)
            .border(1.dp, if (selected) color else s.stroke, RoundedCornerShape(50)).clickable(role = Role.Checkbox, onClick = onClick).padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        if (selected) { androidx.compose.foundation.layout.Box(Modifier.size(8.dp).clip(CircleShape).background(color)); Spacer(Modifier.width(6.dp)) }
        Text(label, style = MaterialTheme.typography.labelLarge, color = if (selected) s.textPrimary else s.textSecondary)
    }
}
