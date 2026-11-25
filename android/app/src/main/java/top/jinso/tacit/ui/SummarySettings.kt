package top.jinso.tacit.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import top.jinso.tacit.TacitApp
import top.jinso.tacit.summary.SummaryClient
import top.jinso.tacit.summary.SummaryFailure
import top.jinso.tacit.summary.SummaryModel
import top.jinso.tacit.summary.SummaryWorker
import top.jinso.tacit.summary.clearSummaryFailure
import top.jinso.tacit.summary.summaryModelConfig
import top.jinso.tacit.summary.summaryModelJson
import top.jinso.tacit.summary.summaryProblem
import top.jinso.tacit.ui.components.*

@Composable
internal fun visibleSummaryProblem(saved: JSONObject?): String? {
    val problem = saved?.takeIf { it.optBoolean("enabled") }?.summaryProblem() ?: return null
    var now by remember(problem) { mutableLongStateOf(System.currentTimeMillis()) }
    // 休眠时 delay 会停表：每次最多等一分钟就按墙上时间重算，醒来后最晚一分钟内显示。
    LaunchedEffect(problem) {
        while (true) {
            now = System.currentTimeMillis()
            if (now >= problem.showAt) break
            delay((problem.showAt - now).coerceAtMost(60_000L))
        }
    }
    return problem.messageAt(now)
}

/** "AI 总结": the phone writes conversation summaries itself with a model service the user fills in. Off by default. */
@Composable internal fun SummarySettings(app: TacitApp, notify: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var saved by remember { mutableStateOf<JSONObject?>(null) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(app) {
        app.vault.changes.collectLatest {
            saved = withContext(Dispatchers.IO) { app.vault.summaryModel() }
            loaded = true
        }
    }
    if (!loaded) { ProgressLine(); return }
    val savedModel = saved?.summaryModelConfig()
    var base by rememberSaveable { mutableStateOf(savedModel?.base.orEmpty()) }
    var model by rememberSaveable { mutableStateOf(savedModel?.model.orEmpty()) }
    var key by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var testing by remember { mutableStateOf(false) }
    var testPassed by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var confirmDeleteKey by rememberSaveable { mutableStateOf(false) }
    val enabled = saved?.optBoolean("enabled") == true
    val hasKey = !savedModel?.key.isNullOrEmpty()

    fun current() = SummaryModel(base.trim(), model.trim(), key.trim().ifBlank { savedModel?.key.orEmpty() })

    fun act(test: Boolean = false, block: suspend () -> Unit) {
        if (busy) return
        busy = true
        testing = test
        testPassed = false
        message = null
        scope.launch {
            try {
                block()
                testPassed = test
            } catch (e: CancellationException) {
                throw e
            } catch (e: SummaryFailure) {
                message = e.reason
            } catch (_: Exception) {
                message = if (test) "测试连接失败，请重试。" else "保存失败，请重试。"
            } finally {
                busy = false
                testing = false
            }
        }
    }

    suspend fun store(on: Boolean) {
        val draft = current()
        if (on && (draft.base.isBlank() || draft.model.isBlank())) {
            message = "请先填写服务地址和模型名。"
            return
        }
        if (draft.base.isNotBlank()) SummaryClient.endpointOf(draft.base)
        withContext(Dispatchers.IO) {
            val vault = app.vault
            synchronized(vault) {
                val previous = vault.summaryModel()
                val state = previous?.takeIf { it.summaryModelConfig() == draft }?.put("enabled", on)
                    ?: summaryModelJson(on, draft)
                vault.saveSummaryModel(state)
            }
            SummaryWorker.apply(app, on)
        }
        base = draft.base
        model = draft.model
        key = ""
    }

    GroupCard {
        SettingsRow("AI 总结", onClick = {
            act {
                if (enabled) {
                    withContext(Dispatchers.IO) {
                        val vault = app.vault
                        synchronized(vault) {
                            // 关掉时连同失败计时和冷却一起清，再打开从零开始。
                            vault.summaryModel()?.let { it.clearSummaryFailure(); vault.saveSummaryModel(it.put("enabled", false)) }
                        }
                        SummaryWorker.apply(app, false)
                    }
                } else store(true)
            }
        }, trailing = {
            Switch(enabled, null, Modifier.semantics { contentDescription = if (enabled) "AI 总结已开启" else "AI 总结已关闭" },
                enabled = !busy,
                colors = SwitchDefaults.colors(checkedTrackColor = tacitColors.accent, checkedThumbColor = tacitColors.paper))
        })
    }
    Caption("开启后，非私密对话的转写文字会发给此服务写总结，也可填本机或局域网服务。")
    GroupCard {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(base, { base = it.take(512) }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true,
                label = { Text("服务地址") }, placeholder = { Text("https://api.example.com/v1") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(model, { model = it.take(200) }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true,
                label = { Text("模型") }, placeholder = { Text("模型名") })
            OutlinedTextField(key, { key = it.take(512) }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true,
                label = { Text(if (hasKey) "API key（已设置）" else "API key") },
                placeholder = if (hasKey) { { Text("留空保持不变") } } else null,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TonalButton(if (testing) "正在测试…" else "测试连接", {
                    act(test = true) {
                        val draft = current()
                        withContext(Dispatchers.IO) {
                            SummaryClient(draft).test()
                            app.vault.clearSummaryFailure(draft)
                        }
                    }
                }, enabled = !busy && base.isNotBlank() && model.isNotBlank())
                val changed = base != savedModel?.base.orEmpty() || model != savedModel?.model.orEmpty() || key.isNotBlank()
                FadeVisibility(changed) {
                    TonalButton("保存", {
                        act {
                            store(enabled)
                            if (message == null) notify("已保存")
                        }
                    }, enabled = !busy)
                }
            }
        }
    }
    val backgroundProblem = visibleSummaryProblem(saved)
    val result = message ?: if (testPassed) "连接正常。" else backgroundProblem
    val shownResult = rememberLatest(result?.let { it to (message != null || !testPassed) })
    Reveal(result != null) {
        shownResult?.let { (text, problem) -> Caption(text, color = if (problem) tacitColors.attention else tacitColors.muted) }
    }
    if (busy) ProgressLine()
    if (hasKey) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
            TextAction("删除 API key", { confirmDeleteKey = true }, enabled = !busy, color = tacitColors.attention)
        }
        if (confirmDeleteKey) AlertDialog(
            onDismissRequest = { confirmDeleteKey = false },
            title = { Text("删除 API key？") },
            text = { Text("如果服务需要 API key，重新填写前将无法写总结。") },
            confirmButton = {
                TextAction("删除", {
                    confirmDeleteKey = false
                    act {
                        withContext(Dispatchers.IO) {
                            val vault = app.vault
                            synchronized(vault) {
                                vault.summaryModel()?.let { state ->
                                    state.remove("key")
                                    state.clearSummaryFailure()
                                    vault.saveSummaryModel(state)
                                }
                            }
                        }
                        key = ""
                    }
                }, color = tacitColors.attention)
            },
            dismissButton = { TextAction("取消", { confirmDeleteKey = false }) },
        )
    }
}
