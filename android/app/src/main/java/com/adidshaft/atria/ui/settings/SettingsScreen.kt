package com.adidshaft.atria.ui.settings

import android.Manifest
import android.app.AlarmManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.health.connect.client.PermissionController
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.analytics.BiologicalSex
import com.adidshaft.atria.analytics.SmartWakePlanner
import com.adidshaft.atria.data.AppSettings
import com.adidshaft.atria.data.Backup
import com.adidshaft.atria.data.DemoData
import com.adidshaft.atria.health.HealthConnectExporter
import com.adidshaft.atria.platform.WakeAlarm
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

@Composable
private fun ToggleRow(title: String, subtitle: String? = null, checked: Boolean, onChange: (Boolean) -> Unit) {
    val s = LocalSurfaces.current
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = s.textSecondary) }
        }
        Switch(checked, onChange)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(vm: AppViewModel, nav: NavHostController, onBack: () -> Unit) {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    val settings by vm.settings.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val g = AtriaApp.graph
    var editProfile by remember { mutableStateOf(false) }
    var pickTime by remember { mutableStateOf(false) }
    fun update(t: (AppSettings) -> AppSettings) = vm.updateSettings(t)
    fun toast(msg: String) = Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show()

    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        uri?.let { scope.launch { withContext(Dispatchers.IO) { Backup(ctx, g.repo).export(it) }; toast("Backup saved") } }
    }
    val restoreLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { scope.launch { val n = withContext(Dispatchers.IO) { Backup(ctx, g.repo).restore(it) }; g.engine.refreshRange(30); toast("Restored $n records") } }
    }
    val hcLauncher = rememberLauncherForActivityResult(PermissionController.createRequestPermissionResultContract()) { granted ->
        if (granted.containsAll(HealthConnectExporter.PERMISSIONS)) update { it.copy(healthConnectExport = true) } else toast("Health Connect permission not granted")
    }
    val ctxLauncher = rememberLauncherForActivityResult(PermissionController.createRequestPermissionResultContract()) { granted ->
        if (granted.isNotEmpty()) scope.launch {
            val kg = withContext(Dispatchers.IO) { HealthConnectExporter(ctx, g.repo).latestWeightKg() }
            if (kg != null) { update { it.copy(profile = it.profile.copy(weightKg = kg)) }; toast("Weight updated to %.1f kg".format(kg)) } else toast("No weight found in Health Connect")
        }
    }
    val phoneLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> if (ok) update { it.copy(haptics = it.haptics.copy(incomingCalls = true)) } }
    val advertiseLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> if (ok) { update { it.copy(heartRateBroadcast = true) }; g.broadcaster.setEnabled(true) } }
    val notifLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    val activityLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> if (ok) com.adidshaft.atria.platform.MotionContext.start(ctx) }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.statusBarsPadding(), verticalAlignment = Alignment.CenterVertically) {
                CircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", size = 46.dp, onClick = onBack)
                Spacer(Modifier.width(12.dp))
                Text("Settings", style = MaterialTheme.typography.titleLarge)
            }
        }
        item {
            AtriaCard(onClick = { editProfile = true }) {
                Eyebrow("Profile")
                val p = settings.profile
                KeyValueRow("Name", p.name.ifBlank { "—" })
                KeyValueRow("Age · sex", "${p.age} · ${p.sex.lowercase().replaceFirstChar { it.uppercase() }}")
                KeyValueRow("Weight · height", "${p.weightKg.toInt()} kg · ${p.heightCm.toInt()} cm")
                KeyValueRow("Max HR", "${p.toAthlete().estimatedMaxHr} bpm${if (p.maxHrOverride != null) " (set)" else if (p.learnedMaxHr != null) " (measured)" else " (age-based)"}")
                KeyValueRow("Sleep goal · step goal", "${p.sleepGoalHours} h · ${p.stepGoal}")
                Text("Tap to edit. Calories need sex, weight and age.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
            }
        }
        item {
            AtriaCard {
                Eyebrow("Strap & devices")
                PillButton("Manage strap", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 46.dp) { nav.navigate("strap") }
                ToggleRow("Detect sleep automatically", "Review-first: long nights save, shorter ones ask", settings.autoDetectSleep) { v -> update { it.copy(autoDetectSleep = v) } }
                ToggleRow("Suggest possible workouts", "Elevated heart rate ≥ 10 min, never while driving", settings.autoDetectWorkouts) { v ->
                    update { it.copy(autoDetectWorkouts = v) }
                    if (v && Build.VERSION.SDK_INT >= 29 && ctx.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED) activityLauncher.launch(Manifest.permission.ACTIVITY_RECOGNITION)
                }
                ToggleRow("Broadcast heart rate", "Share live HR as a standard Bluetooth sensor (gym equipment, bike computers)", settings.heartRateBroadcast) { v ->
                    if (v && Build.VERSION.SDK_INT >= 31 && ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) advertiseLauncher.launch(Manifest.permission.BLUETOOTH_ADVERTISE)
                    else { update { it.copy(heartRateBroadcast = v) }; g.broadcaster.setEnabled(v) }
                }
            }
        }
        item {
            AtriaCard {
                Eyebrow("Lock screen & widgets")
                val modes = listOf("always", "workouts", "off")
                SegmentedTabs(listOf("Always", "Workouts", "Off"), modes.indexOf(settings.glanceMode).coerceAtLeast(0), { i -> update { it.copy(glanceMode = modes[i]) } })
                Text(
                    when (settings.glanceMode) {
                        "always" -> "Live heart rate stays on your lock screen and status bar."
                        "workouts" -> "Live details show only while a workout is running."
                        else -> "Only a quiet 'keeping your strap connected' notice (Android requires one for background Bluetooth)."
                    },
                    style = MaterialTheme.typography.bodySmall, color = s.textSecondary,
                )
                listOf("zone" to "Heart-rate zone", "steps" to "Steps", "battery" to "Strap battery").forEach { (k, label) ->
                    ToggleRow(label, null, k in settings.glanceItems) { v -> update { it.copy(glanceItems = if (v) it.glanceItems + k else it.glanceItems - k) } }
                }
            }
        }
        item {
            AtriaCard {
                Eyebrow("Notifications")
                if (Build.VERSION.SDK_INT >= 33 && ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                    PillButton("Allow notifications", Modifier.fillMaxWidth(), color = AtriaColors.strain, height = 44.dp) { notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) }
                val n = settings.notifications
                ToggleRow("Recovery ready", null, n.recoveryReady) { v -> update { it.copy(notifications = n.copy(recoveryReady = v)) } }
                ToggleRow("Strain target reached", null, n.strainTarget) { v -> update { it.copy(notifications = n.copy(strainTarget = v)) } }
                ToggleRow("Sleep review", null, n.sleepReview) { v -> update { it.copy(notifications = n.copy(sleepReview = v)) } }
                ToggleRow("Workout review", null, n.workoutReview) { v -> update { it.copy(notifications = n.copy(workoutReview = v)) } }
                ToggleRow("Morning summary", null, n.morningSummary) { v -> update { it.copy(notifications = n.copy(morningSummary = v)) } }
                ToggleRow("Weekly report", null, n.weeklyReport) { v -> update { it.copy(notifications = n.copy(weeklyReport = v)) } }
                ToggleRow("Health monitor alerts", "Unusual overnight resting HR (not a diagnosis)", n.healthDeviation) { v -> update { it.copy(notifications = n.copy(healthDeviation = v)) } }
                ToggleRow("Strap battery", null, n.strapBattery) { v -> update { it.copy(notifications = n.copy(strapBattery = v)) } }
                ToggleRow("Bluetooth off", null, n.bluetoothOff) { v -> update { it.copy(notifications = n.copy(bluetoothOff = v)) } }
                ToggleRow("Evening check-in", null, n.eveningCheckIn) { v -> update { it.copy(notifications = n.copy(eveningCheckIn = v)) } }
                ToggleRow("Bedtime wind-down", null, n.bedtimeWindDown) { v -> update { it.copy(notifications = n.copy(bedtimeWindDown = v)) } }
                ToggleRow("Strap fit check", null, n.fitCheck) { v -> update { it.copy(notifications = n.copy(fitCheck = v)) } }
                ToggleRow("History catch-up done", null, n.catchUpComplete) { v -> update { it.copy(notifications = n.copy(catchUpComplete = v)) } }
                ToggleRow("Sync reminders", "When hours of strap data are waiting", n.syncNudge) { v -> update { it.copy(notifications = n.copy(syncNudge = v)) } }
                Text("At most ${com.adidshaft.atria.platform.Notifier.DAILY_BUDGET} insight notifications a day; battery, Bluetooth and health alerts are never held back.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
                TextButton({ ctx.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)) }) { Text("System notification channels") }
            }
        }
        item {
            AtriaCard {
                Eyebrow("Haptic alerts")
                val h = settings.haptics
                ToggleRow("Buzz the strap", "Alerts vibrate the strap itself (phone otherwise)", h.useStrapMotor) { v -> update { it.copy(haptics = h.copy(useStrapMotor = v)) } }
                ToggleRow("Heart-rate zone changes", null, h.heartRateZones) { v -> update { it.copy(haptics = h.copy(heartRateZones = v)) } }
                ToggleRow("Strain target reached", null, h.strainTarget) { v -> update { it.copy(haptics = h.copy(strainTarget = v)) } }
                ToggleRow("Recovery ready", null, h.recoveryReady) { v -> update { it.copy(haptics = h.copy(recoveryReady = v)) } }
                ToggleRow("Low strap battery", null, h.lowBattery) { v -> update { it.copy(haptics = h.copy(lowBattery = v)) } }
                ToggleRow("Incoming calls", "Buzz the strap when the phone rings", h.incomingCalls) { v ->
                    if (v && ctx.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) phoneLauncher.launch(Manifest.permission.READ_PHONE_STATE)
                    else update { it.copy(haptics = h.copy(incomingCalls = v)) }
                }
            }
        }
        item {
            AtriaCard {
                Eyebrow("Smart wake alarm")
                val w = settings.wakeAlarm
                ToggleRow("Wake alarm", "A real system alarm at your wake-by time, earlier in a light stage", w.enabled) { v ->
                    val am = ctx.getSystemService(AlarmManager::class.java)
                    if (v && Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) ctx.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${ctx.packageName}")))
                    update { it.copy(wakeAlarm = w.copy(enabled = v)) }
                    scope.launch { kotlinx.coroutines.delay(300); WakeAlarm.reschedule(ctx) }
                }
                if (w.enabled) {
                    KeyValueRow("Wake by", "%d:%02d".format(w.hour, w.minute))
                    TextButton({ pickTime = true }) { Text("Change time") }
                    val modes = SmartWakePlanner.Mode.entries
                    SegmentedTabs(modes.map { it.title }, modes.indexOfFirst { it.name == w.mode }.coerceAtLeast(0), { i -> update { it.copy(wakeAlarm = w.copy(mode = modes[i].name)) } })
                    ToggleRow("Buzz the strap", null, w.strapHaptic) { v -> update { it.copy(wakeAlarm = w.copy(strapHaptic = v)) } }
                }
            }
        }
        item {
            AtriaCard {
                Eyebrow("Health Connect")
                val available = HealthConnectExporter.isAvailable(ctx)
                Text(if (available) "Write confirmed sleep, workouts, heart rate, HRV, respiratory rate, calories and steps to Health Connect." else "Health Connect isn't available on this device.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
                if (available) {
                    ToggleRow("Export to Health Connect", null, settings.healthConnectExport) { v -> if (v) hcLauncher.launch(HealthConnectExporter.PERMISSIONS) else update { it.copy(healthConnectExport = false) } }
                    PillButton("Import weight & nutrition context", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 44.dp) { ctxLauncher.launch(HealthConnectExporter.CONTEXT_PERMISSIONS) }
                    Spacer(Modifier.height(6.dp))
                    if (settings.healthConnectExport) PillButton("Export now", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 44.dp) {
                        scope.launch { val n = withContext(Dispatchers.IO) { HealthConnectExporter(ctx, g.repo).exportPending() }; toast("Exported $n records") }
                    }
                }
            }
        }
        item {
            AtriaCard {
                Eyebrow("Your data")
                Text("Everything is processed and stored on this phone. Backups go only where you choose.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    PillButton("Export backup", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 44.dp) { exportLauncher.launch("atria-backup-${LocalDate.now()}.zip") }
                    PillButton("Restore", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 44.dp) { restoreLauncher.launch(arrayOf("application/zip", "application/octet-stream")) }
                }
                Spacer(Modifier.height(8.dp))
                var research by remember { mutableStateOf(com.adidshaft.atria.data.ResearchBundle.consented(ctx)) }
                ToggleRow("Anonymous research sharing", "Builds an anonymous bundle (relative dates, age band, random ID) in a local outbox. Nothing is uploaded; you choose when to share one.", research) { v ->
                    if (v) com.adidshaft.atria.data.ResearchBundle.grantConsent(ctx) else com.adidshaft.atria.data.ResearchBundle.revokeConsent(ctx); research = v
                }
                if (research) PillButton("Share a research bundle", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 44.dp) {
                    scope.launch {
                        val r = withContext(Dispatchers.IO) { com.adidshaft.atria.data.ResearchBundle.writeBundle(ctx, com.adidshaft.atria.ui.developer.shareDir(ctx)) }
                        if (r == null) toast("No data to share yet") else com.adidshaft.atria.ui.developer.shareFile(ctx, r.first, "application/gzip")
                    }
                }
                Spacer(Modifier.height(8.dp))
                if (!settings.demoMode) PillButton("Explore with sample data", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 44.dp) { scope.launch(Dispatchers.IO) { DemoData(g.repo).seed(); g.engine.refreshRange(2) } }
                else PillButton("Remove sample data", Modifier.fillMaxWidth(), color = AtriaColors.danger, height = 44.dp) { scope.launch(Dispatchers.IO) { DemoData(g.repo).clear() } }
            }
        }
        item {
            AtriaCard {
                Eyebrow("Appearance")
                val themes = listOf("system", "light", "dark")
                SegmentedTabs(listOf("System", "Light", "Dark"), themes.indexOf(settings.theme).coerceAtLeast(0), { i -> update { it.copy(theme = themes[i]) } })
                Spacer(Modifier.height(10.dp))
                Text("App icon", style = MaterialTheme.typography.titleSmall)
                val icons = listOf("default", "graphite", "mint")
                SegmentedTabs(listOf("Classic", "Graphite", "Mint"), icons.indexOf(settings.appIcon).coerceAtLeast(0), { i ->
                    setAppIcon(ctx, icons[i]); update { it.copy(appIcon = icons[i]) }
                })
            }
        }
        item {
            AtriaCard {
                Eyebrow("Journal")
                ToggleRow("Cycle tracking", "Opt-in. Log periods for phase-aware context. Private to this phone.", settings.cycleTracking) { v -> update { it.copy(cycleTracking = v) } }
            }
        }
        item {
            AtriaCard {
                Eyebrow("Coach")
                ToggleRow("Gemini Nano (on-device)", "Answers are generated on this phone and your health data is not sent. Google's ML Kit may send anonymous usage statistics while this is on.", settings.coachMode == "on_device") { v -> update { it.copy(coachMode = if (v) "on_device" else "built_in") } }
                Text("Off: built-in answers computed from your data, nothing leaves the phone.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
            }
        }
        item {
            AtriaCard {
                Eyebrow("About")
                Text("Atria is an independent, open-source app for a WHOOP 4.0 you own. Not affiliated with or endorsed by WHOOP. Numbers are fitness estimates, not medical advice.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
                KeyValueRow("Version", com.adidshaft.atria.BuildConfig.VERSION_NAME)
                TextButton({ ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/adidshaft/atria/blob/main/PRIVACY.md"))) }) { Text("Privacy") }
                ToggleRow("Developer mode", "Diagnostics, step calibration and sensor-reference research tools", settings.developerMode) { v -> update { it.copy(developerMode = v) } }
                if (settings.developerMode) PillButton("Open developer & research tools", Modifier.fillMaxWidth(), color = s.inset, contentColor = s.textPrimary, height = 44.dp) { nav.navigate("developer") }
            }
        }
    }

    if (editProfile) ProfileDialog(settings, onDismiss = { editProfile = false }) { p -> update { it.copy(profile = p) }; editProfile = false }
    if (pickTime) {
        val st = rememberTimePickerState(settings.wakeAlarm.hour, settings.wakeAlarm.minute)
        AlertDialog(
            onDismissRequest = { pickTime = false },
            confirmButton = { TextButton({ update { it.copy(wakeAlarm = it.wakeAlarm.copy(hour = st.hour, minute = st.minute)) }; pickTime = false; scope.launch { kotlinx.coroutines.delay(300); WakeAlarm.reschedule(ctx) } }) { Text("Save") } },
            dismissButton = { TextButton({ pickTime = false }) { Text("Cancel") } },
            text = { TimePicker(st) },
        )
    }
}

/** CFBundleAlternateIcons → enable exactly one launcher activity-alias. */
fun setAppIcon(ctx: android.content.Context, icon: String) {
    val pm = ctx.packageManager
    mapOf("default" to "LauncherDefault", "graphite" to "LauncherGraphite", "mint" to "LauncherMint").forEach { (key, alias) ->
        pm.setComponentEnabledSetting(
            ComponentName(ctx, "com.adidshaft.atria.$alias"),
            if (key == icon) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
    }
}

@Composable
fun ProfileDialog(settings: AppSettings, onDismiss: () -> Unit, onSave: (com.adidshaft.atria.data.ProfileSettings) -> Unit) {
    val p = settings.profile
    var name by remember { mutableStateOf(p.name) }
    var age by remember { mutableStateOf(p.age.toString()) }
    var weight by remember { mutableStateOf(p.weightKg.toInt().toString()) }
    var height by remember { mutableStateOf(p.heightCm.toInt().toString()) }
    var sex by remember { mutableStateOf(p.sex) }
    var maxHr by remember { mutableStateOf(p.maxHrOverride?.toString() ?: "") }
    var sleepGoal by remember { mutableStateOf(p.sleepGoalHours.toString()) }
    var stepGoal by remember { mutableStateOf(p.stepGoal.toString()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Profile") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(age, { age = it.filter(Char::isDigit) }, Modifier.weight(1f), label = { Text("Age") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                    OutlinedTextField(maxHr, { maxHr = it.filter(Char::isDigit) }, Modifier.weight(1f), label = { Text("Max HR") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(weight, { weight = it.filter(Char::isDigit) }, Modifier.weight(1f), label = { Text("Weight kg") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                    OutlinedTextField(height, { height = it.filter(Char::isDigit) }, Modifier.weight(1f), label = { Text("Height cm") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                }
                val sexes = BiologicalSex.entries
                SegmentedTabs(listOf("Male", "Female", "Unspecified"), sexes.indexOfFirst { it.name == sex }.coerceAtLeast(0), { sex = sexes[it].name })
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(sleepGoal, { sleepGoal = it }, Modifier.weight(1f), label = { Text("Sleep goal h") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                    OutlinedTextField(stepGoal, { stepGoal = it.filter(Char::isDigit) }, Modifier.weight(1f), label = { Text("Step goal") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                }
            }
        },
        confirmButton = {
            TextButton({
                onSave(p.copy(
                    name = name.trim(), age = age.toIntOrNull()?.coerceIn(13, 100) ?: p.age, weightKg = weight.toDoubleOrNull()?.coerceIn(30.0, 250.0) ?: p.weightKg,
                    heightCm = height.toDoubleOrNull()?.coerceIn(100.0, 230.0) ?: p.heightCm, sex = sex, maxHrOverride = maxHr.toIntOrNull()?.takeIf { it in 120..230 },
                    sleepGoalHours = sleepGoal.toDoubleOrNull()?.coerceIn(6.0, 10.0) ?: p.sleepGoalHours, stepGoal = stepGoal.toIntOrNull()?.coerceIn(1000, 50000) ?: p.stepGoal,
                ))
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } },
    )
}
