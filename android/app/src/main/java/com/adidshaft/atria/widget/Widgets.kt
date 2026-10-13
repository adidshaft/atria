package com.adidshaft.atria.widget

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.layout.height
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.adidshaft.atria.AtriaApp
import com.adidshaft.atria.MainActivity
import com.adidshaft.atria.analytics.formatHours
import com.adidshaft.atria.ble.LinkStatus

private val Bg = ColorProvider(Color(0xFF0B0F17))
private val Fg = ColorProvider(Color.White)
private val Dim = ColorProvider(Color(0xFF8A93A6))
private val RecoveryGreen = ColorProvider(Color(0xFF3DDC84))
private val StrainBlue = ColorProvider(Color(0xFF4C8DFF))
private val SleepPurple = ColorProvider(Color(0xFF7B6CF0))
private val HeartRed = ColorProvider(Color(0xFFFF5A5F))

data class WidgetSnapshot(val recovery: Int?, val strain: Double?, val sleepHours: Double?, val heartRate: Int?, val battery: Int?, val connected: Boolean, val steps: Int?, val hrv: Double? = null)

/** WidgetSnapshot.swift equivalent: one read for every widget. */
suspend fun loadSnapshot(): WidgetSnapshot {
    val g = AtriaApp.graph
    val d = g.repo.db.daily().get(g.repo.today().toEpochDay())
    val live = g.strap.state.value
    val hr = if (live.hrFresh) live.heartRate else g.repo.db.samples().latestHr()?.takeIf { System.currentTimeMillis() - it.t < 10 * 60_000 }?.bpm
    val items = g.repo.settings.current().glanceItems
    return WidgetSnapshot(d?.recovery, d?.strain, d?.sleepHours, hr, live.battery.takeIf { "battery" in items }, live.status == LinkStatus.CONNECTED, d?.steps.takeIf { "steps" in items }, d?.hrv)
}

private fun openApp(context: Context, link: String) = actionStartActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link), context, MainActivity::class.java))

/** Today rings widget (small/medium families). */
class TodayWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val s = loadSnapshot()
        provideContent { TodayContent(context, s) }
    }
}

@Composable
private fun TodayContent(context: Context, s: WidgetSnapshot) {
    Column(
        modifier = GlanceModifier.fillMaxSize().background(Bg).cornerRadius(24.dp).padding(14.dp).clickable(openApp(context, "atria://today")),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("ATRIA", style = TextStyle(color = Dim, fontSize = 10.sp, fontWeight = FontWeight.Bold))
        Spacer(GlanceModifier.height(6.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Metric("Recovery", s.recovery?.let { "$it%" } ?: "--", RecoveryGreen)
            Spacer(GlanceModifier.width(12.dp))
            Metric("Strain", s.strain?.let { "%.1f".format(it) } ?: "--", StrainBlue)
            Spacer(GlanceModifier.width(12.dp))
            Metric("Sleep", s.sleepHours?.let { formatHours(it) } ?: "--", SleepPurple)
        }
        Spacer(GlanceModifier.height(6.dp))
        Text(
            (s.heartRate?.let { "♥ $it bpm" } ?: if (s.connected) "♥ --" else "Strap offline") + (s.battery?.let { "  ·  $it%" } ?: ""),
            style = TextStyle(color = HeartRed, fontSize = 12.sp),
        )
    }
}

@Composable
private fun Metric(label: String, value: String, color: ColorProvider) {
    Column {
        Text(value, style = TextStyle(color = color, fontSize = 18.sp, fontWeight = FontWeight.Bold))
        Text(label, style = TextStyle(color = Dim, fontSize = 10.sp))
    }
}

/** Live heart-rate widget (lock-screen/AOD-style compact family). */
class HeartRateWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val s = loadSnapshot()
        provideContent {
            Column(
                modifier = GlanceModifier.fillMaxSize().background(Bg).cornerRadius(24.dp).padding(12.dp).clickable(openApp(context, "atria://vitals")),
                verticalAlignment = Alignment.CenterVertically, horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("♥", style = TextStyle(color = HeartRed, fontSize = 16.sp))
                Text(s.heartRate?.toString() ?: "--", style = TextStyle(color = Fg, fontSize = 30.sp, fontWeight = FontWeight.Bold))
                Text("bpm", style = TextStyle(color = Dim, fontSize = 11.sp))
                s.steps?.takeIf { it > 0 }?.let { Text("$it steps", style = TextStyle(color = Dim, fontSize = 10.sp)) }
            }
        }
    }
}

/** Single-metric widgets (iOS AtriaStepsWidget / AtriaStrainWidget / AtriaHRVWidget). */
abstract class SingleMetricWidget(private val label: String, private val color: ColorProvider, private val link: String, private val value: (WidgetSnapshot) -> String?) : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val s = loadSnapshot()
        provideContent {
            Column(
                modifier = GlanceModifier.fillMaxSize().background(Bg).cornerRadius(24.dp).padding(12.dp).clickable(openApp(context, link)),
                verticalAlignment = Alignment.CenterVertically, horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(label.uppercase(), style = TextStyle(color = Dim, fontSize = 10.sp, fontWeight = FontWeight.Bold))
                Text(value(s) ?: "--", style = TextStyle(color = color, fontSize = 28.sp, fontWeight = FontWeight.Bold))
            }
        }
    }
}

class StepsWidget : SingleMetricWidget("Steps", ColorProvider(Color(0xFFF2994A)), "atria://today", { it.steps?.toString() })
class StrainWidget : SingleMetricWidget("Strain", StrainBlue, "atria://today", { it.strain?.let { v -> "%.1f".format(v) } })
class HrvWidget : SingleMetricWidget("HRV", ColorProvider(Color(0xFF64D2FF)), "atria://vitals", { it.hrv?.let { v -> "${v.toInt()} ms" } })

class StepsWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = StepsWidget() }
class StrainWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = StrainWidget() }
class HrvWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = HrvWidget() }

class TodayWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = TodayWidget() }
class HeartRateWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = HeartRateWidget() }

object WidgetUpdater {
    suspend fun updateAll(context: Context) {
        runCatching { TodayWidget().updateAll(context) }
        runCatching { HeartRateWidget().updateAll(context) }
        runCatching { StepsWidget().updateAll(context) }
        runCatching { StrainWidget().updateAll(context) }
        runCatching { HrvWidget().updateAll(context) }
    }
}
