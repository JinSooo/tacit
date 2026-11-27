package top.jinso.tacit.ui

import top.jinso.tacit.R
import kotlinx.coroutines.flow.merge

import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.EnterExitState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
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
import java.time.LocalDate

@Composable
fun TacitRoot(app: TacitApp, resumed: Int) = TacitTheme {
    val strings = uiStrings()
    val scope = rememberCoroutineScope()
    val activity = LocalActivity.current as ViewModelStoreOwner
    val reading = remember(activity) { ViewModelProvider(activity)[ReadingModel::class.java] }
    var vault by remember { mutableStateOf<Vault?>(null) }
    var locked by remember { mutableStateOf(false) }
    var openAttempt by remember { mutableIntStateOf(0) }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    var hubRoute by rememberSaveable { mutableStateOf<String?>(null) }
    var healthRefresh by remember { mutableIntStateOf(0) }
    val health = rememberCollectionHealth(app, resumed, healthRefresh)
    val mac by rememberConnection(app, vault, resumed)
    val detail = reading.detail
    val conversation = reading.conversation
    val timeline by app.sync.timelineSnapshots.collectAsState()
    var dayEpoch by rememberSaveable { mutableLongStateOf(LocalDate.now().toEpochDay()) }
    val day = LocalDate.ofEpochDay(dayEpoch)
    var selectedItem by remember { mutableStateOf<String?>(null) }
    val timelineItem = timeline.days[day]?.entries(day == LocalDate.now())?.firstOrNull { it.id == selectedItem }
    LaunchedEffect(timelineItem) { if (timelineItem == null) selectedItem = null }
    val snackbar = remember { SnackbarHostState() }
    fun notify(text: String) { scope.launch { snackbar.showSnackbar(text) } }
    fun offerUndo(text: String, undo: suspend () -> Unit) {
        scope.launch {
            if (snackbar.showSnackbar(text, actionLabel = strings.text(R.string.undo), duration = SnackbarDuration.Long) != SnackbarResult.ActionPerformed) {
                return@launch
            }
            try {
                undo()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                snackbar.showSnackbar(strings.text(R.string.undo_failed))
            }
        }
    }
    fun settings(route: String?) {
        hubRoute = route
        settingsOpen = true
    }
    fun back() {
        when {
            detail != null -> reading.detail = null
            conversation.isNotEmpty() -> reading.conversation = emptyList()
            else -> selectedItem = null
        }
    }
    LaunchedEffect(openAttempt) {
        try {
            vault = withContext(Dispatchers.IO) { app.vault }
            if (openAttempt > 0) app.resumeSummaryWorker()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            locked = true
        }
    }
    val open = detail != null || conversation.isNotEmpty() || timelineItem != null
    BackHandler(open) { back() }
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        containerColor = tacitColors.paper,
        contentWindowInsets = WindowInsets.safeDrawing,
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
            val store = vault
            // Only the page's kind and id decide the transition: a background sync that refreshes the record or
            // timeline data must never make the same page slide in again.
            val page = when {
                locked -> Page(PageKind.LOCKED)
                store == null -> Page(PageKind.LOADING)
                detail != null -> Page(PageKind.RECORD, detail.id)
                conversation.isNotEmpty() -> Page(PageKind.CONVERSATION)
                timelineItem != null -> Page(PageKind.TIMELINE, timelineItem.id)
                !settingsOpen -> Page(PageKind.HOME)
                else -> Page(PageKind.SETTINGS)
                }
            val reduceMotion = LocalReduceMotion.current
            AnimatedContent(
                page,
                transitionSpec = { pageTransform(initialState.kind.depth, targetState.kind.depth, reduceMotion) },
                label = "page",
            ) { page ->
                // A page animating out is only a picture of where you were: it no longer takes back presses or taps.
                val active = transition.targetState == EnterExitState.Visible
                // A page animating out keeps the data it was showing after the state has moved on.
                val shownDetail = rememberLatest(detail?.takeIf { page.kind == PageKind.RECORD && it.id == page.id })
                val shownConversation = rememberLatest(conversation.takeIf { page.kind == PageKind.CONVERSATION && it.isNotEmpty() })
                val shownItem = rememberLatest(timelineItem?.takeIf { page.kind == PageKind.TIMELINE && it.id == page.id })
                ActiveScope(active) { Box(Modifier.fillMaxSize().background(tacitColors.paper)) {
                    when {
                        page.kind == PageKind.LOCKED -> EmptyState(
                            strings.text(R.string.vault_locked), strings.text(R.string.vault_locked_hint),
                        ) {
                            TonalButton(strings.text(R.string.retry), {
                                locked = false
                                openAttempt++
                            }, enabled = active)
                        }
                        page.kind == PageKind.LOADING || store == null -> ProgressLine()
                        page.kind == PageKind.RECORD -> if (shownDetail != null) RecordDetail(
                            shownDetail, store, app, onBack = ::back, notify = ::notify,
                    onSelect = { reading.detail = it },
                    onDelete = { record ->
                        scope.launch {
                            try {
                                val deletedCount = withContext(Dispatchers.IO) {
                                    if (record.source == Sources.AUDIO) AudioController(app).deleteRecordAudio(record.id).get()
                                    val deleted = setOf(record.id) + store.corrections(record.id).map { it.id }
                                    store.delete(record.id)
                                    app.sync.withdrawTimelineRecords(deleted)
                                    deleted.size
                                }
                                reading.conversation = reading.conversation.filterNot { it.id == record.id }
                                reading.detail = null
                                notify(if (deletedCount > 1) strings.text(R.string.deleted_record_corrections) else strings.text(R.string.deleted))
                            } catch (_: Exception) { notify(strings.text(R.string.delete_retry)) }
                        }
                    },
                )
                        page.kind == PageKind.CONVERSATION -> if (shownConversation != null) {
                            ConversationDetail(shownConversation, app, store, ::back, ::notify) { reading.detail = it }
                }
                        page.kind == PageKind.TIMELINE -> if (shownItem != null) {
                            TimelineDetails(app, shownItem, timeline.invalidation, ::back) { reading.conversation = it }
                        }
                        page.kind == PageKind.HOME -> AudioPage(
                            app, resumed, ::notify, ::offerUndo, ::settings, { reading.conversation = it }, timeline,
                            day, { dayEpoch = it.toEpochDay() }, { selectedItem = it.id },
                            macRemoved = mac?.status?.removed == true, health = health,
                        )
                else -> SettingsPage(
                    app, resumed, ::notify, ::offerUndo, hubRoute, { hubRoute = it }, { settingsOpen = false; hubRoute = null },
                    health, mac?.status, mac?.retentionDays, { healthRefresh++ },
                )
            }
                    if (!active) Box(Modifier.matchParentSize().pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
                        }
                    })
                } }
            }
        }
    }
}

/** Depth orders the pages: going to a deeper one pushes in, going to a shallower one comes back. */
private enum class PageKind(val depth: Int) { LOCKED(0), LOADING(0), HOME(0), SETTINGS(1), TIMELINE(1), CONVERSATION(2), RECORD(3) }

private data class Page(val kind: PageKind, val id: String? = null)

private data class ConnectionSummary(val status: MacStatus, val retentionDays: Int?)

@Composable
private fun rememberConnection(app: TacitApp, vault: Vault?, resumed: Int) =
    produceState<ConnectionSummary?>(null, vault, resumed) {
        if (vault != null) merge(vault.changes, vault.syncChanges).collect {
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
