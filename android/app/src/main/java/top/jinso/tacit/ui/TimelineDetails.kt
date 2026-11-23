package top.jinso.tacit.ui

import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import top.jinso.tacit.TacitApp
import top.jinso.tacit.sync.TimelineItem
import top.jinso.tacit.sync.TimelineOriginal
import top.jinso.tacit.ui.components.Caption
import top.jinso.tacit.ui.components.PageBar
import top.jinso.tacit.ui.components.ProgressLine
import top.jinso.tacit.ui.components.SourceIcon

@Composable
internal fun Modifier.timelineAxis(first: Boolean, last: Boolean): Modifier {
    val line = tacitColors.faint
    val dot = tacitColors.accent
    return drawBehind {
        val x = 47.dp.toPx()
        val y = 26.dp.toPx()
        drawLine(line, Offset(x, if (first) y else 0f), Offset(x, if (last) y else size.height), 1.dp.toPx())
        drawCircle(dot, 2.5.dp.toPx(), Offset(x, y))
    }
}

@Composable
internal fun ProjectedTimelineRow(item: TimelineItem, modifier: Modifier, onClick: () -> Unit) {
    Row(modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(onClick = onClick)
        .padding(top = 12.dp, bottom = 12.dp, end = 12.dp)) {
        Caption(item.timeLabel, Modifier.width(56.dp).padding(top = 5.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            TimelineTitle(item.title)
            if (item.description.isNotBlank()) Text(item.description, color = tacitColors.muted)
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
internal fun TimelineDetails(app: TacitApp, item: TimelineItem, invalidation: Long, onBack: () -> Unit) {
    val owner = LocalActivity.current as? LifecycleOwner
    var originals by remember(item.recordIds, invalidation) { mutableStateOf<List<TimelineOriginal>?>(null) }
    var offline by remember(item.recordIds, invalidation) { mutableStateOf(false) }
    LaunchedEffect(owner, item.recordIds, invalidation) {
        owner?.lifecycle?.repeatOnLifecycle(Lifecycle.State.STARTED) {
            offline = false
            try {
                originals = app.sync.timelineOriginals(item.recordIds)
                // Keep the result only while this detail page is visible.
                kotlinx.coroutines.awaitCancellation()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                offline = true
            } finally {
                originals = null
            }
        }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar("原始记录", onBack)
        LazyColumn(contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                TimelineTitle(item.title)
                if (item.description.isNotBlank()) Text(item.description, color = tacitColors.muted)
            }
            when {
                offline -> item { Caption("当前离线，无法读取原文") }
                originals == null -> item { ProgressLine(Modifier.fillMaxWidth()) }
                originals.isNullOrEmpty() -> item { Caption("没有可读取的原文") }
                else -> originals.orEmpty().forEach { record ->
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            SourceIcon(record.source)
                            Caption(record.title.ifBlank { sourceName(record.source) })
                        }
                        Text(record.body, color = tacitColors.readingBody)
                    }
                }
            }
        }
    }
}
