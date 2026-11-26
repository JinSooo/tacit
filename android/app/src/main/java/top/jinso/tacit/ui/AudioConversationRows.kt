package top.jinso.tacit.ui

import top.jinso.tacit.audio.AudioConversation
import top.jinso.tacit.core.HistoryRecord

/** Keep the same privacy boundary as history when one conversation contains mixed records. */
internal data class AudioConversationRow(
    val key: String,
    val start: Long,
    val records: List<HistoryRecord>,
    val private: Boolean,
    val end: Long = start,
    val conversationId: String = key,
    val audioAvailable: Boolean = false,
    val userConfirmed: Boolean = false,
    val transcribePending: Boolean = false,
    val hasUntranscribedClips: Boolean = false,
    val untranscribedAudioAvailable: Boolean = false,
    val untranscribedStart: Long? = null,
    val untranscribedEnd: Long? = null,
    val untranscribedClipIds: List<String> = emptyList(),
)

internal fun audioConversationRows(
    scenes: List<AudioConversation>,
    records: Map<String, HistoryRecord>,
): List<AudioConversationRow> = scenes.sortedByDescending { it.start }.flatMap { scene ->
    val text = scene.recordIds.mapNotNull { records[it] }.sortedBy { it.start }
    if (text.isEmpty()) listOf(
        AudioConversationRow(
            key = scene.id,
            start = scene.start,
            records = emptyList(),
            private = false,
            end = scene.end,
            conversationId = scene.id,
            audioAvailable = scene.audioAvailable,
            userConfirmed = scene.userConfirmed,
            transcribePending = scene.transcribePending,
            hasUntranscribedClips = scene.hasUntranscribedClips,
            untranscribedAudioAvailable = scene.untranscribedAudioAvailable,
            untranscribedStart = scene.untranscribedStart,
            untranscribedEnd = scene.untranscribedEnd,
            untranscribedClipIds = scene.untranscribedClipIds,
        ),
    )
    else text.groupBy { it.sensitivity }.map { (sensitivity, group) ->
        AudioConversationRow(
            key = "${scene.id}:$sensitivity",
            start = group.first().start,
            records = group,
            private = sensitivity == "private",
            end = group.maxOf { it.end ?: it.start },
            conversationId = scene.id,
            audioAvailable = scene.audioAvailable,
            userConfirmed = scene.userConfirmed,
            transcribePending = scene.transcribePending,
            hasUntranscribedClips = scene.hasUntranscribedClips,
            untranscribedAudioAvailable = scene.untranscribedAudioAvailable,
            untranscribedStart = scene.untranscribedStart,
            untranscribedEnd = scene.untranscribedEnd,
            untranscribedClipIds = scene.untranscribedClipIds,
        )
    }
}

/** A partially represented conversation stays visible so its remaining local records can still be opened. */
internal fun undisplayedConversations(rows: List<AudioConversationRow>, projectedIds: Set<String>) =
    rows.filterNot { row -> row.records.isNotEmpty() && row.records.all { it.id in projectedIds } }

internal fun matchingLocalConversations(rows: List<AudioConversationRow>, recordIds: Set<String>) =
    rows.filter { row -> !row.private && row.records.any { it.id in recordIds } }
