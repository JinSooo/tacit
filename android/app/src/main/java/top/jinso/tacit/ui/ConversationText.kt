package top.jinso.tacit.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.core.readableTranscript

@Composable internal fun ConversationText(records:List<HistoryRecord>,app:TacitApp,onSelect:(HistoryRecord)->Unit) {
    val ordered=remember(records){records.sortedBy{it.start}}
    val transcript by produceState<String?>(null,ordered) {
        value=withContext(Dispatchers.IO){val audio=AudioController(app);ordered.joinToString("\n\n"){record->
            val correction=app.vault.corrections(record.id).maxWithOrNull(compareBy<HistoryRecord>{it.start}.thenBy{it.id})
            correction?.body?:readableTranscript(runCatching{audio.renderTranscript(record.id,record.body).get()}.getOrDefault(record.body))
        }}
    }
    var evidence by remember {mutableStateOf(false)}
    Column(Modifier.fillMaxWidth().padding(horizontal=24.dp,vertical=16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        Text(date(ordered.first().start,"HH:mm")+" 至 "+date(ordered.last().end?:ordered.last().start,"HH:mm"),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        val text=transcript
        if(text==null)LinearProgressIndicator(Modifier.fillMaxWidth())else if(text.isBlank())Text("这一场没有需要展示的完整内容，可查看原始片段。",color=MaterialTheme.colorScheme.onSurfaceVariant)else SelectionContainer{Text(text)}
        TextButton(onClick={evidence=!evidence}){Text(if(evidence)"收起原始片段" else "查看原始片段、修正或删除")}
        if(evidence)ordered.forEach { record -> TextButton(onClick={onSelect(record)}){Text(date(record.start,"HH:mm:ss")+"  查看这段记录")} }
    }
}
