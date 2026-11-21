package top.jinso.tacit.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
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
import top.jinso.tacit.core.Draft
import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.data.Vault
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.sync.MacStatus
import top.jinso.tacit.ui.components.*
import top.jinso.tacit.ui.onboarding.*

@Composable
fun TacitRoot(app: TacitApp, shared: String?, resumed: Int, quickNote: Int, consumeShare: () -> Unit) = TacitTheme {
    val scope = rememberCoroutineScope()
    val activity = LocalActivity.current as ViewModelStoreOwner
    val draft = remember(activity) { ViewModelProvider(activity)[EditorDraftModel::class.java] }
    val pageState = rememberSaveableStateHolder()
    var vault by remember { mutableStateOf<Vault?>(null) }
    var locked by remember { mutableStateOf(false) }
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var hubRoute by rememberSaveable { mutableStateOf<String?>(null) }
    var healthRefresh by remember { mutableIntStateOf(0) }
    val health = rememberCollectionHealth(app, resumed, healthRefresh)
    val mac by rememberConnection(app, vault, resumed)
    var historyQuery by remember { mutableStateOf("") }
    var editing by rememberSaveable { mutableStateOf(false) }
    val detail = draft.detail
    val conversation = draft.conversation
    val snackbar = remember { SnackbarHostState() }
    fun notify(text: String) { scope.launch { snackbar.showSnackbar(text) } }
    fun settings(route: String?) {
        hubRoute = route.takeUnless { it == SettingsRoutes.PRIVACY }
        tab = 2
    }
    fun newNote(text: String = "", fromShare: Boolean = false) {
        draft.clear()
        draft.initial = text
        draft.sharedOrigin = fromShare
        draft.correction = null
        editing = true
    }
    fun closeEditor() {
        draft.clear()
        editing = false
        draft.correction = null
    }
    fun back() {
        when {
            editing -> closeEditor()
            detail != null -> draft.detail = null
            else -> draft.conversation = emptyList()
        }
    }
    fun openConversation(records: List<HistoryRecord>) {
        draft.conversation = records
    }
    LaunchedEffect(Unit) {
        try { vault = withContext(Dispatchers.IO) { app.vault } }
        catch (_: Exception) { locked = true }
    }
    LaunchedEffect(resumed) { Sources.refresh(app) }
    LaunchedEffect(quickNote) {
        if (quickNote > 0 && !editing) {
            draft.detail = null
            draft.conversation = emptyList()
            newNote()
        }
    }
    LaunchedEffect(shared) {
        if (shared != null) {
            draft.detail = null
            draft.conversation = emptyList()
            newNote(shared, fromShare = true)
            consumeShare()
        }
    }
    val reading = detail != null || conversation.isNotEmpty()
    BackHandler(editing || reading) { back() }
    val showTabs = !editing && !reading && (tab != 2 || hubRoute == null)
    val history = showTabs && tab == 0 && !locked && vault != null
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        containerColor = tacitColors.paper,
        contentWindowInsets = WindowInsets.safeDrawing,
        bottomBar = {
            if (showTabs) {
                Column {
                    GroupDivider()
                    NavigationBar(containerColor = tacitColors.paper, tonalElevation = 0.dp) {
                        listOf("记录" to Icons.AutoMirrored.Outlined.List, "录音" to Icons.Outlined.Mic, "设置" to Icons.Outlined.Settings)
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
        floatingActionButton = {
            if (history) FloatingActionButton(
                onClick = { newNote() }, modifier = Modifier.size(52.dp), shape = MaterialTheme.shapes.large,
                containerColor = tacitColors.accent, contentColor = tacitColors.onAccent,
            ) { Icon(Icons.Outlined.Add, "补写") }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
            val store = vault
            val recovery: @Composable () -> Unit = {
                if (health != null && recoveryIssues(health).any { tab != 1 || it.action != RecoveryAction.AUDIO }) {
                    CollectionRecoveryNotice(health, ::settings, { tab = 1 }, ::notify, onAudioPage = tab == 1)
                } else if (tab == 0 && health != null && enabledSourceCount(app, health) == 0) {
                    NoticeRow("还没有开启记录来源") { settings(SettingsRoutes.SOURCES) }
                }
            }
            when {
                locked -> EmptyState("记录库暂时无法打开", "密钥或数据库不可用，原文件已保留，请勿卸载应用或清除数据。")
                store == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                editing -> Editor(draft, ::closeEditor) { title, body, private ->
                    try {
                        val correction = draft.correction
                        val id = withContext(Dispatchers.IO) {
                            store.ingest(Draft(
                                if (correction == null) Sources.NOTE else Sources.CORRECTION,
                                title, body, method = "manual", private = private, corrects = correction?.id,
                            ))
                        }
                        if (id != null) {
                            closeEditor()
                            draft.detail = null
                            notify("已保存")
                        }
                    } catch (_: Exception) { notify("未能保存，请保留输入后重试") }
                }
                detail != null -> RecordDetail(
                    detail, store, app, onBack = ::back, notify = ::notify,
                    onSelect = { draft.detail = it },
                    onCorrect = {
                        draft.correction = it
                        draft.initial = it.body
                        draft.sharedOrigin = false
                        editing = true
                    },
                    onDelete = { record ->
                        scope.launch {
                            try {
                                withContext(Dispatchers.IO) {
                                    if (record.source == Sources.AUDIO) AudioController(app).deleteRecordAudio(record.id).get()
                                    store.delete(record.id)
                                }
                                draft.conversation = draft.conversation.filterNot { it.id == record.id }
                                draft.detail = null
                                notify("已删除记录及关联修正")
                            } catch (_: Exception) { notify("删除未完成，请重试") }
                        }
                    },
                )
                conversation.isNotEmpty() -> ConversationDetail(conversation, app, store, ::back) { draft.detail = it }
                tab == 0 -> pageState.SaveableStateProvider("history") {
                    val synced = mac?.status?.takeIf { it.name != null && !it.removed }?.let {
                        if (it.lastSync == 0L) "尚未同步" else "${syncAge(it.lastSync)}同步到 Mac"
                    }
                    HistoryPage(
                        app, store, resumed, health, synced, historyQuery, { historyQuery = it },
                        { draft.detail = it }, ::openConversation, recovery,
                    )
                }
                tab == 1 -> AudioPage(app, resumed, ::notify, ::settings, ::openConversation, mac?.retentionDays, recovery)
                else -> SettingsPage(
                    app, resumed, ::notify, hubRoute, { hubRoute = it }, { tab = 1 },
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
