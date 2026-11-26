package top.jinso.tacit.ui

import top.jinso.tacit.R
import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.UiStrings
import java.util.Locale
import java.time.format.DateTimeFormatter
import java.time.ZoneId
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
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
    offerUndo: (String, suspend () -> Unit) -> Unit,
    onOpenSettings: (String?) -> Unit,
    onConversation: (List<HistoryRecord>) -> Unit,
    timeline: TimelineSnapshot,
    day: LocalDate,
    onDay: (LocalDate) -> Unit,
    onTimelineItem: (TimelineItem) -> Unit,
    macRemoved: Boolean,
    health: CollectionHealth?,
) {
    val format = uiFormat()
    val strings = uiStrings()
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
                notify(strings.text(R.string.operation_failed))
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
    val manualTranscriptions by audio.manualTranscriptions.collectAsState()
    val toggleSample = rememberSampleToggle(audio, notify)
    var sheetMessage by remember { mutableStateOf<String?>(null) }
    val toggleConversationSample: (String) -> Unit = { conversationId ->
        val loading = audio.playConversationSample(conversationId)
        scope.launch {
            try { withContext(Dispatchers.IO) { loading.get() } }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) {
                val msg = strings.text(R.string.preview_unavailable)
                sheetMessage = msg
                notify(msg)
            }
        }
    }
    DisposableEffect(Unit){onDispose{audio.stopPlayback()}}
    // Each day has its own cards, so a sample playing for the old day would keep going with no stop button in sight.
    var showUntranscribed by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(day) { audio.stopPlayback(); showUntranscribed = false; sheetMessage = null }
    val candidate = myVoiceOverview(speakers, macVoice).candidate
    val today = LocalDate.now()
    val local = remember(rows, timeline.days, today) {
        val projectedIds = timeline.days.flatMap { (date, value) -> value.entries(date == today) }
            .flatMap { it.recordIds }.toSet()
        undisplayedConversations(rows, projectedIds).groupBy { Instant.ofEpochMilli(it.start).atZone(ZoneId.systemDefault()).toLocalDate() }
    }
    val untranscribedByDay = remember(rows) {
        rows.filter { it.hasUntranscribedClips }
            .distinctBy { it.conversationId }
            .groupBy { Instant.ofEpochMilli(it.untranscribedStart ?: it.start).atZone(ZoneId.systemDefault()).toLocalDate() }
            .mapValues { (_, list) -> list.sortedByDescending { it.untranscribedStart ?: it.start } }
    }
    val availableDays = local.keys + untranscribedByDay.keys + timeline.days.filter { (date, value) ->
        !value.overview.isNullOrBlank() || value.entries(date == today).isNotEmpty()
    }.keys
    val earlier = availableDays.filter { it < day }.maxOrNull()
    val later = availableDays.filter { it > day }.minOrNull()
    val reduceMotion = LocalReduceMotion.current
    val (shiftIn, shiftOut) = with(LocalDensity.current) { 24.dp.roundToPx() to 16.dp.roundToPx() }
    var showDatePicker by rememberSaveable { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        // The date bar stays put while the day below changes, so the arrows never move under a finger.
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 20.dp, bottom = 4.dp), verticalAlignment = Alignment.Top) {
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = 48.dp)
                    .clip(MaterialTheme.shapes.small)
                    .clickable(role = Role.Button, onClickLabel = strings.text(R.string.select_date)) {
                        showDatePicker = true
                    }
                    .padding(top = 8.dp, end = 4.dp, bottom = 4.dp),
            ) {
                Crossfade(day, animationSpec = Motion.quick(), label = "day-title") {
                    DayHeading(it, today, stacked = true, showPickerHint = true)
                }
            }
            val earlierTint by animateColorAsState(if (earlier != null) tacitColors.muted else tacitColors.faint, Motion.quick(), label = "earlier")
            val laterTint by animateColorAsState(if (later != null) tacitColors.muted else tacitColors.faint, Motion.quick(), label = "later")
            IconButton(onClick = { earlier?.let(onDay) }, enabled = earlier != null) {
                Icon(Icons.AutoMirrored.Outlined.KeyboardArrowLeft, strings.text(R.string.previous_day), tint = earlierTint)
            }
            if (day != today) TextButton(onClick = { onDay(today) }) { Text(strings.text(R.string.today)) }
            IconButton(onClick = { later?.let(onDay) }, enabled = later != null) {
                Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, strings.text(R.string.next_day), tint = laterTint)
            }
            IconButton(onClick = { onOpenSettings(null) }) {
                Icon(Icons.Outlined.Settings, strings.text(R.string.settings), tint = tacitColors.muted)
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
            health?.recordingNotificationsBlocked == true, macRemoved, strings,
        )
        if (notice != null) item(key = "notice") {
                    Box(Modifier.itemMotion(this).padding(end = 12.dp, top = 8.dp)) {
                val route = notice.route
                when {
                    notice.start -> NoticeAction(notice.text, strings.text(R.string.turn_on), !busy, startRecording)
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
                        work({ audio.markMe(candidate.id) }, strings.text(R.string.voice_marked_me)) {
                            speakers = speakers.map { if (it.id == candidate.id) it.copy(isMe = true) else it }
                        }
                    },
                    ignore = {
                        audio.stopPlayback()
                        scope.launch {
                            busy = true
                            try {
                                withContext(Dispatchers.IO) { audio.setIgnored(candidate.id, true).get() }
                                speakers = speakers.filterNot { it.id == candidate.id }
                                offerUndo(strings.text(R.string.voice_try_another)) {
                                    withContext(Dispatchers.IO) { audio.setIgnored(candidate.id, false).get() }
                                }
                            } catch (error: CancellationException) {
                                throw error
                            } catch (_: Exception) {
                                notify(strings.text(R.string.operation_failed))
                            } finally {
                                busy = false
                            }
                        }
                    },
                )
            }
        }
                if ((!loaded && !loadFailed) || busy) item(key = "progress") { ProgressLine(Modifier.itemMotion(this).padding(end = 12.dp, top = 8.dp)) }
                if (loadFailed) item(key = "failed") {
                    Caption(strings.text(R.string.recordings_unavailable), Modifier.itemMotion(this).padding(top = 16.dp), color = tacitColors.attention)
        } else if (loaded && day !in availableDays) item(key = "empty") {
                    Text(strings.text(R.string.timeline_empty), Modifier.itemMotion(this).padding(top = 48.dp, end = 12.dp),
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
        val untranscribed = untranscribedByDay[day].orEmpty()
        if (untranscribed.isNotEmpty()) item(key = "untranscribed-$day") {
            val caption = if (entries.isNotEmpty()) R.plurals.more_audio_without_voice else R.plurals.audio_without_voice
            Row(
                Modifier
                    .itemMotion(this)
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clip(MaterialTheme.shapes.small)
                    .clickable(role = Role.Button) {
                        sheetMessage = null
                        showUntranscribed = true
                    }
                    .padding(top = 12.dp, bottom = 12.dp, end = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.width(format.timeColumnWidth.dp)) {
                    Box(Modifier.width(16.dp).height(1.dp).background(tacitColors.faint))
                }
                Caption(
                    strings.quantity(caption, untranscribed.size, countLabel(untranscribed.size)),
                    Modifier.weight(1f),
                )
                Icon(Icons.Outlined.ChevronRight, null, Modifier.size(16.dp), tint = tacitColors.muted)
            }
        }
        timeline.staleSync(day)?.let { instant ->
            val synced = if (instant.atZone(ZoneId.systemDefault()).toLocalDate() == day) format.clock(instant.toEpochMilli())
                else format.dateAndClock(instant.toEpochMilli())
            item(key = "timeline-sync-time") {
                Caption(strings.text(R.string.timeline_synced, synced), Modifier.padding(top = 12.dp, end = 12.dp))
            }
        }
    }
        }
    }
    val untranscribedForDay = untranscribedByDay[day].orEmpty()
    LaunchedEffect(untranscribedForDay, playingSpeaker, showUntranscribed) {
        if (!showUntranscribed) return@LaunchedEffect
        val activeKeys = untranscribedForDay.mapTo(HashSet()) { conversationPlaybackKey(it.conversationId) }
        val activePlaying = playingSpeaker
        if (activePlaying != null && activePlaying.startsWith("conversation:") && activePlaying !in activeKeys) {
            audio.stopPlayback()
        }
        if (untranscribedForDay.isEmpty()) {
            audio.stopPlayback()
            showUntranscribed = false
            sheetMessage = null
        }
    }
    if (showUntranscribed && untranscribedForDay.isNotEmpty()) {
        UntranscribedAudioSheet(
            scenes = untranscribedForDay,
            modelsReady = state.modelsReady,
            busy = busy,
            playingKey = playingSpeaker,
            statuses = manualTranscriptions,
            statusMessage = sheetMessage,
            onTogglePlay = toggleConversationSample,
            onTranscribe = { scene ->
                audio.stopPlayback()
                scope.launch {
                    busy = true
                    try {
                        val targetClips = scene.untranscribedClipIds.toSet()
                        withContext(Dispatchers.IO) {
                            audio.transcribeConversation(scene.conversationId, targetClips).get()
                        }
                        val msg = strings.text(
                            if (state.modelsReady) R.string.transcribe_queued else R.string.transcribe_queued_models_missing,
                        )
                        sheetMessage = msg
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        sheetMessage = strings.text(R.string.operation_failed)
                    } finally {
                        busy = false
                    }
                }
            },
            onRetry = { scene ->
                audio.stopPlayback()
                scope.launch {
                    busy = true
                    try {
                        withContext(Dispatchers.IO) {
                            audio.retryConversationTranscription(scene.conversationId).get()
                        }
                        val msg = strings.text(
                            if (state.modelsReady) R.string.transcribe_queued else R.string.transcribe_queued_models_missing,
                        )
                        sheetMessage = msg
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        sheetMessage = strings.text(R.string.operation_failed)
                    } finally {
                        busy = false
                    }
                }
            },
            onDelete = { scene ->
                audio.stopPlayback()
                scope.launch {
                    busy = true
                    try {
                        val result = withContext(Dispatchers.IO) { audio.deleteConversationAudio(scene.conversationId).get() }
                        val msg = when (result) {
                            DeleteConversationAudioResult.DELETED -> strings.text(R.string.deleted)
                            DeleteConversationAudioResult.ALREADY_TRANSCRIBED -> strings.text(R.string.untranscribed_already_transcribed)
                            DeleteConversationAudioResult.NOT_FOUND -> strings.text(R.string.untranscribed_already_removed)
                        }
                        sheetMessage = msg
                        notify(msg)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        sheetMessage = strings.text(R.string.delete_retry)
                    } finally {
                        busy = false
                    }
                }
            },
            onDismiss = {
                audio.stopPlayback()
                showUntranscribed = false
                sheetMessage = null
            },
        )
    }
    if (showDatePicker) {
        TimelineDatePickerSheet(
            selected = day,
            today = today,
            availableDays = availableDays,
            onSelect = { chosen ->
                onDay(chosen)
                showDatePicker = false
            },
            onDismiss = { showDatePicker = false },
        )
    }
}

/** One tap does both system prompts and the start, because capture may only begin from a visible page. */
@Composable
internal fun rememberRecordingStarter(app: TacitApp, audio: AudioController, notify: (String) -> Unit, after: () -> Unit): () -> Unit {
    val strings = uiStrings()
    val activity = LocalActivity.current ?: return {}
    val owner = activity as? LifecycleOwner
    val scope = rememberCoroutineScope()
    fun start() {
        try {
            app.prefs.setEnabled(AUDIO_SOURCE, true)
            audio.start(activity)
        } catch (_: Exception) {
            notify(strings.text(R.string.recording_start_failed))
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
        } else notify(strings.text(R.string.microphone_ungranted_recording))
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
    strings: UiStrings,
): RecordingNotice? = when {
    !microphoneGranted && (wanted || state.recording) ->
        RecordingNotice(strings.text(R.string.microphone_ungranted), Sources.AUDIO)
    !state.recording && !wanted && state.message == null ->
        RecordingNotice(strings.text(R.string.recording_off), start = true)
    !state.recording && state.message != null ->
        RecordingNotice(strings.text(state.message), start = true)
    !state.modelsReady ->
        RecordingNotice(strings.text(R.string.recording_models_missing), SettingsRoutes.SPEECH)
    state.message != null -> RecordingNotice(strings.text(state.message))
    notificationsBlocked -> RecordingNotice(strings.text(R.string.recording_notifications_off), openNotifications = true)
    macRemoved -> RecordingNotice(strings.text(R.string.mac_removed_notice), SettingsRoutes.MAC)
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
private fun DayHeading(
    day: LocalDate,
    today: LocalDate,
    modifier: Modifier = Modifier,
    stacked: Boolean = false,
    showPickerHint: Boolean = false,
) {
    val strings = uiStrings()
    val relative = when (day) { today -> strings.text(R.string.today); today.minusDays(1) -> strings.text(R.string.yesterday); else -> null }
    val lang = uiFormat().lang
    val locale = if (lang == AppLang.ZH) Locale.SIMPLIFIED_CHINESE else Locale.ENGLISH
    val titlePattern = strings.text(if (day.year == today.year) R.string.day_heading else R.string.day_heading_year)
    val title = day.format(DateTimeFormatter.ofPattern(titlePattern, locale))
    val weekday = day.format(DateTimeFormatter.ofPattern(strings.text(R.string.weekday_pattern), locale))
    val note = relative?.let { strings.text(R.string.day_heading_note, it, weekday) } ?: weekday
    @Composable fun titleWithHint() = Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(title, style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Serif)
        if (showPickerHint) {
            Icon(
                Icons.Outlined.KeyboardArrowDown,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = tacitColors.muted,
            )
        }
    }
    if (stacked) Column(modifier) {
        titleWithHint()
        if (note != null) Caption(note)
    } else Row(modifier, verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        titleWithHint()
        if (note != null) Caption(note, Modifier.padding(bottom = 4.dp))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun VoiceConfirmation(
    speaker: AudioSpeaker, enabled: Boolean, playing: Boolean, play: () -> Unit, mark: () -> Unit, ignore: () -> Unit,
) {
    val strings = uiStrings()
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
            Text(strings.text(R.string.voice_question), style = MaterialTheme.typography.titleLarge)
            Caption(strings.text(R.string.voice_question_hint))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FilledIconButton(onClick = play, enabled = enabled,
                    colors = IconButtonDefaults.filledIconButtonColors(containerColor = tacitColors.fill, contentColor = tacitColors.ink)) {
                    Crossfade(playing, animationSpec = Motion.quick(), label = "play") {
                        if (it) Icon(Icons.Outlined.Stop, strings.text(R.string.preview_stop)) else Icon(Icons.Outlined.PlayArrow, strings.text(R.string.preview_play))
                    }
                }
                Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    listOf(6, 12, 18, 10, 22, 14, 8, 16, 24, 12, 6, 14, 20, 10, 16, 8, 12, 18, 10, 6).forEach { height ->
                        Box(Modifier.width(3.dp).height(height.dp).background(wave, CircleShape))
                    }
                }
                seconds?.let { Caption(strings.quantity(R.plurals.sample_seconds, it, countLabel(it))) }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PrimaryButton(strings.text(R.string.voice_yes), mark, enabled)
                TonalButton(strings.text(R.string.voice_no), ignore, enabled = enabled)
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
    val format = uiFormat()
    val records = scene.records
    Row(
        modifier.fillMaxWidth().heightIn(min = 56.dp)
            .clickable(enabled = records.isNotEmpty()) { onConversation(records) }.padding(top = 12.dp, bottom = 12.dp, end = 12.dp),
    ) {
        Caption(format.clock(scene.start), Modifier.width(format.timeColumnWidth.dp).padding(top = 5.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // The title and summary once the phone or the Mac has written them. Until then a mixed timeline titles it like the
            // Mac's drafts ("一场对话" with the most telling sentence under it); the phone-only list uses that sentence as the title.
            // When the summary arrives it cross-fades in place of the sentence.
            val draftExcerpt = if (summary == null) telltaleSentence(records) else ""
            val title = summary?.title ?: if (showsSource) format.conversationTitle(scene.private)
                else draftExcerpt.ifBlank { format.conversationTitle(scene.private) }
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
                Caption(format.durationLabel(conversationDuration(records)))
                if (scene.private) PrivacyLock()
            }
        }
    }
}
