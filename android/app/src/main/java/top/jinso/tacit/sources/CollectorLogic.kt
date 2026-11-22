package top.jinso.tacit.sources

import java.security.MessageDigest

/** Fixed-size identifiers never expose a notification key, activity name, or captured text. */
internal fun sourceRef(device: String, source: String, vararg parts: String): String {
    fun digest(values: List<String>): String {
        val hash = MessageDigest.getInstance("SHA-256")
        values.forEach { value ->
            val bytes = value.toByteArray(Charsets.UTF_8)
            hash.update(java.nio.ByteBuffer.allocate(4).putInt(bytes.size).array())
            hash.update(bytes)
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
    return "android-${digest(listOf(device)).take(24)}:$source:${digest(parts.toList())}"
}

internal enum class UsageKind { RESUME, PAUSE, LOCK, UNLOCK, RESET }
internal data class UsageEvent(val time: Long, val kind: UsageKind, val app: String = "", val activity: String = "")
internal data class UsageInterval(val app: String, val start: Long, val end: Long)
internal data class UsageScan(val intervals: List<UsageInterval>, val cursor: Long)

/** Leaving an app for less than this and coming back keeps one interval, as on the Mac. */
internal const val USAGE_BOUNCE_MS = 15_000L

private class UsagePiece(val app: String, val start: Long, var end: Long, val afterBoundary: Boolean)

/**
 * Only the app and its duration matter: page changes inside one app and short visits elsewhere do not split it.
 * Blocked apps, the home screen, locks and reboots stay boundaries; nothing is merged across them.
 */
private fun mergeUsage(pieces: List<UsagePiece>): List<UsageInterval> {
    val merged = mutableListOf<UsagePiece>()
    for (piece in pieces) {
        val last = merged.lastOrNull()
        val before = merged.getOrNull(merged.size - 2)
        when {
            last != null && !piece.afterBoundary && last.app == piece.app -> last.end = piece.end
            before != null && last != null && !piece.afterBoundary && !last.afterBoundary &&
                before.app == piece.app && last.end - last.start < USAGE_BOUNCE_MS -> {
                merged.removeAt(merged.lastIndex); before.end = piece.end
            }
            else -> merged += UsagePiece(piece.app, piece.start, piece.end, piece.afterBoundary)
        }
    }
    return merged.map { UsageInterval(it.app, it.start, it.end) }
}

/** Replay the unfinished interval next time; never invent an end at the polling boundary. */
internal fun usageIntervals(events: List<UsageEvent>, from: Long, until: Long): UsageScan {
    require(until >= from)
    var active: UsageEvent? = null
    var locked = false
    var lockStart: Long? = null
    var previous = from
    var boundary = false
    val pieces = mutableListOf<UsagePiece>()
    fun finish(time: Long) {
        active?.let { if (time > it.time) { pieces += UsagePiece(it.app, it.time, time, boundary); boundary = false } }
        active = null
    }
    fun boundary(time: Long) { finish(time); boundary = true }
    events.forEach { event ->
        require(event.time >= previous) { "Usage events must be chronological" }
        previous = event.time
        if (event.time < from || event.time >= until) return@forEach
        when (event.kind) {
            UsageKind.LOCK -> { boundary(event.time); locked = true; lockStart = event.time }
            UsageKind.UNLOCK -> { locked = false; lockStart = null }
            UsageKind.RESET -> { boundary(event.time); locked = true; lockStart = event.time }
            UsageKind.RESUME -> if (!locked) {
                if (event.app.isBlank()) {
                    boundary(event.time) // A blocked app still ends the preceding allowed interval.
                } else if (active?.app != event.app || active?.activity != event.activity) {
                    finish(event.time); active = event
                }
            }
            UsageKind.PAUSE -> if (active?.app == event.app && active?.activity == event.activity) finish(event.time)
        }
    }
    return UsageScan(mergeUsage(pieces), active?.time ?: lockStart ?: until)
}
