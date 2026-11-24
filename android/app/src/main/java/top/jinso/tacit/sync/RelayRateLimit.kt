package top.jinso.tacit.sync

import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException

/** One cooldown per relay space, shared by polling, sync and original reads. */
internal class RelayRateLimit(
    private val elapsed: () -> Long = { System.nanoTime() / 1_000_000 },
    private val wallTime: () -> Long = System::currentTimeMillis,
) {
    private val limits = mutableMapOf<String, Cooldown>()

    internal class Cooldown(val until: Long, val delay: Long)

    @Synchronized fun beforeRequest(space: String): Cooldown? = limits[space]?.also {
        if (elapsed() < it.until) throw RelayStatus(429)
    }

    @Synchronized fun afterResponse(space: String, previous: Cooldown?, status: Int, retryAfter: String?) {
        // An in-flight response must not clear or double a cooldown established by another request.
        if (limits[space] !== previous) return
        if (status in 200..299) limits.remove(space)
        if (status == 429) {
            val delay = ((previous?.delay ?: 30_000) * 2).coerceAtMost(3_600_000)
            val wait = maxOf(delay, retryAfterMillis(retryAfter))
            limits[space] = Cooldown(elapsed() + wait, delay)
        }
    }

    private fun retryAfterMillis(header: String?): Long {
        val value = header?.trim() ?: return 0
        val maxSeconds = 6 * 60 * 60L
        value.toLongOrNull()?.let { return it.coerceIn(0, maxSeconds) * 1_000 }
        return try {
            (ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() - wallTime())
                .coerceIn(0, maxSeconds * 1_000)
        } catch (_: DateTimeParseException) {
            0
        }
    }
}
