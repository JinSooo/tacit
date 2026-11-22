package top.jinso.tacit.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.activity.compose.LocalActivity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.withResumed
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.*
import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.ui.components.*
import java.time.LocalDate
import java.util.concurrent.CompletableFuture

@OptIn(ExperimentalLayoutApi::class)
@Composable fun AudioPage(
    app: TacitApp,
    resumed: Int,
    notify: (String) -> Unit,
    onOpenSettings: (String) -> Unit,
    onConversation: (List<HistoryRecord>) -> Unit,
    macDays: Int?,
    recovery: @Composable () -> Unit,
) {
    val activity=LocalActivity.current ?: return
    val audio=remember{AudioController(app)};val scope=rememberCoroutineScope()
    var state by remember{mutableStateOf(audio.state())};var speakers by remember{mutableStateOf(emptyList<AudioSpeaker>())}
    var busy by remember { mutableStateOf(false) }
    var rows by remember { mutableStateOf(emptyList<AudioConversationRow>()) }
    var waitingClips by remember { mutableIntStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    var macVoice by remember { mutableStateOf(false) }
    var loadFailed by remember { mutableStateOf(false) }
    val includeIgnored = false
    fun work(task: () -> CompletableFuture<Unit>, success: String, after: () -> Unit = {}) {
        scope.launch {
            busy = true
            try {
                withContext(Dispatchers.IO) { task().get() }
                after()
                notify(success)
            } catch (_: Exception) {
                notify("操作未完成，请检查状态后重试")
            } finally {
                busy = false
            }
        }
    }
    fun start() {
        try {
            app.prefs.setEnabled(AUDIO_SOURCE, true)
            audio.start(activity)
            state = audio.state()
        } catch (_: Exception) {
            notify("无法开始录音，请先授权麦克风并继续采集")
        }
    }
    val owner = activity as? LifecycleOwner
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result[Manifest.permission.RECORD_AUDIO] == true ||
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        ) {
            // The result arrives before the page is resumed, and capture may only start from a visible page:
            // starting here failed the first time ("无法开始录音") right after the permission dialogs.
            scope.launch { owner?.lifecycle?.withResumed { start() } ?: start() }
        } else notify("麦克风未授权，未开始录音")
    }
    LaunchedEffect(owner, resumed, includeIgnored) {
        // Re-read only when recordings, voices or status change; nothing runs while the page is hidden.
        owner?.lifecycle?.repeatOnLifecycle(Lifecycle.State.RESUMED) { audio.changes.collectLatest {
            state = audio.state()
            val snapshot = withContext(Dispatchers.IO) {
                    runCatching {
                        val voices = audio.listSpeakers(includeIgnored).get()
                        val mac = audio.macVoiceKnown().get()
                        val scenes = audio.listConversations().get().sortedByDescending { it.start }
                        val text = scenes.flatMap { it.recordIds }.distinct().mapNotNull { app.vault.get(it) }.associateBy { it.id }
                        val waiting = audio.listClips().get().count { it.conversationId == null && !it.analyzed }
                        Triple(voices to mac, audioConversationRows(scenes, text), waiting)
                    }
                }
            snapshot.onSuccess { (voices, conversations, waiting) ->
                speakers = voices.first; macVoice = voices.second; rows = conversations; waitingClips = waiting
            }
            loadFailed = snapshot.isFailure
            loaded = true
        } }
    }
    DisposableEffect(Unit){onDispose{audio.stopPlayback()}}
    val candidate = if (macVoice || speakers.any { it.isMe }) null else speakers
        .filter { !it.ignored && it.name == null && it.sampleAvailable }.maxByOrNull { it.seconds }
    val days = remember(rows) { rows.groupBy { date(it.start, "yyyy-MM-dd") } }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp)) {
        item(key = "recording") {
            Column(
                Modifier.fillMaxWidth().padding(top = 24.dp, bottom = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    if (state.recording) "正在录音" else "未在录音",
                    style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Serif,
                    color = if (state.recording) tacitColors.attention else tacitColors.ink,
                )
                Text(state.message, style = MaterialTheme.typography.bodySmall, color = tacitColors.muted,
                    textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis)
                RecordingButton(state.recording, !busy) {
                    if (state.recording) {
                        audio.stop()
                        state = audio.state()
                    } else {
                        val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)
                        if (Build.VERSION.SDK_INT >= 33) permissions += Manifest.permission.POST_NOTIFICATIONS
                        permission.launch(permissions.toTypedArray())
                    }
                }
                Caption("只转写有你声音的对话")
                FlowRow(itemVerticalAlignment = Alignment.CenterVertically) {
                    AudioChip(if (state.modelsReady) "语音模型已就绪" else "语音模型未准备", !state.modelsReady) {
                        onOpenSettings(SettingsRoutes.SPEECH)
                    }
                    Caption("·", color = tacitColors.faint)
                    AudioChip(if (macDays != null) "保留期随 Mac" else "录音保留 ${retentionLabel(app.prefs.retentionDays)}") {
                        onOpenSettings(SettingsRoutes.RETENTION)
                    }
                }
                if (busy) ProgressLine()
            }
        }
        item(key = "recovery") { recovery() }
        if (candidate != null) item(key = "voice-${candidate.id}") {
            Column(Modifier.padding(top = 12.dp)) {
                VoiceConfirmation(
                    candidate, !busy,
                    play = { work({ audio.playSample(candidate.id) }, "正在试听") },
                    mark = {
                        work({ audio.markMe(candidate.id) }, "已标记为我，将补转写保留期内的录音") {
                            speakers = speakers.map { if (it.id == candidate.id) it.copy(isMe = true) else it }
                        }
                    },
                    ignore = {
                        work({ audio.setIgnored(candidate.id, true) }, "好的，换一段再问") {
                            speakers = speakers.filterNot { it.id == candidate.id }
                        }
                    },
                )
            }
        }
        item(key = "conversations-title") {
            SectionLabel("录下的对话", Modifier.padding(top = 24.dp, bottom = 8.dp))
        }
        if (!loaded) item { ProgressLine() }
        if (loadFailed) item {
            Caption("暂时无法读取录音，正在重试。", color = tacitColors.attention)
        } else if (loaded && rows.isEmpty() && waitingClips == 0) item {
            Caption("还没有录下的对话。")
        }
        if (waitingClips > 0) item(key = "waiting-clips") {
            Caption("$waitingClips 段录音等待识别", Modifier.padding(vertical = 8.dp))
        }
        days.forEach { (day, scenes) ->
            item(key = "day-$day") {
                SectionLabel(if (day == LocalDate.now().toString()) "今天" else date(scenes.first().start, "M 月 d 日"),
                    Modifier.padding(top = 12.dp, bottom = 4.dp))
            }
            scenes.filter { it.records.isNotEmpty() }.forEach { scene ->
                item(key = "conversation-${scene.key}") { RecordedConversation(scene, onConversation) }
            }
            val untranscribed = scenes.count { it.records.isEmpty() }
            if (untranscribed > 0) item(key = "untranscribed-$day") {
                val other = if (scenes.any { it.records.isNotEmpty() }) "另有 " else ""
                Caption("$other$untranscribed 段录音还没有文字", Modifier.padding(vertical = 8.dp))
            }
        }
    }
}

@Composable
private fun RecordingButton(recording: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val tint = if (recording) tacitColors.paper else tacitColors.accent
    Surface(
        onClick = onClick, enabled = enabled, modifier = Modifier.size(76.dp), shape = CircleShape,
        color = if (recording) tacitColors.attention else tacitColors.paper,
        border = if (recording) null else BorderStroke(2.dp, tint),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(if (recording) Icons.Outlined.Stop else Icons.Outlined.Mic,
                if (recording) "停止录音" else "开始录音", Modifier.size(32.dp),
                tint = if (enabled) tint else tint.copy(alpha = .55f))
        }
    }
}

@Composable
private fun AudioChip(label: String, problem: Boolean = false, onClick: () -> Unit) {
    Surface(color = Color.Transparent, shape = MaterialTheme.shapes.small, onClick = onClick) {
        Box(Modifier.heightIn(min = 48.dp).padding(horizontal = 8.dp), contentAlignment = Alignment.Center) {
            Caption(label, color = if (problem) tacitColors.attention else tacitColors.muted)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun VoiceConfirmation(speaker: AudioSpeaker, enabled: Boolean, play: () -> Unit, mark: () -> Unit, ignore: () -> Unit) {
    val context = LocalActivity.current ?: return
    val seconds by produceState<Int?>(null, speaker.id, speaker.seconds) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                val runtime = AudioRuntime.get(context)
                synchronized(runtime.lock) {
                    runtime.sample(speaker.id)?.let { (_, start, end) ->
                        ((end - start + SAMPLE_RATE - 1) / SAMPLE_RATE).coerceAtLeast(1)
                    }
                }
            }.getOrNull()
        }
    }
    GroupCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("这是你的声音吗？", style = MaterialTheme.typography.titleLarge)
            Caption("确认一次，之后自动认出你")
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FilledIconButton(onClick = play, enabled = enabled,
                    colors = IconButtonDefaults.filledIconButtonColors(containerColor = tacitColors.fill, contentColor = tacitColors.ink)) {
                    Icon(Icons.Outlined.PlayArrow, "试听")
                }
                Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    listOf(6, 12, 18, 10, 22, 14, 8, 16, 24, 12, 6, 14, 20, 10, 16, 8, 12, 18, 10, 6).forEach { height ->
                        Box(Modifier.width(3.dp).height(height.dp).background(tacitColors.faint, CircleShape))
                    }
                }
                seconds?.let { Caption("$it 秒") }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PrimaryButton("是我", mark, enabled)
                TonalButton("不是", ignore, enabled = enabled)
            }
        }
    }
}

@Composable
private fun RecordedConversation(scene: AudioConversationRow, onConversation: (List<HistoryRecord>) -> Unit) {
    val records = scene.records
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .clickable(enabled = records.isNotEmpty()) { onConversation(records) }.padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Caption(date(scene.start, "HH:mm"), Modifier.width(44.dp))
        Column(Modifier.weight(1f)) {
            if (records.isEmpty()) Text("已保存录音，还没有文字", color = tacitColors.muted)
            else {
                Text(firstSentence(records).ifBlank { conversationTitle(scene.private) },
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Caption(durationLabel(conversationDuration(records)))
                    if (scene.private) PrivacyLock()
                }
            }
        }
    }
    GroupDivider()
}
