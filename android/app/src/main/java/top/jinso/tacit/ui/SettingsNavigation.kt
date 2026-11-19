package top.jinso.tacit.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** Internal destinations accepted by SettingsPage.initialSource, alongside source IDs. */
internal object SettingsRoutes {
    const val SOURCES = "settings.sources"
    const val SPEECH = "settings.speech"
    const val PRIVACY = "settings.privacy"
    const val RETENTION = "settings.retention"
    const val BACKGROUND = "settings.background"
    const val SHORTCUT = "settings.shortcut"

    fun parent(route: String?): String? = if (route == RETENTION) PRIVACY else null
    fun title(route: String?): String? = when (route) {
        SOURCES -> "数据源"
        SPEECH -> "语音转写"
        PRIVACY -> "隐私与存储"
        RETENTION -> "录音保留与清理"
        BACKGROUND -> "后台运行"
        SHORTCUT -> "快捷补写"
        else -> null
    }
}

@Composable internal fun SettingsNavigationRow(title: String, description: String? = null, onClick: () -> Unit) {
    Column {
        Row(Modifier.fillMaxWidth().clickable(onClick=onClick).padding(vertical=12.dp), verticalAlignment=Alignment.CenterVertically, horizontalArrangement=Arrangement.spacedBy(12.dp)) {
            Column(Modifier.weight(1f), verticalArrangement=Arrangement.spacedBy(4.dp)) {
                Text(title)
                description?.let { Text(it,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            Icon(Icons.Outlined.ChevronRight,null,tint=MaterialTheme.colorScheme.onSurfaceVariant)
        }
        HorizontalDivider()
    }
}
