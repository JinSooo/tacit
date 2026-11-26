package top.jinso.tacit.ui

import top.jinso.tacit.R
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
    val strings = uiStrings()
    val audio = remember(app) { AudioController(app) }
    var modelsReady by remember { mutableStateOf<Boolean?>(null) }
    var preparation by remember { mutableStateOf(audio.modelPreparation()) }
    var accelerationReady by remember { mutableStateOf(false) }
    var accelerationFallback by remember { mutableStateOf(audio.accelerationUsingFallback()) }
    val models = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val uri = result.data?.data
        if (result.resultCode == Activity.RESULT_OK && uri != null) {
            runCatching { audio.importModels(uri) }.onFailure { notify(strings.text(R.string.models_preparing)) }
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
        SettingsRow(strings.text(R.string.speech_models), status = if (modelsReady == false) strings.text(R.string.models_missing_size) else null,
            problem = modelsReady == false) {
            if (modelsReady != null && !preparation.busy) {
                val download = {
                    runCatching { audio.downloadModels() }.onFailure { notify(strings.text(R.string.models_preparing)) }
                    preparation = audio.modelPreparation()
                }
                if (modelsReady == true) TonalButton(strings.text(R.string.download_again), download)
                else PrimaryButton(strings.text(R.string.models_download), download)
            }
        }
        if (preparation.busy || preparation.message != null) {
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
                    Caption(preparation.message?.resolve(strings).orEmpty(), color = if (preparation.phase == SpeechPreparationPhase.ERROR)
                        tacitColors.attention else tacitColors.muted)
                }
                if (preparation.busy && preparation.phase != SpeechPreparationPhase.IMPORTING) {
                    TextAction(
                        if (preparation.cancelling) strings.text(R.string.cancelling) else strings.text(R.string.download_cancel),
                        { audio.cancelModelDownload(); preparation = audio.modelPreparation() },
                        enabled = preparation.canCancel,
                    )
                }
            }
        }
        GroupDivider()
        val canImport = modelsReady != null && !preparation.busy
        SettingsRow(
            if (modelsReady == true) strings.text(R.string.models_replace_folder) else strings.text(R.string.models_import_folder),
            onClick = if (canImport) {{
                models.launch(android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT_TREE)
                    .putExtra(android.content.Intent.EXTRA_LOCAL_ONLY, true)
                    .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION))
            }} else null,
        )
        if (audio.supportsNpu()) {
            GroupDivider()
            val status = when {
                !accelerationReady -> strings.text(R.string.acceleration_size)
                accelerationFallback -> strings.text(R.string.acceleration_cpu_fallback)
                else -> null
            }
            SettingsRow(strings.text(R.string.acceleration), status, problem = accelerationReady && accelerationFallback) {
                if (!accelerationReady) TonalButton(strings.text(R.string.prepare), {
                    runCatching { audio.downloadAcceleration() }.onFailure { notify(strings.text(R.string.acceleration_prepare_failed)) }
                    preparation = audio.modelPreparation()
                }, enabled = modelsReady == true && canImport)
            }
        }
    }
    Caption(strings.text(R.string.speech_models_hint))
    SpeakerSettings(audio, resumed, notify, offerUndo)
}

@Composable
private fun SpeakerSettings(
    audio: AudioController, resumed: Int, notify: (String) -> Unit, offerUndo: (String, suspend () -> Unit) -> Unit,
) {
    val format = uiFormat()
    val strings = uiStrings()
    var speakers by remember { mutableStateOf<List<AudioSpeaker>?>(null) }
    var loadFailed by remember { mutableStateOf(false) }
    var refresh by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(false) }
    var mineExpanded by rememberSaveable { mutableStateOf(false) }
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
                notify(strings.text(R.string.operation_failed))
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
                offerUndo(strings.text(R.string.voice_unmarked)) {
                    withContext(Dispatchers.IO) { audio.undoUnmarkMe(undo).get() }
                    refresh++
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                notify(strings.text(R.string.operation_failed))
            } finally {
                busy = false
            }
        }
    }

    SectionLabel(strings.text(R.string.voices))
    val current = speakers
    when {
        loadFailed -> GroupCard { SettingsRow(strings.text(R.string.voices_unavailable)) }
        current == null -> ProgressLine()
        else -> GroupCard {
            val (mine, others) = orderedSpeakers(current)
            val visible = mine + others
            val ignored = current.filter { it.ignored }
            if (current.isEmpty()) SettingsRow(strings.text(R.string.voices_empty))
            @Composable fun mineRow(speaker: AudioSpeaker, title: String, status: String) =
                SettingsRow(title, status = status) {
                    Row {
                        SpeakerPlay(speaker, !busy, playingSpeaker == speaker.id) { toggleSample(speaker.id) }
                        TextAction(strings.text(R.string.voice_not_me), { unmark(speaker.id) }, enabled = !busy)
                    }
                }
            // 好几个声音都被认成“我”时合成一行，点开逐个核对；每个都标上最近出现和说了多久。
            if (mine.size == 1) mineRow(mine[0], strings.text(R.string.speaker_me), format.speakerStatus(mine[0]))
            else if (mine.isNotEmpty()) {
                SettingsRow(strings.text(R.string.speaker_me), status = format.totalSpeechLabel(mine.sumOf { it.seconds }),
                    value = strings.quantity(R.plurals.voice_count, mine.size, countLabel(mine.size)), expanded = mineExpanded,
                    onClick = { mineExpanded = !mineExpanded })
                Reveal(mineExpanded) {
                    Column {
                        mine.forEach { speaker ->
                            GroupDivider()
                            mineRow(speaker, speaker.lastSeen?.let { format.lastHeardLabel(it) } ?: strings.text(R.string.earlier_recordings),
                                format.totalSpeechLabel(speaker.seconds))
                        }
                    }
                }
            }
            var unnamed = 0
            others.forEachIndexed { index, speaker ->
                if (index > 0 || mine.isNotEmpty()) GroupDivider()
                val label = speaker.name ?: strings.text(R.string.unnamed_voice, ++unnamed)
                SettingsRow(label, status = format.speakerStatus(speaker)) {
                    Row {
                        SpeakerPlay(speaker, !busy, playingSpeaker == speaker.id) { toggleSample(speaker.id) }
                        val action = if (speaker.name == null) strings.text(R.string.voice_name_add) else strings.text(R.string.voice_name_edit)
                        TextAction(action, {
                            speakerName = speaker.name.orEmpty()
                            namingTitle = action
                            naming = speaker.id
                        }, enabled = !busy)
                    }
                }
            }
            if (ignored.isNotEmpty()) {
                if (visible.isNotEmpty()) GroupDivider()
                SettingsRow(strings.text(R.string.voices_ignored), value = strings.quantity(R.plurals.ignored_voice_count, ignored.size, countLabel(ignored.size)),
                    expanded = expanded, onClick = { expanded = !expanded })
                Reveal(expanded) {
                    ignored.forEachIndexed { index, speaker ->
                        GroupDivider()
                        SettingsRow(speaker.name ?: strings.text(R.string.unnamed_voice, index + 1), status = format.speakerStatus(speaker)) {
                            Row {
                                SpeakerPlay(speaker, !busy, playingSpeaker == speaker.id) { toggleSample(speaker.id) }
                                TextAction(strings.text(R.string.restore), { work({ audio.setIgnored(speaker.id, false) }, strings.text(R.string.voice_restored)) }, enabled = !busy)
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
        text = { OutlinedTextField(speakerName, { speakerName = it.take(80) }, label = { Text(strings.text(R.string.voice_name)) }, singleLine = true) },
        confirmButton = { TextAction(strings.text(R.string.save), {
            val label = speakerName
            work({ audio.renameSpeaker(target, label) }, strings.text(R.string.voice_name_saved))
            naming = null
        }, enabled = !busy) },
        dismissButton = { TextAction(strings.text(R.string.cancel), { naming = null }) },
    )
}

@Composable
private fun SpeakerPlay(speaker: AudioSpeaker, enabled: Boolean, playing: Boolean, onClick: () -> Unit) {
    val strings = uiStrings()
    IconButton(onClick = onClick, enabled = enabled && (speaker.sampleAvailable || playing)) {
        Icon(if (playing) Icons.Outlined.Pause else Icons.Outlined.PlayArrow, if (playing) strings.text(R.string.preview_stop) else strings.text(R.string.preview_play))
    }
}

@Composable
internal fun rememberSampleToggle(audio: AudioController, notify: (String) -> Unit): (String) -> Unit {
    val strings = uiStrings()
    val scope = rememberCoroutineScope()
    DisposableEffect(audio) { onDispose { audio.stopPlayback() } }
    return { id ->
        val loading = audio.playSample(id)
        scope.launch {
            try { withContext(Dispatchers.IO) { loading.get() } }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { notify(strings.text(R.string.preview_unavailable)) }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun AudioStorageSettings(app: TacitApp, notify: (String) -> Unit) {
    val format = uiFormat()
    val strings = uiStrings()
    val audio = remember(app) { AudioController(app) }
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    fun work(task: () -> CompletableFuture<Unit>, success: String) {
        scope.launch {
            busy = true
            try { withContext(Dispatchers.IO) { task().get() }; notify(success) }
            catch (_: Exception) { notify(strings.text(R.string.operation_failed)) }
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
            SettingsRow(strings.text(R.string.local_recordings), value = strings.quantity(R.plurals.clip_count, it.clips, countLabel(it.clips)))
            GroupDivider()
        }
        val syncedDays = macDays
        if (syncedDays != null) {
            SettingsRow(strings.text(R.string.retention_period), status = strings.text(R.string.follows_mac), value = format.retentionLabel(syncedDays))
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
                Text(strings.text(R.string.keep_forever))
            }
            val entered = localRetentionDays(days, keepForever)
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                itemVerticalAlignment = Alignment.CenterVertically,
            ) {
                if (!keepForever) OutlinedTextField(
                    days, { days = it.filter(Char::isDigit).take(3) },
                    Modifier.widthIn(max = 180.dp), label = { Text(strings.text(R.string.retention_days)) }, singleLine = true,
                    enabled = !busy, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    isError = days.isNotEmpty() && entered == null,
                    supportingText = if (days.isNotEmpty() && entered == null) {
                        { Text(strings.text(R.string.retention_range, MAX_AUDIO_RETENTION_DAYS)) }
                    } else null,
                )
                val change = entered?.takeIf { it != savedDays }
                if (change != null) TonalButton(strings.text(R.string.save), {
                    app.prefs.retentionDays = change
                    savedDays = app.prefs.retentionDays
                    work({ audio.prune() }, strings.text(R.string.retention_updated))
                }, enabled = !busy)
            }
        }
        if (busy) ProgressLine()
    }
    Caption(strings.text(R.string.retention_hint))
    if (storage?.canClear == true) {
        Row(Modifier.fillMaxWidth().padding(top = 16.dp), horizontalArrangement = Arrangement.End) {
            TextAction(strings.text(R.string.delete_local_audio), { clear = true }, enabled = !busy, color = tacitColors.attention)
        }
    }
    if (clear) AlertDialog(
        onDismissRequest = { clear = false },
        title = { Text(strings.text(R.string.delete_local_audio_title)) },
        text = { Text(strings.text(R.string.delete_local_audio_message)) },
        confirmButton = { TextAction(strings.text(R.string.delete), {
            clear = false
            work({ audio.clearAudio() }, strings.text(R.string.local_audio_deleted))
        }, color = tacitColors.attention) },
        dismissButton = { TextAction(strings.text(R.string.cancel), { clear = false }) },
    )
}
