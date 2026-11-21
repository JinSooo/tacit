package top.jinso.tacit.ui

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon as AndroidIcon
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.BuildConfig
import top.jinso.tacit.MainActivity
import top.jinso.tacit.R
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.core.PausePolicy
import top.jinso.tacit.lifecycle.PauseResumeWorker
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.sync.MacStatus
import top.jinso.tacit.ui.components.*
import top.jinso.tacit.ui.onboarding.*

@Composable
internal fun SettingsPage(
    app: TacitApp,
    resumed: Int,
    notify: (String) -> Unit,
    initialSource: String?,
    setRoute: (String?) -> Unit,
    onOpenAudio: () -> Unit,
    health: CollectionHealth?,
    mac: MacStatus?,
    macDays: Int?,
    refreshHealth: () -> Unit,
) {
    var sourceParent by rememberSaveable { mutableStateOf<String?>(null) }
    val selected = initialSource.takeUnless { it == SettingsRoutes.PRIVACY }
    val paused = health?.paused ?: app.prefs.paused
    val activity = LocalActivity.current ?: return
    var pendingPermission by rememberSaveable { mutableStateOf<String?>(null) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        Sources.refresh(app)
        refreshHealth()
        val granted = when (pendingPermission) {
            Sources.AUDIO -> activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            "tacit.notifications" -> app.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
            else -> pendingPermission?.let { Sources.granted(app, it) } == true
        }
        notify(if (granted) "权限已更新，录音仍需手动开始" else "尚未允许权限，可打开应用信息检查")
        pendingPermission = null
    }
    fun appInfo() = openSystemPage(activity, SystemPage.APP, notify)
    fun requestMicrophone() {
        if (!app.prefs.enabled(Sources.AUDIO)) {
            notify("请先启用这个来源，再决定是否授权")
            return
        }
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
    fun openSource(id: String) {
        sourceParent = selected.takeIf { it == SettingsRoutes.SOURCES || it == SettingsRoutes.BACKGROUND }
        setRoute(id)
    }
    fun back() {
        setRoute(sourceParent)
        sourceParent = null
    }
    val entry = Sources.descriptors.firstOrNull { it.id == selected }
    val title = when {
        selected == Sources.AUDIO -> "麦克风与录音"
        entry != null -> entry.title
        else -> SettingsRoutes.title(selected)
    }
    BackHandler(selected != null) { back() }
    LaunchedEffect(entry?.id) { if (entry != null) Sources.refresh(app) }
    Column(Modifier.fillMaxSize().imePadding()) {
        if (selected != null) PageBar(title.orEmpty(), ::back)
        key(selected) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                when (selected) {
                    SettingsRoutes.MAC -> MacConnectionPage(app)
                    SettingsRoutes.SPEECH -> SpeechSettings(app, notify, resumed)
                    SettingsRoutes.RETENTION -> AudioStorageSettings(app, notify)
                    SettingsRoutes.EXCLUSIONS -> AppExclusions(app, resumed, notify)
                    SettingsRoutes.SHORTCUT -> ShortcutSettings(app, notify)
                    SettingsRoutes.BACKGROUND -> BackgroundChecklist(health, ::openSource, ::requestNotifications, notify)
                    SettingsRoutes.SOURCES -> SourceCards(app, health, ::openSource) { id, enabled ->
                        Sources.setEnabled(app, id, enabled)
                        refreshHealth()
                    }
                    Sources.AUDIO -> {
                        Caption("只在你点开始后录音。")
                        val granted = health?.microphoneGranted
                        GroupCard {
                            SettingsRow(
                                "麦克风权限", when (granted) { true -> "已允许"; false -> "尚未允许"; null -> "正在检查" },
                                problem = granted == false, leading = { StatusMark(checkMark(granted)) },
                            ) {
                                if (granted == false && health.microphoneCaptureExpected) {
                                    TonalButton("允许", ::requestMicrophone)
                                } else TonalButton("检查", ::appInfo)
                            }
                            GroupDivider()
                            SettingsRow("系统麦克风开关", onClick = { openSystemPage(activity, SystemPage.PRIVACY, notify) })
                            GroupDivider()
                            SettingsRow("应用信息", onClick = ::appInfo)
                            GroupDivider()
                            SettingsRow("去录音页", onClick = { setRoute(null); onOpenAudio() })
                        }
                    }
                    else -> if (entry != null) {
                        Caption(entry.description)
                        val sourceHealth = health?.sources?.firstOrNull { it.id == entry.id }
                        val enabled = app.prefs.enabled(entry.id)
                        val granted = sourceHealth?.granted ?: Sources.granted(app, entry.id)
                        GroupCard {
                            SettingsRow("启用") {
                                SourceSwitch("启用${entry.title}", enabled) {
                                    Sources.setEnabled(app, entry.id, it)
                                    refreshHealth()
                                }
                            }
                            GroupDivider()
                            SettingsRow("系统权限", sourceHealth?.permissionText ?: if (granted) "已允许" else "尚未允许",
                                problem = enabled && !granted) {
                                TonalButton(if (granted) "检查" else "去授权", onClick = {
                                    runCatching { activity.startActivity(Sources.permissionIntent(app, entry.id)) }.onFailure { appInfo() }
                                }, enabled = enabled)
                            }
                            GroupDivider()
                            SettingsRow("应用信息", onClick = ::appInfo)
                        }
                        if (entry.id == Sources.NOTIFICATION) ChatApps(app, resumed, notify)
                    } else {
                        SettingsHome(
                            app, health, mac, macDays, resumed, paused, setRoute, ::openSource,
                            onToggle = { id, enabled -> Sources.setEnabled(app, id, enabled); refreshHealth() },
                            onPause = { until -> PauseResumeWorker.change(app, until != null, until ?: 0L); refreshHealth() },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsHome(
    app: TacitApp, health: CollectionHealth?, mac: MacStatus?, macDays: Int?, resumed: Int, paused: Boolean,
    open: (String) -> Unit, openSource: (String) -> Unit, onToggle: (String, Boolean) -> Unit, onPause: (Long?) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val ready by produceState<Boolean?>(null, app, resumed) {
        value = withContext(Dispatchers.IO) { runCatching { AudioController(app).state().modelsReady }.getOrNull() }
    }
    val count = enabledSourceCount(app, health)
    GroupCard {
        SettingsRow(
            when { paused -> "已暂停"; count == 0 -> "未在记录"; else -> "正在记录" },
            if (paused && app.prefs.pauseUntil > 0) "到 " + date(app.prefs.pauseUntil, "M 月 d 日 HH:mm") else "$count 个来源开着",
        ) {
            Box {
                TonalButton(if (paused) "继续" else "暂停", { if (paused) onPause(null) else menu = true })
                DropdownMenu(menu, { menu = false }) {
                    val now = System.currentTimeMillis()
                    listOf("暂停 1 小时" to now + 3_600_000, "暂停到明天" to PausePolicy.tomorrow(now), "暂停，手动继续" to 0L)
                        .forEach { (label, until) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { onPause(until); menu = false })
                        }
                }
            }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel("来源")
        SourceCards(app, health, openSource, onToggle)
    }
    GroupCard {
        val status = when {
            mac == null -> "正在读取"
            mac.removed -> "已在 Mac 上移除"
            mac.name == null -> "未连接"
            mac.lastSync == 0L -> "已连接，尚未同步"
            else -> "已连接，${syncAge(mac.lastSync)}同步"
        }
        SettingsRow("连接 Mac", status, problem = mac?.removed == true, icon = Icons.Outlined.Computer,
            onClick = { open(SettingsRoutes.MAC) })
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        GroupCard {
            SettingsRow("语音转写", value = when (ready) { true -> "已就绪"; false -> "未准备"; null -> null },
                onClick = { open(SettingsRoutes.SPEECH) })
            GroupDivider()
            val retention = retentionLabel(macDays ?: app.prefs.retentionDays)
            SettingsRow("录音保留", value = if (macDays != null && macDays != 0) "$retention，随 Mac" else retention,
                onClick = { open(SettingsRoutes.RETENTION) })
            GroupDivider()
            SettingsRow("不记录的应用", value = "${app.prefs.blockedApps.size} 个",
                onClick = { open(SettingsRoutes.EXCLUSIONS) })
        }
        Caption("记录和录音加密保存在这台手机上。")
    }
    GroupCard {
        val problems = health?.let(::backgroundProblemCount)
        SettingsRow("后台运行", value = when (problems) { null -> null; 0 -> "正常"; else -> "$problems 项要处理" },
            problem = (problems ?: 0) > 0, onClick = { open(SettingsRoutes.BACKGROUND) })
        GroupDivider()
        SettingsRow("桌面快捷补写", onClick = { open(SettingsRoutes.SHORTCUT) })
    }
    Caption("Tacit ${BuildConfig.VERSION_NAME}")
}

@Composable
private fun SourceCards(app: TacitApp, health: CollectionHealth?, open: (String) -> Unit, onToggle: (String, Boolean) -> Unit) {
    val lackingMic = health?.microphoneGranted == false
    val recording = health?.audioRunning == true
    GroupCard {
        SettingsRow(
            "录音", when { lackingMic -> "需要麦克风权限"; recording -> "录音中"; else -> "未在录音" },
            problem = lackingMic, icon = Icons.Outlined.Mic, onClick = { open(Sources.AUDIO) },
        )
        listOf(Sources.NOTIFICATION to Icons.Outlined.ChatBubbleOutline, Sources.USAGE to Icons.Outlined.GridView)
            .forEach { (id, icon) ->
                GroupDivider()
                val enabled = app.prefs.enabled(id)
                val state = health?.sources?.firstOrNull { it.id == id }?.copy(enabled = enabled)
                val status = if (state != null) sourceStatus(state, health) else if (enabled) "已启用" else "未启用"
                val name = sourceName(id)
                SettingsRow(name, status, problem = enabled && state?.granted == false, icon = icon, onClick = { open(id) }) {
                    SourceSwitch(name, enabled) { onToggle(id, it) }
                }
            }
    }
}

@Composable
private fun SourceSwitch(label: String, enabled: Boolean, toggle: (Boolean) -> Unit) {
    Switch(enabled, toggle, modifier = Modifier.semantics { contentDescription = label }, colors = SwitchDefaults.colors(
        checkedThumbColor = tacitColors.onAccent, checkedTrackColor = tacitColors.accent,
        uncheckedBorderColor = tacitColors.muted, uncheckedThumbColor = tacitColors.muted, uncheckedTrackColor = tacitColors.fill,
    ))
}

@Composable
private fun ShortcutSettings(app: TacitApp, notify: (String) -> Unit) {
    Caption("可以添加独立入口，或长按桌面 Tacit 图标补写。")
    TonalButton("添加到桌面", {
        val manager = app.getSystemService(ShortcutManager::class.java)
        if (manager.isRequestPinShortcutSupported) {
            val shortcut = ShortcutInfo.Builder(app, "write").setShortLabel("写一条记录")
                .setIcon(AndroidIcon.createWithResource(app, R.drawable.ic_stat_tacit))
                .setIntent(Intent(app, MainActivity::class.java).setAction("top.jinso.tacit.WRITE")).build()
            manager.requestPinShortcut(shortcut, null)
        } else notify("当前桌面不支持添加，请长按 Tacit 图标使用")
    })
}
