package top.jinso.tacit.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.activity.compose.LocalActivity
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.withResumed
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.*
import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.data.ConversationSummary
import top.jinso.tacit.sources.Sources
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import top.jinso.tacit.ui.components.*
import top.jinso.tacit.ui.onboarding.CollectionHealth
import top.jinso.tacit.ui.onboarding.SystemPage
import top.jinso.tacit.ui.onboarding.openSystemPage
import top.jinso.tacit.sync.TimelineSnapshot
import top.jinso.tacit.sync.TimelineItem
import java.time.Instant
import java.time.LocalDate
import java.util.concurrent.CompletableFuture

/**
 * The phone's one page: what was said, by day. Recording is always meant to be on, like a Mac source, so it has no
 * control here; the page only speaks up when recording is off or something needs the user.
 */
@Composable internal fun AudioPage(
    app: TacitApp,
    resumed: Int,
    notify: (String) -> Unit,
    onOpenSettings: (String?) -> Unit,
    onConversation: (List<HistoryRecord>) -> Unit,
    timeline: TimelineSnapshot,
    day: LocalDate,
    onDay: (LocalDate) -> Unit,
    onTimelineItem: (TimelineItem) -> Unit,
    macRemoved: Boolean,
    health: CollectionHealth?,
) {
    val activity=LocalActivity.current ?: return
    val audio=remember{AudioController(app)};val scope=rememberCoroutineScope()
    var state by remember{mutableStateOf(audio.state())};var speakers by remember{mutableStateOf(emptyList<AudioSpeaker>())}
    var busy by remember { mutableStateOf(false) }
    var rows by remember { mutableStateOf(emptyList<AudioConversationRow>()) }
    var loaded by remember { mutableStateOf(false) }
    var macVoice by remember { mutableStateOf(false) }
    var loadFailed by remember { mutableStateOf(false) }
    var summaries by remember { mutableStateOf(emptyMap<String, ConversationSummary>()) }
    val includeIgnored = false
    fun work(task: () -> CompletableFuture<Unit>, success: String, after: () -> Unit = {}) {
        scope.launch {
            busy = true
            try {
                withContext(Dispatchers.IO) { task().get() }
                after()
                notify(success)
            } catch (_: Exception) {
                notify("操作未完成，请稍后重试")
            } finally {
                busy = false
            }
        }
    }
    val owner = activity as? LifecycleOwner
    val startRecording = rememberRecordingStarter(app, audio, notify) { state = audio.state() }
    LaunchedEffect(owner, resumed) {
        // Opening Tacit picks recording back up after a reboot or a system stop, unless the user turned it off.
        if (app.prefs.audioCaptureWanted && !audio.state().recording &&
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        ) owner?.lifecycle?.withResumed {
            runCatching { app.prefs.setEnabled(AUDIO_SOURCE, true); audio.start(activity) }
            state = audio.state()
        }
    }
    LaunchedEffect(owner, resumed, includeIgnored) {
        // Re-read only when recordings, voices or status change; nothing runs while the page is hidden.
        // A sync that brings new Mac summaries only touches the vault, so listen to both.
        owner?.lifecycle?.repeatOnLifecycle(Lifecycle.State.RESUMED) { merge(audio.changes, app.vault.changes).collectLatest {
            state = audio.state()
            val (voices, conversations, written) = retryAudioPageRead(onFailure = { loadFailed = true }) {
                withContext(Dispatchers.IO) {
                    val voices = audio.listSpeakers(includeIgnored).get()
                    val mac = audio.macVoiceKnown().get()
                    val scenes = audio.listConversations().get().sortedByDescending { it.start }
                    val text = scenes.flatMap { it.recordIds }.distinct().mapNotNull { app.vault.get(it) }.associateBy { it.id }
                    val written = app.vault.summaries().flatMap { m -> m.recordIds.map { it to m } }.toMap()
                    Triple(voices to mac, audioConversationRows(scenes, text), written)
                }
            }
            speakers = voices.first
            macVoice = voices.second
            rows = conversations
            summaries = written
            loadFailed = false
            loaded = true
        } }
    }
    val playingSpeaker by audio.playingSpeaker.collectAsState()
    val toggleSample = rememberSampleToggle(audio, notify)
    DisposableEffect(Unit){onDispose{audio.stopPlayback()}}
    // Each day has its own cards, so a sample playing for the old day would keep going with no stop button in sight.
    LaunchedEffect(day) { audio.stopPlayback() }
    val candidate = if (macVoice || speakers.any { it.isMe }) null else speakers
        .filter { !it.ignored && it.name == null && it.sampleAvailable }.maxByOrNull { it.seconds }
    val today = LocalDate.now()
    val local = remember(rows, timeline.days, today) {
        val projectedIds = timeline.days.flatMap { (date, value) -> value.entries(date == today) }
            .flatMap { it.recordIds }.toSet()
        undisplayedConversations(rows, projectedIds).groupBy { LocalDate.parse(date(it.start, "yyyy-MM-dd")) }
    }
    val availableDays = local.keys + timeline.days.filter { (date, value) ->
        !value.overview.isNullOrBlank() || value.entries(date == today).isNotEmpty()
    }.keys
    val earlier = availableDays.filter { it < day }.maxOrNull()
    val later = availableDays.filter { it > day }.minOrNull()
    val reduceMotion = LocalReduceMotion.current
    val (shiftIn, shiftOut) = with(LocalDensity.current) { 24.dp.roundToPx() to 16.dp.roundToPx() }

    Column(Modifier.fillMaxSize()) {
        // The date bar stays put while the day below changes, so the arrows never move under a finger.
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 20.dp, bottom = 4.dp), verticalAlignment = Alignment.Top) {
            Crossfade(day, Modifier.weight(1f).padding(top = 8.dp), Motion.quick(), label = "day-title") {
                DayHeading(it, today, stacked = true)
            }
            val earlierTint by animateColorAsState(if (earlier != null) tacitColors.muted else tacitColors.faint, Motion.quick(), label = "earlier")
            val laterTint by animateColorAsState(if (later != null) tacitColors.muted else tacitColors.faint, Motion.quick(), label = "later")
            IconButton(onClick = { earlier?.let(onDay) }, enabled = earlier != null) {
                Icon(Icons.AutoMirrored.Outlined.KeyboardArrowLeft, "前一天", tint = earlierTint)
            }
            if (day != today) TextButton(onClick = { onDay(today) }) { Text("今天") }
            IconButton(onClick = { later?.let(onDay) }, enabled = later != null) {
                Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, "后一天", tint = laterTint)
            }
            IconButton(onClick = { onOpenSettings(null) }) {
                Icon(Icons.Outlined.Settings, "设置", tint = tacitColors.muted)
            }
        }
        AnimatedContent(day, transitionSpec = {
            dayTransform(later = targetState > initialState, shiftIn, shiftOut, reduceMotion)
        }, label = "day") { day ->
            val dayTimeline = timeline.days[day]
            LazyColumn(Modifier.fillMaxSize().background(tacitColors.paper), contentPadding = PaddingValues(start = 20.dp, end = 8.dp, bottom = 32.dp)) {
        dayTimeline?.overview?.takeIf { it.isNotBlank() }?.let { overview ->
            item(key = "overview") {
                        Text(overview, Modifier.itemMotion(this).padding(top = 8.dp, end = 12.dp, bottom = 12.dp),
                    style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Serif,
                    fontWeight = FontWeight.Normal, color = tacitColors.ink)
            }
        }
        val notice = recordingNotice(
            state, app.prefs.audioCaptureWanted,
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
            health?.recordingNotificationsBlocked == true, macRemoved,
        )
        if (notice != null) item(key = "notice") {
                    Box(Modifier.itemMotion(this).padding(end = 12.dp, top = 8.dp)) {
                val route = notice.route
                when {
                    notice.start -> NoticeAction(notice.text, "开启", !busy, startRecording)
                    route != null -> NoticeRow(notice.text) { onOpenSettings(route) }
                    notice.openNotifications -> NoticeRow(notice.text) { openSystemPage(activity, SystemPage.NOTIFICATIONS, notify) }
                    else -> NoticeText(notice.text)
                }
            }
        }
        if (candidate != null) item(key = "voice-${candidate.id}") {
                    Column(Modifier.itemMotion(this).padding(top = 12.dp, end = 12.dp)) {
                VoiceConfirmation(
                            candidate, !busy, playingSpeaker == candidate.id,
                            play = { toggleSample(candidate.id) },
                    mark = {
                        audio.stopPlayback()
                        work({ audio.markMe(candidate.id) }, "已标记为我，将补转写保留期内的录音") {
                            speakers = speakers.map { if (it.id == candidate.id) it.copy(isMe = true) else it }
                        }
                    },
                    ignore = {
                        audio.stopPlayback()
                        work({ audio.setIgnored(candidate.id, true) }, "好的，换一段再问") {
                            speakers = speakers.filterNot { it.id == candidate.id }
                        }
                    },
                )
            }
        }
                if ((!loaded && !loadFailed) || busy) item(key = "progress") { ProgressLine(Modifier.itemMotion(this).padding(end = 12.dp, top = 8.dp)) }
                if (loadFailed) item(key = "failed") {
                    Caption("暂时无法读取录音，正在重试。", Modifier.itemMotion(this).padding(top = 16.dp), color = tacitColors.attention)
        } else if (loaded && day !in availableDays) item(key = "empty") {
                    Text("说过的话，会按天写在这里。", Modifier.itemMotion(this).padding(top = 48.dp, end = 12.dp),
                style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Serif,
                fontWeight = FontWeight.Normal, color = tacitColors.muted)
        }
        val scenes = local[day].orEmpty()
        val entries = (dayTimeline?.entries(day == today).orEmpty().map { TimelineEntry.Projected(it) } +
            scenes.filter { it.records.isNotEmpty() }.map { TimelineEntry.Local(it) }).sortedByDescending { it.start }
        entries.forEachIndexed { index, entry ->
            item(key = entry.key) {
                val summary = (entry as? TimelineEntry.Local)?.scene?.records?.firstNotNullOfOrNull { summaries[it.id] }
                // 还没整理的段（草稿、手机上还没写总结的对话）用空心点。
                val draft = when (entry) {
                    is TimelineEntry.Local -> summary == null
                    is TimelineEntry.Projected -> entry.item.draft
                }
                        val axis = Modifier.itemMotion(this).timelineAxis(index == 0, index == entries.lastIndex, draft)
                when (entry) {
                    // 和其他来源的段混排时才标手机录音图标；只有本机录音时不用强调。
                    is TimelineEntry.Local -> RecordedConversation(entry.scene, summary, onConversation, axis,
                        showsSource = dayTimeline != null)
                    is TimelineEntry.Projected -> ProjectedTimelineRow(entry.item, axis) {
                        onTimelineItem(entry.item)
                    }
                }
            }
        }
        val untranscribed = scenes.count { it.records.isEmpty() }
        if (untranscribed > 0) item(key = "untranscribed-$day") {
            val other = if (entries.isNotEmpty()) "另有 " else ""
                    Row(Modifier.itemMotion(this).padding(vertical = 12.dp)) {
                Box(Modifier.width(56.dp).padding(top = 9.dp)) {
                    Box(Modifier.width(16.dp).height(1.dp).background(tacitColors.faint))
                }
                Caption("$other${countLabel(untranscribed)} 段没认出你的声音，未转写")
            }
        }
        timeline.staleTime(day)?.let { synced ->
            item(key = "timeline-sync-time") {
                Caption("已同步到 $synced", Modifier.padding(top = 12.dp, end = 12.dp))
            }
        }
    }
        }
    }
}

/** One tap does both system prompts and the start, because capture may only begin from a visible page. */
@Composable
internal fun rememberRecordingStarter(app: TacitApp, audio: AudioController, notify: (String) -> Unit, after: () -> Unit): () -> Unit {
    val activity = LocalActivity.current ?: return {}
    val owner = activity as? LifecycleOwner
    val scope = rememberCoroutineScope()
    fun start() {
        try {
            app.prefs.setEnabled(AUDIO_SOURCE, true)
            audio.start(activity)
        } catch (_: Exception) {
            notify("暂时无法开启录音，请稍后重试")
        }
        after()
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result[Manifest.permission.RECORD_AUDIO] == true ||
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        ) {
            // The result arrives before the page is resumed, and capture may only start from a visible page:
            // starting here failed the first time ("无法开始录音") right after the permission dialogs.
            scope.launch { owner?.lifecycle?.withResumed { start() } ?: start() }
        } else notify("麦克风未允许，录音没有开启")
    }
    return {
        val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) permissions += Manifest.permission.POST_NOTIFICATIONS
        permission.launch(permissions.toTypedArray())
    }
}

internal data class RecordingNotice(
    val text: String,
    val route: String? = null,
    val start: Boolean = false,
    val openNotifications: Boolean = false,
)

internal fun recordingNotice(
    state: AudioState,
    wanted: Boolean,
    microphoneGranted: Boolean,
    notificationsBlocked: Boolean,
    macRemoved: Boolean,
): RecordingNotice? = when {
    !microphoneGranted && (wanted || state.recording) ->
        RecordingNotice("麦克风未授权", Sources.AUDIO)
    !state.recording && !wanted && state.message.isEmpty() ->
        RecordingNotice("录音没有开启", start = true)
    !state.recording && state.message.isNotEmpty() ->
        RecordingNotice(state.message, start = true)
    !state.modelsReady ->
        RecordingNotice("语音模型未准备，录音暂时不能转写", SettingsRoutes.SPEECH)
    state.message.isNotEmpty() -> RecordingNotice(state.message)
    notificationsBlocked -> RecordingNotice("录音通知未开启", openNotifications = true)
    macRemoved -> RecordingNotice("已在 Mac 上移除，请在 Mac 的 Tacit 里重新添加这台手机", SettingsRoutes.MAC)
    else -> null
}

@Composable
private fun NoticeAction(text: String, action: String, enabled: Boolean, onClick: () -> Unit) {
    Surface(color = tacitColors.fill, shape = MaterialTheme.shapes.medium) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(start = 16.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(text, Modifier.weight(1f), color = tacitColors.ink)
            PrimaryButton(action, onClick, enabled)
        }
    }
}

/** A passing condition the user can't act on (the phone is playing sound, another app holds the mic). */
@Composable
private fun NoticeText(text: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Outlined.ErrorOutline, null, Modifier.size(16.dp), tint = tacitColors.attention)
        Text(text, color = tacitColors.muted)
    }
}

/** Serif date as the day's anchor; today also carries the weekday under it. */
@Composable
private fun DayHeading(day: LocalDate, today: LocalDate, modifier: Modifier = Modifier, stacked: Boolean = false) {
    val relative = when (day) { today -> "今天"; today.minusDays(1) -> "昨天"; else -> null }
    val weekday = "星期" + "一二三四五六日"[day.dayOfWeek.value - 1]
    val note = listOfNotNull(relative, weekday).joinToString("，")
    val title = if (day.year == today.year) "${day.monthValue} 月 ${day.dayOfMonth} 日" else "${day.year} 年 ${day.monthValue} 月 ${day.dayOfMonth} 日"
    if (stacked) Column(modifier) {
        Text(title, style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Serif)
        Caption(note)
    } else Row(modifier, verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Serif)
        Caption(note, Modifier.padding(bottom = 4.dp))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun VoiceConfirmation(
    speaker: AudioSpeaker, enabled: Boolean, playing: Boolean, play: () -> Unit, mark: () -> Unit, ignore: () -> Unit,
) {
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
    // While the sample plays the button stops it and the wave lights up; the controller says when it ends.
    val wave by animateColorAsState(if (playing) tacitColors.accent else tacitColors.faint, Motion.quick(), label = "wave")
    GroupCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("这是你的声音吗？", style = MaterialTheme.typography.titleLarge)
            Caption("确认一次，之后自动认出你")
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FilledIconButton(onClick = play, enabled = enabled,
                    colors = IconButtonDefaults.filledIconButtonColors(containerColor = tacitColors.fill, contentColor = tacitColors.ink)) {
                    Crossfade(playing, animationSpec = Motion.quick(), label = "play") {
                        if (it) Icon(Icons.Outlined.Stop, "停止试听") else Icon(Icons.Outlined.PlayArrow, "试听")
                    }
                }
                Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    listOf(6, 12, 18, 10, 22, 14, 8, 16, 24, 12, 6, 14, 20, 10, 16, 8, 12, 18, 10, 6).forEach { height ->
                        Box(Modifier.width(3.dp).height(height.dp).background(wave, CircleShape))
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

private sealed class TimelineEntry(val key: String, val start: Instant) {
    class Projected(val item: TimelineItem) : TimelineEntry("projected-${item.id}", item.start)
    class Local(val scene: AudioConversationRow) : TimelineEntry("conversation-${scene.key}", Instant.ofEpochMilli(scene.start))
}

@Composable
private fun RecordedConversation(
    scene: AudioConversationRow, summary: ConversationSummary?, onConversation: (List<HistoryRecord>) -> Unit,
    modifier: Modifier, showsSource: Boolean = false,
) {
    val records = scene.records
    Row(
        modifier.fillMaxWidth().heightIn(min = 56.dp)
            .clickable(enabled = records.isNotEmpty()) { onConversation(records) }.padding(top = 12.dp, bottom = 12.dp, end = 12.dp),
    ) {
        Caption(date(scene.start, "HH:mm"), Modifier.width(56.dp).padding(top = 5.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // The title and summary once the phone or the Mac has written them. Until then a mixed timeline titles it like the
            // Mac's drafts ("一场对话" with the most telling sentence under it); the phone-only list uses that sentence as the title.
            // When the summary arrives it cross-fades in place of the sentence.
            val draftExcerpt = if (summary == null) telltaleSentence(records) else ""
            val title = summary?.title ?: if (showsSource) conversationTitle(scene.private)
                else draftExcerpt.ifBlank { conversationTitle(scene.private) }
            val text = summary?.summary ?: draftExcerpt.takeIf { showsSource && it.isNotBlank() }
            CrossSwap(title to text) { (title, text) ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(title,
                        style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Serif, fontWeight = FontWeight.Normal,
                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                    if (text != null) Text(text, color = tacitColors.muted, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (showsSource) SourceIcon(AUDIO_SOURCE, 14.dp)
                Caption(durationLabel(conversationDuration(records)))
                if (scene.private) PrivacyLock()
            }
        }
    }
}
