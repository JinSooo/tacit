package top.jinso.tacit.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SegmentOriginalsTest {
    private data class Original(val id: String, val source: String)

    // 2026-11-25: an AI-session segment opened on a long screen-read block; the conversation sat far below it.
    @Test fun conversationsComeBeforeFoldedScreenRecords() {
        val records = listOf(Original("s1", "mac.screen"), Original("c1", "claude_code.session"),
            Original("b1", "mac.browser"), Original("w1", "mac.wechat"))
        val (main, backdrop) = splitBackdrop(records, hasOtherMain = false) { it.source }
        assertEquals(listOf("c1", "w1"), main.map { it.id })
        assertEquals(listOf("s1", "b1"), backdrop.map { it.id })
    }

    @Test fun skeletonOnlySegmentListsItsRecordsUnlessThePhoneRecordedTheConversation() {
        val records = listOf(Original("s1", "mac.screen"), Original("a1", "mac.app"))
        assertEquals(records to emptyList<Original>(), splitBackdrop(records, hasOtherMain = false) { it.source })
        assertEquals(emptyList<Original>() to records, splitBackdrop(records, hasOtherMain = true) { it.source })
    }

    @Test fun screenFragmentsJoinIntoReadableLines() {
        val body = "Code\nTacit\nDone\n这一行是屏幕上读到的一整句比较长的文字内容\n13m\n30m"
        assertEquals("Code · Tacit · Done\n这一行是屏幕上读到的一整句比较长的文字内容\n13m · 30m", readingText(body, "mac.screen"))
        assertEquals(body, readingText(body, "claude_code.session"))
    }
}
