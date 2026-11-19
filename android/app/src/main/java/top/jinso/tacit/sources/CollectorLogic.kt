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

/** Replay the unfinished interval next time; never invent an end at the polling boundary. */
internal fun usageIntervals(events: List<UsageEvent>, from: Long, until: Long): UsageScan {
    require(until >= from)
    var active: UsageEvent? = null
    var locked = false
    var lockStart: Long? = null
    var previous = from
    val intervals = mutableListOf<UsageInterval>()
    fun finish(time: Long) {
        active?.let { if (time > it.time) intervals += UsageInterval(it.app, it.time, time) }
        active = null
    }
    events.forEach { event ->
        require(event.time >= previous) { "Usage events must be chronological" }
        previous = event.time
        if (event.time < from || event.time >= until) return@forEach
        when (event.kind) {
            UsageKind.LOCK -> { finish(event.time); locked = true; lockStart = event.time }
            UsageKind.UNLOCK -> { locked = false; lockStart = null }
            UsageKind.RESET -> { finish(event.time); locked = true; lockStart = event.time }
            UsageKind.RESUME -> if (!locked) {
                if (event.app.isBlank()) {
                    finish(event.time) // A blocked app still ends the preceding allowed interval.
                } else if (active?.app != event.app || active?.activity != event.activity) {
                    finish(event.time); active = event
                }
            }
            UsageKind.PAUSE -> if (active?.app == event.app && active?.activity == event.activity) finish(event.time)
        }
    }
    return UsageScan(intervals, active?.time ?: lockStart ?: until)
}
