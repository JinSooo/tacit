package top.jinso.tacit.ui

import android.Manifest
import android.app.NotificationManager
import android.content.pm.PackageManager
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
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
    selected: String?,
    setRoute: (String?) -> Unit,
    onOpenAudio: () -> Unit,
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
        notify(if (granted) "权限已更新，录音仍需手动开始" else "尚未允许权限，可打开应用信息检查")
        pendingPermission = null
    }
    fun appInfo() = openSystemPage(activity, SystemPage.APP, notify)
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
    val title = if (selected == Sources.AUDIO) "麦克风" else SettingsRoutes.title(selected)
    BackHandler(selected != null) { back() }
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
                    SettingsRoutes.BACKGROUND -> BackgroundChecklist(health, ::openMicrophone, ::requestNotifications, notify)
                    Sources.AUDIO -> {
                        Caption("只在你点开始后录音。")
                        val granted = health?.microphoneGranted
                        GroupCard {
                            SettingsRow(
                                "麦克风权限", when (granted) { true -> "已允许"; false -> "尚未允许"; null -> "正在检查" },
                                problem = granted == false, leading = { StatusMark(checkMark(granted)) },
                            ) {
                                if (granted == false) TonalButton("允许", ::requestMicrophone)
                                else TonalButton("检查", ::appInfo)
                            }
                            GroupDivider()
                            SettingsRow("系统麦克风开关", onClick = { openSystemPage(activity, SystemPage.PRIVACY, notify) })
                            GroupDivider()
                            SettingsRow("去录音页", onClick = { setRoute(null); onOpenAudio() })
                        }
                    }
                    else -> SettingsHome(app, health, mac, macDays, resumed, setRoute)
                }
            }
        }
    }
}

@Composable
private fun SettingsHome(
    app: TacitApp, health: CollectionHealth?, mac: MacStatus?, macDays: Int?, resumed: Int, open: (String) -> Unit,
) {
    val ready by produceState<Boolean?>(null, app, resumed) {
        value = withContext(Dispatchers.IO) { runCatching { AudioController(app).state().modelsReady }.getOrNull() }
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
        }
        Caption("录音和转写加密保存在这台手机上。")
    }
    GroupCard {
        val problems = health?.let(::backgroundProblemCount)
        SettingsRow("后台运行", value = when (problems) { null -> null; 0 -> "正常"; else -> "$problems 项要处理" },
            problem = (problems ?: 0) > 0, onClick = { open(SettingsRoutes.BACKGROUND) })
    }
    Caption("Tacit ${BuildConfig.VERSION_NAME}")
}
