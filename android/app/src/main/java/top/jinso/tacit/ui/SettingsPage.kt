package top.jinso.tacit.ui

import top.jinso.tacit.R
import android.Manifest
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import top.jinso.tacit.BuildConfig
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.sync.MacStatus
import top.jinso.tacit.ui.components.*
import top.jinso.tacit.ui.onboarding.*

@Composable
internal fun SettingsPage(
    app: TacitApp,
    resumed: Int,
    notify: (String) -> Unit,
    offerUndo: (String, suspend () -> Unit) -> Unit,
    selected: String?,
    setRoute: (String?) -> Unit,
    onClose: () -> Unit,
    health: CollectionHealth?,
    mac: MacStatus?,
    macDays: Int?,
    refreshHealth: () -> Unit,
) {
    val strings = uiStrings()
    var parent by rememberSaveable { mutableStateOf<String?>(null) }
    val activity = LocalActivity.current ?: return
    var pendingPermission by rememberSaveable { mutableStateOf<String?>(null) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        refreshHealth()
        val granted = when (pendingPermission) {
            Sources.AUDIO -> activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            else -> app.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        }
        val requested = when {
            pendingPermission == Sources.AUDIO -> Manifest.permission.RECORD_AUDIO
            Build.VERSION.SDK_INT >= 33 -> Manifest.permission.POST_NOTIFICATIONS
            else -> null
        }
        // 被永久拒绝后系统不再弹框，直接打开系统设置让人手动开，免得“允许”变成点了没反应的按钮。
        if (!granted && (requested == null || !activity.shouldShowRequestPermissionRationale(requested))) {
            openSystemPage(activity, if (pendingPermission == Sources.AUDIO) SystemPage.APP else SystemPage.NOTIFICATIONS, notify)
        } else notify(if (granted) strings.text(R.string.permissions_updated) else strings.text(R.string.permission_missing_hint))
        pendingPermission = null
    }
    fun requestMicrophone() {
        pendingPermission = Sources.AUDIO
        permission.launch(arrayOf(Manifest.permission.RECORD_AUDIO))
    }
    fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingPermission = "tacit.notifications"
            permission.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
        } else openSystemPage(activity, SystemPage.NOTIFICATIONS, notify)
    }
    fun openMicrophone() {
        parent = selected.takeIf { it == SettingsRoutes.BACKGROUND }
        setRoute(Sources.AUDIO)
    }
    fun back() {
        setRoute(parent)
        parent = null
    }
    val title = if (selected == Sources.AUDIO) strings.text(R.string.microphone) else SettingsRoutes.title(selected, strings) ?: strings.text(R.string.settings)
    BackHandler(LocalContentActive.current) { if (selected != null) back() else onClose() }
    Column(Modifier.fillMaxSize().imePadding()) {
        PageBar(title, onBack = { if (selected != null) back() else onClose() })
        val reduceMotion = LocalReduceMotion.current
        // The bar stays put and only its title changes; the page below moves in or back by depth.
        AnimatedContent(selected, transitionSpec = {
            pageTransform(settingsDepth(initialState), settingsDepth(targetState), reduceMotion)
        }, label = "settings") { selected ->
            Column(
                Modifier.fillMaxSize().background(tacitColors.paper)
                    .verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                when (selected) {
                    SettingsRoutes.MAC -> MacConnectionPage(app)
                    SettingsRoutes.SPEECH -> SpeechSettings(app, notify, resumed, offerUndo)
                    SettingsRoutes.SUMMARY -> SummarySettings(app, notify)
                    SettingsRoutes.RETENTION -> AudioStorageSettings(app, notify)
                    SettingsRoutes.BACKGROUND -> BackgroundChecklist(health, ::openMicrophone, ::requestNotifications, notify)
                    Sources.AUDIO -> {
                        val granted = health?.microphoneGranted
                        GroupCard {
                            if (granted == null) {
                                ProgressLine()
                            } else {
                                SettingsRow(
                                    strings.text(R.string.microphone_permission), status = if (granted) null else strings.text(R.string.permission_missing),
                                    problem = !granted, leading = { StatusMark(checkMark(granted)) },
                                ) {
                                    if (!granted) TonalButton(strings.text(R.string.allow), ::requestMicrophone)
                                }
                                GroupDivider()
                            }
                            SettingsRow(strings.text(R.string.system_microphone_toggle), onClick = { openSystemPage(activity, SystemPage.PRIVACY, notify) })
                        }
                    }
                    else -> SettingsHome(app, health, mac, macDays, resumed, notify, setRoute)
                }
            }
        }
    }
}

/** The settings home, its pages, and the microphone page reached from 后台运行. */
private fun settingsDepth(route: String?) = when (route) { null -> 0; Sources.AUDIO -> 2; else -> 1 }

@Composable
private fun SettingsHome(
    app: TacitApp, health: CollectionHealth?, mac: MacStatus?, macDays: Int?, resumed: Int, notify: (String) -> Unit,
    open: (String) -> Unit,
) {
    val format = uiFormat()
    val strings = uiStrings()
    val ready by produceState<Boolean?>(null, app, resumed) {
        value = withContext(Dispatchers.IO) { runCatching { AudioController(app).state().modelsReady }.getOrNull() }
    }
    // Rows say something only when it is a choice the user made or needs their hand; "正常" is the default.
    val audio = remember(app) { AudioController(app) }
    // On is the default and stays on across reboots; this switch is the one place to turn it off besides the notification.
    var on by remember { mutableStateOf(app.prefs.audioCaptureWanted || audio.state().recording) }
    LaunchedEffect(audio) { audio.changes.collect { on = app.prefs.audioCaptureWanted || audio.state().recording } }
    val start = rememberRecordingStarter(app, audio, notify) { on = app.prefs.audioCaptureWanted || audio.state().recording }
    GroupCard {
        // The whole row is the switch, so it is one large target and reads as one control.
        SettingsRow(strings.text(R.string.recording), onClick = { if (on) { audio.stop(); on = false } else start() }, trailing = {
            Switch(on, null, Modifier.semantics { contentDescription = if (on) strings.text(R.string.recording_enabled) else strings.text(R.string.recording_disabled) },
                colors = SwitchDefaults.colors(checkedTrackColor = tacitColors.accent, checkedThumbColor = tacitColors.paper))
        })
    }
    GroupCard {
        val macValue = when {
            mac == null -> null
            mac.removed -> strings.text(R.string.removed)
            mac.name == null -> strings.text(R.string.not_connected)
            else -> mac.name
        }
        SettingsRow(strings.text(R.string.connect_mac), value = macValue, problem = mac?.removed == true,
            onClick = { open(SettingsRoutes.MAC) })
        GroupDivider()
        SettingsRow(strings.text(R.string.speech_transcription), value = if (ready == false) strings.text(R.string.models_not_ready) else null, problem = ready == false,
            onClick = { open(SettingsRoutes.SPEECH) })
        GroupDivider()
        val summary by produceState<JSONObject?>(null, app) {
            app.vault.changes.collect { value = withContext(Dispatchers.IO) { app.vault.summaryModel() } }
        }
        val summaryProblem = visibleSummaryProblem(summary)
        val summaryValue = summary?.takeIf { it.optBoolean("enabled") }?.optString("model")?.takeIf(String::isNotBlank)
        SettingsRow(strings.text(R.string.ai_summaries), status = summaryProblem, value = summaryValue.takeIf { summaryProblem == null },
            problem = summaryProblem != null, onClick = { open(SettingsRoutes.SUMMARY) })
        GroupDivider()
        SettingsRow(strings.text(R.string.audio_retention), value = format.retentionLabel(macDays ?: app.prefs.retentionDays),
            onClick = { open(SettingsRoutes.RETENTION) })
        GroupDivider()
        val problems = health?.let(::backgroundProblemCount) ?: 0
        SettingsRow(strings.text(R.string.background_operation), value = if (problems > 0) strings.quantity(R.plurals.setup_problem_count, problems, countLabel(problems)) else null, problem = problems > 0,
            onClick = { open(SettingsRoutes.BACKGROUND) })
    }
    VersionLine(app)
}

/** The app version with “Check for updates”; the result stays on this line. */
@Composable
private fun VersionLine(app: TacitApp) {
    val strings = uiStrings()
    val update by app.updates.state.collectAsState()
    val scope = rememberCoroutineScope()
    val uri = androidx.compose.ui.platform.LocalUriHandler.current
    val latest = update.latest
    DisposableEffect(Unit) { onDispose { app.updates.clearManual() } }
    Row(Modifier.fillMaxWidth().heightIn(min = 40.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Caption("Tacit ${BuildConfig.VERSION_NAME}")
        when {
            latest != null -> TextButton(onClick = { runCatching { uri.openUri(latest.page) } }) {
                Text(strings.text(R.string.download_version, latest.version), style = MaterialTheme.typography.bodySmall)
            }
            update.manual == top.jinso.tacit.data.UpdateCheck.Manual.CHECKING ->
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = tacitColors.muted)
            update.manual == top.jinso.tacit.data.UpdateCheck.Manual.UP_TO_DATE -> Caption(strings.text(R.string.up_to_date))
            else -> {
                if (update.manual == top.jinso.tacit.data.UpdateCheck.Manual.FAILED) Caption(strings.text(R.string.update_check_failed))
                TextButton(onClick = { scope.launch { app.updates.checkNow() } }) {
                    Text(strings.text(R.string.check_for_updates), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}
