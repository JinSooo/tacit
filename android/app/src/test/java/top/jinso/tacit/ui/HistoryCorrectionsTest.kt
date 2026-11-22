package top.jinso.tacit.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import top.jinso.tacit.core.HistoryRecord

class HistoryCorrectionsTest {
    private fun record(id: String, start: Long, body: String, corrects: String? = null) = HistoryRecord(
        id, if (corrects == null) "manual.note" else "manual.correction", "周会准备", body, start, null, null, "normal", corrects, 0)

    @Test fun correctedRecordShowsOnceWithLatestText() {
        // Reported case: a Mac correction appeared as a second row while the original kept the old text.
        val rows = foldCorrections(listOf(record("c2", 30, "第二次修正", "c1"), record("c1", 20, "第一次修正", "a"),
            record("a", 10, "原文"), record("b", 5, "另一条")))
        assertEquals(listOf("a", "b"), rows.map { it.id })
        assertEquals("第二次修正", rows[0].body)
        assertEquals(true, rows[0].corrected)
        assertEquals(10L, rows[0].start)
    }

    @Test fun correctionWithoutListedOriginalStaysVisible() {
        val rows = foldCorrections(listOf(record("c", 20, "修正后", "missing")))
        assertEquals(listOf("c"), rows.map { it.id })
        assertEquals(false, rows[0].corrected)
    }
}
