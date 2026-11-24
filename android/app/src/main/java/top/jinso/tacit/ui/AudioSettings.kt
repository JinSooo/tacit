package top.jinso.tacit.ui

import android.app.Activity
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.KeyboardType
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.*
import top.jinso.tacit.data.DEFAULT_AUDIO_RETENTION_DAYS
import top.jinso.tacit.data.MAX_AUDIO_RETENTION_DAYS
import top.jinso.tacit.ui.components.*
import java.util.concurrent.CompletableFuture

/** Model controls live only in Settings; opening this page never starts a download. */
@Composable internal fun SpeechSettings(
    app: TacitApp, notify: (String) -> Unit, resumed: Int, offerUndo: (String, suspend () -> Unit) -> Unit,
) {
    val audio = remember(app) { AudioController(app) }
    var modelsReady by remember { mutableStateOf<Boolean?>(null) }
    var preparation by remember { mutableStateOf(audio.modelPreparation()) }
    var accelerationReady by remember { mutableStateOf(false) }
    var accelerationStatus by remember { mutableStateOf(audio.accelerationState()) }
    val models = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val uri = result.data?.data
        if (result.resultCode == Activity.RESULT_OK && uri != null) {
            runCatching { audio.importModels(uri) }.onFailure { notify("模型正在准备，请稍后重试") }
            preparation = audio.modelPreparation()
        }
    }
    val owner = LocalActivity.current as? LifecycleOwner
    LaunchedEffect(audio, owner) {
        owner?.lifecycle?.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                val installed = withContext(Dispatchers.IO) { audio.modelsReady() to audio.accelerationReady() }
                modelsReady = installed.first
                accelerationReady = installed.second
                preparation = audio.modelPreparation()
                accelerationStatus = audio.accelerationState()
                delay(250)
            }
        }
    }
    GroupCard {
        // Installed is the normal case; only a missing model gets words.
        SettingsRow("语音模型", status = if (modelsReady == false) "未安装，约 280 MB，下载后在手机上转写" else null,
            problem = modelsReady == false)
        GroupDivider()
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (preparation.busy) {
                if (preparation.phase == SpeechPreparationPhase.DOWNLOADING) {
                    LinearProgressIndicator(
                        progress = { (preparation.receivedBytes.toFloat() / preparation.totalBytes.coerceAtLeast(1)).coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Caption(String.format(java.util.Locale.ROOT, "%.1f / %.1f MB",
                        preparation.receivedBytes / 1_000_000.0, preparation.totalBytes / 1_000_000.0))
                } else LinearProgressIndicator(Modifier.fillMaxWidth())
                if (preparation.phase != SpeechPreparationPhase.DOWNLOADING || preparation.cancelling) {
                    Caption(preparation.message)
                }
                if (preparation.phase != SpeechPreparationPhase.IMPORTING) {
                    TextAction(
                        if (preparation.cancelling) "正在取消" else "取消下载",
                        { audio.cancelModelDownload(); preparation = audio.modelPreparation() },
                        enabled = preparation.canCancel,
                    )
                }
            } else {
                if (preparation.message.isNotEmpty()) {
                    Caption(preparation.message, color = if (preparation.phase == SpeechPreparationPhase.ERROR)
                        tacitColors.attention else tacitColors.muted)
                }
                val download = {
                    runCatching { audio.downloadModels() }.onFailure { notify("模型正在准备，请稍后重试") }
                    preparation = audio.modelPreparation()
                }
                val enabled = modelsReady != null
                val label = when {
                    preparation.phase == SpeechPreparationPhase.ERROR -> "重试下载"
                    modelsReady == true -> "重新下载"
                    else -> "下载模型"
                }
                if (modelsReady == true) TonalButton(label, download, enabled = enabled)
                else PrimaryButton(label, download, enabled)
            }
        }
        GroupDivider()
        val canImport = modelsReady != null && !preparation.busy
        SettingsRow(
            if (modelsReady == true) "更换模型文件夹" else "导入模型文件夹",
            onClick = if (canImport) {{
                models.launch(android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT_TREE)
                    .putExtra(android.content.Intent.EXTRA_LOCAL_ONLY, true)
                    .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION))
            }} else null,
        )
        if (audio.supportsNpu()) {
            GroupDivider()
            SettingsRow("本机加速", if (accelerationReady) accelerationStatus else "约 162 MB") {
                if (!accelerationReady) TonalButton("准备", {
                    runCatching { audio.downloadAcceleration() }.onFailure { notify(it.message ?: "暂时无法准备加速模型") }
                    preparation = audio.modelPreparation()
                }, enabled = modelsReady == true && canImport)
            }
        }
    }
    Caption("来自 sherpa-onnx 官方发布，下载后校验。")
    SpeakerSettings(audio, resumed, notify, offerUndo)
}

@Composable
private fun SpeakerSettings(
    audio: AudioController, resumed: Int, notify: (String) -> Unit, offerUndo: (String, suspend () -> Unit) -> Unit,
) {
    var speakers by remember { mutableStateOf<List<AudioSpeaker>?>(null) }
    var refresh by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(false) }
    var naming by rememberSaveable { mutableStateOf<String?>(null) }
    var speakerName by rememberSaveable { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    LaunchedEffect(audio, resumed, refresh) {
        val result = withContext(Dispatchers.IO) { runCatching { audio.listSpeakers(includeIgnored = true).get() } }
        result.onSuccess { speakers = it }.onFailure { notify("暂时无法读取声音标记") }
    }
    val playingSpeaker by audio.playingSpeaker.collectAsState()
    val toggleSample = rememberSampleToggle(audio, notify)

    fun work(task: () -> CompletableFuture<Unit>, success: String) {
        scope.launch {
            busy = true
            try {
                withContext(Dispatchers.IO) { task().get() }
                refresh++
                notify(success)
            } catch (_: Exception) {
                notify("操作未完成，请检查状态后重试")
            } finally {
                busy = false
            }
        }
    }

    fun unmark(id: String) {
        if (busy) return
        audio.stopPlayback()
        busy = true
        scope.launch {
            try {
                val undo = withContext(Dispatchers.IO) { audio.unmarkMe(id).get() }
                refresh++
                offerUndo("已取消本人标记") {
                    withContext(Dispatchers.IO) { audio.undoUnmarkMe(undo).get() }
                    refresh++
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                notify("操作未完成，请检查状态后重试")
            } finally {
                busy = false
            }
        }
    }

    SectionLabel("你的声音")
    GroupCard {
        val current = speakers
        if (current == null) {
            SettingsRow("声音标记", "暂时没有可显示的声音")
        } else {
            val named = current.filter { !it.ignored && (it.isMe || !it.name.isNullOrBlank()) }
            val ignored = current.filter { it.ignored }
            if (named.isEmpty()) SettingsRow("尚未确认你的声音", "录到清晰的说话声后，可以在首页确认。")
            named.forEachIndexed { index, speaker ->
                if (index > 0) GroupDivider()
                SettingsRow(if (speaker.isMe) "我" else speaker.name.orEmpty()) {
                    Row {
                        SpeakerPlay(speaker, !busy, playingSpeaker == speaker.id) { toggleSample(speaker.id) }
                        if (speaker.isMe) TextAction("这不是我", { unmark(speaker.id) }, enabled = !busy)
                        else TextAction("改称呼", {
                            speakerName = speaker.name.orEmpty()
                            naming = speaker.id
                        }, enabled = !busy)
                    }
                }
            }
            // No ignored voices is the normal case, not a row.
            if (ignored.isNotEmpty()) {
                GroupDivider()
                SettingsRow("已忽略的声音", value = "${ignored.size} 个",
                    expanded = expanded, onClick = { expanded = !expanded })
                if (expanded) ignored.forEachIndexed { index, speaker ->
                    GroupDivider()
                    SettingsRow(speaker.name ?: "声音 ${index + 1}") {
                        Row {
                            SpeakerPlay(speaker, !busy, playingSpeaker == speaker.id) { toggleSample(speaker.id) }
                            TextAction("恢复", { work({ audio.setIgnored(speaker.id, false) }, "已恢复这个声音") }, enabled = !busy)
                        }
                    }
                }
            }
        }
    }

    val target = naming
    if (target != null) AlertDialog(
        onDismissRequest = { naming = null },
        title = { Text("改称呼") },
        text = { OutlinedTextField(speakerName, { speakerName = it.take(80) }, label = { Text("如何称呼") }, singleLine = true) },
        confirmButton = { TextAction("保存", {
            val label = speakerName
            work({ audio.renameSpeaker(target, label) }, "称呼已更新")
            naming = null
        }, enabled = !busy) },
        dismissButton = { TextAction("取消", { naming = null }) },
    )
}

@Composable
private fun SpeakerPlay(speaker: AudioSpeaker, enabled: Boolean, playing: Boolean, onClick: () -> Unit) {
    IconButton(onClick = onClick, enabled = enabled && (speaker.sampleAvailable || playing)) {
        Icon(if (playing) Icons.Outlined.Pause else Icons.Outlined.PlayArrow, if (playing) "停止试听" else "试听")
    }
}

@Composable
internal fun rememberSampleToggle(audio: AudioController, notify: (String) -> Unit): (String) -> Unit {
    val scope = rememberCoroutineScope()
    DisposableEffect(audio) { onDispose { audio.stopPlayback() } }
    return { id ->
        val loading = audio.playSample(id)
        scope.launch {
            try { withContext(Dispatchers.IO) { loading.get() } }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { notify("暂时无法试听") }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun AudioStorageSettings(app: TacitApp, notify: (String) -> Unit) {
    val audio = remember(app) { AudioController(app) }
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    fun work(task: () -> CompletableFuture<Unit>, success: String) {
        scope.launch {
            busy = true
            try { withContext(Dispatchers.IO) { task().get() }; notify(success) }
            catch (_: Exception) { notify("操作未完成，请检查状态后重试") }
            finally { busy = false }
        }
    }
    var storage by remember { mutableStateOf<AudioStorageUsage?>(null) }
    var clear by remember { mutableStateOf(false) }
    var savedDays by remember { mutableIntStateOf(app.prefs.retentionDays) }
    var keepForever by rememberSaveable { mutableStateOf(savedDays == 0) }
    var days by rememberSaveable {
        mutableStateOf((savedDays.takeIf { it > 0 } ?: DEFAULT_AUDIO_RETENTION_DAYS).toString())
    }
    var macDays by remember { mutableStateOf<Int?>(null) }
    val owner = LocalActivity.current as? LifecycleOwner
    LaunchedEffect(audio, busy, owner) {
        if (busy) return@LaunchedEffect
        val vault = withContext(Dispatchers.IO) { runCatching { app.vault }.getOrNull() } ?: return@LaunchedEffect
        owner?.lifecycle?.repeatOnLifecycle(Lifecycle.State.RESUMED) { audio.changes.collect {
            withContext(Dispatchers.IO) {
                runCatching {
                    vault.syncConnection()?.optJSONObject("audio")?.getInt("retention_days") to audio.storageUsage().get()
                }.getOrNull()
            }?.let { (retention, usage) -> macDays = retention; storage = usage }
        } }
    }
    GroupCard {
        storage?.let {
            SettingsRow("本机录音 ${it.clips} 段")
            GroupDivider()
        }
        val syncedDays = macDays
        if (syncedDays != null) {
            SettingsRow(if (syncedDays == 0) "按 Mac 设置，不自动清除" else "按 Mac 设置保留 $syncedDays 天")
        } else Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .toggleable(value = keepForever, enabled = !busy, role = Role.Checkbox) { keepForever = it },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Checkbox(checked = keepForever, onCheckedChange = null, enabled = !busy)
                Text("不自动清除")
            }
            val entered = localRetentionDays(days, keepForever)
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                itemVerticalAlignment = Alignment.CenterVertically,
            ) {
                if (!keepForever) OutlinedTextField(
                    days, { days = it.filter(Char::isDigit).take(3) },
                    Modifier.widthIn(max = 180.dp), label = { Text("保留天数") }, singleLine = true,
                    enabled = !busy, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    isError = days.isNotEmpty() && entered == null,
                    supportingText = if (days.isNotEmpty() && entered == null) {
                        { Text("请输入 1 至 $MAX_AUDIO_RETENTION_DAYS 天") }
                    } else null,
                )
                val change = entered?.takeIf { it != savedDays }
                if (change != null) TonalButton("保存", {
                    app.prefs.retentionDays = change
                    savedDays = app.prefs.retentionDays
                    work({ audio.prune() }, "已更新保留期")
                }, enabled = !busy)
            }
        }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
    }
    if (storage?.canClear == true) {
        TextAction("清理录音和声纹", { clear = true }, enabled = !busy, color = tacitColors.attention)
    }
    if (clear) AlertDialog(
        onDismissRequest = { clear = false },
        title = { Text("清理本机录音和声纹？") },
        text = { Text("全部录音和声音标记将永久删除。已生成的文字记录保留，可在时间线中单独删除。") },
        confirmButton = { TextAction("清理", {
            clear = false
            work({ audio.clearAudio() }, "录音和声纹已清理")
        }, color = tacitColors.attention) },
        dismissButton = { TextAction("取消", { clear = false }) },
    )
}
