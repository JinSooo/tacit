package top.jinso.tacit.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal class TacitPalette(
    val paper: Color, val raised: Color, val ink: Color, val readingBody: Color,
    val muted: Color, val faint: Color, val line: Color, val fill: Color,
    val accent: Color, val onAccent: Color, val accentContainer: Color, val attention: Color,
)

private val light = TacitPalette(
    Color(0xFFFBFAF7), Color.White, Color(0xFF1C1B1A), Color(0xFF45413C),
    Color(0xFF6E6860), Color(0xFFA39D94), Color(0xFFE7E3DC), Color(0xFF1C1B1A).copy(alpha = .05f),
    Color(0xFF3B7468), Color.White, Color(0xFFE5EFEB), Color(0xFF9D2933),
)
private val dark = TacitPalette(
    Color(0xFF181716), Color(0xFF211F1D), Color(0xFFF2EFEA), Color(0xFFCCC7C0),
    Color(0xFFA8A197), Color(0xFF5E5953), Color(0xFF2F2C29), Color(0xFFF2EFEA).copy(alpha = .06f),
    Color(0xFF7DB8A9), Color(0xFF181716), Color(0xFF274F46), Color(0xFFE58A8F),
)
private val localPalette = staticCompositionLocalOf { light }
internal val tacitColors: TacitPalette @Composable get() = localPalette.current

private val caption = TextStyle(fontSize = 12.sp, lineHeight = 18.sp, fontFeatureSettings = "tnum")
private val body = caption.copy(fontSize = 15.sp, lineHeight = 24.sp)
private val title = body.copy(fontSize = 18.sp, lineHeight = 26.sp, fontWeight = FontWeight.Medium)
private val heading = title.copy(fontSize = 24.sp, lineHeight = 32.sp, fontWeight = FontWeight.SemiBold)
private val tacitTypography = Typography(
    displayLarge = heading, displayMedium = heading, displaySmall = heading,
    headlineLarge = heading, headlineMedium = heading, headlineSmall = heading,
    titleLarge = title, titleMedium = title, titleSmall = body.copy(fontWeight = FontWeight.Medium),
    bodyLarge = body, bodyMedium = body, bodySmall = caption,
    labelLarge = body.copy(fontWeight = FontWeight.Medium), labelMedium = caption, labelSmall = caption,
)
private val tacitShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp), small = RoundedCornerShape(6.dp),
    medium = RoundedCornerShape(10.dp), large = RoundedCornerShape(14.dp),
    extraLarge = RoundedCornerShape(14.dp),
)

@Composable
fun TacitTheme(content: @Composable () -> Unit) {
    val isDark = isSystemInDarkTheme()
    val palette = if (isDark) dark else light
    val base = if (isDark) darkColorScheme() else lightColorScheme()
    val colors = with(palette) {
        base.copy(
            primary = ink, onPrimary = paper, primaryContainer = fill, onPrimaryContainer = ink,
            secondary = ink, onSecondary = paper, secondaryContainer = fill, onSecondaryContainer = ink,
            background = paper, onBackground = ink, surface = paper, onSurface = ink,
            surfaceVariant = raised, onSurfaceVariant = muted, outline = faint, outlineVariant = line,
            surfaceContainerLowest = paper, surfaceContainerLow = raised, surfaceContainer = paper,
            surfaceContainerHigh = raised, surfaceContainerHighest = raised, surfaceTint = paper, error = attention,
            inverseSurface = ink, inverseOnSurface = paper, inversePrimary = onAccent,
        )
    }
    CompositionLocalProvider(localPalette provides palette) {
        MaterialTheme(colorScheme = colors, typography = tacitTypography, shapes = tacitShapes, content = content)
    }
}
