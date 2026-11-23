package top.jinso.tacit.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
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

@Composable
internal fun ConversationDetail(
    records: List<HistoryRecord>, app: TacitApp, vault: Vault, onBack: () -> Unit, onSelect: (HistoryRecord) -> Unit,
) {
    val ordered = remember(records) { records.sortedBy { it.start } }
    val changes by vault.changes.collectAsState()
    val parts by produceState<List<Pair<HistoryRecord, String>>?>(null, ordered, changes) {
        value = withContext(Dispatchers.IO) {
            val audio = AudioController(app)
            ordered.mapNotNull { previous ->
                val record = vault.get(previous.id) ?: return@mapNotNull null
                val latest = vault.corrections(record.id).maxWithOrNull(correctionOrder)
                record to (latest?.body ?: readableTranscript(renderedTranscript(audio, record)))
            }
        }
    }
    var expanded by rememberSaveable(ordered.first().id) { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        PageBar("", onBack)
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
            val start = current.first().first.start
            val end = current.maxOf { (record, _) -> record.end ?: record.start }
            val private = current.any { (record, _) -> record.sensitivity == "private" }
            DetailInfo(Sources.AUDIO, start, end, private)
            // Like the Mac: what the conversation was about first, then the cleaned-up transcript.
            val summary = remember(current, changes) {
                val ids = current.map { it.first.id }.toSet()
                vault.summaries().firstOrNull { m -> m.recordIds.any(ids::contains) }
            }
            DetailTitle(summary?.title ?: conversationTitle(private))
            if (summary != null) {
                ReadingBody(summary.summary)
                summary.points.forEach { Text("· $it", Modifier.padding(top = 6.dp), color = tacitColors.muted) }
                Spacer(Modifier.height(20.dp))
            }
            val body = current.joinToString("\n\n") { it.second }.trim()
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
