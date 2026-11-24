package top.jinso.tacit.sync

import org.json.JSONObject

internal const val TIMELINE_RECHECK = 5 * 60_000L
private const val RETRY_LIMIT = 3

/** Automatic reads use the regular down scan for replies. Persist only request metadata, never replies. */
internal class RelayTimeline(
    private val connection: JSONObject,
    private val box: String,
    private val cache: TimelineCache,
    private val timeline: TimelineSync,
    private val persist: () -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val state = connection.optJSONObject("relayTimeline")?.takeIf { it.optString("box") == box }
        ?: JSONObject().put("box", box)
    private val pending = state.optJSONObject("pending") ?: JSONObject().also { state.put("pending", it) }
    private val ops = listOf("relay", "projection.pull", "projection.ack")
    private val view get() = state.optString("role") == "view"

    val replyIds get() = ops.mapNotNull { pending.optJSONObject(it)?.optionalString("nonce") }.toSet()

    fun push(message: JSONObject): Boolean {
        val kind = message.getString("kind")
        if (kind == "projection.reset" || kind == "projection.invalidate") {
            pending.optJSONObject("projection.pull")?.put("stale", true)
        }
        if (kind == "projection.reset") {
            state.remove("role")
            state.remove("roleAt")
            pending.optJSONObject("relay")?.put("stale", true)
        }
        timeline.push(message, view)
        state.remove("retryAt")
        state.remove("retries")
        state.put("needsPull", true)
        save()
        return true
    }

    fun reply(nonce: String, message: JSONObject, protocol: DeviceMessages) {
        val op = ops.firstOrNull { pending.optJSONObject(it)?.optString("nonce") == nonce } ?: return
        val request = pending.getJSONObject(op)
        val cursor = ProjectionCursor(request.getLong("epoch"), request.getLong("cursor"))
        try {
            val body = protocol.response(op, message)
            if (request.optBoolean("stale")) return
            when (op) {
                "relay" -> role(body.optionalString("role"))
                "projection.pull" -> if (view && cursor == cache.cursor) {
                    when (timeline.applyPage(body, cursor)) {
                        TimelinePage.COMPLETE -> { state.put("lastPull", now()); state.remove("retries") }
                        TimelinePage.REVOKED -> role("collect")
                        TimelinePage.MORE -> state.put("needsPull", true)
                        TimelinePage.RESET -> retryPull()
                    }
                } else if (view) state.put("needsPull", true)
                "projection.ack" -> if (view) {
                    timeline.confirmAck(cursor, body)
                    state.remove("retries")
                    state.remove("ackRetries")
                }
            }
        } catch (error: DeviceStatus) {
            when (error.status) {
                403 -> role("collect")
                409 -> retryPull()
                // A busy or failing hub must not abort the whole mailbox drain and hold back recording uploads;
                // drop this reply and try again later (2026-11-24 review). A failing ack keeps its own count: a
                // successful pull in between used to reset the shared one, so pull and ack alternated forever.
                else -> if (op == "projection.ack") retryAck() else {
                    if (op == "projection.pull") cache.refreshFailed()
                    retryPull()
                }
            }
        } finally {
            pending.remove(op)
            save()
        }
    }

    fun postDue(protocol: DeviceMessages, post: (DeviceEnvelope.Request) -> Unit) {
        val time = now()
        if (time < state.optLong("retryAt")) return
        fun due(key: String) = !state.has(key) || time - state.getLong(key) >= TIMELINE_RECHECK
        val cursor = cache.cursor
        val op = when {
            !view && due("roleAt") -> "relay"
            !view -> return
            state.optBoolean("needsPull") || due("lastPull") ||
                pending.optJSONObject("projection.pull")?.has("wire") == true -> "projection.pull"
            timeline.needsAck(cursor) -> "projection.ack"
            else -> return
        }
        // A request marked stale by an invalidate or reset is replaced at once: the hub deletes its old reply from
        // the mailbox, so waiting out the 24 h delivery window left the timeline blank (2026-11-24 review).
        val previous = pending.optJSONObject(op)?.takeUnless { it.optBoolean("stale") }
        if (previous != null && time - previous.getLong("at") < DELIVERY_TTL) {
            previous.optionalString("wire")?.let { wire ->
                postRequest(op, previous, DeviceEnvelope.Request(wire.toByteArray(), previous.getString("nonce")), post)
            }
            return
        }
        val body = when (op) {
            "projection.pull" -> cursor.pullBody()
            "projection.ack" -> cursor.ackBody()
            else -> JSONObject()
        }
        val request = protocol.request(op, body)
        val entry = JSONObject().put("nonce", request.nonce).put("at", time)
            .put("epoch", cursor.epoch).put("cursor", cursor.seq).put("wire", request.json.toString(Charsets.UTF_8))
        pending.put(op, entry)
        if (op == "projection.pull") state.remove("needsPull")
        save()
        postRequest(op, entry, request, post)
    }

    private fun postRequest(
        op: String, entry: JSONObject, request: DeviceEnvelope.Request, post: (DeviceEnvelope.Request) -> Unit,
    ) {
        try {
            post(request)
            entry.remove("wire")
            save()
        } catch (error: RelayStatus) {
            // An ambiguous failure may already have reached up. A definitive refusal may be retried.
            if (error.status < 500 || error.status == 507) {
                pending.remove(op)
                if (op == "projection.pull") state.put("needsPull", true)
                save()
            }
            throw error
        }
    }

    fun role(role: String?) {
        val current = if (timeline.role(role)) "view" else "collect"
        val time = now()
        if (state.optString("role") == current && time - state.optLong("roleAt") < TIMELINE_RECHECK) return
        state.put("role", current).put("roleAt", time)
        save()
    }

    private fun retryAck() {
        val retries = state.optInt("ackRetries") + 1
        if (retries > RETRY_LIMIT) {
            state.remove("ackRetries")
            state.put("retryAt", now() + TIMELINE_RECHECK)
        } else state.put("ackRetries", retries)
    }

    private fun retryPull() {
        val retries = state.optInt("retries") + 1
        if (retries > RETRY_LIMIT) {
            state.remove("retries")
            state.put("retryAt", now() + TIMELINE_RECHECK)
        } else state.put("retries", retries)
        state.put("needsPull", true)
    }

    private fun save() {
        connection.put("relayTimeline", state)
        persist()
    }
}
