package top.jinso.tacit.ui

import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.audio.AudioConversation
import top.jinso.tacit.core.HistoryRecord

class AudioConversationRowsTest {
    private fun record(id: String, start: Long, sensitivity: String = "normal") =
        HistoryRecord(id, "android.audio", "对话", "内容", start, start + 1000, null, sensitivity, null, 0)
    private fun scene(id: String, start: Long, vararg recordIds: String) =
        AudioConversation(id, start, start + 5000, listOf("clip-$id"), recordIds.toList())

    @Test fun savedAudioWithoutTranscriptionStillHasAVisibleRow() {
        val scene = AudioConversation(
            id = "pending",
            start = 1000,
            end = 181_000,
            clipIds = listOf("clip-pending"),
            recordIds = emptyList(),
            audioAvailable = true,
            userConfirmed = true,
            transcribePending = true,
        )
        val rows = audioConversationRows(listOf(scene), emptyMap())
        assertEquals(1, rows.size)
        val row = rows.single()
        assertEquals("pending", row.key)
        assertEquals("pending", row.conversationId)
        assertEquals(181_000L, row.end)
        assertTrue(row.records.isEmpty())
        assertTrue(row.audioAvailable)
        assertTrue(row.userConfirmed)
        assertTrue(row.transcribePending)
    }

    @Test fun privateTextNeverJoinsNormalConversationPreview() {
        val normal = record("normal", 2000)
        val private = record("private", 1000, "private")
        val rows = audioConversationRows(listOf(scene("same", 1000, "normal", "private")),
            listOf(normal, private).associateBy { it.id })
        assertEquals(2, rows.size)
        assertEquals(listOf(private), rows.single { it.private }.records)
        assertEquals(listOf(normal), rows.single { !it.private }.records)
        assertEquals(2, rows.map { it.key }.distinct().size)
    }

    @Test fun onlyFullyProjectedConversationsAreHidden() {
        val first = record("first", 1000)
        val second = record("second", 1500)
        val rows = audioConversationRows(listOf(scene("phone", 1000, first.id, second.id), scene("pending", 3000)),
            listOf(first, second).associateBy { it.id })
        assertEquals(rows, undisplayedConversations(rows, setOf(first.id)))
        assertEquals(listOf("pending"), undisplayedConversations(rows, setOf(first.id, second.id)).map { it.key })
    }

    // 回归（2026-11-24 审查第 5 条）
    @Test fun mergedAndSplitProjectionCanOpenTheEntireLocalConversation() {
        val first = record("first", 1000)
        val second = record("second", 1500)
        val private = record("private", 2000, "private")
        val rows = audioConversationRows(listOf(scene("phone", 1000, first.id, second.id, private.id)),
            listOf(first, second, private).associateBy { it.id })
        assertEquals(listOf("phone:private"), undisplayedConversations(rows, setOf(first.id, second.id)).map { it.key })
        for (ids in listOf(setOf(first.id, second.id, "mac"), setOf(first.id), setOf(second.id))) {
            assertEquals(listOf(first, second), matchingLocalConversations(rows, ids).single().records)
        }
        assertTrue(matchingLocalConversations(rows, setOf("mac", private.id)).isEmpty())
    }

    @Test fun newestConversationsComeFirstAndDeletedRecordsAreOmitted() {
        val earlier = record("earlier", 1100)
        val later = record("later", 1200)
        val rows = audioConversationRows(listOf(scene("old", 1000, "later", "deleted", "earlier"), scene("new", 3000)),
            listOf(earlier, later).associateBy { it.id })
        assertEquals(listOf(3000L, 1100L), rows.map { it.start })
        assertEquals(listOf(earlier, later), rows.last().records)
    }
}
