package top.jinso.tacit.ui.components

import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.ui.sourceName
import top.jinso.tacit.ui.tacitColors

@Composable
internal fun SourceIcon(source: String, size: Dp = 16.dp) {
    Icon(when (source) {
        Sources.AUDIO, "mac.audio" -> Icons.Outlined.Mic
        "claude_code.session" -> Icons.Outlined.AutoAwesome
        "codex.session" -> Icons.Outlined.Code
        "mac.wechat" -> Icons.Outlined.ChatBubbleOutline
        "mac.browser" -> Icons.Outlined.Language
        "mac.screen", "mac.app" -> Icons.Outlined.Computer
        Sources.NOTE, Sources.CORRECTION -> Icons.Outlined.Edit
        else -> Icons.Outlined.Description
    }, sourceName(source), Modifier.size(size), tint = tacitColors.muted)
}
