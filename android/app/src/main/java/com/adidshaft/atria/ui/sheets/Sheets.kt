package com.adidshaft.atria.ui.sheets

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.material3.DatePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.adidshaft.atria.R
import com.adidshaft.atria.analytics.formatHours
import com.adidshaft.atria.data.DailyMetricsEntity
import com.adidshaft.atria.ui.components.PillButton
import com.adidshaft.atria.ui.components.SegmentedTabs
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset

/** AtriaManualSleepSheet: log a sleep or nap with start/end times. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ManualSleepSheet(onDismiss: () -> Unit, onSave: (Long, Long, Boolean) -> Unit) {
    val s = LocalSurfaces.current
    val date = rememberDatePickerState(initialSelectedDateMillis = LocalDate.now().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
    val start = rememberTimePickerState(23, 0)
    val end = rememberTimePickerState(7, 0)
    var step by remember { mutableIntStateOf(0) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = s.card) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Log sleep", style = MaterialTheme.typography.titleLarge)
            SegmentedTabs(listOf("Wake day", "Fell asleep", "Woke up"), step, { step = it }, Modifier.padding(vertical = 10.dp))
            when (step) {
                0 -> DatePicker(date, showModeToggle = false, title = null, headline = null)
                1 -> TimePicker(start)
                else -> TimePicker(end)
            }
            val wakeDay = Instant.ofEpochMilli(date.selectedDateMillis ?: System.currentTimeMillis()).atZone(ZoneOffset.UTC).toLocalDate()
            val endAt = wakeDay.atTime(end.hour, end.minute).atZone(ZoneId.systemDefault())
            var startAt = wakeDay.atTime(start.hour, start.minute).atZone(ZoneId.systemDefault())
            if (!startAt.isBefore(endAt)) startAt = startAt.minusDays(1)
            val durH = (endAt.toInstant().toEpochMilli() - startAt.toInstant().toEpochMilli()) / 3_600_000.0
            // Same nap inference as AtriaAnalytics.ManualSleep.inferredIsNap: < 3 h in the 11:00–20:00 window.
            val isNap = durH < 3 && startAt.hour >= 11 && endAt.hour <= 20
            Text("${formatHours(durH)} · ${if (isNap) "nap" else "sleep"}", color = s.textSecondary, modifier = Modifier.padding(8.dp))
            PillButton("Save", Modifier.fillMaxWidth(), color = AtriaColors.sleep, enabled = durH in 0.33..14.0) {
                onSave(startAt.toInstant().toEpochMilli(), endAt.toInstant().toEpochMilli(), isNap)
            }
        }
    }
}

/** AtriaAboutMetricSheet: plain-language explanations (fewer words, honest provenance). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MetricAboutSheet(key: String, onDismiss: () -> Unit) {
    val s = LocalSurfaces.current
    val (title, body) = when (key) {
        "recovery" -> "Recovery" to "How ready your body is today, from last night's HRV, resting heart rate, sleep and breathing compared with your own baseline. It needs 14 nights to fully personalise. 67%+ is good, 34–66% fair, below 34% low."
        "strain" -> "Strain" to "Cardiovascular load on a 0–21 scale from time spent at elevated heart rate relative to your resting and max heart rate. The target adapts to your recovery and recent training load."
        "sleep" -> "Sleep" to "Detected from a still wrist and a low heart rate, then confirmed by you when it's ambiguous. Your need adapts to your typical sleep, yesterday's strain, recent debt and naps."
        "steps" -> "Steps" to "Counted from the strap's own accelerometer, never the phone. Walking was validated against counted steps (95–100% in controlled walks)."
        "hrv" -> "HRV" to "Heart-rate variability (RMSSD) from beat-to-beat intervals during steady sleep, with artifact rejection. Higher than your usual usually means better recovered."
        "rhr" -> "Resting heart rate" to "The lowest sustained heart rate during sleep. A rise above your usual can follow hard training, alcohol, illness or poor sleep."
        "resp" -> "Respiratory rate" to "Breaths per minute estimated from how your heart rhythm changes as you breathe during sleep."
        "skin" -> "Skin signal" to "A directional reading from the strap's skin sensor: higher, lower or typical compared with this strap's own recent nights. It is not a body temperature."
        "spo2" -> "Blood oxygen" to "Hidden on purpose. The strap's red and infrared signals haven't yet matched a reference oximeter, so no number is shown."
        else -> "Atria" to "Fitness estimates computed on this phone."
    }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = s.card) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp)) {
            Text(title, style = MaterialTheme.typography.headlineMedium)
            Spacer(Modifier.height(8.dp))
            Text(body, style = MaterialTheme.typography.bodyLarge, color = s.textSecondary)
            Spacer(Modifier.height(8.dp))
            val source = when (key) {
                "recovery" -> "Sources: Plews et al. 2013 (ln-RMSSD monitoring); Buchheit 2014 (HRV-guided training)."
                "strain" -> "Sources: Banister 1991 (TRIMP); Edwards 1993 (zone load); heart-rate reserve (Karvonen)."
                "sleep" -> "Sources: Hirshkowitz et al. 2015 (NSF duration guidance); Walch et al. 2019 (wrist HR/motion staging)."
                "hrv" -> "Source: Task Force ESC/NASPE 1996 (RMSSD definition, artifact handling)."
                "rhr" -> "Source: adult resting heart-rate norms (AHA)."
                "resp" -> "Source: respiratory sinus arrhythmia (Hirsch & Bishop 1981)."
                "steps" -> "Validated against metronome-counted walks (docs/METRIC_VALIDATION_PLAN.md)."
                else -> null
            }
            source?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = s.textTertiary); Spacer(Modifier.height(4.dp)) }
            Text("Estimates only — not medical advice.", style = MaterialTheme.typography.bodySmall, color = s.textTertiary)
        }
    }
}

/** AtriaCustomizeSheet: show/hide and reorder Today cards. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CustomizeSheet(current: List<String>, onDismiss: () -> Unit, onChange: (List<String>) -> Unit) {
    val s = LocalSurfaces.current
    val all = listOf("rings" to "Rings", "trio" to "Sleep · Recovery · Strain", "live" to "Live heart rate & reviews", "brief" to "Daily brief", "steps" to "Steps", "stress" to "Stress", "sleep" to "Sleep week", "journal" to "Coach")
    var order by remember { mutableStateOf(current + all.map { it.first }.filter { it !in current }) }
    var enabled by remember { mutableStateOf(current.toSet()) }
    fun emit() = onChange(order.filter { it in enabled })
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = s.card) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp)) {
            Text("Customize Today", style = MaterialTheme.typography.titleLarge)
            order.forEachIndexed { i, key ->
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(all.first { it.first == key }.second, Modifier.weight(1f))
                    Icon(Icons.Filled.KeyboardArrowUp, "Move up", Modifier.clickable(enabled = i > 0) { order = order.toMutableList().apply { add(i - 1, removeAt(i)) }; emit() }.padding(6.dp))
                    Icon(Icons.Filled.KeyboardArrowDown, "Move down", Modifier.clickable(enabled = i < order.lastIndex) { order = order.toMutableList().apply { add(i + 1, removeAt(i)) }; emit() }.padding(6.dp))
                    Switch(key in enabled, { on -> enabled = if (on) enabled + key else enabled - key; emit() })
                }
            }
        }
    }
}

private val shareBackgrounds = listOf(R.drawable.share_neon_run, R.drawable.share_alpine_dawn, R.drawable.share_abstract_pulse, R.drawable.share_dawn_ridgeline, R.drawable.share_kinetic_topo, R.drawable.share_neon_circuit)

/** AtriaShareCard: render a story-sized card to a bitmap and hand it to the Android share sheet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShareCardSheet(today: DailyMetricsEntity?, onDismiss: () -> Unit) {
    val s = LocalSurfaces.current
    val ctx = LocalContext.current
    var bg by remember { mutableIntStateOf(0) }
    var photo by remember { mutableStateOf<Uri?>(null) }
    // PHPickerViewController → Android Photo Picker (no storage permission needed).
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> if (uri != null) photo = uri }
    val bitmap = remember(bg, photo, today) { renderShareCard(ctx, today, photo, shareBackgrounds[bg]) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = s.card) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Image(bitmap.asImageBitmap(), "Share card preview", Modifier.height(360.dp).aspectRatio(9f / 16f).clip(RoundedCornerShape(20.dp)), contentScale = ContentScale.Crop)
            Spacer(Modifier.height(10.dp))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                itemsIndexed(shareBackgrounds) { i, res ->
                    Image(androidx.compose.ui.res.painterResource(res), null, Modifier.size(56.dp).clip(RoundedCornerShape(12.dp)).clickable { bg = i; photo = null }, contentScale = ContentScale.Crop)
                }
            }
            TextButton({ picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) { Text("Use my photo") }
            PillButton("Share", Modifier.fillMaxWidth(), color = AtriaColors.strain) {
                val dir = File(ctx.cacheDir, "share").apply { mkdirs() }
                val f = File(dir, "atria-today.png")
                f.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)
                ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), "Share"))
            }
        }
    }
}

fun renderShareCard(ctx: android.content.Context, d: DailyMetricsEntity?, photo: Uri?, bgRes: Int): Bitmap {
    val w = 1080; val h = 1920
    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val source = photo?.let { runCatching { ctx.contentResolver.openInputStream(it)?.use(BitmapFactory::decodeStream) }.getOrNull() }
        ?: BitmapFactory.decodeResource(ctx.resources, bgRes)
    source?.let {
        val scale = maxOf(w / it.width.toFloat(), h / it.height.toFloat())
        val sw = (w / scale).toInt(); val sh = (h / scale).toInt()
        val sx = (it.width - sw) / 2; val sy = (it.height - sh) / 2
        c.drawBitmap(it, Rect(sx, sy, sx + sw, sy + sh), Rect(0, 0, w, h), null)
    }
    c.drawRect(0f, 0f, w.toFloat(), h.toFloat(), Paint().apply { shader = LinearGradient(0f, h * 0.35f, 0f, h.toFloat(), 0x00000000, 0xE6000000.toInt(), Shader.TileMode.CLAMP) })
    val big = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; textSize = 150f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD) }
    val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xCCFFFFFF.toInt(); textSize = 44f; letterSpacing = 0.12f }
    val brand = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; textSize = 56f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD) }
    var y = h - 760f
    listOf(
        Triple("RECOVERY", d?.recovery?.let { "$it%" } ?: "--", AtriaColors.recoveryColor(d?.recovery).toArgb()),
        Triple("STRAIN", d?.strain?.let { "%.1f".format(it) } ?: "--", AtriaColors.strain.toArgb()),
        Triple("SLEEP", d?.sleepHours?.let { formatHours(it) } ?: "--", AtriaColors.sleep.toArgb()),
    ).forEach { (k, v, col) ->
        c.drawRoundRect(RectF(80f, y + 30f, 92f, y + 190f), 6f, 6f, Paint().apply { color = col })
        c.drawText(k, 120f, y + 70f, label)
        c.drawText(v, 120f, y + 200f, big)
        y += 230f
    }
    c.drawText("ATRIA", 80f, 160f, brand)
    c.drawText(LocalDate.now().toString(), 80f, 220f, label)
    return bmp
}

@Suppress("unused") private fun nowTime() = LocalTime.now()
