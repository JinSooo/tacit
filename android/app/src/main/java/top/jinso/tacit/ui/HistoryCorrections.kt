package top.jinso.tacit.ui

import top.jinso.tacit.core.HistoryRecord

/**
 * One line per record, as on the Mac: a listed record shows its latest correction's text and the corrections
 * leave the list. A correction whose original is not listed (another day, another search) stays on its own.
 */
internal fun foldCorrections(records: List<HistoryRecord>): List<HistoryRecord> {
    val byId = records.associateBy { it.id }
    fun root(record: HistoryRecord): HistoryRecord {
        var current = record
        val seen = mutableSetOf(current.id)
        while (true) {
            val parent = current.corrects?.let(byId::get) ?: return current
            if (!seen.add(parent.id)) return current
            current = parent
        }
    }
    val latest = mutableMapOf<String, HistoryRecord>()
    for (record in records) {
        if (record.corrects == null) continue
        val original = root(record)
        if (original === record) continue
        val previous = latest[original.id]
        if (previous == null || record.start > previous.start || record.start == previous.start && record.id > previous.id)
            latest[original.id] = record
    }
    return records.mapNotNull { record ->
        when {
            record.corrects != null && root(record) !== record -> null
            else -> latest[record.id]?.let { record.copy(title = it.title, body = it.body, corrected = true) } ?: record
        }
    }
}
