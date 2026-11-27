package top.jinso.tacit.ui

import top.jinso.tacit.R
import top.jinso.tacit.audio.STORED_CONVERSATION_TITLE
import top.jinso.tacit.i18n.UiStrings
import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.core.SPEAKER_ME
import top.jinso.tacit.core.speakerDisplayName
import top.jinso.tacit.core.transcriptLine
import top.jinso.tacit.core.localizeTranscriptLines
import android.content.ClipData
import android.content.ClipDescription
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import android.content.ClipboardManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.selection.DisableSelection
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

internal fun recordTitle(title: String, source: String, strings: UiStrings): String =
    if (source == Sources.AUDIO && title == STORED_CONVERSATION_TITLE) strings.text(R.string.stored_conversation_title) else title

internal val correctionOrder = compareBy<HistoryRecord> { it.start }.thenBy { it.id }

internal fun copyRecordText(context: Context, body: String, sensitive: Boolean) {
    val clip = ClipData.newPlainText(context.getString(R.string.app_name), body)
    if (sensitive && Build.VERSION.SDK_INT >= 33) {
        clip.description.extras = PersistableBundle().apply {
            putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
        }
    }
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
}

@Composable
internal fun RecordDetail(
    record: HistoryRecord, vault: Vault, app: TacitApp, onBack: () -> Unit, notify: (String) -> Unit,
    onSelect: (HistoryRecord) -> Unit, onDelete: (HistoryRecord) -> Unit,
) = key(record.id) {
    val format = uiFormat()
    val strings = uiStrings()
    var deleting by remember { mutableStateOf(false) }
    var raw by rememberSaveable { mutableStateOf(false) }
    val changes by vault.changes.collectAsState()
    val corrected by produceState(emptyList<HistoryRecord>(), record.id, changes) {
        value = withContext(Dispatchers.IO) { vault.corrections(record.id).sortedWith(correctionOrder) }
    }
    val isPhoneAudio = record.source == Sources.AUDIO
    val isAudio = isPhoneAudio || (record.source == "mac.audio" && format.lang == AppLang.EN)
    val rendered by produceState(record.body, record.id) {
        if (isPhoneAudio) value = withContext(Dispatchers.IO) { renderedTranscript(AudioController(app), record) }
    }
    val original by produceState<HistoryRecord?>(null, record.corrects, changes) {
        value = record.corrects?.let { withContext(Dispatchers.IO) { vault.get(it) } }
    }
    val latest = corrected.lastOrNull()
    val body = latest?.body ?: when {
        isAudio -> readableTranscript(rendered)
        hasSpeakerMarkers(record.source) -> localizeTranscriptLines(record.body, format.lang, strings)
        else -> record.body
    }
    val context = LocalContext.current
    Column(Modifier.fillMaxSize()) {
        PageBar("", onBack) {
            val copy = latest?.body ?: record.body
            IconButton(enabled = copy.isNotBlank(), onClick = {
                copyRecordText(context, copy, record.sensitivity == "private" || latest?.sensitivity == "private")
                notify(strings.text(R.string.copied))
            }) { Icon(Icons.Outlined.ContentCopy, strings.text(R.string.copy)) }
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 12.dp),
        ) {
            DetailInfo(record.source, record.start, record.end, record.sensitivity == "private", includeYear = true)
            DetailTitle(recordTitle(record.title, record.source, strings))
            if (body.isNotBlank()) ReadingBody(body, isAudio)
            else Caption(strings.text(R.string.record_no_content))
            Spacer(Modifier.height(12.dp))
            corrected.singleOrNull()?.let { DetailLink(strings.text(R.string.view_correction)) { onSelect(it) } }
            if (body != record.body) {
                DetailLink(if (raw) strings.text(R.string.hide_original) else if (isAudio) strings.text(R.string.view_raw_transcript) else strings.text(R.string.view_original), expanded = raw) { raw = !raw }
                Reveal(raw) { ReadingBody(record.body) }
            }
            original?.let { DetailLink(strings.text(R.string.view_original_record)) { onSelect(it) } }
            if (corrected.size > 1) {
                GroupDivider()
                SectionLabel(strings.text(R.string.later_corrections), Modifier.padding(top = 12.dp))
                corrected.asReversed().forEach { change ->
                    DetailLink(strings.text(R.string.correction_at, format.dateAndClock(change.start))) { onSelect(change) }
                }
            }
            if (record.redactions > 0) Caption(strings.quantity(R.plurals.redactions_count, record.redactions, countLabel(record.redactions)), Modifier.padding(top = 12.dp))
        }
        GroupDivider()
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            TextAction(strings.text(R.string.delete), { deleting = true }, color = tacitColors.attention)
        }
    }
    if (deleting) AlertDialog(
        onDismissRequest = { deleting = false },
        title = { Text(strings.text(R.string.delete_record_title)) },
        text = {
            Text(if (corrected.isEmpty()) strings.text(R.string.delete_irreversible)
                else strings.quantity(R.plurals.delete_record_corrections_message, corrected.size, countLabel(corrected.size)))
        },
        confirmButton = { TextAction(strings.text(R.string.delete), { deleting = false; onDelete(record) }, color = tacitColors.attention) },
        dismissButton = { TextAction(strings.text(R.string.cancel), { deleting = false }) },
    )
}

@Composable
internal fun EmptyState(title: String, message: String, action: (@Composable () -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 40.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Serif)
        Text(message, color = tacitColors.muted)
        action?.invoke()
    }
}

@Composable
internal fun DetailInfo(source: String, start: Long, end: Long?, private: Boolean, includeYear: Boolean = false) {
    val format = uiFormat()
    val label = format.detailTimeLabel(start, end, includeYear)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SourceIcon(source, 20.dp)
        Caption("${format.sourceName(source)} · $label", Modifier.weight(1f, fill = false))
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
    val strings = uiStrings()
    val lang = uiFormat().lang
    SelectionContainer {
        if (!transcript) Text(body, color = tacitColors.readingBody)
        else Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
            body.split(Regex("\\r?\\n[ \\t]*\\r?\\n")).filter { it.isNotBlank() }.forEach { paragraph ->
                val turn = transcriptLine(paragraph)
                val speaker = turn.speaker
                if (speaker.isNotEmpty() && speaker.length <= 80 && '\n' !in speaker) {
                    DisableSelection {
                        Text(speakerDisplayName(speaker, lang, strings), style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Medium, color = if (speaker == SPEAKER_ME) tacitColors.accent else tacitColors.muted)
                    }
                    Text(turn.text, color = tacitColors.readingBody)
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
