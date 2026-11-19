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
        val rows = audioConversationRows(listOf(scene("pending", 1000)), emptyMap())
        assertEquals(1, rows.size)
        assertEquals("pending", rows.single().key)
        assertTrue(rows.single().records.isEmpty())
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

    @Test fun newestConversationsComeFirstAndDeletedRecordsAreOmitted() {
        val earlier = record("earlier", 1100)
        val later = record("later", 1200)
        val rows = audioConversationRows(listOf(scene("old", 1000, "later", "deleted", "earlier"), scene("new", 3000)),
            listOf(earlier, later).associateBy { it.id })
        assertEquals(listOf(3000L, 1100L), rows.map { it.start })
        assertEquals(listOf(earlier, later), rows.last().records)
    }
}
