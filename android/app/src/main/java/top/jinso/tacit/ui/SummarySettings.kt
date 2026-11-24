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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import top.jinso.tacit.TacitApp
import top.jinso.tacit.summary.SummaryClient
import top.jinso.tacit.summary.SummaryFailure
import top.jinso.tacit.summary.SummaryModel
import top.jinso.tacit.summary.SummaryWorker
import top.jinso.tacit.summary.summaryModelJson
import top.jinso.tacit.ui.components.*

/** Settings row value: the model the user picked, or what needs their hand. */
internal fun summaryRowValue(saved: JSONObject?): Pair<String?, Boolean> = when {
    saved?.optBoolean("enabled") != true -> null to false
    saved.optString("error").isNotEmpty() -> saved.optString("error") to true
    else -> saved.optString("model") to false
}

/** "AI 总结": the phone writes conversation summaries itself with a model service the user fills in. Off by default. */
@Composable internal fun SummarySettings(app: TacitApp, notify: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var saved by remember { mutableStateOf<JSONObject?>(null) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(app) {
        app.vault.changes.collectLatest { saved = withContext(Dispatchers.IO) { app.vault.summaryModel() }; loaded = true }
    }
    if (!loaded) { ProgressLine(); return }
    var base by rememberSaveable { mutableStateOf(saved?.optString("base").orEmpty()) }
    var model by rememberSaveable { mutableStateOf(saved?.optString("model").orEmpty()) }
    // The key is never shown again; an empty field keeps the one already saved.
    var key by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val enabled = saved?.optBoolean("enabled") == true
    val hasKey = saved?.optString("key").orEmpty().isNotEmpty()
    fun current() = SummaryModel(base, model, key.ifBlank { saved?.optString("key").orEmpty() })
    fun act(block: suspend () -> String?) {
        if (busy) return
        busy = true; message = null
        scope.launch {
            try { message = block() }
            catch (e: SummaryFailure) { message = e.reason }
            finally { busy = false }
        }
    }
    fun store(on: Boolean): String? {
        val m = current()
        if (on && (m.base.isBlank() || m.model.isBlank())) return "先填服务地址和模型名"
        if (m.base.isNotBlank()) SummaryClient.endpointOf(m.base)
        app.vault.saveSummaryModel(summaryModelJson(on, m))
        SummaryWorker.apply(app, on)
        key = ""
        return null
    }

    GroupCard {
        SettingsRow("AI 总结", onClick = { act { withContext(Dispatchers.IO) { store(!enabled) } } }, trailing = {
            Switch(enabled, null, Modifier.semantics { contentDescription = if (enabled) "AI 总结已开启" else "AI 总结已关闭" },
                colors = SwitchDefaults.colors(checkedTrackColor = tacitColors.accent, checkedThumbColor = tacitColors.paper))
        })
    }
    Caption("开启后，对话的转写文字会发给这里填的服务来写总结，私密的不发；也可以填本机或家里网络中的模型服务。")
    GroupCard {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(base, { base = it.take(512) }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true,
                label = { Text("服务地址") }, placeholder = { Text("https://api.example.com/v1") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(model, { model = it.take(200) }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true,
                label = { Text("模型名") })
            OutlinedTextField(key, { key = it.take(512) }, Modifier.fillMaxWidth(), enabled = !busy, singleLine = true,
                label = { Text("API Key") },
                placeholder = if (hasKey) { { Text("已设置，留空保持不变") } } else null,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TonalButton("测试连接", { act { withContext(Dispatchers.IO) { SummaryClient(current()).test() }; "连接正常" } },
                    enabled = !busy && base.isNotBlank() && model.isNotBlank())
                val changed = base != saved?.optString("base").orEmpty() || model != saved?.optString("model").orEmpty() || key.isNotBlank()
                FadeVisibility(changed) {
                    TonalButton("保存", { act { withContext(Dispatchers.IO) { store(enabled) }.also { if (it == null) notify("已保存") } } },
                    enabled = !busy)
            }
        }
    }
    }
    val result = message ?: saved?.optString("error")?.takeIf { enabled && it.isNotEmpty() }
    val shownResult = rememberLatest(result)
    Reveal(result != null) {
        shownResult?.let { Caption(it, color = if (it == "连接正常") tacitColors.muted else tacitColors.attention) }
    }
    if (busy) ProgressLine()
}
