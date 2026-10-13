package com.adidshaft.atria.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** AtriaDesignTokens.Radius / Spacing. */
object Radius { val chip = 12.dp; val inset = 18.dp; val tile = 20.dp; val card = 28.dp; val hero = 32.dp }
object Spacing { val xs = 4.dp; val sm = 8.dp; val md = 12.dp; val lg = 16.dp; val xl = 20.dp; val xxl = 28.dp }

/**
 * Hue only for data/state (2026-10-03 colour rule); surfaces stay neutral.
 * Stage hues from the iOS hypnogram: Awake #FFB340, REM #64D2FF, Light #4C8DFF, Deep #7B6CF0.
 */
object AtriaColors {
    val recovery = Color(0xFF3DDC84)
    val recoveryFair = Color(0xFFF2C94C)
    val recoveryLow = Color(0xFFFF5A5F)
    val strain = Color(0xFF4C8DFF)
    val sleep = Color(0xFF7B6CF0)
    val heart = Color(0xFFFF5A5F)
    val stress = Color(0xFFFF9F0A)
    val steps = Color(0xFFF2994A)
    val hrv = Color(0xFF64D2FF)
    val calm = Color(0xFF30D158)
    val awake = Color(0xFFFFB340)
    val rem = Color(0xFF64D2FF)
    val light = Color(0xFF4C8DFF)
    val deep = Color(0xFF7B6CF0)
    val zones = listOf(Color(0xFF8E8E93), Color(0xFF4C8DFF), Color(0xFF30D158), Color(0xFFF2C94C), Color(0xFFFF9F0A), Color(0xFFFF453A))
    val batteryGood = Color(0xFF2F5E3A)
    val teal = Color(0xFF63DAC5)
    val orange = Color(0xFFF0994A)
    val danger = Color(0xFFE5504A)

    fun recoveryColor(p: Int?) = when { p == null -> Color(0xFF8E8E93); p >= 67 -> recovery; p >= 34 -> recoveryFair; else -> recoveryLow }
}

@Immutable
data class Surfaces(val background: Color, val card: Color, val raised: Color, val inset: Color, val stroke: Color, val textPrimary: Color, val textSecondary: Color, val textTertiary: Color)

val DarkSurfaces = Surfaces(Color(0xFF000000), Color(0xFF16181C), Color(0xFF1E2126), Color(0xFF26292F), Color(0x1FFFFFFF), Color.White, Color(0xFFB3B8C2), Color(0xFF7C8290))
val LightSurfaces = Surfaces(Color(0xFFF2F2F7), Color.White, Color.White, Color(0xFFE9E9EF), Color(0x14000000), Color(0xFF0B0D12), Color(0xFF555B66), Color(0xFF8A909C))

val LocalSurfaces = staticCompositionLocalOf { DarkSurfaces }

private val Rounded = FontFamily.Default

val AtriaTypography = Typography(
    displayLarge = TextStyle(fontFamily = Rounded, fontWeight = FontWeight.Bold, fontSize = 64.sp, letterSpacing = (-1).sp),
    displayMedium = TextStyle(fontFamily = Rounded, fontWeight = FontWeight.Bold, fontSize = 44.sp, letterSpacing = (-0.5).sp),
    headlineLarge = TextStyle(fontWeight = FontWeight.Bold, fontSize = 30.sp),
    headlineMedium = TextStyle(fontWeight = FontWeight.Bold, fontSize = 24.sp),
    titleLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 20.sp),
    titleMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 17.sp),
    titleSmall = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 15.sp),
    bodyLarge = TextStyle(fontSize = 17.sp),
    bodyMedium = TextStyle(fontSize = 15.sp),
    bodySmall = TextStyle(fontSize = 13.sp),
    labelLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 15.sp),
    labelMedium = TextStyle(fontWeight = FontWeight.Medium, fontSize = 13.sp),
    labelSmall = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 11.sp, letterSpacing = 0.8.sp),
)

@Composable
fun AtriaTheme(theme: String = "system", content: @Composable () -> Unit) {
    val dark = when (theme) { "light" -> false; "dark" -> true; else -> isSystemInDarkTheme() }
    val s = if (dark) DarkSurfaces else LightSurfaces
    val scheme = if (dark) darkColorScheme(
        primary = AtriaColors.strain, secondary = AtriaColors.recovery, background = s.background, surface = s.card,
        surfaceVariant = s.inset, onBackground = s.textPrimary, onSurface = s.textPrimary, onSurfaceVariant = s.textSecondary, error = AtriaColors.danger,
    ) else lightColorScheme(
        primary = AtriaColors.strain, secondary = AtriaColors.recovery, background = s.background, surface = s.card,
        surfaceVariant = s.inset, onBackground = s.textPrimary, onSurface = s.textPrimary, onSurfaceVariant = s.textSecondary, error = AtriaColors.danger,
    )
    CompositionLocalProvider(LocalSurfaces provides s) {
        MaterialTheme(colorScheme = scheme, typography = AtriaTypography) {
            CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides s.textPrimary, content = content)
        }
    }
}
