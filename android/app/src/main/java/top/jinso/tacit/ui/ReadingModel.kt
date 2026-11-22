package top.jinso.tacit.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import top.jinso.tacit.core.HistoryRecord

/** What is open on top of the tabs; kept in memory, never in the persisted instance-state Bundle. */
class ReadingModel : ViewModel() {
    var detail by mutableStateOf<HistoryRecord?>(null)
    var conversation by mutableStateOf<List<HistoryRecord>>(emptyList())
}
