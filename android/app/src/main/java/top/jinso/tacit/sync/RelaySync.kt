package top.jinso.tacit.sync

import org.json.JSONArray
import org.json.JSONObject

private const val DELIVERY_TTL = 86_400_000L
private const val REPLY_WAIT = 20_000L

/** Stored in the Keystore-protected Vault alongside the paired connection. */
internal class RelayJournal(
    private val data: JSONObject,
    private val persist: () -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val entries = data.optJSONObject("relayJournal") ?: JSONObject()
    val active get() = data.optJSONObject("relay")?.let(RelayConfig::parse)
    val disabled get() = data.optBoolean("relayDisabled")

    data class Delivery(val nonce: String, val box: String, val op: String, val ids: List<String>)

    private fun delivery(nonce: String, entry: JSONObject) =
        Delivery(nonce, entry.getString("box"), entry.getString("op"), entry.getJSONArray("ids").strings())

    fun deliveries(): List<Delivery> = entries.keys().asSequence().map { delivery(it, entries.getJSONObject(it)) }.toList()

    fun inFlight(op: String): Set<String> = deliveries().filter { it.op == op }.flatMap { it.ids }.toSet()

    fun prune() {
        val cutoff = now() - DELIVERY_TTL
        val expired = deliveries().filter { entries.getJSONObject(it.nonce).getLong("at") <= cutoff }
        if (expired.isEmpty()) return
        expired.forEach { entries.remove(it.nonce) }
        save()
    }

    fun config(next: RelayConfig?) {
        val previous = active
        if (previous == next && !disabled) return
        // Outstanding writes may still get their replies on the retired mailbox during its grace period.
        if (previous != null && previous != next && !disabled &&
            deliveries().any { it.box == previous.down && it.ids.isNotEmpty() }) {
            val retired = data.optJSONObject("relayRetired") ?: JSONObject()
            retired.put(previous.down, previous.json())
            data.put("relayRetired", retired)
        }
        data.put("relay", next?.json())
        data.remove("relayDisabled")
        clearRound()
        save()
    }

    fun disable(config: RelayConfig) {
        if (active == config) data.put("relayDisabled", true)
        else data.optJSONObject("relayRetired")?.remove(config.down)
        save()
    }

    inline fun <T> useMailbox(config: RelayConfig, block: () -> T): T = try {
        block()
    } catch (error: RelayStatus) {
        if (error.unauthorized) disable(config)
        throw error
    }

    fun retired(): List<RelayConfig> {
        val retired = data.optJSONObject("relayRetired") ?: return emptyList()
        return retired.keys().asSequence().map { RelayConfig.parse(retired.getJSONObject(it)) }.toList()
    }

    fun track(box: String, request: DeviceEnvelope.Request, op: String, ids: List<String>, cursor: Long?) {
        entries.put(request.nonce, JSONObject().put("box", box).put("op", op).put("ids", JSONArray(ids))
            .put("cursor", cursor).put("at", now()).put("wire", request.json.toString(Charsets.UTF_8)))
        save()
    }

    fun unconfirmedPut(nonce: String): DeviceEnvelope.Request? =
        entries.optJSONObject(nonce)?.optionalString("wire")?.let { DeviceEnvelope.Request(it.toByteArray(), nonce) }

    fun markPosted(nonce: String) {
        entries.optJSONObject(nonce)?.remove("wire")
        save()
    }

    fun remove(nonce: String) {
        entries.remove(nonce)
        save()
    }

    fun delivery(box: String, nonce: String): Delivery? =
        entries.optJSONObject(nonce)?.takeIf { it.getString("box") == box }?.let { delivery(nonce, it) }

    fun complete(nonce: String, reply: JSONObject) {
        val entry = entries.getJSONObject(nonce)
        entry.remove("wire")
        entry.put("reply", reply)
        save()
    }

    fun request(box: String, op: String, cursor: Long?): String? =
        deliveries().firstOrNull {
            val entry = entries.getJSONObject(it.nonce)
            it.box == box && it.op == op && (if (cursor == null) entry.isNull("cursor") else entry.getLong("cursor") == cursor)
        }?.nonce

    fun reply(nonce: String): JSONObject? = entries.optJSONObject(nonce)?.optJSONObject("reply")

    fun hasUnanswered(box: String, op: String): Boolean =
        deliveries().any { it.box == box && it.op == op && reply(it.nonce) == null }

    fun appliedPage(box: String, cursor: Long) {
        // Keep only pagination progress once the records have been committed to the Vault.
        val page = deliveries().asSequence().filter { it.box == box && it.op == "sync" }
            .mapNotNull { reply(it.nonce)?.optJSONObject("body") }
            .firstOrNull { it.optLong("cursor") == cursor } ?: return
        if (page.optJSONArray("changes")?.length() == 0) return
        page.put("changes", JSONArray())
        save()
    }

    fun roundTime(): Long = data.optLong("relayRoundAt").takeIf { it != 0L } ?: now().also {
        data.put("relayRoundAt", it)
        save()
    }

    fun finishRound() {
        if (!data.has("relayRoundAt") && deliveries().none { it.ids.isEmpty() }) return
        clearRound()
        save()
    }

    private fun clearRound() {
        deliveries().filter { it.ids.isEmpty() }.forEach { entries.remove(it.nonce) }
        data.remove("relayRoundAt")
    }

    private fun save() {
        val retired = data.optJSONObject("relayRetired")
        if (retired != null) {
            val outstanding = deliveries().map { it.box }.toSet()
            retired.keys().asSequence().toList().filter { it !in outstanding }.forEach { retired.remove(it) }
            if (retired.length() == 0) data.remove("relayRetired")
        }
        data.put("relayJournal", entries.takeIf { it.length() > 0 })
        persist()
    }
}

internal class RelayExchange(
    private val protocol: DeviceMessages,
    private val journal: RelayJournal,
    private val mailbox: RelayMailbox,
    private val applyReceipt: (RelayJournal.Delivery, JSONObject) -> Unit,
    private val waitMillis: Long = REPLY_WAIT,
    private val now: () -> Long = System::currentTimeMillis,
    private val canResubmit: (RelayJournal.Delivery) -> Boolean = { true },
) {
    fun drain(allowMove: Boolean = true, projection: ((JSONObject) -> Boolean)? = null) {
        var moved: JSONObject? = null
        val notifications = mutableListOf<String>()
        mailbox.scan { nonce ->
            val wire = mailbox.get(nonce)
            if (wire != null) {
                val message = open(wire, nonce)
                if (allowMove && message?.optString("kind") == "relay.moved" &&
                    journal.delivery(mailbox.config.down, nonce) == null) {
                    // Apply after harvesting the rest of this mailbox's replies.
                    if (message.has("relay")) {
                        moved = message
                        notifications += nonce
                    } else mailbox.delete(nonce)
                } else if (message?.optString("kind")?.startsWith("projection.") == true) {
                    if (projection?.invoke(message) == true || !allowMove) mailbox.delete(nonce)
                } else {
                    process(nonce, message)
                    mailbox.delete(nonce)
                }
            }
        }
        moved?.let {
            // If interrupted after applying the move, the new configuration is already durable.
            journal.config(if (it.isNull("relay")) null else RelayConfig.parse(it.getJSONObject("relay")))
            notifications.forEach(mailbox::delete)
        }
    }

    private fun open(wire: ByteArray, nonce: String): JSONObject? =
        runCatching { protocol.open(wire, nonce) }.getOrNull()

    private fun process(nonce: String, message: JSONObject?) {
        val delivery = journal.delivery(mailbox.config.down, nonce) ?: return
        if (message == null) return // Keep waiting for an authenticated reply.
        val status = runCatching { message.integer("status") }.getOrNull() ?: return
        if (status in 500..599 || delivery.ids.isNotEmpty()) {
            try {
                if (delivery.ids.isNotEmpty() && status == 200L) applyReceipt(delivery, message.getJSONObject("body"))
            } finally {
                journal.remove(nonce)
            }
        } else journal.complete(nonce, message)
    }

    suspend fun send(op: String, body: JSONObject = JSONObject()): JSONObject {
        val cursor = body.optLong("cursor").takeIf { body.has("cursor") }
        val box = mailbox.config.down
        if (op == "sync.ack" && cursor != null) journal.appliedPage(box, cursor)
        val id = journal.request(box, op, cursor) ?: run {
            if (journal.hasUnanswered(box, op)) throw RelayWaiting()
            submit(protocol.request(op, body), op, emptyList(), cursor)
        }
        val existing = journal.reply(id)
        if (existing != null) return protocol.response(op, existing)
        journal.unconfirmedPut(id)?.let { post(it, fresh = false) }
        val message = receive(id)
        return protocol.response(op, message)
    }

    // Projection and original reads must never enter the persistent delivery journal.
    suspend fun sendTransient(op: String, body: JSONObject): JSONObject {
        val request = protocol.request(op, body)
        mailbox.put(request)
        val wire = mailbox.await(request.nonce, now() + waitMillis, now) ?: throw RelayWaiting()
        val message = protocol.open(wire, request.nonce)
        mailbox.delete(request.nonce)
        return protocol.response(op, message)
    }

    suspend fun resumeWrites() {
        for (delivery in journal.deliveries().filter { it.box == mailbox.config.down && it.ids.isNotEmpty() }) {
            val request = journal.unconfirmedPut(delivery.nonce) ?: continue
            if (!canResubmit(delivery)) {
                journal.markPosted(delivery.nonce)
                continue
            }
            post(request, fresh = false)
            protocol.response(delivery.op, receive(delivery.nonce))
        }
    }

    suspend fun sendWrite(op: String, request: DeviceEnvelope.Request, ids: List<String>): JSONObject {
        val id = submit(request, op, ids, null)
        return protocol.response(op, receive(id))
    }

    private fun submit(request: DeviceEnvelope.Request, op: String, ids: List<String>, cursor: Long?): String {
        if (request.json.size > mailbox.messageBytes) throw EnvelopeTooLarge()
        // Record the nonce first so a crash or an ambiguous HTTP failure cannot cause immediate duplicate uploads.
        journal.track(mailbox.config.down, request, op, ids, cursor)
        post(request, fresh = true)
        return request.nonce
    }

    private fun post(request: DeviceEnvelope.Request, fresh: Boolean) {
        try {
            mailbox.put(request)
            journal.markPosted(request.nonce)
        } catch (error: RelayStatus) {
            // An earlier attempt may have reached the mailbox even if a repeat is rejected.
            if (fresh && (error.status < 500 || error.status == 507)) journal.remove(request.nonce)
            if (error.status == 413) throw EnvelopeTooLarge()
            throw error
        }
    }

    private suspend fun receive(id: String): JSONObject {
        val wire = mailbox.await(id, now() + waitMillis, now) ?: throw RelayWaiting()
        val message = open(wire, id)
        process(id, message)
        mailbox.delete(id)
        return message ?: throw RelayWaiting()
    }
}

internal data class RelayUpload(val request: DeviceEnvelope.Request, val count: Int)

internal fun relayUpload(
    protocol: DeviceMessages, batch: List<Pair<String, JSONObject>>, limit: Int,
): RelayUpload? {
    require(batch.isNotEmpty())
    var count = batch.size
    while (true) {
        val body = JSONObject().put("records", JSONArray(batch.take(count).map { it.second }))
        val request = protocol.request("ingest", body)
        if (request.json.size <= limit) return RelayUpload(request, count)
        if (count == 1) return null
        count = (count + 1) / 2
    }
}
