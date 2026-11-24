package top.jinso.tacit.ui

import android.content.ClipData
import android.content.ClipDescription
import android.os.Build
import android.os.PersistableBundle
import android.content.ClipboardManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.core.readableTranscript
import top.jinso.tacit.data.Vault
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.ui.components.*

internal val correctionOrder = compareBy<HistoryRecord> { it.start }.thenBy { it.id }

@Composable
internal fun RecordDetail(
    record: HistoryRecord, vault: Vault, app: TacitApp, onBack: () -> Unit, notify: (String) -> Unit,
    onSelect: (HistoryRecord) -> Unit, onDelete: (HistoryRecord) -> Unit,
) = key(record.id) {
    var deleting by remember { mutableStateOf(false) }
    var raw by rememberSaveable { mutableStateOf(false) }
    val changes by vault.changes.collectAsState()
    val corrected by produceState(emptyList<HistoryRecord>(), record.id, changes) {
        value = withContext(Dispatchers.IO) { vault.corrections(record.id).sortedWith(correctionOrder) }
    }
    val isAudio = record.source == Sources.AUDIO
    val rendered by produceState(record.body, record.id) {
        if (isAudio) value = withContext(Dispatchers.IO) { renderedTranscript(AudioController(app), record) }
    }
    val original by produceState<HistoryRecord?>(null, record.corrects, changes) {
        value = record.corrects?.let { withContext(Dispatchers.IO) { vault.get(it) } }
    }
    val latest = corrected.lastOrNull()
    val body = latest?.body ?: if (isAudio) readableTranscript(rendered) else record.body
    val context = LocalContext.current
    Column(Modifier.fillMaxSize()) {
        PageBar("", onBack) {
            IconButton(enabled = body.isNotBlank(), onClick = {
                val copy = context.getSystemService(ClipboardManager::class.java)
                val clip = ClipData.newPlainText("Tacit", body)
                if (record.sensitivity == "private" || latest?.sensitivity == "private") {
                    if (Build.VERSION.SDK_INT >= 33) {
                        clip.description.extras = PersistableBundle().apply {
                            putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                        }
                    }
                }
                copy.setPrimaryClip(clip)
                // Android 13 and later show their own clipboard confirmation.
                if (Build.VERSION.SDK_INT < 33) notify("已复制")
            }) { Icon(Icons.Outlined.ContentCopy, "复制") }
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 12.dp),
        ) {
            DetailInfo(record.source, record.start, record.end, record.sensitivity == "private", includeYear = true)
            DetailTitle(record.title)
            if (body.isNotBlank()) ReadingBody(body, isAudio)
            else Caption("这一段没有可显示的完整内容。")
            Spacer(Modifier.height(12.dp))
            latest?.let { DetailLink("查看这条修正") { onSelect(it) } }
            if (body != record.body) {
                DetailLink(if (raw) "收起原文" else if (isAudio) "查看转写原文" else "查看原文", expanded = raw) { raw = !raw }
                Reveal(raw) { ReadingBody(record.body) }
            }
            original?.let { DetailLink("查看原记录") { onSelect(it) } }
            if (corrected.isNotEmpty()) {
                GroupDivider()
                SectionLabel("后续修正", Modifier.padding(top = 12.dp))
                corrected.asReversed().forEach { change ->
                    DetailLink(date(change.start, "M 月 d 日 HH:mm") + " 的修正") { onSelect(change) }
                }
            }
            if (record.redactions > 0) Caption("已过滤 ${record.redactions} 处凭据", Modifier.padding(top = 12.dp))
        }
        GroupDivider()
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            TextAction("删除", { deleting = true }, color = tacitColors.attention)
        }
    }
    if (deleting) AlertDialog(
        onDismissRequest = { deleting = false },
        title = { Text("删除这条记录？") },
        text = { Text("这条记录和关联修正会永久删除，无法恢复。") },
        confirmButton = { TextAction("删除", { deleting = false; onDelete(record) }, color = tacitColors.attention) },
        dismissButton = { TextAction("取消", { deleting = false }) },
    )
}

@Composable
internal fun EmptyState(title: String, message: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 40.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Serif)
        Text(message, color = tacitColors.muted)
    }
}

@Composable
internal fun DetailInfo(source: String, start: Long, end: Long?, private: Boolean, includeYear: Boolean = false) {
    val startLabel = date(start, if (includeYear) "yyyy 年 M 月 d 日 HH:mm" else "M 月 d 日 HH:mm")
    val label = if (end == null) startLabel else "$startLabel–${date(end, "HH:mm")} · ${durationLabel(end - start)}"
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SourceIcon(source, 20.dp)
        Caption("${sourceName(source)} · $label", Modifier.weight(1f, fill = false))
        if (private) PrivacyLock()
    }
}

@Composable
internal fun DetailTitle(title: String) {
    Text(title, Modifier.padding(top = 12.dp, bottom = 20.dp),
        style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Serif)
}

@Composable
internal fun ReadingBody(body: String, transcript: Boolean = false) {
    SelectionContainer {
        if (!transcript) Text(body, color = tacitColors.readingBody)
        else Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
            body.split(Regex("\\r?\\n[ \\t]*\\r?\\n")).filter { it.isNotBlank() }.forEach { paragraph ->
                val at = paragraph.indexOf('：')
                if (at > 0 && at <= 80 && '\n' !in paragraph.take(at)) {
                    val speaker = paragraph.take(at).trim()
                    Text(speaker, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium,
                        color = if (speaker == "我") tacitColors.accent else tacitColors.muted)
                    Text(paragraph.substring(at + 1).trimStart(), color = tacitColors.readingBody)
                } else Text(paragraph, color = tacitColors.readingBody)
            }
        }
    }
}

@Composable
internal fun DetailLink(label: String, expanded: Boolean? = null, action: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(onClick = action),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Caption(label)
        if (expanded != null) ExpandChevron(expanded, tacitColors.muted)
    }
}

@Composable
internal fun EvidenceRow(time: String, text: String, private: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).then(modifier).heightIn(min = 48.dp).padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Caption(time, Modifier.alignByBaseline())
        Text(text, Modifier.weight(1f).alignByBaseline(), color = tacitColors.readingBody, maxLines = 3, overflow = TextOverflow.Ellipsis)
        if (private) PrivacyLock()
    }
}

internal fun renderedTranscript(audio: AudioController, record: HistoryRecord): String =
    runCatching { audio.renderTranscript(record.id, record.body).get() }.getOrDefault(record.body)
