package top.jinso.tacit.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.sources.WECHAT_PACKAGE

@Composable
internal fun ChatApps(app: TacitApp, resumed: Int, notify: (String) -> Unit) {
    var selected by remember { mutableStateOf(app.prefs.chatApps) }
    var installed by remember { mutableStateOf(emptyList<LauncherApp>()) }
    var choosing by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    LaunchedEffect(app, resumed, choosing) {
        selected = app.prefs.chatApps
        if (choosing) {
            installed = withContext(Dispatchers.IO) { runCatching { launcherApps(app) }.getOrDefault(emptyList()) }
        }
    }

    val names = remember(app, resumed, selected, installed) {
        installed.associate { it.packageName to it.name } + (WECHAT_PACKAGE to "微信")
    }
    fun save(next: Set<String>) {
        runCatching { Sources.setChatApps(app, next) }
            .onSuccess { selected = next }
            .onFailure { notify("未能保存聊天应用，请重试") }
    }
    Text("聊天应用", style = MaterialTheme.typography.titleMedium)
    if (selected.isEmpty()) Text("尚未选择应用", color = MaterialTheme.colorScheme.onSurfaceVariant)
    selected.sorted().forEach { packageName ->
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(names[packageName] ?: packageName, Modifier.weight(1f))
            TextButton(onClick = { save(selected - packageName) }) { Text("移除") }
        }
    }
    TextButton(onClick = { choosing = !choosing }) { Text(if (choosing) "收起应用列表" else "添加聊天应用") }
    if (choosing) {
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), singleLine = true,
            label = { Text("搜索已安装的应用") })
        val options = (listOf(LauncherApp(WECHAT_PACKAGE, "微信")) + installed)
            .distinctBy { it.packageName }
            .filter { it.packageName !in selected && it.packageName !in app.prefs.blockedApps }
            .filter { it.name.contains(query.trim(), ignoreCase = true) || it.packageName.contains(query.trim(), ignoreCase = true) }
        if (options.isEmpty()) Text("没有可添加的应用", color = MaterialTheme.colorScheme.onSurfaceVariant)
        options.forEach { entry ->
            Row(Modifier.fillMaxWidth().toggleable(false, role = Role.Checkbox) { save(selected + entry.packageName) }
                .padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(entry.name, Modifier.weight(1f))
                Checkbox(checked = false, onCheckedChange = null)
            }
        }
    }
}
