package top.jinso.tacit.core

import org.junit.Assert.assertEquals
import org.junit.Test
import top.jinso.tacit.sources.Sources
import java.time.Instant
import java.time.ZoneOffset

class UsageRunsTest {
    @Test fun usageRunsBreakAtSubjectRecordsAndMidnightAndSumOnlyKnownDurations() {
        fun record(id: String, timestamp: String, minutes: Long?, source: String = Sources.USAGE): HistoryRecord {
            val start = Instant.parse(timestamp).toEpochMilli()
            return HistoryRecord(id, source, "虚构应用", "", start, minutes?.let { start + it * 60_000 },
                "example.app", "normal", null, 0)
        }
        val newest = record("a", "2026-01-02T10:30:00Z", 5)
        val earlier = record("b", "2026-01-02T10:10:00Z", 2)
        val noEnd = record("c", "2026-01-02T10:00:00Z", null)
        val note = record("note", "2026-01-02T09:00:00Z", null, Sources.NOTE)
        val firstMorning = record("d", "2026-01-02T00:00:00Z", 6)
        val previousDay = record("e", "2026-01-01T23:55:00Z", 3)
        val groups = listOf(
            ActivityGroup(listOf(newest, earlier)),
            ActivityGroup(listOf(noEnd)), ActivityGroup(listOf(note)),
            ActivityGroup(listOf(firstMorning)), ActivityGroup(listOf(previousDay)),
        )

        val folded = foldUsageRuns(groups, ZoneOffset.UTC)

        assertEquals(listOf(listOf("a", "b", "c"), listOf("note"), listOf("d"), listOf("e")),
            folded.map { group -> group.records.map { it.id } })
        assertEquals(listOf(420_000L, 360_000L, 180_000L),
            folded.filter { it.first.source == Sources.USAGE }.map { usageDurationMillis(it.records) })
    }
}
