package top.jinso.tacit.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel

/** Unsaved content stays in memory, never in the framework's persisted instance-state Bundle. */
class EditorDraftModel : ViewModel() {
    var correction by mutableStateOf<top.jinso.tacit.core.HistoryRecord?>(null)
    var detail by mutableStateOf<top.jinso.tacit.core.HistoryRecord?>(null)
    var conversation by mutableStateOf<List<top.jinso.tacit.core.HistoryRecord>>(emptyList())
    var initial by mutableStateOf("")
    var sharedOrigin by mutableStateOf(false)
    var session by mutableStateOf<String?>(null)
        private set
    var title by mutableStateOf("")
    var body by mutableStateOf("")
    var private by mutableStateOf(false)
    fun open(id: String, initialTitle: String, initialBody: String, isPrivate: Boolean) {
        if(session == id) return
        session = id; title = initialTitle; body = initialBody; private = isPrivate
    }
    fun clear() { session = null; title = ""; body = ""; private = false }
}
