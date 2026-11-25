package top.jinso.tacit.ui

import android.net.ConnectivityManager
import android.net.Network
import androidx.activity.compose.LocalActivity
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.lerp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.sync.TimelineItem
import top.jinso.tacit.sync.TimelineOriginal
import top.jinso.tacit.ui.components.Caption
import top.jinso.tacit.ui.components.PageBar
import top.jinso.tacit.ui.components.ProgressLine
import top.jinso.tacit.ui.components.SourceIcon
import top.jinso.tacit.ui.components.TextAction
import java.util.concurrent.atomic.AtomicReference

@Composable
internal fun Modifier.timelineAxis(first: Boolean, last: Boolean, draft: Boolean = false): Modifier {
    val line = tacitColors.faint
    val dot = tacitColors.accent
    val paper = tacitColors.paper
    // When a draft is written up its hollow dot fills in place rather than swapping.
    val filled by animateFloatAsState(if (draft) 0f else 1f, Motion.enter(), label = "dot")
    return drawBehind {
        val x = 47.dp.toPx()
        val y = 26.dp.toPx()
        drawLine(line, Offset(x, if (first) y else 0f), Offset(x, if (last) y else size.height), 1.dp.toPx())
            // 还没整理的段画空心点（Mac 时间线同样如此），整理好的是实心点。
        val hollow = 1f - filled
        if (hollow > 0f) {
            drawCircle(paper, 3.5.dp.toPx(), Offset(x, y), alpha = hollow)
            drawCircle(dot, lerp(3.dp, 2.5.dp, filled).toPx(), Offset(x, y), alpha = hollow, style = Stroke(1.dp.toPx()))
        }
        if (filled > 0f) drawCircle(dot, 2.5.dp.toPx() * filled, Offset(x, y))
    }
}

@Composable
internal fun ProjectedTimelineRow(item: TimelineItem, modifier: Modifier, onClick: () -> Unit) {
    Row(modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(onClick = onClick)
        .padding(top = 12.dp, bottom = 12.dp, end = 12.dp)) {
        Caption(item.timeLabel(), Modifier.width(56.dp).padding(top = 5.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // A draft's sentence gives way to the written title and description with a cross-fade, in place.
            CrossSwap(item.title to item.description) { (title, description) ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TimelineTitle(title)
                    if (description.isNotBlank()) Text(description, color = tacitColors.muted)
                }
            }
            if (item.sources.isNotEmpty()) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    item.sources.distinct().forEach { SourceIcon(it, 14.dp) }
                }
            }
        }
    }
}

@Composable
private fun TimelineTitle(title: String) {
    Text(title, style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Serif,
        fontWeight = FontWeight.Normal)
}

@Composable
internal fun TimelineDetails(
    app: TacitApp, item: TimelineItem, invalidation: Long, onBack: () -> Unit,
    onOpenLocal: (List<HistoryRecord>) -> Unit,
) {
    val owner = LocalActivity.current as? LifecycleOwner
    // Survives sync invalidation so the page reloads in place instead of flashing through loading.
    var local by remember(item.id) { mutableStateOf<List<AudioConversationRow>?>(null) }
    LaunchedEffect(item.recordIds, invalidation) {
        local = try {
            withContext(Dispatchers.IO) {
                val scenes = AudioController(app).listConversations().get()
                    .filter { scene -> scene.recordIds.any { it in item.recordIds } }
                val records = scenes.flatMap { it.recordIds }.distinct()
                    .mapNotNull(app.vault::get).associateBy { it.id }
                matchingLocalConversations(audioConversationRows(scenes, records), item.recordIds)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            emptyList()
        }
    }
    val remoteIds = local?.let { rows -> item.recordIds - rows.flatMap { row -> row.records.map { it.id } }.toSet() }
    // The previous result stays on screen while a sync change is refetched; rows are keyed by record ID,
    // so a retracted original leaves and the rest move up. A failed refetch clears it, like the Mac.
    var fetched by remember(item.id) { mutableStateOf<List<TimelineOriginal>?>(null) }
    val originals = fetched?.let { list -> remoteIds?.let { ids -> list.filter { it.id in ids } } }
    var offline by remember(remoteIds, invalidation) { mutableStateOf(false) }
    val retries = remember(remoteIds, invalidation) { Channel<Unit>(Channel.CONFLATED) }
    LaunchedEffect(owner, remoteIds, invalidation) {
        if (remoteIds.isNullOrEmpty()) return@LaunchedEffect
        owner?.lifecycle?.repeatOnLifecycle(Lifecycle.State.STARTED) {
            val connectivity = app.getSystemService(ConnectivityManager::class.java)
            val activeNetwork = AtomicReference(connectivity.activeNetwork)
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    if (activeNetwork.getAndSet(network) != network) retries.trySend(Unit)
                }
                override fun onLost(network: Network) { activeNetwork.updateAndGet { if (it == network) null else it } }
            }
            retries.tryReceive()
            connectivity.registerDefaultNetworkCallback(callback)
            try {
                while (true) {
                    offline = false
                    try {
                        fetched = app.sync.timelineOriginals(remoteIds)
                        break
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        fetched = null
                        offline = true
                        retries.receive()
                    }
                }
                // Keep the result only while this detail page is visible.
                awaitCancellation()
            } finally {
                connectivity.unregisterNetworkCallback(callback)
                // Leaving the screen drops the result; a restart for a sync change keeps it until the refetch lands.
                if (owner?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) != true) fetched = null
                offline = false
            }
        }
    }
    var showsBackdrop by remember(item.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        PageBar("原始记录", onBack)
        LazyColumn(contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item(key = "head") {
                TimelineTitle(item.title)
                if (item.description.isNotBlank()) Text(item.description, color = tacitColors.muted)
            }
            local.orEmpty().forEach { row ->
                item(key = row.key) {
                    TextButton(onClick = { onOpenLocal(row.records) }, Modifier.itemMotion(this)) {
                        Text(if (local.orEmpty().size == 1) "这台手机录的对话"
                            else "这台手机录的对话，${date(row.start, "HH:mm")}")
                    }
                }
            }
            // Keyed so the loading line fades out as the originals fade in.
            when {
                remoteIds?.isEmpty() == true && local.orEmpty().isNotEmpty() -> Unit
                remoteIds?.isEmpty() == true -> item(key = "none") { Caption("没有可读取的原文", Modifier.itemMotion(this)) }
                offline -> item(key = "offline") {
                    Row(Modifier.itemMotion(this), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Caption("暂时无法读取原文")
                        TextAction("重试", { retries.trySend(Unit) })
                    }
                }
                originals == null -> item(key = "loading") { ProgressLine(Modifier.itemMotion(this).fillMaxWidth()) }
                originals.isNullOrEmpty() -> item(key = "none") { Caption("没有可读取的原文", Modifier.itemMotion(this)) }
                else -> {
                    val (main, backdrop) = splitBackdrop(originals, local.orEmpty().isNotEmpty()) { it.source }
                    main.forEach { record -> item(key = "original-${record.id}") { OriginalRecord(record, Modifier.itemMotion(this)) } }
                    if (backdrop.isNotEmpty()) {
                        item(key = "backdrop") {
                            Box(Modifier.itemMotion(this)) {
                                DetailLink("另有 ${backdrop.size} 条屏幕和网页记录", showsBackdrop) { showsBackdrop = !showsBackdrop }
                            }
                        }
                        if (showsBackdrop) backdrop.forEach { record ->
                            item(key = "original-${record.id}") { OriginalRecord(record, Modifier.itemMotion(this)) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun OriginalRecord(record: TimelineOriginal, modifier: Modifier) {
    Column(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            SourceIcon(record.source)
            Caption(date(record.start.toEpochMilli(), "HH:mm"))
            Caption(record.title.ifBlank { sourceName(record.source) })
        }
        ReadingBody(readingText(record.body, record.source))
    }
}
