package top.jinso.tacit.ui

import top.jinso.tacit.R
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.core.readableTranscript
import top.jinso.tacit.data.Vault
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.ui.components.*


private data class ConversationPart(val record: HistoryRecord, val text: String, val original: String, val sensitive: Boolean)

@Composable
internal fun ConversationDetail(
    records: List<HistoryRecord>, app: TacitApp, vault: Vault, onBack: () -> Unit, notify: (String) -> Unit,
    onSelect: (HistoryRecord) -> Unit,
) {
    val format = uiFormat()
    val strings = uiStrings()
    val ordered = remember(records) { records.sortedBy { it.start } }
    val changes by vault.changes.collectAsState()
    val parts by produceState<List<ConversationPart>?>(null, ordered, changes) {
        // Stops between records when a newer change restarts the load, so reloads never pile up behind each other.
        value = withContext(Dispatchers.IO) {
            val current = ordered.mapNotNull { previous ->
                ensureActive()
                val record = vault.get(previous.id) ?: return@mapNotNull null
                record to vault.corrections(record.id).maxWithOrNull(correctionOrder)
            }
            ensureActive()
            val audio = current.filter { (_, latest) -> latest == null }.associate { (record, _) -> record.id to record.body }
            val rendered = if (audio.isEmpty()) emptyMap()
                else runCatching { AudioController(app).renderTranscripts(audio).get() }.getOrDefault(audio)
            current.map { (record, latest) ->
                ConversationPart(record, latest?.body ?: readableTranscript(rendered[record.id] ?: record.body),
                    latest?.body ?: record.body,
                    record.sensitivity == "private" || latest?.sensitivity == "private")
            }
        }
    }
    var expanded by rememberSaveable(ordered.first().id) { mutableStateOf(false) }
    val context = LocalContext.current
    val wholeText = remember(parts) { parts.orEmpty().joinToString("\n\n") { it.original } }
    Column(Modifier.fillMaxSize()) {
        PageBar("", onBack) {
            IconButton(enabled = wholeText.isNotBlank(), onClick = {
                copyRecordText(context, wholeText, parts.orEmpty().any { it.sensitive })
                notify(strings.text(R.string.copied))
            }) { Icon(Icons.Outlined.ContentCopy, strings.text(R.string.copy)) }
        }
        // Loading → the conversation as a cross-fade; the loading line itself only shows after a noticeable wait.
        LoadCrossfade(parts == null) { loading ->
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 12.dp)) {
                val current = parts.takeUnless { loading }
                if (current == null) {
                    ProgressLine()
                    return@Column
                }
                if (current.isEmpty()) {
                    Caption(strings.text(R.string.conversation_removed))
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
                DetailTitle(summary?.title ?: format.conversationTitle(private))
                if (summary != null) {
                    ReadingBody(summary.summary)
                    summary.points.forEach { Text("· $it", Modifier.padding(top = 6.dp), color = tacitColors.muted) }
                    Spacer(Modifier.height(20.dp))
                }
                val body = current.joinToString("\n\n") { it.text }.trim()
                if (body.isBlank()) Caption(strings.text(R.string.conversation_no_transcript))
                else ReadingBody(body, transcript = true)
                Spacer(Modifier.height(12.dp))
                DetailLink(strings.quantity(R.plurals.raw_clip_count, current.size, countLabel(current.size)), expanded) { expanded = !expanded }
                Reveal(expanded) {
                    current.forEach { (record, _) ->
                        EvidenceRow(format.clock(record.start, seconds = true), firstSentence(record.body).ifBlank { recordTitle(record.title, record.source, strings) },
                            record.sensitivity == "private", onClick = { onSelect(record) })
                    }
                }
            }
        }
    }
}
