package top.jinso.tacit.ui

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.ui.components.*
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
        Caption("选中的应用不记录聊天通知和应用使用。")
        GroupCard {
            SettingsRow(if (advanced) "返回应用列表" else "按包名编辑", onClick = {
                if (!advanced) {
                    draftOriginal = app.prefs.blockedApps
                    draft = draftOriginal.sorted().joinToString("\n")
                }
                advanced = !advanced
            })
        }
        if (advanced) {
            Caption("每行一个包名，系统项和未安装的应用也可以保留。")
            OutlinedTextField(draft, { draft = it }, Modifier.fillMaxWidth(), minLines = 6,
                label = { Text("不记录的包名") })
            TonalButton("保存", {
                val entries = draft.lines().map { it.trim() }.filter { it.isNotEmpty() }.toSet()
                // Legacy component entries remain valid when retained unchanged.
                val existing = app.prefs.blockedApps + draftOriginal
                if ((entries - existing).any { !it.matches(Regex("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+")) }) {
                    notify("请每行填写一个完整应用包名")
                } else if (save(entries)) {
                    advanced = false
                    notify("已保存不记录列表")
                }
            })
        } else {
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), singleLine = true,
                placeholder = { Text("搜索应用") }, leadingIcon = { Icon(Icons.Outlined.Search, null) })
            val installed = apps
            when {
                failed -> {
                    Caption("暂时无法读取应用列表，原有排除项已保留。", color = tacitColors.attention)
                    TonalButton("重试", { retry++ })
                }
                installed == null -> LinearProgressIndicator(Modifier.fillMaxWidth())
                else -> {
                    val term = query.trim()
                    val visible = installed.filter { it.name.contains(term, ignoreCase = true) || it.packageName.contains(term, ignoreCase = true) }
                    val duplicateNames = installed.groupingBy { it.name }.eachCount().filterValues { it > 1 }.keys
                    if (visible.isEmpty()) {
                        Caption(if (term.isEmpty()) "没有可显示的应用，原有排除项已保留。" else "没有匹配的应用。")
                    } else GroupCard {
                        visible.forEachIndexed { index, entry ->
                            key(entry.packageName) {
                                if (index > 0) GroupDivider()
                                val checked = entry.packageName in blocked
                                val toggle: (Boolean) -> Unit = {
                                    save(withAppExclusion(app.prefs.blockedApps, entry.packageName, it))
                                }
                                SettingsRow(
                                    entry.name, entry.packageName.takeIf { entry.name in duplicateNames },
                                    onClick = { toggle(!checked) },
                                    leading = { SourceIcon(Sources.USAGE, entry.packageName, 24.dp, entry.name) },
                                ) {
                                    Checkbox(checked, toggle, colors = CheckboxDefaults.colors(
                                        checkedColor = tacitColors.ink, checkmarkColor = tacitColors.paper,
                                        uncheckedColor = tacitColors.muted,
                                    ))
                                }
                            }
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
