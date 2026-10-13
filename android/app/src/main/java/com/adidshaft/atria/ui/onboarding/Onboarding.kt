package com.adidshaft.atria.ui.onboarding

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.R
import com.adidshaft.atria.analytics.BiologicalSex
import com.adidshaft.atria.ble.LinkStatus
import com.adidshaft.atria.ble.Permissions
import com.adidshaft.atria.data.DemoData
import com.adidshaft.atria.ui.AppViewModel
import com.adidshaft.atria.ui.components.AtriaCard
import com.adidshaft.atria.ui.components.KeyValueRow
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.components.SegmentedTabs
import com.adidshaft.atria.ui.strap.BatteryOptimizationCard
import com.adidshaft.atria.ui.strap.PairCard
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * AtriaOnboardingFlow: 4 pages — welcome, about you, permissions, strap setup
 * (pair → wear → history choice). Ready = strap connected and the first data
 * range check (22/00) answered; live HR is not a gate.
 */
@Composable
fun OnboardingFlow(vm: AppViewModel) {
    val s = LocalSurfaces.current
    var page by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    Box(Modifier.fillMaxSize().background(s.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                repeat(4) { i -> Box(Modifier.padding(4.dp).size(if (i == page) 10.dp else 7.dp).clip(CircleShape).background(if (i <= page) AtriaColors.strain else s.inset)) }
            }
            when (page) {
                0 -> Welcome(onNext = { page = 1 }, onDemo = {
                    scope.launch(Dispatchers.IO) { DemoData(AtriaApp.graph.repo).seed(); AtriaApp.graph.engine.refreshRange(2); AtriaApp.graph.repo.settings.update { it.copy(onboardingComplete = true) } }
                })
                1 -> AboutYou(vm) { page = 2 }
                2 -> PermissionsPage { page = 3 }
                else -> StrapSetup(vm) { vm.updateSettings { it.copy(onboardingComplete = true) } }
            }
        }
    }
}

@Composable
private fun Welcome(onNext: () -> Unit, onDemo: () -> Unit) {
    val s = LocalSurfaces.current
    Image(painterResource(R.drawable.atria_onboarding_backdrop), null, Modifier.fillMaxWidth().height(300.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(32.dp)), contentScale = ContentScale.Crop)
    Text("Your unused strap.\nYour phone. Your choice.", style = MaterialTheme.typography.headlineLarge)
    Text("Atria reads a WHOOP 4.0 you already own and computes heart rate, sleep, recovery, strain and steps on this phone. No account, no cloud, no subscription.", color = s.textSecondary)
    AtriaCard {
        Text("Independent project, not affiliated with or endorsed by WHOOP. Atria provides fitness estimates; ask a doctor before making medical decisions.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
    }
    PillButton("Get started", Modifier.fillMaxWidth(), color = AtriaColors.strain, onClick = onNext)
    TextButton(onDemo, Modifier.fillMaxWidth()) { Text("Explore with sample data") }
}

@Composable
private fun AboutYou(vm: AppViewModel, onNext: () -> Unit) {
    val s = LocalSurfaces.current
    val settings by vm.settings.collectAsStateWithLifecycle()
    var name by remember { mutableStateOf(settings.profile.name) }
    var age by remember { mutableStateOf(settings.profile.age.toString()) }
    var weight by remember { mutableStateOf(settings.profile.weightKg.toInt().toString()) }
    var height by remember { mutableStateOf(settings.profile.heightCm.toInt().toString()) }
    var sex by remember { mutableIntStateOf(2) }
    Text("About you", style = MaterialTheme.typography.headlineLarge)
    Text("Used for max heart rate, calories and fitness age. Stays on this phone.", color = s.textSecondary)
    OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("First name (optional)") }, singleLine = true)
    OutlinedTextField(age, { age = it.filter(Char::isDigit) }, Modifier.fillMaxWidth(), label = { Text("Age") }, singleLine = true)
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        OutlinedTextField(weight, { weight = it.filter(Char::isDigit) }, Modifier.weight(1f), label = { Text("Weight (kg)") }, singleLine = true)
        OutlinedTextField(height, { height = it.filter(Char::isDigit) }, Modifier.weight(1f), label = { Text("Height (cm)") }, singleLine = true)
    }
    Text("Sex (for calorie and strain equations)", color = s.textSecondary)
    SegmentedTabs(listOf("Male", "Female", "Prefer not"), sex, { sex = it })
    PillButton("Continue", Modifier.fillMaxWidth(), color = AtriaColors.strain) {
        vm.updateSettings { st ->
            st.copy(profile = st.profile.copy(
                name = name.trim(), age = age.toIntOrNull()?.coerceIn(13, 100) ?: 30, weightKg = weight.toDoubleOrNull()?.coerceIn(30.0, 250.0) ?: 70.0,
                heightCm = height.toDoubleOrNull()?.coerceIn(100.0, 230.0) ?: 175.0, sex = BiologicalSex.entries[sex].name,
            ))
        }
        onNext()
    }
}

@Composable
private fun PermissionsPage(onNext: () -> Unit) {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    var refresh by remember { mutableIntStateOf(0) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh++ }
    Text("Permissions", style = MaterialTheme.typography.headlineLarge)
    Text("Android asks for these separately. Atria uses each only for the purpose shown.", color = s.textSecondary)
    key(refresh) {
        AtriaCard {
            KeyValueRow("Nearby devices (Bluetooth)", if (Permissions.hasBluetooth(ctx)) "Allowed" else "Needed", valueColor = if (Permissions.hasBluetooth(ctx)) AtriaColors.calm else AtriaColors.stress)
            Text("Connect to the strap and keep it connected in the background.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
            KeyValueRow("Notifications", if (Permissions.hasNotifications(ctx)) "Allowed" else "Recommended", valueColor = if (Permissions.hasNotifications(ctx)) AtriaColors.calm else s.textSecondary)
            Text("Sleep and workout reviews, recovery, and the live strap status.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
            KeyValueRow("Physical activity", if (Build.VERSION.SDK_INT < 29 || Permissions.granted(ctx, Permissions.activityRecognition())) "Allowed" else "Optional")
            Text("Tells driving apart from a workout. Phone motion never counts steps.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
        }
    }
    PillButton("Allow", Modifier.fillMaxWidth(), color = AtriaColors.strain) {
        val ask = (Permissions.bluetooth() + Permissions.notifications() + if (Build.VERSION.SDK_INT >= 29) arrayOf(Manifest.permission.ACTIVITY_RECOGNITION) else emptyArray())
        launcher.launch(ask)
    }
    BatteryOptimizationCard()
    PillButton("Continue", Modifier.fillMaxWidth(), color = if (Permissions.hasBluetooth(ctx)) AtriaColors.strain else s.inset, contentColor = if (Permissions.hasBluetooth(ctx)) androidx.compose.ui.graphics.Color.White else s.textPrimary, onClick = onNext)
}

@Composable
private fun key(k: Int, content: @Composable () -> Unit) = androidx.compose.runtime.key(k) { content() }

@Composable
private fun StrapSetup(vm: AppViewModel, onDone: () -> Unit) {
    val s = LocalSurfaces.current
    val live by vm.live.collectAsStateWithLifecycle()
    val strap by vm.strap.collectAsStateWithLifecycle()
    var historyChoice by remember { mutableIntStateOf(0) }
    Text("Set up your strap", style = MaterialTheme.typography.headlineLarge)
    Image(painterResource(R.drawable.atria_setup_pair_scene), null, Modifier.fillMaxWidth().height(200.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(28.dp)), contentScale = ContentScale.Crop)
    if (strap.pairedAddress == null) PairCard(vm)
    else AtriaCard {
        KeyValueRow("Strap", strap.pairedName ?: strap.pairedAddress ?: "")
        KeyValueRow("Connection", when (live.status) { LinkStatus.CONNECTED -> "Connected"; LinkStatus.CONNECTING -> "Connecting…"; else -> live.status.name.lowercase() }, valueColor = if (live.status == LinkStatus.CONNECTED) AtriaColors.calm else AtriaColors.recoveryFair)
        KeyValueRow("Strap check (22/00)", live.pendingRecords?.let { "Answered" } ?: "Waiting", valueColor = if (live.pendingRecords != null) AtriaColors.calm else s.textSecondary)
        live.pendingRecords?.takeIf { it > 0 }?.let { KeyValueRow("Stored on strap", com.adidshaft.atria.ui.strap.formatBacklog(it)) }
        Text("Wear it snug, a finger's width above the wrist bone.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
    }
    if (strap.pairedAddress != null) {
        Text("History already on the strap", style = MaterialTheme.typography.titleMedium)
        SegmentedTabs(listOf("Bring my history", "Start fresh"), historyChoice, { historyChoice = it })
        Text(
            if (historyChoice == 0) "Atria drains the strap's stored data oldest-first in the background. It can take a while after a long gap."
            else "Atria clears the strap backlog without saving it, so today's data arrives sooner. Nothing on the phone is deleted.",
            style = MaterialTheme.typography.bodySmall, color = s.textSecondary, textAlign = TextAlign.Start,
        )
    }
    PillButton(
        if (live.status == LinkStatus.CONNECTED && live.pendingRecords != null) "Finish" else "Finish later",
        Modifier.fillMaxWidth(), color = AtriaColors.strain,
    ) {
        if (historyChoice == 1) vm.viewModelScopeLaunchStartFresh()
        onDone()
    }
}
