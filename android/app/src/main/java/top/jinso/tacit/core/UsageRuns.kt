package top.jinso.tacit.core

import top.jinso.tacit.sources.Sources
import java.time.Instant
import java.time.ZoneId

internal fun usageDurationMillis(records: List<HistoryRecord>): Long = records.sumOf { record ->
    ((record.end ?: record.start) - record.start).coerceAtLeast(0)
}

/** Takes the display order, retaining every non-usage row and each day's boundaries. */
internal fun foldUsageRuns(
    groups: List<ActivityGroup>,
    zone: ZoneId = ZoneId.systemDefault(),
): List<ActivityGroup> = buildList {
    val pending = mutableListOf<HistoryRecord>()
    fun flush() {
        if (pending.isNotEmpty()) add(ActivityGroup(pending.toList()))
        pending.clear()
    }
    fun day(record: HistoryRecord) = Instant.ofEpochMilli(record.start).atZone(zone).toLocalDate()
    for (group in groups) {
        if (group.first.source != Sources.USAGE) {
            flush()
            add(group)
        } else for (record in group.records) {
            if (pending.isNotEmpty() && day(pending.first()) != day(record)) flush()
            pending.add(record)
        }
    }
    flush()
}
