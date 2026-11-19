package top.jinso.tacit.core

import java.time.Instant
import java.time.ZoneId

object PausePolicy {
    fun tomorrow(now: Long, zone: ZoneId = ZoneId.systemDefault()): Long =
        Instant.ofEpochMilli(now).atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
    fun active(manual: Boolean, until: Long, now: Long) = manual && (until == 0L || now < until)
}
