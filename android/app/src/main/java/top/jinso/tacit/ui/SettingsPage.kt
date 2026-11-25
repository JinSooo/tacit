package top.jinso.tacit.ui

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
    var parent by rememberSaveable { mutableStateOf<String?>(null) }
    val activity = LocalActivity.current ?: return
    var pendingPermission by rememberSaveable { mutableStateOf<String?>(null) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        refreshHealth()
        val granted = when (pendingPermission) {
            Sources.AUDIO -> activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            else -> app.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        }
        notify(if (granted) "权限已更新" else "未授权，可打开应用信息检查")
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
    val title = if (selected == Sources.AUDIO) "麦克风" else SettingsRoutes.title(selected) ?: "设置"
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
                                    "麦克风权限", status = if (granted) null else "未授权",
                                    problem = !granted, leading = { StatusMark(checkMark(granted)) },
                                ) {
                                    if (!granted) TonalButton("允许", ::requestMicrophone)
                                }
                                GroupDivider()
                            }
                            SettingsRow("系统麦克风开关", onClick = { openSystemPage(activity, SystemPage.PRIVACY, notify) })
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
        SettingsRow("录音", onClick = { if (on) { audio.stop(); on = false } else start() }, trailing = {
            Switch(on, null, Modifier.semantics { contentDescription = if (on) "录音已开启" else "录音已关闭" },
                colors = SwitchDefaults.colors(checkedTrackColor = tacitColors.accent, checkedThumbColor = tacitColors.paper))
        })
    }
    GroupCard {
        val macValue = when {
            mac == null -> null
            mac.removed -> "已移除"
            mac.name == null -> "未连接"
            else -> mac.name
        }
        SettingsRow("连接 Mac", value = macValue, problem = mac?.removed == true || (mac != null && mac.name == null),
            onClick = { open(SettingsRoutes.MAC) })
        GroupDivider()
        SettingsRow("语音转写", value = if (ready == false) "未准备" else null, problem = ready == false,
            onClick = { open(SettingsRoutes.SPEECH) })
        GroupDivider()
        val summary by produceState<JSONObject?>(null, app) {
            app.vault.changes.collect { value = withContext(Dispatchers.IO) { app.vault.summaryModel() } }
        }
        val summaryProblem = visibleSummaryProblem(summary)
        val summaryValue = summary?.takeIf { it.optBoolean("enabled") }?.optString("model")?.takeIf(String::isNotBlank)
        SettingsRow("AI 总结", status = summaryProblem, value = summaryValue.takeIf { summaryProblem == null },
            problem = summaryProblem != null, onClick = { open(SettingsRoutes.SUMMARY) })
        GroupDivider()
        SettingsRow("录音保留", value = retentionLabel(macDays ?: app.prefs.retentionDays),
            onClick = { open(SettingsRoutes.RETENTION) })
        GroupDivider()
        val problems = health?.let(::backgroundProblemCount) ?: 0
        SettingsRow("后台运行", value = if (problems > 0) "$problems 项要处理" else null, problem = problems > 0,
            onClick = { open(SettingsRoutes.BACKGROUND) })
    }
    Caption("Tacit ${BuildConfig.VERSION_NAME}")
}
