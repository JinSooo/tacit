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

/** Where a row starts on the timeline: folded usage runs and audio scenes begin at their earliest record. */
internal fun timelineStart(group: ActivityGroup): Long =
    if (group.first.source == Sources.AUDIO || group.first.source == Sources.USAGE) group.records.minOf { it.start }
    else group.first.start

internal data class AppUsage(val record: HistoryRecord, val millis: Long)

/** One line per app for a folded run, longest first, so hundreds of short sessions stay readable. */
internal fun usageByApp(records: List<HistoryRecord>): List<AppUsage> =
    records.groupBy { it.app ?: it.title }.map { (_, sessions) -> AppUsage(sessions.first(), usageDurationMillis(sessions)) }
        .sortedByDescending { it.millis }
