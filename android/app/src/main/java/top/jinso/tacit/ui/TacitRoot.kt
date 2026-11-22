package top.jinso.tacit.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStoreOwner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.data.Vault
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.sync.MacStatus
import top.jinso.tacit.ui.components.*
import top.jinso.tacit.ui.onboarding.*

private const val RECORDING_TAB = 0
private const val SETTINGS_TAB = 1

@Composable
fun TacitRoot(app: TacitApp, resumed: Int) = TacitTheme {
    val scope = rememberCoroutineScope()
    val activity = LocalActivity.current as ViewModelStoreOwner
    val reading = remember(activity) { ViewModelProvider(activity)[ReadingModel::class.java] }
    var vault by remember { mutableStateOf<Vault?>(null) }
    var locked by remember { mutableStateOf(false) }
    var tab by rememberSaveable { mutableIntStateOf(RECORDING_TAB) }
    var hubRoute by rememberSaveable { mutableStateOf<String?>(null) }
    var healthRefresh by remember { mutableIntStateOf(0) }
    val health = rememberCollectionHealth(app, resumed, healthRefresh)
    val mac by rememberConnection(app, vault, resumed)
    val detail = reading.detail
    val conversation = reading.conversation
    val snackbar = remember { SnackbarHostState() }
    fun notify(text: String) { scope.launch { snackbar.showSnackbar(text) } }
    fun settings(route: String?) {
        hubRoute = route
        tab = SETTINGS_TAB
    }
    fun back() {
        if (detail != null) reading.detail = null else reading.conversation = emptyList()
    }
    LaunchedEffect(Unit) {
        try { vault = withContext(Dispatchers.IO) { app.vault } }
        catch (_: Exception) { locked = true }
    }
    val open = detail != null || conversation.isNotEmpty()
    BackHandler(open) { back() }
    val showTabs = !open && (tab != SETTINGS_TAB || hubRoute == null)
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        containerColor = tacitColors.paper,
        contentWindowInsets = WindowInsets.safeDrawing,
        bottomBar = {
            if (showTabs) {
                Column {
                    GroupDivider()
                    NavigationBar(containerColor = tacitColors.paper, tonalElevation = 0.dp) {
                        listOf("录音" to Icons.Outlined.Mic, "设置" to Icons.Outlined.Settings)
                            .forEachIndexed { index, (name, icon) ->
                                NavigationBarItem(
                                    selected = tab == index, onClick = { tab = index },
                                    icon = { Icon(icon, null) },
                                    label = { Text(name, fontWeight = if (tab == index) FontWeight.Medium else FontWeight.Normal) },
                                    colors = NavigationBarItemDefaults.colors(
                                        selectedIconColor = tacitColors.accent, selectedTextColor = tacitColors.ink,
                                        indicatorColor = tacitColors.accentContainer,
                                        unselectedIconColor = tacitColors.muted, unselectedTextColor = tacitColors.muted,
                                    ),
                                )
                            }
                    }
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
            val store = vault
            val recovery: @Composable () -> Unit = {
                if (health != null) CollectionRecoveryNotice(
                    health, { settings(Sources.AUDIO) }, { tab = RECORDING_TAB }, ::notify,
                    onAudioPage = tab == RECORDING_TAB,
                )
            }
            when {
                locked -> EmptyState("记录库暂时无法打开", "密钥或数据库不可用，原文件已保留，请勿卸载应用或清除数据。")
                store == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                detail != null -> RecordDetail(
                    detail, store, app, onBack = ::back, notify = ::notify,
                    onSelect = { reading.detail = it },
                    onDelete = { record ->
                        scope.launch {
                            try {
                                withContext(Dispatchers.IO) {
                                    if (record.source == Sources.AUDIO) AudioController(app).deleteRecordAudio(record.id).get()
                                    store.delete(record.id)
                                }
                                reading.conversation = reading.conversation.filterNot { it.id == record.id }
                                reading.detail = null
                                notify("已删除记录及关联修正")
                            } catch (_: Exception) { notify("删除未完成，请重试") }
                        }
                    },
                )
                conversation.isNotEmpty() -> ConversationDetail(conversation, app, store, ::back) { reading.detail = it }
                tab == RECORDING_TAB -> {
                    val synced = mac?.status?.let {
                        when {
                            it.removed -> "已在 Mac 上移除"
                            it.name == null -> "未连接 Mac"
                            it.lastSync == 0L -> "尚未同步到 Mac"
                            else -> "${syncAge(it.lastSync)}同步到 Mac"
                        }
                    }
                    AudioPage(app, resumed, ::notify, ::settings, { reading.conversation = it }, mac?.retentionDays, synced, recovery)
                }
                else -> SettingsPage(
                    app, resumed, ::notify, hubRoute, { hubRoute = it }, { tab = RECORDING_TAB },
                    health, mac?.status, mac?.retentionDays, { healthRefresh++ },
                )
            }
        }
    }
}

private data class ConnectionSummary(val status: MacStatus, val retentionDays: Int?)

@Composable
private fun rememberConnection(app: TacitApp, vault: Vault?, resumed: Int) =
    produceState<ConnectionSummary?>(null, vault, resumed) {
        if (vault != null) vault.changes.collect {
            try {
                val status = app.sync.status(includeReasons = false)
                val retention = withContext(Dispatchers.IO) {
                    vault.syncConnection()?.optJSONObject("audio")?.optString("retention_days")?.toIntOrNull()
                }
                value = ConnectionSummary(status, retention)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                value = null
            }
        }
    }
