package top.jinso.tacit.sync

import org.json.JSONArray
import org.json.JSONObject

internal typealias TimelineRequest = suspend (String, JSONObject) -> JSONObject
internal enum class TimelinePage { COMPLETE, MORE, RESET, REVOKED }

internal class TimelineSync(private val cache: TimelineCache, private val now: () -> Long = System::currentTimeMillis) {
    private var confirmed: ProjectionCursor? = null

    fun clear() {
        confirmed = null
        cache.clear()
    }

    fun role(value: String?): Boolean {
        if (value == "view") return true
        clear()
        return false
    }

    /** Pull is gated by the authenticated current role, including when an old pairing is promoted. */
    suspend fun pull(role: String?, send: TimelineRequest) {
        if (!role(role)) return
        var resets = 0
        var conflicts = 0
        while (true) {
            try {
                val previous = cache.cursor
                val page = send("projection.pull", previous.pullBody())
                when (applyPage(page, previous)) {
                    TimelinePage.REVOKED -> return
                    TimelinePage.RESET -> if (++resets >= 3) return
                    TimelinePage.MORE -> Unit
                    TimelinePage.COMPLETE -> {
                        acknowledge(send)
                        return
                    }
                }
            } catch (error: DeviceStatus) {
                when (error.status) {
                    401, 403 -> clear()
                    409 -> {
                        confirmed = null
                        if (conflicts++ < 3) continue
                    }
                }
                throw error
            } catch (error: DeviceRemoved) {
                clear()
                throw error
            }
        }
    }

    fun applyPage(page: JSONObject, previous: ProjectionCursor): TimelinePage {
        val epoch = page.integer("epoch")
        val more = page.getBoolean("more")
        if (page.getBoolean("reset")) {
            if (page.optString("kind") == "projection.reset" || !more) {
                clear()
                return TimelinePage.REVOKED
            }
            confirmed = null
            cache.reset(epoch)
            return TimelinePage.RESET
        }
        cache.apply(epoch, page.integer("cursor"), page.getJSONArray("changes"), syncedAt = if (more) null else now())
        if (!more) return TimelinePage.COMPLETE
        check(cache.cursor != previous)
        return TimelinePage.MORE
    }

    fun needsAck(cursor: ProjectionCursor) = cursor.seq > 0 && cursor != confirmed

    fun confirmAck(cursor: ProjectionCursor, reply: JSONObject) {
        check(reply.getBoolean("ok"))
        confirmed = cursor
    }

    private suspend fun acknowledge(send: TimelineRequest) {
        val cursor = cache.cursor
        if (needsAck(cursor)) confirmAck(cursor, send("projection.ack", cursor.ackBody()))
    }

    /** Returns whether the message may be deleted. Urgent notices can be applied before probing the role. */
    fun push(message: JSONObject, view: Boolean): Boolean {
        val epoch = message.integer("epoch")
        when (message.getString("kind")) {
            "projection.reset" -> {
                confirmed = null
                cache.reset(epoch)
            }
            "projection.invalidate" -> cache.invalidate(epoch, message.integer("to_seq"), message.getJSONArray("items"))
            "projection.hint" -> if (cache.cursor.epoch != 0L && cache.cursor.epoch != epoch) {
                confirmed = null
                cache.reset(epoch)
            }
            "projection.delta" -> {
                val cursor = cache.cursor
                if (!view) return false
                if (cursor.epoch != 0L && cursor.epoch != epoch) {
                    confirmed = null
                    cache.reset(epoch)
                } else if (cursor.seq > 0 && message.integer("from_seq") <= cursor.seq) {
                    cache.apply(epoch, message.integer("to_seq"), message.getJSONArray("changes"))
                }
                // The scheduled pull fills any gap, selects the cold-start window, and acknowledges the cursor.
            }
        }
        return true
    }
}

internal data class TimelineOriginal(val source: String, val title: String, val body: String)

/** Results belong to the requesting detail page. This reader has no storage or relay journal. */
internal suspend fun readTimelineOriginals(ids: Set<String>, send: TimelineRequest): List<TimelineOriginal> {
    var retries = 0
    while (true) {
        val records = linkedMapOf<String, Pair<TimelineOriginal, StringBuilder>>()
        try {
            for (batch in ids.chunked(50)) {
                val body = JSONObject().put("ids", JSONArray(batch))
                var cursor: String? = null
                do {
                    val page = send("records.get", body.put("cursor", cursor))
                    for (record in page.getJSONArray("records").objects()) {
                        if (record.optBoolean("redacted_private")) continue
                        val id = record.getString("id")
                        val (_, text) = records.getOrPut(id) {
                            TimelineOriginal(record.getString("source"), record.optionalString("title").orEmpty(), "") to StringBuilder()
                        }
                        text.append(record.getString("body"))
                    }
                    val next = page.optionalString("next_cursor")
                    check(next == null || next != cursor)
                    cursor = next
                } while (cursor != null)
            }
            return records.values.map { (record, text) -> record.copy(body = text.toString()) }
        } catch (error: DeviceStatus) {
            if (error.status != 409 || retries++ >= 2) throw error
        }
    }
}
