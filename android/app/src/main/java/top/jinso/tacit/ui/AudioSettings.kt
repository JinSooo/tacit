package top.jinso.tacit.ui

import android.app.Activity
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
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
    var accelerationFallback by remember { mutableStateOf(audio.accelerationUsingFallback()) }
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
                accelerationFallback = audio.accelerationUsingFallback()
                delay(250)
            }
        }
    }
    GroupCard {
        SettingsRow("语音模型", status = if (modelsReady == false) "未安装，约 280 MB" else null,
            problem = modelsReady == false) {
            if (modelsReady != null && !preparation.busy) {
                val download = {
                    runCatching { audio.downloadModels() }.onFailure { notify("模型正在准备，请稍后重试") }
                    preparation = audio.modelPreparation()
                }
                if (modelsReady == true) TonalButton("重新下载", download)
                else PrimaryButton("下载模型", download)
            }
        }
        if (preparation.busy || preparation.message.isNotEmpty()) {
            GroupDivider()
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (preparation.busy) {
                    if (preparation.phase == SpeechPreparationPhase.DOWNLOADING) {
                        // Progress is polled every 250 ms; following it smoothly keeps the bar from stepping.
                        val progress by animateFloatAsState(
                            (preparation.receivedBytes.toFloat() / preparation.totalBytes.coerceAtLeast(1)).coerceIn(0f, 1f),
                            Motion.polled(), label = "download",
                        )
                        LinearProgressIndicator(
                            progress = { progress },
                            modifier = Modifier.fillMaxWidth(),
                            color = tacitColors.accent,
                            trackColor = tacitColors.fill,
                        )
                        Caption(String.format(java.util.Locale.ROOT, "%.1f / %.1f MB",
                            preparation.receivedBytes / 1_000_000.0, preparation.totalBytes / 1_000_000.0))
                    } else ProgressLine()
                }
                if (preparation.phase != SpeechPreparationPhase.DOWNLOADING || preparation.cancelling) {
                    Caption(preparation.message, color = if (preparation.phase == SpeechPreparationPhase.ERROR)
                        tacitColors.attention else tacitColors.muted)
                }
                if (preparation.busy && preparation.phase != SpeechPreparationPhase.IMPORTING) {
                    TextAction(
                        if (preparation.cancelling) "正在取消" else "取消下载",
                        { audio.cancelModelDownload(); preparation = audio.modelPreparation() },
                        enabled = preparation.canCancel,
                    )
                }
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
            val status = when {
                !accelerationReady -> "约 162 MB"
                accelerationFallback -> "本机加速暂时不可用，将改用普通转写"
                else -> null
            }
            SettingsRow("本机加速", status, problem = accelerationReady && accelerationFallback) {
                if (!accelerationReady) TonalButton("准备", {
                    runCatching { audio.downloadAcceleration() }.onFailure { notify("暂时无法准备本机加速，请稍后重试") }
                    preparation = audio.modelPreparation()
                }, enabled = modelsReady == true && canImport)
            }
        }
    }
    Caption("语音模型从官方发布页下载并校验，转写在手机本地完成。")
    SpeakerSettings(audio, resumed, notify, offerUndo)
}

@Composable
private fun SpeakerSettings(
    audio: AudioController, resumed: Int, notify: (String) -> Unit, offerUndo: (String, suspend () -> Unit) -> Unit,
) {
    var speakers by remember { mutableStateOf<List<AudioSpeaker>?>(null) }
    var loadFailed by remember { mutableStateOf(false) }
    var refresh by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(false) }
    var naming by rememberSaveable { mutableStateOf<String?>(null) }
    var speakerName by rememberSaveable { mutableStateOf("") }
    var namingTitle by rememberSaveable { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    LaunchedEffect(audio, resumed, refresh) {
        loadFailed = false
        try {
            speakers = withContext(Dispatchers.IO) { audio.listSpeakers(includeIgnored = true).get() }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            loadFailed = true
        }
    }
    val playingSpeaker by audio.playingSpeaker.collectAsState()
    val toggleSample = rememberSampleToggle(audio, notify)

    fun work(task: () -> CompletableFuture<Unit>, success: String?, update: Boolean = true) {
        scope.launch {
            busy = true
            try {
                withContext(Dispatchers.IO) { task().get() }
                if (update) refresh++
                success?.let(notify)
            } catch (_: Exception) {
                notify("操作未完成，请稍后重试")
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
                offerUndo("已取消“我”的标记") {
                    withContext(Dispatchers.IO) { audio.undoUnmarkMe(undo).get() }
                    refresh++
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                notify("操作未完成，请稍后重试")
            } finally {
                busy = false
            }
        }
    }

    SectionLabel("声音")
    val current = speakers
    when {
        loadFailed -> GroupCard { SettingsRow("暂时无法读取声音列表") }
        current == null -> ProgressLine()
        else -> GroupCard {
            val visible = current.filterNot { it.ignored }
                .sortedWith(compareByDescending<AudioSpeaker> { it.isMe }.thenByDescending { it.name != null })
            val ignored = current.filter { it.ignored }
            if (current.isEmpty()) SettingsRow("暂时没有可显示的声音")
            var unnamed = 0
            visible.forEachIndexed { index, speaker ->
                if (index > 0) GroupDivider()
                val label = if (speaker.isMe) "我" else speaker.name ?: "声音 ${++unnamed}"
                SettingsRow(label) {
                    Row {
                        SpeakerPlay(speaker, !busy, playingSpeaker == speaker.id) { toggleSample(speaker.id) }
                        if (speaker.isMe) TextAction("这不是我", { unmark(speaker.id) }, enabled = !busy)
                        else {
                            val action = if (speaker.name == null) "起称呼" else "改称呼"
                            TextAction(action, {
                                speakerName = speaker.name.orEmpty()
                                namingTitle = action
                                naming = speaker.id
                            }, enabled = !busy)
                        }
                    }
                }
            }
            if (ignored.isNotEmpty()) {
                if (visible.isNotEmpty()) GroupDivider()
                SettingsRow("已忽略的声音", value = "${countLabel(ignored.size)} 个",
                    expanded = expanded, onClick = { expanded = !expanded })
                Reveal(expanded) {
                    ignored.forEachIndexed { index, speaker ->
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
    }

    val target = naming
    if (target != null) AlertDialog(
        onDismissRequest = { naming = null },
        title = { Text(namingTitle) },
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
            catch (_: Exception) { notify("操作未完成，请稍后重试") }
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
        storage?.takeIf { it.clips > 0 }?.let {
            SettingsRow("本机录音", value = "${countLabel(it.clips)} 段")
            GroupDivider()
        }
        val syncedDays = macDays
        if (syncedDays != null) {
            SettingsRow("保留期限", status = "跟随 Mac 设置", value = retentionLabel(syncedDays))
        } else Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .toggleable(value = keepForever, enabled = !busy, role = Role.Checkbox) { keepForever = it },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Checkbox(
                    checked = keepForever, onCheckedChange = null, enabled = !busy,
                    colors = CheckboxDefaults.colors(checkedColor = tacitColors.accent, checkmarkColor = tacitColors.onAccent),
                )
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
        if (busy) ProgressLine()
    }
    Caption("只清原始音频，转好的文字一直保留。")
    if (storage?.canClear == true) {
        Row(Modifier.fillMaxWidth().padding(top = 16.dp), horizontalArrangement = Arrangement.End) {
            TextAction("删除全部本机音频", { clear = true }, enabled = !busy, color = tacitColors.attention)
        }
    }
    if (clear) AlertDialog(
        onDismissRequest = { clear = false },
        title = { Text("删除全部本机音频？") },
        text = { Text("本机原始音频和声音记录将永久删除，尚未转写的录音会丢失，已转好的文字保留。") },
        confirmButton = { TextAction("删除", {
            clear = false
            work({ audio.clearAudio() }, "已删除全部本机音频")
        }, color = tacitColors.attention) },
        dismissButton = { TextAction("取消", { clear = false }) },
    )
}
