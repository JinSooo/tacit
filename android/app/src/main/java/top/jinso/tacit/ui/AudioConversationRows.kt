package top.jinso.tacit.ui

import top.jinso.tacit.audio.AudioConversation
import top.jinso.tacit.core.HistoryRecord

/** Keep the same privacy boundary as history when one conversation contains mixed records. */
internal data class AudioConversationRow(
    val key: String,
    val start: Long,
    val records: List<HistoryRecord>,
    val private: Boolean,
)

internal fun audioConversationRows(
    scenes: List<AudioConversation>,
    records: Map<String, HistoryRecord>,
): List<AudioConversationRow> = scenes.sortedByDescending { it.start }.flatMap { scene ->
    val text = scene.recordIds.mapNotNull { records[it] }.sortedBy { it.start }
    if (text.isEmpty()) listOf(AudioConversationRow(scene.id, scene.start, emptyList(), false))
    else text.groupBy { it.sensitivity }.map { (sensitivity, group) ->
        AudioConversationRow("${scene.id}:$sensitivity", group.first().start, group, sensitivity == "private")
    }
}

/** A partially represented conversation stays visible so its remaining local records can still be opened. */
internal fun undisplayedConversations(rows: List<AudioConversationRow>, projectedIds: Set<String>) =
    rows.filterNot { row -> row.records.isNotEmpty() && row.records.all { it.id in projectedIds } }

internal fun matchingLocalConversations(rows: List<AudioConversationRow>, recordIds: Set<String>) =
    rows.filter { row -> !row.private && row.records.any { it.id in recordIds } }
