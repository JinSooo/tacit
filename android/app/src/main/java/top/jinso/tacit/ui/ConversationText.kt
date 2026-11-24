package top.jinso.tacit.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
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

private data class ConversationPart(val record: HistoryRecord, val text: String, val sensitive: Boolean)

@Composable
internal fun ConversationDetail(
    records: List<HistoryRecord>, app: TacitApp, vault: Vault, onBack: () -> Unit, notify: (String) -> Unit,
    onSelect: (HistoryRecord) -> Unit,
) {
    val ordered = remember(records) { records.sortedBy { it.start } }
    val changes by vault.changes.collectAsState()
    val parts by produceState<List<ConversationPart>?>(null, ordered, changes) {
        value = withContext(Dispatchers.IO) {
            val audio = AudioController(app)
            ordered.mapNotNull { previous ->
                val record = vault.get(previous.id) ?: return@mapNotNull null
                val latest = vault.corrections(record.id).maxWithOrNull(correctionOrder)
                ConversationPart(record, latest?.body ?: readableTranscript(renderedTranscript(audio, record)),
                    record.sensitivity == "private" || latest?.sensitivity == "private")
            }
        }
    }
    var expanded by rememberSaveable(ordered.first().id) { mutableStateOf(false) }
    val context = LocalContext.current
    val body = remember(parts) { parts.orEmpty().joinToString("\n\n") { it.text }.trim() }
    Column(Modifier.fillMaxSize()) {
        PageBar("", onBack) {
            IconButton(enabled = body.isNotBlank(), onClick = {
                copyRecordText(context, body, parts.orEmpty().any { it.sensitive })
                notify("已复制")
            }) { Icon(Icons.Outlined.ContentCopy, "复制") }
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 12.dp)) {
            val current = parts
            if (current == null) {
                ProgressLine()
                return@Column
            }
            if (current.isEmpty()) {
                Caption("这场对话的记录已移除。")
                return@Column
            }
            val start = current.first().record.start
            val end = current.maxOf { (record, _) -> record.end ?: record.start }
            val private = current.any { it.sensitive }
            DetailInfo(Sources.AUDIO, start, end, private)
            // Like the Mac: what the conversation was about first, then the cleaned-up transcript.
            val summary = remember(current, changes) {
                val ids = current.map { it.record.id }.toSet()
                vault.summaries().firstOrNull { m -> m.recordIds.any(ids::contains) }
            }
            DetailTitle(summary?.title ?: conversationTitle(private))
            if (summary != null) {
                ReadingBody(summary.summary)
                summary.points.forEach { Text("· $it", Modifier.padding(top = 6.dp), color = tacitColors.muted) }
                Spacer(Modifier.height(20.dp))
            }
            if (body.isBlank()) Caption("这场对话没有可显示的完整转写。")
            else ReadingBody(body, transcript = true)
            Spacer(Modifier.height(12.dp))
            DetailLink("原始片段 ${current.size} 段", expanded) { expanded = !expanded }
            if (expanded) current.forEach { (record, _) ->
                EvidenceRow(date(record.start, "HH:mm:ss"), firstSentence(record.body).ifBlank { record.title },
                    record.sensitivity == "private", onClick = { onSelect(record) })
            }
        }
    }
}
