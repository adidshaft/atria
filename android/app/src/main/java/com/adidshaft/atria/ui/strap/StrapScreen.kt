package com.adidshaft.atria.ui.strap

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.R
import com.adidshaft.atria.ble.LinkStatus
import com.adidshaft.atria.ble.Permissions
import com.adidshaft.atria.platform.CompanionPairing
import com.adidshaft.atria.platform.StrapService
import com.adidshaft.atria.ui.AppViewModel
import com.adidshaft.atria.ui.components.AtriaCard
import com.adidshaft.atria.ui.components.CircleButton
import com.adidshaft.atria.ui.components.Dot
import com.adidshaft.atria.ui.components.Eyebrow
import com.adidshaft.atria.ui.components.KeyValueRow
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import com.adidshaft.atria.ui.today.ago
import com.adidshaft.atria.ui.today.clock

@Composable
fun StrapScreen(vm: AppViewModel, onBack: () -> Unit) {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    val live by vm.live.collectAsStateWithLifecycle()
    val strap by vm.strap.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    val log by vm.eventLog.collectAsStateWithLifecycle()
    var confirmForget by remember { mutableStateOf(false) }
    val g = AtriaApp.graph

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(Modifier.statusBarsPadding(), verticalAlignment = Alignment.CenterVertically) {
                CircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", size = 46.dp, onClick = onBack)
                Spacer(Modifier.width(12.dp))
                Text("Strap", style = MaterialTheme.typography.titleLarge)
            }
        }
        item {
            Image(painterResource(R.drawable.atria_strap_hero), "WHOOP 4.0 strap", Modifier.fillMaxWidth().height(160.dp), contentScale = ContentScale.Fit)
        }
        if (strap.pairedAddress == null) {
            item { PairCard(vm) }
        } else {
            item {
                AtriaCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Dot(when (live.status) { LinkStatus.CONNECTED -> AtriaColors.calm; LinkStatus.CONNECTING, LinkStatus.SCANNING -> AtriaColors.recoveryFair; else -> AtriaColors.heart })
                        Spacer(Modifier.width(8.dp))
                        Text(live.status.name.lowercase().replace('_', ' ').replaceFirstChar { it.uppercase() }, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        Text(strap.pairedName ?: "WHOOP 4.0", color = s.textSecondary)
                    }
                    KeyValueRow("Battery", live.battery?.let { "$it%${if (live.charging) " · charging" else ""}" } ?: "--")
                    KeyValueRow("Heart rate", if (live.hrFresh) "${live.heartRate} bpm" else "waiting")
                    KeyValueRow("On wrist", if (live.onWrist) "Yes" else "No skin contact")
                    KeyValueRow("Motion stream", if (live.imuLive) "Live" else "Idle")
                    KeyValueRow("Firmware", live.firmware ?: strap.firmware ?: "--")
                    KeyValueRow("Address", strap.pairedAddress ?: "--")
                    strap.lastConnectedAt?.let { KeyValueRow("Last link change", ago(it)) }
                }
            }
            item {
                AtriaCard {
                    Text("History catch-up", style = MaterialTheme.typography.titleSmall)
                    Text("The strap banks data while away from the phone. Atria drains it oldest-first and saves each page before acknowledging it.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
                    KeyValueRow("Status", if (live.drainActive) "Syncing · ${live.drainRows} saved" else "Idle")
                    (live.pendingRecords ?: strap.pendingRecords)?.let { KeyValueRow("Waiting on strap", if (it == 0L) "Caught up" else "≈ ${formatBacklog(it)}") }
                    strap.lastHistorySyncAt?.let { KeyValueRow("Last sync", "${clock(it)} (${ago(it)})") }
                    KeyValueRow("Records saved", "${strap.historyRecordsSaved}")
                    KeyValueRow("Clock offset", "${strap.clockOffsetSeconds} s")
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        PillButton("Sync now", Modifier.weight(1f), color = AtriaColors.strain, height = 46.dp) { StrapService.start(ctx, StrapService.ACTION_SYNC) }
                        PillButton("Buzz strap", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 46.dp) { g.strap.haptic(2) }
                    }
                }
            }
            if (strap.parkedAt != null) item {
                AtriaCard(tint = AtriaColors.stress) {
                    Text("Strap can't catch up", style = MaterialTheme.typography.titleSmall)
                    Text("${strap.consecutiveZeroProgressSlices} sync attempts saved nothing while the strap still reports a backlog. Start fresh clears that backlog so today's data arrives; nothing on this phone is deleted.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
                    Spacer(Modifier.height(8.dp))
                    PillButton("Start fresh", Modifier.fillMaxWidth(), color = AtriaColors.stress, height = 44.dp) {
                        kotlinx.coroutines.runBlocking { g.repo.settings.updateStrap { it.copy(historyIgnoreBeforeMs = System.currentTimeMillis(), parkedAt = null, consecutiveZeroProgressSlices = 0) } }
                        g.strap.requestHistorySync()
                    }
                }
            }
            item { DataCoverageCard() }
            item {
                AtriaCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("All-day motion", style = MaterialTheme.typography.titleSmall)
                            Text("Streams strap motion for steps and sleep. Uses more strap battery.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
                        }
                        Switch(settings.allDayMotion, { on -> vm.updateSettings { it.copy(allDayMotion = on) }; g.strap.setAllDayMotion(on) })
                    }
                }
            }
            item { BatteryOptimizationCard() }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    PillButton(if (strap.capturePaused) "Resume capture" else "Reconnect", Modifier.weight(1f), color = s.inset, contentColor = s.textPrimary, height = 46.dp) {
                        kotlinx.coroutines.runBlocking { g.repo.settings.updateStrap { it.copy(capturePaused = false) } }
                        g.strap.disconnect(); g.strap.resume(); StrapService.start(ctx)
                    }
                    PillButton("Forget strap", Modifier.weight(1f), color = AtriaColors.danger, height = 46.dp) { confirmForget = true }
                }
            }
        }
        item { com.adidshaft.atria.ui.extras.CompatibleHardwareCard() }
        item { Eyebrow("Diagnostics") }
        items(log.take(60)) { e ->
            Text("${clock(e.t)}  ${e.tag}  ${e.message}", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
        }
    }
    if (confirmForget) AlertDialog(
        onDismissRequest = { confirmForget = false },
        title = { Text("Forget this strap?") },
        text = { Text("Atria stops reconnecting. Your saved data stays on this phone.") },
        confirmButton = { TextButton({ confirmForget = false; g.strap.forget(); CompanionPairing.disassociateAll(ctx); ctx.stopService(Intent(ctx, StrapService::class.java)) }) { Text("Forget", color = AtriaColors.danger) } },
        dismissButton = { TextButton({ confirmForget = false }) { Text("Cancel") } },
    )
}

fun formatBacklog(records: Long): String = when {
    records < 120 -> "$records s of data"
    records < 7200 -> "${records / 60} min of data"
    else -> "%.1f h of data".format(records / 3600.0)
}

/** Scan + pair; CompanionDeviceManager when available, raw scan list as a fallback. */
@Composable
fun PairCard(vm: AppViewModel, onPaired: (() -> Unit)? = null) {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    val live by vm.live.collectAsStateWithLifecycle()
    val g = AtriaApp.graph
    val chooser = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val device: android.bluetooth.le.ScanResult? = result.data?.let {
                @Suppress("DEPRECATION") it.getParcelableExtra(android.companion.CompanionDeviceManager.EXTRA_DEVICE)
            }
            val address = device?.device?.address
            if (address != null) {
                g.strap.connect(address, device.scanRecord?.deviceName)
                CompanionPairing.observe(ctx, address)
                StrapService.start(ctx)
                onPaired?.invoke()
            }
        }
    }
    val perms = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { if (Permissions.hasBluetooth(ctx)) g.strap.startScan() }
    AtriaCard {
        Text("Pair your WHOOP 4.0", style = MaterialTheme.typography.titleMedium)
        Text("Take the strap off the official app's Bluetooth first, then keep it close to the phone.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        Spacer(Modifier.height(10.dp))
        PillButton("Find my strap", Modifier.fillMaxWidth(), color = AtriaColors.strain) {
            CompanionPairing.associate(ctx as Activity, onChooser = { chooser.launch(IntentSenderRequest.Builder(it).build()) }, onError = {
                if (Permissions.hasBluetooth(ctx)) g.strap.startScan() else perms.launch(Permissions.bluetooth())
            })
        }
        Spacer(Modifier.height(6.dp))
        TextButton({ if (Permissions.hasBluetooth(ctx)) g.strap.startScan() else perms.launch(Permissions.bluetooth()) }) { Text(if (live.status == LinkStatus.SCANNING) "Scanning…" else "Scan manually") }
        live.discovered.forEach { d ->
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) { Text(d.name, style = MaterialTheme.typography.titleSmall); Text("${d.address} · ${d.rssi} dBm", style = MaterialTheme.typography.bodySmall, color = s.textTertiary) }
                PillButton("Connect", height = 40.dp, color = AtriaColors.strain) { g.strap.connect(d.address, d.name); StrapService.start(ctx); onPaired?.invoke() }
            }
        }
    }
}

/** iOS has no equivalent: aggressive OEM battery savers kill BLE services unless exempted. */
@Composable
fun BatteryOptimizationCard() {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    val pm = ctx.getSystemService(PowerManager::class.java)
    if (pm.isIgnoringBatteryOptimizations(ctx.packageName)) return
    AtriaCard(tint = AtriaColors.stress) {
        Text("Keep Atria running", style = MaterialTheme.typography.titleSmall)
        Text("Allow Atria to run in the background so overnight sleep and history sync aren't interrupted by battery optimisation.", style = MaterialTheme.typography.bodySmall, color = s.textSecondary)
        Spacer(Modifier.height(8.dp))
        PillButton("Allow background use", Modifier.fillMaxWidth(), color = AtriaColors.stress, height = 46.dp) {
            @Suppress("BatteryLife")
            runCatching { ctx.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}"))) }
        }
    }
}


/** "Verified complete days and honest partial coverage": share of each day with strap HR. */
@Composable
fun DataCoverageCard() {
    val s = LocalSurfaces.current
    var rows by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<List<Pair<java.time.LocalDate, Int>>>(emptyList()) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        rows = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val g = AtriaApp.graph
            (6 downTo 0).map { i ->
                val day = g.repo.today().minusDays(i.toLong())
                val (a, b) = g.repo.dayBounds(day)
                val end = minOf(b, System.currentTimeMillis())
                val minutes = g.repo.db.samples().hrMinutes(a, end).size
                val possible = ((end - a) / 60_000).coerceAtLeast(1)
                day to (minutes * 100 / possible).toInt().coerceIn(0, 100)
            }
        }
    }
    AtriaCard {
        Text("Data coverage", style = MaterialTheme.typography.titleSmall)
        rows.forEach { (d, pct) ->
            KeyValueRow(if (d == java.time.LocalDate.now()) "Today so far" else d.format(java.time.format.DateTimeFormatter.ofPattern("EEE MMM d")),
                if (pct >= 90) "Complete · $pct%" else "Partial · $pct%", valueColor = if (pct >= 90) AtriaColors.calm else s.textSecondary)
        }
        Text("Minutes with strap heart rate. Gaps stay gaps; nothing is filled in.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
    }
}
