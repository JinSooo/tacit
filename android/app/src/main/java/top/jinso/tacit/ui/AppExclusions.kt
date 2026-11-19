package top.jinso.tacit.ui

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.sources.Sources
import java.text.Collator

/** Change exactly one package, never rebuild the exclusions from a filtered launcher list. */
internal fun withAppExclusion(current: Set<String>, packageName: String, excluded: Boolean): Set<String> =
    if (excluded) current + packageName else current - packageName

internal data class LauncherApp(val packageName: String, val name: String)

@Composable
internal fun AppExclusions(app: TacitApp, resumed: Int, notify: (String) -> Unit) {
    var blocked by remember { mutableStateOf(app.prefs.blockedApps) }
    var apps by remember { mutableStateOf<List<LauncherApp>?>(null) }
    var failed by remember { mutableStateOf(false) }
    var retry by remember { mutableIntStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    var advanced by rememberSaveable { mutableStateOf(false) }
    var draft by rememberSaveable { mutableStateOf("") }
    var draftOriginal by remember { mutableStateOf(emptySet<String>()) }

    LaunchedEffect(app, resumed, retry) {
        blocked = app.prefs.blockedApps
        apps = null
        failed = false
        val result = withContext(Dispatchers.IO) {
            runCatching {
                launcherApps(app)
            }
        }
        result.onSuccess { apps = it }.onFailure { failed = true }
    }

    fun save(next: Set<String>): Boolean = try {
        app.prefs.blockedApps = next
        blocked = app.prefs.blockedApps
        check(blocked == next)
        Sources.refresh(app)
        true
    } catch (_: Exception) {
        notify("未能更新不记录列表，请重试")
        false
    }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("选中的应用不记录聊天通知和应用使用。", color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = {
            if (!advanced) {
                draftOriginal = app.prefs.blockedApps
                draft = draftOriginal.sorted().joinToString("\n")
            }
            advanced = !advanced
        }) { Text(if (advanced) "返回应用列表" else "按包名编辑") }

        if (advanced) {
            Text("完整排除列表，每行一项。系统项和未安装应用也保留在这里。",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(draft, { draft = it }, Modifier.fillMaxWidth(), minLines = 6,
                label = { Text("不记录的包名") })
            Button(onClick = {
                val entries = draft.lines().map { it.trim() }.filter { it.isNotEmpty() }.toSet()
                // Legacy component entries remain valid when retained unchanged.
                val existing = app.prefs.blockedApps + draftOriginal
                if ((entries - existing).any { !it.matches(Regex("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+")) }) {
                    notify("请每行填写一个完整应用包名")
                } else if (save(entries)) {
                    advanced = false
                    notify("已保存不记录列表")
                }
            }) { Text("保存") }
        } else {
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), singleLine = true,
                placeholder = { Text("搜索应用") }, leadingIcon = { Icon(Icons.Outlined.Search, null) })
            val installed = apps
            when {
                failed -> {
                    Text("暂时无法读取应用列表，原有排除项已保留。", color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = { retry++ }) { Text("重试") }
                }
                installed == null -> LinearProgressIndicator(Modifier.fillMaxWidth())
                else -> {
                    val term = query.trim()
                    val visible = installed.filter { it.name.contains(term, ignoreCase = true) || it.packageName.contains(term, ignoreCase = true) }
                    val duplicateNames = installed.groupingBy { it.name }.eachCount().filterValues { it > 1 }.keys
                    if (visible.isEmpty()) Text(if (term.isEmpty()) "没有可显示的应用，原有排除项已保留。" else "没有匹配的应用。",
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    visible.forEach { entry ->
                        key(entry.packageName) {
                            val checked = entry.packageName in blocked
                            Row(Modifier.fillMaxWidth().toggleable(value = checked, role = Role.Checkbox,
                                onValueChange = { excluded -> save(withAppExclusion(app.prefs.blockedApps, entry.packageName, excluded)) })
                                .padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Column(Modifier.weight(1f)) {
                                    Text(entry.name)
                                    if (entry.name in duplicateNames) Text(entry.packageName,
                                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Checkbox(checked = checked, onCheckedChange = null)
                            }
                            HorizontalDivider()
                        }
                    }
                }
            }
        }
    }
}

internal fun launcherApps(app: TacitApp): List<LauncherApp> {
    val manager = app.packageManager
    val collator = Collator.getInstance()
    return manager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
        .mapNotNull { it.activityInfo?.applicationInfo }
        .distinctBy { it.packageName }
        // Tacit is always excluded by the collector, independently of this preference.
        .filter { it.packageName != app.packageName }
        .map { info ->
            val label = runCatching { manager.getApplicationLabel(info).toString().trim() }
                .getOrDefault("")
            LauncherApp(info.packageName, label.ifBlank { info.packageName })
        }
        .sortedWith { a, b ->
            collator.compare(a.name, b.name).takeIf { it != 0 } ?: a.packageName.compareTo(b.packageName)
        }
}
