package com.adidshaft.atria.ui

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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.BatteryFull
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.BluetoothDisabled
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.adidshaft.atria.ble.LinkStatus
import com.adidshaft.atria.ui.activity.ActivityScreen
import com.adidshaft.atria.ui.activity.SleepDetailScreen
import com.adidshaft.atria.ui.activity.WorkoutDetailScreen
import com.adidshaft.atria.ui.assistant.AssistantScreen
import com.adidshaft.atria.ui.breathe.BreathworkScreen
import com.adidshaft.atria.ui.journal.JournalScreen
import com.adidshaft.atria.ui.settings.SettingsScreen
import com.adidshaft.atria.ui.sheets.ManualSleepSheet
import com.adidshaft.atria.ui.strap.StrapScreen
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import com.adidshaft.atria.ui.today.TodayScreen
import com.adidshaft.atria.ui.vitals.VitalsScreen
import com.adidshaft.atria.ui.workout.LiveWorkoutScreen
import com.adidshaft.atria.ui.workout.WorkoutSetupScreen

enum class Tab(val route: String, val title: String, val icon: ImageVector) {
    TODAY("today", "Today", Icons.Filled.Home),
    VITALS("vitals", "Vitals", Icons.Filled.MonitorHeart),
    JOURNAL("journal", "Journal", Icons.Filled.EditNote),
    ACTIVITY("activity", "Activity", Icons.AutoMirrored.Filled.List),
}

/** atria:// deep-link tokens → routes (same aliases as HomeTab.deepLinkDestination). */
fun routeForLink(token: String): String = when (token) {
    "overview", "today" -> "today"
    "sleep-review", "sleep" -> "vitals?tab=1"
    "vitals" -> "vitals"
    "journal" -> "journal"
    "plan", "activity" -> "activity"
    "chat", "assistant" -> "assistant"
    "strap", "data", "collection" -> "strap"
    "workout" -> "workout"
    "breathe" -> "breathe"
    "log-sleep" -> "logsleep"
    "privacy" -> "settings"
    "developer" -> "developer"
    else -> "today"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AtriaRoot(vm: AppViewModel, pendingLink: MutableState<String?>) {
    val nav = rememberNavController()
    val s = LocalSurfaces.current
    val backStack by nav.currentBackStackEntryAsState()
    val route = backStack?.destination?.route ?: "today"
    var showQuick by remember { mutableStateOf(false) }
    var showManualSleep by remember { mutableStateOf(false) }
    val liveWorkout by vm.liveWorkout.collectAsStateWithLifecycle()

    LaunchedEffect(pendingLink.value) {
        pendingLink.value?.let { link ->
            pendingLink.value = null
            val r = if (link.startsWith("compare:")) "compare/" + android.net.Uri.encode(link.removePrefix("compare:")) else routeForLink(link)
            if (r == "logsleep") showManualSleep = true
            else if (r == "workout" && liveWorkout != null) nav.navigate("liveworkout")
            else nav.navigate(r) { launchSingleTop = true }
        }
    }

    val isTab = Tab.entries.any { route.startsWith(it.route) }
    Box(Modifier.fillMaxSize().background(s.background)) {
        NavHost(nav, startDestination = "today", modifier = Modifier.fillMaxSize()) {
            composable("today") { TabPage(vm, nav, onQuick = { showQuick = true }) { TodayScreen(vm, nav) } }
            composable("vitals?tab={tab}", arguments = listOf(navArgument("tab") { type = NavType.IntType; defaultValue = 0 })) { e ->
                TabPage(vm, nav, onQuick = { showQuick = true }) { VitalsScreen(vm, nav, e.arguments?.getInt("tab") ?: 0) }
            }
            composable("journal") { TabPage(vm, nav, onQuick = { showQuick = true }) { JournalScreen(vm) } }
            composable("activity") { TabPage(vm, nav, onQuick = { showQuick = true }) { ActivityScreen(vm, nav) } }
            composable("assistant") { AssistantScreen(onBack = { nav.popBackStack() }) }
            composable("strap") { StrapScreen(vm, onBack = { nav.popBackStack() }) }
            composable("settings") { SettingsScreen(vm, nav, onBack = { nav.popBackStack() }) }
            composable("workout") { WorkoutSetupScreen(onBack = { nav.popBackStack() }, onStarted = { nav.navigate("liveworkout") { popUpTo("workout") { inclusive = true } } }) }
            composable("liveworkout") { LiveWorkoutScreen(vm, onClose = { nav.popBackStack() }) }
            composable("compare/{d}") { e -> com.adidshaft.atria.ui.extras.FaceOffScreen(vm, e.arguments?.getString("d") ?: "", onBack = { nav.popBackStack() }) }
            composable("developer") { com.adidshaft.atria.ui.developer.DeveloperScreen(vm, onBack = { nav.popBackStack() }) }
            composable("breathe") { BreathworkScreen(onBack = { nav.popBackStack() }) }
            composable("sleep/{id}", arguments = listOf(navArgument("id") { type = NavType.LongType })) { e -> SleepDetailScreen(vm, e.arguments!!.getLong("id"), onBack = { nav.popBackStack() }) }
            composable("workoutdetail/{id}", arguments = listOf(navArgument("id") { type = NavType.LongType })) { e -> WorkoutDetailScreen(vm, e.arguments!!.getLong("id"), onBack = { nav.popBackStack() }) }
        }
        if (isTab) BottomBar(route) { tab -> nav.navigate(tab.route) { popUpTo("today") { saveState = true }; launchSingleTop = true; restoreState = true } }
    }

    if (showQuick) {
        ModalBottomSheet(onDismissRequest = { showQuick = false }, containerColor = s.card) {
            Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp)) {
                Text("Add", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(bottom = 12.dp))
                QuickRow(Icons.Filled.FitnessCenter, if (liveWorkout != null) "Return to workout" else "Start workout", AtriaColors.strain) { showQuick = false; nav.navigate(if (liveWorkout != null) "liveworkout" else "workout") }
                QuickRow(Icons.Filled.Bedtime, "Log sleep or nap", AtriaColors.sleep) { showQuick = false; showManualSleep = true }
                QuickRow(Icons.Filled.SelfImprovement, "Breathwork", AtriaColors.hrv) { showQuick = false; nav.navigate("breathe") }
                QuickRow(Icons.Filled.EditNote, "Journal check-in", AtriaColors.recovery) { showQuick = false; nav.navigate("journal") }
            }
        }
    }
    if (showManualSleep) ManualSleepSheet(onDismiss = { showManualSleep = false }) { start, end, nap -> vm.logManualSleep(start, end, nap); showManualSleep = false }
}

@Composable
private fun QuickRow(icon: ImageVector, label: String, color: Color, onClick: () -> Unit) {
    val s = LocalSurfaces.current
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp).clip(RoundedCornerShape(18.dp)).background(s.inset).clickable(role = Role.Button, onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = color)
        Spacer(Modifier.width(14.dp))
        Text(label, style = MaterialTheme.typography.titleSmall)
    }
}

/** Shared tab chrome: battery pill, add, settings, sync banner — then the page body. */
@Composable
fun TabPage(vm: AppViewModel, nav: NavHostController, onQuick: () -> Unit, content: @Composable () -> Unit) {
    val live by vm.live.collectAsStateWithLifecycle()
    val s = LocalSurfaces.current
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 120.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                val (label, color, icon) = when {
                    live.status == LinkStatus.BLUETOOTH_OFF -> Triple("Bluetooth off", AtriaColors.danger.copy(alpha = 0.5f), Icons.Filled.BluetoothDisabled)
                    live.status == LinkStatus.UNPAIRED -> Triple("Pair strap", s.raised, Icons.Filled.Add)
                    live.battery != null -> Triple("${live.battery}%", if ((live.battery ?: 0) > 20) AtriaColors.batteryGood else AtriaColors.danger.copy(alpha = 0.6f), if (live.charging) Icons.Filled.BatteryChargingFull else Icons.Filled.BatteryFull)
                    else -> Triple(if (live.status == LinkStatus.CONNECTED) "Connected" else "Connecting…", s.raised, Icons.Filled.Sync)
                }
                Row(
                    Modifier.weight(1f).height(52.dp).clip(RoundedCornerShape(50)).background(color).clickable { nav.navigate("strap") }.padding(horizontal = 20.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center,
                ) {
                    Icon(icon, null, tint = Color.White, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(label, color = Color.White, style = MaterialTheme.typography.labelLarge)
                }
                Spacer(Modifier.width(80.dp))
                com.adidshaft.atria.ui.components.CircleButton(Icons.Filled.Add, "Add", onClick = onQuick)
                Spacer(Modifier.width(10.dp))
                com.adidshaft.atria.ui.components.CircleButton(Icons.Filled.Settings, "Settings") { nav.navigate("settings") }
            }
        }
        live.powerNote?.let { note ->
            item { Text(note, style = MaterialTheme.typography.bodySmall, color = s.textSecondary, modifier = Modifier.padding(start = 8.dp)) }
        }
        if (live.drainActive || live.status == LinkStatus.CONNECTING || live.status == LinkStatus.DISCONNECTED) {
            item {
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(s.card).border(1.dp, s.stroke, RoundedCornerShape(50)).clickable { nav.navigate("strap") }.padding(horizontal = 18.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.Sync, null, tint = s.textPrimary, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(10.dp))
                    Text(
                        if (live.drainActive) "Syncing strap history · ${live.drainRows} saved" else "Reconnecting to strap…",
                        style = MaterialTheme.typography.titleSmall,
                    )
                }
            }
        }
        item { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { content() } }
    }
}

@Composable
private fun BottomBar(route: String, onSelect: (Tab) -> Unit) {
    val s = LocalSurfaces.current
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Row(
            Modifier.navigationBarsPadding().padding(horizontal = 24.dp, vertical = 10.dp).fillMaxWidth()
                .clip(RoundedCornerShape(50)).background(s.raised.copy(alpha = 0.96f)).border(1.dp, s.stroke, RoundedCornerShape(50)).padding(6.dp),
        ) {
            Tab.entries.forEach { t ->
                val sel = route.startsWith(t.route)
                Column(
                    Modifier.weight(1f).clip(RoundedCornerShape(50)).background(if (sel) s.inset else Color.Transparent).clickable(role = Role.Tab) { onSelect(t) }.padding(vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(t.icon, t.title, tint = if (sel) AtriaColors.strain else s.textPrimary)
                    Text(t.title, style = MaterialTheme.typography.labelMedium, color = if (sel) AtriaColors.strain else s.textPrimary)
                }
            }
        }
    }
}
