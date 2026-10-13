package com.adidshaft.atria.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.adidshaft.atria.analytics.SleepStage
import com.adidshaft.atria.analytics.StageSegment
import com.adidshaft.atria.ui.theme.AtriaColors
import com.adidshaft.atria.ui.theme.LocalSurfaces
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

data class ChartPoint(val t: Long, val v: Double)
data class Band(val from: Double, val to: Double, val color: Color)

private val hourFmt = DateTimeFormatter.ofPattern("h a")

/** Value → colour gradient used for HR (cool at rest, hot at effort). */
fun heatColor(fraction: Float): Color {
    val stops = listOf(AtriaColors.hrv, AtriaColors.calm, AtriaColors.recoveryFair, AtriaColors.stress, AtriaColors.heart)
    val f = fraction.coerceIn(0f, 1f) * (stops.size - 1)
    val i = floor(f).toInt().coerceAtMost(stops.size - 2)
    return androidx.compose.ui.graphics.lerp(stops[i], stops[i + 1], f - i)
}

/**
 * Time-series line with real gaps (no interpolation across missing telemetry —
 * the iOS "HR gap segmentation" honesty rule), optional background bands,
 * heat-coloured stroke, area fill and a drag inspector.
 */
@Composable
fun TimeSeriesChart(
    points: List<ChartPoint>,
    modifier: Modifier = Modifier,
    height: Dp = 220.dp,
    color: Color? = null,
    gapMs: Long = 5 * 60_000L,
    yMin: Double? = null,
    yMax: Double? = null,
    startMs: Long? = null,
    endMs: Long? = null,
    bands: List<Band> = emptyList(),
    unit: String = "",
    valueFormat: (Double) -> String = { "%.0f".format(it) },
    description: String = "Chart",
) {
    val s = LocalSurfaces.current
    val measurer = rememberTextMeasurer()
    var inspect by remember { mutableStateOf<Float?>(null) }
    if (points.size < 2) {
        Box(modifier.fillMaxWidth().height(height), contentAlignment = Alignment.Center) {
            Text("No data in this window yet", color = s.textTertiary, style = MaterialTheme.typography.bodyMedium)
        }
        return
    }
    val t0 = startMs ?: points.first().t
    val t1 = max(endMs ?: points.last().t, t0 + 1)
    val lo = yMin ?: floor(points.minOf { it.v } / 10) * 10 - 5
    val hi = yMax ?: ceil(points.maxOf { it.v } / 10) * 10 + 5
    Column(modifier.semantics { contentDescription = "$description, ${points.size} points, range ${valueFormat(points.minOf { it.v })} to ${valueFormat(points.maxOf { it.v })} $unit" }) {
        Box {
            Canvas(
                Modifier.fillMaxWidth().height(height)
                    // Horizontal-only so vertical swipes still scroll the page.
                    .pointerInput(points) { detectHorizontalDragGestures(onDragEnd = { inspect = null }, onDragCancel = { inspect = null }) { c, _ -> inspect = c.position.x } }
                    .pointerInput(points) { detectTapGestures { inspect = if (inspect == null) it.x else null } },
            ) {
                val axisW = 34.dp.toPx()
                val w = size.width - axisW
                val h = size.height - 18.dp.toPx()
                fun x(t: Long) = ((t - t0).toFloat() / (t1 - t0)) * w
                fun y(v: Double) = h - (((v - lo) / (hi - lo)).toFloat().coerceIn(0f, 1f) * h)
                bands.forEach { b -> drawRect(b.color.copy(alpha = 0.10f), Offset(0f, y(b.to)), Size(w, y(b.from) - y(b.to))) }
                // grid + y labels
                val step = niceStep(hi - lo)
                var g = ceil(lo / step) * step
                while (g <= hi) {
                    val yy = y(g)
                    drawLine(s.stroke, Offset(0f, yy), Offset(w, yy), 1f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f)))
                    label(measurer, valueFormat(g), Offset(w + 6.dp.toPx(), yy - 7.dp.toPx()), s.textTertiary)
                    g += step
                }
                // x labels: hours for short spans, dates for multi-day spans
                val zone = ZoneId.systemDefault()
                val spanH = (t1 - t0) / 3_600_000.0
                if (spanH > 48) {
                    val dayFmt = DateTimeFormatter.ofPattern("MMM d")
                    val everyD = when { spanH <= 24 * 8 -> 1; spanH <= 24 * 16 -> 3; else -> 7 }
                    var day = Instant.ofEpochMilli(t0).atZone(zone).toLocalDate().plusDays(1)
                    while (true) {
                        val tick = day.atStartOfDay(zone).toInstant().toEpochMilli()
                        if (tick >= t1) break
                        if (day.toEpochDay() % everyD == 0L) {
                            val xx = x(tick)
                            drawLine(s.stroke, Offset(xx, 0f), Offset(xx, h), 1f)
                            label(measurer, day.format(dayFmt), Offset(xx + 3.dp.toPx(), h + 2.dp.toPx()), s.textTertiary)
                        }
                        day = day.plusDays(1)
                    }
                } else {
                    val everyH = when { spanH <= 3 -> 1; spanH <= 8 -> 2; else -> 6 }
                    var tick = (t0 / 3_600_000 + 1) * 3_600_000
                    while (tick < t1) {
                        val hour = Instant.ofEpochMilli(tick).atZone(zone).hour
                        if (hour % everyH == 0) {
                            val xx = x(tick)
                            drawLine(s.stroke, Offset(xx, 0f), Offset(xx, h), 1f)
                            label(measurer, Instant.ofEpochMilli(tick).atZone(zone).format(hourFmt).lowercase(), Offset(xx + 3.dp.toPx(), h + 2.dp.toPx()), s.textTertiary)
                        }
                        tick += 3_600_000
                    }
                }
                // segments split at gaps
                val segments = ArrayList<MutableList<ChartPoint>>()
                for (p in points) {
                    val last = segments.lastOrNull()?.lastOrNull()
                    if (last == null || p.t - last.t > gapMs) segments += mutableListOf(p) else segments.last() += p
                }
                for (seg in segments) {
                    if (seg.size == 1) { drawCircle(color ?: heatColor(((seg[0].v - lo) / (hi - lo)).toFloat()), 3.dp.toPx(), Offset(x(seg[0].t), y(seg[0].v))); continue }
                    val line = Path().apply { moveTo(x(seg[0].t), y(seg[0].v)); seg.drop(1).forEach { lineTo(x(it.t), y(it.v)) } }
                    val area = Path().apply { addPath(line); lineTo(x(seg.last().t), h); lineTo(x(seg[0].t), h); close() }
                    val brush = if (color != null) Brush.verticalGradient(listOf(color, color)) else Brush.verticalGradient(listOf(AtriaColors.heart, AtriaColors.recoveryFair, AtriaColors.calm, AtriaColors.hrv), 0f, h)
                    drawPath(area, Brush.verticalGradient(listOf((color ?: AtriaColors.calm).copy(alpha = 0.25f), Color.Transparent), 0f, h))
                    drawPath(line, brush, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                }
                inspect?.let { ix ->
                    val t = t0 + ((ix / w).coerceIn(0f, 1f) * (t1 - t0)).toLong()
                    val nearest = points.minByOrNull { kotlin.math.abs(it.t - t) } ?: return@let
                    val px = x(nearest.t); val py = y(nearest.v)
                    drawLine(s.textSecondary, Offset(px, 0f), Offset(px, h), 1.5f)
                    drawCircle(Color.White, 5.dp.toPx(), Offset(px, py))
                    val txt = "${valueFormat(nearest.v)} $unit · ${Instant.ofEpochMilli(nearest.t).atZone(zone).format(DateTimeFormatter.ofPattern("h:mm a")).lowercase()}"
                    val layout = measurer.measure(txt, TextStyle(fontSize = 12.sp, color = s.textPrimary))
                    val bx = (px - layout.size.width / 2).coerceIn(0f, w - layout.size.width)
                    drawRoundRect(s.raised, Offset(bx - 6, 0f), Size(layout.size.width + 12f, layout.size.height + 8f), CornerRadius(12f))
                    drawText(layout, topLeft = Offset(bx, 4f))
                }
            }
        }
    }
}

private fun niceStep(range: Double): Double = when {
    range <= 3 -> 0.5
    range <= 8 -> 1.0
    range <= 30 -> 5.0
    range <= 80 -> 20.0
    range <= 200 -> 40.0
    else -> 100.0
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.label(m: TextMeasurer, text: String, at: Offset, color: Color) {
    drawText(m, text, at, TextStyle(fontSize = 10.sp, color = color))
}

data class BarDatum(val label: String, val value: Double?, val color: Color? = null)

/** Seven-day style bars with optional target line; null bars render as an honest "no data" stub. */
@Composable
fun BarChart(
    data: List<BarDatum>,
    color: Color,
    modifier: Modifier = Modifier,
    height: Dp = 160.dp,
    target: Double? = null,
    maxValue: Double? = null,
    valueFormat: (Double) -> String = { "%.0f".format(it) },
    description: String = "Bar chart",
) {
    val s = LocalSurfaces.current
    val measurer = rememberTextMeasurer()
    val top = maxValue ?: max(data.mapNotNull { it.value }.maxOrNull() ?: 1.0, target ?: 0.0) * 1.15
    Canvas(modifier.fillMaxWidth().height(height).semantics { contentDescription = description + ": " + data.joinToString { "${it.label} ${it.value?.let(valueFormat) ?: "no data"}" } }) {
        val labelH = 16.dp.toPx()
        val h = size.height - labelH - 14.dp.toPx()
        val slot = size.width / max(1, data.size)
        val barW = min(slot * 0.56f, 28.dp.toPx())
        data.forEachIndexed { i, d ->
            val cx = slot * i + slot / 2
            val v = d.value
            if (v != null && top > 0) {
                val bh = max(3f, (v / top).toFloat() * h)
                drawRoundRect(d.color ?: color, Offset(cx - barW / 2, 14.dp.toPx() + h - bh), Size(barW, bh), CornerRadius(8f))
                drawText(measurer, valueFormat(v), Offset(cx - barW / 2, 14.dp.toPx() + h - bh - 14.dp.toPx()), TextStyle(fontSize = 9.sp, color = s.textSecondary))
            } else {
                drawRoundRect(s.inset, Offset(cx - barW / 2, 14.dp.toPx() + h - 3f), Size(barW, 3f), CornerRadius(2f))
            }
            drawText(measurer, d.label, Offset(cx - barW / 2, size.height - labelH), TextStyle(fontSize = 10.sp, color = s.textTertiary))
        }
        target?.let { tg ->
            val ty = 14.dp.toPx() + h - (tg / top).toFloat() * h
            drawLine(s.textSecondary, Offset(0f, ty), Offset(size.width, ty), 1.5f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f)))
        }
    }
}

fun stageColor(stage: SleepStage) = when (stage) {
    SleepStage.AWAKE -> AtriaColors.awake
    SleepStage.REM -> AtriaColors.rem
    SleepStage.LIGHT -> AtriaColors.light
    SleepStage.DEEP -> AtriaColors.deep
}

/** Four-lane hypnogram (Awake / REM / Light / Deep) on the real time axis. */
@Composable
fun Hypnogram(segments: List<StageSegment>, startMs: Long, endMs: Long, modifier: Modifier = Modifier) {
    val s = LocalSurfaces.current
    val measurer = rememberTextMeasurer()
    val lanes = listOf(SleepStage.AWAKE, SleepStage.REM, SleepStage.LIGHT, SleepStage.DEEP)
    Canvas(modifier.fillMaxWidth().height(130.dp).semantics { contentDescription = "Sleep stages hypnogram, estimate" }) {
        val labelW = 48.dp.toPx()
        val laneH = 18.dp.toPx(); val gap = 6.dp.toPx()
        val w = size.width - labelW
        lanes.forEachIndexed { i, st ->
            val y = i * (laneH + gap)
            drawText(measurer, st.label, Offset(0f, y + 1.dp.toPx()), TextStyle(fontSize = 11.sp, color = s.textSecondary))
            drawRoundRect(s.inset, Offset(labelW, y), Size(w, laneH), CornerRadius(6f))
        }
        val span = max(1L, endMs - startMs).toFloat()
        segments.forEach { seg ->
            val lane = lanes.indexOf(seg.stage)
            val x0 = labelW + ((seg.startMs - startMs) / span).coerceIn(0f, 1f) * w
            val x1 = labelW + ((seg.endMs - startMs) / span).coerceIn(0f, 1f) * w
            drawRoundRect(stageColor(seg.stage), Offset(x0, lane * (laneH + gap)), Size(max(2f, x1 - x0), laneH), CornerRadius(6f))
        }
        val fmt = DateTimeFormatter.ofPattern("h:mm a")
        val z = ZoneId.systemDefault()
        val y = 4 * (laneH + gap)
        drawText(measurer, Instant.ofEpochMilli(startMs).atZone(z).format(fmt).lowercase(), Offset(labelW, y), TextStyle(fontSize = 10.sp, color = s.textTertiary))
        val endLabel = measurer.measure(Instant.ofEpochMilli(endMs).atZone(z).format(fmt).lowercase(), TextStyle(fontSize = 10.sp, color = s.textTertiary))
        drawText(endLabel, topLeft = Offset(size.width - endLabel.size.width, y))
    }
}

/** Horizontal HR-zone distribution bars (Z0–Z5). */
@Composable
fun ZoneBars(seconds: List<Double>, modifier: Modifier = Modifier) {
    val s = LocalSurfaces.current
    val total = seconds.sum().coerceAtLeast(1.0)
    Column(modifier) {
        seconds.forEachIndexed { i, sec ->
            Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Z$i", style = MaterialTheme.typography.labelMedium, color = s.textSecondary, modifier = Modifier.width(28.dp))
                ProgressBar((sec / total).toFloat(), AtriaColors.zones[i], Modifier.weight(1f), height = 8.dp)
                Spacer(Modifier.width(8.dp))
                Text("${(sec / 60).toInt()}m", style = MaterialTheme.typography.labelMedium, color = s.textSecondary, modifier = Modifier.width(44.dp))
            }
        }
    }
}

/** Live workout zone strip (Z0–Z5 segments with the current zone highlighted). */
@Composable
fun ZoneStrip(current: Int, modifier: Modifier = Modifier) {
    val s = LocalSurfaces.current
    Row(modifier.fillMaxWidth()) {
        (0..5).forEach { i ->
            Column(Modifier.weight(1f).padding(horizontal = 3.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Canvas(Modifier.fillMaxWidth().height(if (i == current) 18.dp else 10.dp)) {
                    drawRoundRect(AtriaColors.zones[i].copy(alpha = if (i == current) 1f else 0.35f), cornerRadius = CornerRadius(size.height / 2))
                }
                Spacer(Modifier.height(6.dp))
                Text("Z$i", style = MaterialTheme.typography.labelMedium, color = if (i == current) s.textPrimary else s.textTertiary)
            }
        }
    }
}
