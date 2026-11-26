package top.jinso.tacit.ui.components

import top.jinso.tacit.ui.uiStrings
import top.jinso.tacit.R
import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.ui.uiFormat
import androidx.compose.animation.Crossfade
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import top.jinso.tacit.ui.DelayedAppearance
import top.jinso.tacit.ui.ExpandChevron
import top.jinso.tacit.ui.Motion
import top.jinso.tacit.ui.tacitColors

@Composable
internal fun GroupCard(content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = tacitColors.raised,
        shape = MaterialTheme.shapes.medium,
        border = androidx.compose.foundation.BorderStroke(1.dp, tacitColors.line),
    ) { Column(content = content) }
}

@Composable
internal fun GroupDivider() = HorizontalDivider(color = tacitColors.line)

@Composable
internal fun Caption(text: String, modifier: Modifier = Modifier, color: Color = tacitColors.muted) {
    Text(text, modifier, style = MaterialTheme.typography.bodySmall, color = color)
}

@Composable
internal fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier, style = MaterialTheme.typography.bodySmall,
        fontWeight = FontWeight.Medium, color = tacitColors.muted)
}

@Composable
internal fun SettingsRow(
    title: String,
    status: String? = null,
    problem: Boolean = false,
    icon: ImageVector? = null,
    value: String? = null,
    onClick: (() -> Unit)? = null,
    expanded: Boolean? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val english = uiFormat().lang == AppLang.EN
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Box(Modifier.size(32.dp).background(tacitColors.fill, RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
                Icon(icon, null, Modifier.size(18.dp), tint = tacitColors.ink)
            }
        } else leading?.invoke()
        Column(Modifier.weight(1f).padding(vertical = 4.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
            status?.let { Caption(it, color = if (problem) tacitColors.attention else tacitColors.muted) }
        }
        if (value != null) {
            Text(value, Modifier.widthIn(max = 108.dp), style = MaterialTheme.typography.bodySmall,
                color = if (problem) tacitColors.attention else tacitColors.muted,
                maxLines = if (english) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis)
        }
        if (trailing != null) trailing()
        else if (onClick != null) {
            if (expanded != null) ExpandChevron(expanded, tacitColors.muted)
            else Icon(Icons.Outlined.ChevronRight, null, Modifier.size(16.dp), tint = tacitColors.muted)
        }
    }
}

@Composable
internal fun NoticeRow(text: String, onClick: () -> Unit) {
    Surface(color = tacitColors.fill, shape = MaterialTheme.shapes.medium, onClick = onClick) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.ErrorOutline, null, Modifier.size(16.dp), tint = tacitColors.attention)
            Text(text, Modifier.weight(1f), color = tacitColors.ink)
            Icon(Icons.Outlined.ChevronRight, null, Modifier.size(16.dp), tint = tacitColors.muted)
        }
    }
}

internal enum class Mark { OK, PROBLEM, UNKNOWN }

@Composable
internal fun StatusMark(mark: Mark) = Crossfade(mark, animationSpec = Motion.quick(), label = "status-mark") { mark ->
    when (mark) {
        Mark.OK -> Icon(Icons.Outlined.Check, null, Modifier.size(18.dp), tint = tacitColors.accent)
        Mark.PROBLEM -> Icon(Icons.Outlined.ErrorOutline, null, Modifier.size(18.dp), tint = tacitColors.attention)
        Mark.UNKNOWN -> {
            val color = tacitColors.faint
            Canvas(Modifier.size(18.dp)) {
                drawCircle(color, radius = 7.dp.toPx(), style = Stroke(
                    width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())),
                ))
            }
        }
    }
}

@Composable
internal fun PrimaryButton(label: String, onClick: () -> Unit, enabled: Boolean = true) {
    Button(
        onClick = onClick, enabled = enabled, shape = MaterialTheme.shapes.small,
        colors = ButtonDefaults.buttonColors(containerColor = tacitColors.accent, contentColor = tacitColors.onAccent),
    ) { Text(label) }
}

@Composable
internal fun TonalButton(
    label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true,
) {
    Surface(
        onClick = onClick, modifier = modifier.semantics { role = Role.Button }, enabled = enabled,
        shape = MaterialTheme.shapes.small, color = tacitColors.fill,
        contentColor = if (enabled) tacitColors.ink else tacitColors.muted.copy(alpha = .6f),
    ) {
        Box(
            Modifier.heightIn(min = 36.dp).padding(horizontal = 12.dp, vertical = 6.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(label, style = MaterialTheme.typography.labelLarge)
        }
    }
}

@Composable
internal fun TextAction(
    label: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    color: Color = tacitColors.muted,
    icon: ImageVector? = null,
    weight: FontWeight = FontWeight.Medium,
) {
    TextButton(onClick, enabled = enabled, shape = MaterialTheme.shapes.small,
        colors = ButtonDefaults.textButtonColors(contentColor = color)) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(label, fontWeight = weight)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PageBar(title: String, onBack: () -> Unit, close: Boolean = false, actions: @Composable RowScope.() -> Unit = {}) {
    val strings = uiStrings()
    TopAppBar(
        title = {
            Crossfade(title, animationSpec = Motion.quick(), label = "page-title") {
                Text(it, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            }
        },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(if (close) Icons.Outlined.Close else Icons.AutoMirrored.Outlined.ArrowBack, if (close) strings.text(R.string.close) else strings.text(R.string.back))
            }
        },
        actions = actions,
        colors = TopAppBarDefaults.topAppBarColors(containerColor = tacitColors.paper),
    )
}

@Composable
internal fun PrivacyLock() {
    val strings = uiStrings()
    Icon(Icons.Outlined.Lock, strings.text(R.string.private_record), Modifier.size(16.dp), tint = tacitColors.muted)
}

/** Thin accent progress line; the Material default is a heavy ink bar on this palette. */
@Composable
internal fun ProgressLine(modifier: Modifier = Modifier) {
    // Only a wait the user would notice shows a line; quick local reads show nothing.
    DelayedAppearance(modifier.fillMaxWidth()) {
        LinearProgressIndicator(Modifier.fillMaxWidth(), color = tacitColors.accent, trackColor = tacitColors.fill)
    }
}
