package com.adidshaft.atria.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.Canvas
import com.adidshaft.atria.ui.theme.LocalSurfaces
import com.adidshaft.atria.ui.theme.Radius
import com.adidshaft.atria.ui.theme.Spacing

@Composable
fun AtriaCard(
    modifier: Modifier = Modifier,
    tint: Color? = null,
    onClick: (() -> Unit)? = null,
    padding: Dp = Spacing.lg,
    content: @Composable ColumnScope.() -> Unit,
) {
    val s = LocalSurfaces.current
    val shape = RoundedCornerShape(Radius.card)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(tint?.copy(alpha = 0.14f)?.let { androidx.compose.ui.graphics.lerp(s.card, it, 0.6f) } ?: s.card)
            .border(1.dp, tint?.copy(alpha = 0.35f) ?: s.stroke, shape)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(padding),
        content = content,
    )
}

@Composable
fun Eyebrow(text: String, modifier: Modifier = Modifier, color: Color = LocalSurfaces.current.textTertiary) =
    Text(text.uppercase(), modifier = modifier, style = MaterialTheme.typography.labelSmall, color = color)

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier, trailing: @Composable (RowScope.() -> Unit)? = null) {
    Row(modifier.fillMaxWidth().padding(top = Spacing.lg, bottom = Spacing.sm), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.weight(1f))
        trailing?.invoke(this)
    }
}

@Composable
fun CircleButton(icon: ImageVector, description: String, size: Dp = 52.dp, tint: Color = LocalSurfaces.current.textPrimary, onClick: () -> Unit) {
    val s = LocalSurfaces.current
    Box(
        Modifier.size(size).clip(CircleShape).background(s.raised).border(1.dp, s.stroke, CircleShape).clickable(role = Role.Button, onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, contentDescription = description, tint = tint, modifier = Modifier.size(22.dp)) }
}

@Composable
fun PillButton(
    text: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    color: Color = MaterialTheme.colorScheme.primary,
    contentColor: Color = Color.White,
    height: Dp = 56.dp,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Row(
        modifier
            .height(height)
            .clip(RoundedCornerShape(50))
            .background(if (enabled) color else color.copy(alpha = 0.35f))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 22.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        icon?.let { Icon(it, null, tint = contentColor, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)) }
        Text(text, color = contentColor, style = MaterialTheme.typography.labelLarge, maxLines = 1)
    }
}

@Composable
fun SegmentedTabs(options: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val s = LocalSurfaces.current
    Row(modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(s.card).padding(4.dp)) {
        options.forEachIndexed { i, o ->
            val sel = i == selected
            Box(
                Modifier.weight(1f).height(44.dp).clip(RoundedCornerShape(50)).background(if (sel) s.inset else Color.Transparent)
                    .clickable(role = Role.Tab) { onSelect(i) },
                contentAlignment = Alignment.Center,
            ) { Text(o, color = if (sel) s.textPrimary else s.textSecondary, style = MaterialTheme.typography.labelLarge) }
        }
    }
}

@Composable
fun StatTile(label: String, value: String, modifier: Modifier = Modifier, color: Color = LocalSurfaces.current.textPrimary, caption: String? = null, icon: ImageVector? = null, onClick: (() -> Unit)? = null) {
    val s = LocalSurfaces.current
    Column(
        modifier.clip(RoundedCornerShape(Radius.tile)).background(s.card).border(1.dp, s.stroke, RoundedCornerShape(Radius.tile))
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            icon?.let { Icon(it, null, tint = color, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)) }
            Text(label, style = MaterialTheme.typography.labelMedium, color = s.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.height(4.dp))
        Text(value, style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold), color = color, maxLines = 1)
        caption?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = s.textTertiary, maxLines = 2) }
    }
}

/** Today tri-ring (AtriaTriRing): outer strain, middle recovery, inner sleep; centre = recovery. */
@Composable
fun TriRing(
    recovery: Int?,
    strainFraction: Float,
    sleepFraction: Float,
    centerValue: String,
    centerLabel: String,
    centerCaption: String?,
    modifier: Modifier = Modifier,
    size: Dp = 280.dp,
) {
    val s = LocalSurfaces.current
    val rec by animateFloatAsState((recovery ?: 0) / 100f, tween(700), label = "rec")
    val st by animateFloatAsState(strainFraction.coerceIn(0f, 1f), tween(700), label = "strain")
    val sl by animateFloatAsState(sleepFraction.coerceIn(0f, 1f), tween(700), label = "sleep")
    val recColor = com.adidshaft.atria.ui.theme.AtriaColors.recoveryColor(recovery)
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size)) {
            val stroke = this.size.minDimension * 0.085f
            fun ring(inset: Float, fraction: Float, color: Color) {
                val d = this.size.minDimension - inset * 2
                val tl = androidx.compose.ui.geometry.Offset(inset, inset)
                val sz = androidx.compose.ui.geometry.Size(d, d)
                drawArc(color.copy(alpha = 0.18f), -90f, 360f, false, tl, sz, style = Stroke(stroke))
                drawArc(color, -90f, 360f * fraction, false, tl, sz, style = Stroke(stroke, cap = StrokeCap.Round))
            }
            ring(stroke / 2, st, com.adidshaft.atria.ui.theme.AtriaColors.strain)
            ring(stroke * 1.75f, rec, recColor)
            ring(stroke * 3.0f, sl, com.adidshaft.atria.ui.theme.AtriaColors.sleep)
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(centerValue, style = MaterialTheme.typography.displayMedium, color = s.textPrimary)
            Text(centerLabel.uppercase(), style = MaterialTheme.typography.labelSmall.copy(fontSize = 13.sp), color = s.textTertiary)
            centerCaption?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = s.textSecondary, textAlign = TextAlign.Center) }
        }
    }
}

@Composable
fun ProgressBar(fraction: Float, color: Color, modifier: Modifier = Modifier, height: Dp = 10.dp) {
    val s = LocalSurfaces.current
    Box(modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(50)).background(s.inset)) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(height).clip(RoundedCornerShape(50)).background(color))
    }
}

@Composable
fun EmptyState(title: String, body: String, modifier: Modifier = Modifier) {
    val s = LocalSurfaces.current
    Column(modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, style = MaterialTheme.typography.titleMedium, color = s.textPrimary, textAlign = TextAlign.Center)
        Spacer(Modifier.height(6.dp))
        Text(body, style = MaterialTheme.typography.bodyMedium, color = s.textSecondary, textAlign = TextAlign.Center)
    }
}

@Composable
fun KeyValueRow(key: String, value: String, modifier: Modifier = Modifier, valueColor: Color = LocalSurfaces.current.textPrimary) {
    val s = LocalSurfaces.current
    Row(modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(key, style = MaterialTheme.typography.bodyMedium, color = s.textSecondary, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold), color = valueColor)
    }
}

@Composable
fun Dot(color: Color, size: Dp = 8.dp) = Box(Modifier.size(size).clip(CircleShape).background(color))
