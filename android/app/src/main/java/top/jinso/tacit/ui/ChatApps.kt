package top.jinso.tacit.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.sources.WECHAT_PACKAGE
import top.jinso.tacit.ui.components.*

@Composable
internal fun ChatApps(app: TacitApp, resumed: Int, notify: (String) -> Unit) {
    var selected by remember { mutableStateOf(app.prefs.chatApps) }
    var installed by remember { mutableStateOf(emptyList<LauncherApp>()) }
    var choosing by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    LaunchedEffect(app, resumed) {
        selected = app.prefs.chatApps
        installed = withContext(Dispatchers.IO) { runCatching { launcherApps(app) }.getOrDefault(emptyList()) }
    }

    val names = remember(installed) { installed.associate { it.packageName to it.name } + (WECHAT_PACKAGE to "微信") }
    fun save(next: Set<String>) {
        runCatching { Sources.setChatApps(app, next) }
            .onSuccess { selected = next }
            .onFailure { notify("未能保存聊天应用，请重试") }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel("聊天应用")
        GroupCard {
            selected.sorted().forEach { packageName ->
                val name = names[packageName] ?: packageName
                SettingsRow(name, leading = { SourceIcon(Sources.NOTIFICATION, packageName, 24.dp, name) }) {
                    IconButton(onClick = { save(selected - packageName) }) { Icon(Icons.Outlined.Close, "移除$name") }
                }
                GroupDivider()
            }
            SettingsRow(if (choosing) "收起应用列表" else "添加聊天应用", expanded = choosing, onClick = { choosing = !choosing })
            if (choosing) {
                OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                    singleLine = true, label = { Text("搜索已安装的应用") })
                val options = (listOf(LauncherApp(WECHAT_PACKAGE, "微信")) + installed)
                    .distinctBy { it.packageName }
                    .filter { it.packageName !in selected && it.packageName !in app.prefs.blockedApps }
                    .filter { it.name.contains(query.trim(), ignoreCase = true) || it.packageName.contains(query.trim(), ignoreCase = true) }
                if (options.isEmpty()) Caption("没有可添加的应用", Modifier.padding(12.dp))
                options.forEach { entry ->
                    GroupDivider()
                    SettingsRow(entry.name,
                        leading = { SourceIcon(Sources.NOTIFICATION, entry.packageName, 24.dp, entry.name) },
                        onClick = { save(selected + entry.packageName) })
                }
            }
        }
    }
}
