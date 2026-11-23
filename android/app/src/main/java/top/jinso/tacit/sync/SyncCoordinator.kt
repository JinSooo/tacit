package top.jinso.tacit.sync

import android.os.Build
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.bouncycastle.crypto.AsymmetricCipherKeyPair
import org.json.JSONArray
import org.json.JSONObject
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioRuntime
import top.jinso.tacit.data.Keys
import java.io.IOException

internal data class MacStatus(
    val name: String?, val manual: String, val removed: Boolean, val lastSync: Long,
    val pending: Int, val rejected: Map<String, Int>, val error: String?, val relayDisabled: Boolean = false,
)

internal class SyncCoordinator(private val app: TacitApp) {
    private val mutex = Mutex()
    private val vault get() = app.vault
    private val timelineCache = TimelineCache(EncryptedTimelineDisk(app))
    private val timeline = TimelineSync(timelineCache)
    private var timelineWorkerScheduled = false
    val timelineSnapshots = timelineCache.snapshots

    suspend fun status(includeReasons: Boolean): MacStatus = withContext(Dispatchers.IO) {
        val data = vault.syncConnection()
        MacStatus(data?.optionalString("name"), data?.optString("manual").orEmpty(),
            data?.optBoolean("removed") == true, data?.optLong("lastSync") ?: 0L,
            if (data == null) 0 else vault.pendingCount(),
            if (data == null) emptyMap() else vault.rejectedReasons(includeReasons),
            data?.optionalString("error"), data?.optBoolean("relayDisabled") == true)
    }

    suspend fun pair(uri: String, address: String) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val previous = vault.syncConnection()
            check(previous?.optBoolean("removed") != false)
            val invite = Invitation.parse(uri)
            val manual = parseAddress(address)
            val last = previous?.takeIf { it.optString("hub") == invite.hubId }?.optionalString("last")
            val keys = DeviceEnvelope.generate()
            val public = DeviceEnvelope.public(keys).base64url()
            val secret = DeviceEnvelope.secret(keys)
            val wrapped = try { Keys(app).wrapDeviceKey(secret, public).base64url() } finally { secret.fill(0) }
            val phoneName = Build.MODEL.take(200).ifBlank { "Android" }
            pairWithAvailableTransport(invite, keys, phoneName, findMac = {
                MacDiscovery(app).find(invite.hubId, last, invite.addresses, manual)
            }) { paired, origin ->
                vault.saveSyncConnection(JSONObject().put("device", paired.id).put("hub", invite.hubId)
                    .put("name", invite.macName).put("hubKey", invite.publicKey).put("private", wrapped)
                    .put("public", public)
                    .put("addresses", JSONArray(invite.addresses)).put("last", origin).put("manual", manual)
                    .put("relay", paired.relay?.json()))
            }
            SyncWorker.schedulePeriodic(app)
            timelineWorkerScheduled = true
            SyncWorker.enqueue(app)
        }
    }

    suspend fun updateManual(address: String) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val data = vault.syncConnection() ?: return@withLock
            val manual = parseAddress(address)
            data.put("manual", manual).remove("retryAt")
            vault.saveSyncConnection(data)
            SyncWorker.enqueue(app)
        }
    }

    suspend fun disconnect() = withContext(Dispatchers.IO) {
        mutex.withLock {
            timeline.clear()
            forgetAudioPolicy { vault.saveSyncConnection(null) }
            SyncWorker.cancel(app)
            timelineWorkerScheduled = false
        }
    }

    suspend fun run(retry: Boolean) = mutex.withLock {
        val data = vault.syncConnection() ?: return@withLock
        if (data.optBoolean("removed")) return@withLock
        val wait = data.optLong("retryAt") - System.currentTimeMillis()
        if (wait > 0) {
            if (retry) SyncWorker.retry(app, wait.coerceAtMost(MAX_RETRY))
            return@withLock
        }
        val ctx = currentCoroutineContext()
        try {
            val journal = RelayJournal(data, { vault.saveSyncConnection(data) })
            var unavailable: MacUnavailable? = null
            val origin = try { findOrigin(data) } catch (error: MacUnavailable) {
                unavailable = error
                null
            }
            val device = data.getString("device")
            val keys = restoreKeys(data)
            val hubKey = data.getString("hubKey")
            val protocol = DeviceMessages(hubKey, keys, device)
            fun exchange(mailbox: RelayMailbox) = RelayExchange(protocol, journal, mailbox,
                { delivery, reply -> applyRelayReceipt(data, delivery, reply) },
                canResubmit = { it.op != "ingest" || it.ids.all { id -> vault.wire(id) != null } })
            fun drain(config: RelayConfig, required: Boolean, allowMove: Boolean) {
                try {
                    ctx.ensureActive()
                    journal.useMailbox(config) { exchange(RelayMailbox(config)).drain(allowMove) }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    if (required) throw error
                }
            }
            val startingRelay = journal.active
            if (startingRelay != null && !journal.disabled &&
                (origin == null || journal.deliveries().any { it.box == startingRelay.down && it.ids.isNotEmpty() })) {
                drain(startingRelay, origin == null, allowMove = true)
            }
            for (retired in journal.retired().filter { it != startingRelay }) drain(retired, required = false, allowMove = false)
            journal.prune()

            if (origin != null) {
                val client = DeviceClient(hubKey, keys, { request ->
                    ctx.ensureActive()
                    deviceHttp(origin, request)
                }, device)
                journal.finishRound()
                refreshRelay(client, journal)
                data.put("last", origin)
                pullFromMac(data, client::send)
                sendDirect(device, client, journal)
                syncSummaries(System.currentTimeMillis(), client::send)
            } else {
                val config = journal.active?.takeUnless { journal.disabled } ?: throw requireNotNull(unavailable)
                val mailbox = RelayMailbox(config)
                val relay = exchange(mailbox)
                journal.useMailbox(config) {
                    if (config != startingRelay) relay.drain()
                    if (journal.active != config) throw RelayWaiting()
                    // Deposit queued writes before making a pull that needs the Mac to be awake.
                    relay.resumeWrites()
                    sendThroughRelay(device, protocol, journal, mailbox, relay)
                    pullFromMac(data, relay::send)
                    syncSummaries(journal.roundTime(), relay::send, relay = true)
                    journal.finishRound()
                }
            }
            data.put("lastSync", System.currentTimeMillis())
            data.remove("error")
            data.remove("retryAt")
            data.remove("failures")
            vault.saveSyncConnection(data)
        } catch (error: CancellationException) {
            throw error
        } catch (_: DeviceRemoved) {
            markRemoved(data)
        } catch (error: Exception) {
            if (error is RelayStatus && error.unauthorized && data.optBoolean("relayDisabled")) timeline.clear()
            val failures = (data.optInt("failures") + 1).coerceAtMost(8)
            val delay = (30_000L shl (failures - 1)).coerceAtMost(MAX_RETRY)
            data.put("error", if (data.optBoolean("relayDisabled")) null else syncError(error)).put("failures", failures).put("retryAt", System.currentTimeMillis() + delay)
            vault.saveSyncConnection(data)
            SyncWorker.retry(app, delay)
        }
    }

    suspend fun refreshTimeline(foreground: Boolean = false) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val data = try {
                vault.syncConnection()
            } catch (_: Exception) {
                // The app already shows the locked-vault state. Do not restore a view without its pairing.
                timeline.clear()
                return@withLock
            }
            timelineCache.bind(data?.takeUnless { it.optBoolean("removed") }?.let(::timelineOwner))
            if (data == null || data.optBoolean("removed")) return@withLock
            if (foreground && !timelineWorkerScheduled) {
                // Update the recurring work of phones paired before timeline support.
                SyncWorker.schedulePeriodic(app)
                timelineWorkerScheduled = true
            }

            try {
                val origin = try { findOrigin(data) } catch (_: MacUnavailable) { null }
                if (origin != null) {
                    val client = DeviceClient(data.getString("hubKey"), restoreKeys(data),
                        { deviceHttp(origin, it) }, data.getString("device"))
                    val role = client.send("relay").optionalString("role")
                    timeline.pull(role, client::send)
                } else {
                    val journal = RelayJournal(data, { vault.saveSyncConnection(data) })
                    if (journal.disabled) {
                        timeline.clear()
                        return@withLock
                    }
                    val config = journal.active ?: return@withLock
                    val relay = timelineRelay(data, journal, config)
                    journal.useMailbox(config) {
                        // Withdrawals apply even when the upstream role request cannot reach the hub.
                        relay.drain { timeline.push(it, view = false) }
                        if (journal.active != config) return@useMailbox
                        val role = relay.sendTransient("relay", JSONObject()).optionalString("role")
                        if (timeline.role(role)) {
                            relay.drain { timeline.push(it, view = true) }
                            if (journal.active == config) timeline.pull(role, relay::sendTransient)
                        }
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: DeviceRemoved) {
                markRemoved(data)
            } catch (error: RelayStatus) {
                // A revoked mailbox can no longer deliver a downgrade or deletion notice.
                if (error.unauthorized) timeline.clear()
            } catch (error: Exception) {
                // Keep the last confirmed view while the hub is unreachable.
            }
        }
    }

    suspend fun timelineOriginals(ids: Set<String>): List<TimelineOriginal> = withContext(Dispatchers.IO) {
        mutex.withLock {
            val data = vault.syncConnection()?.takeUnless { it.optBoolean("removed") } ?: throw DeviceRemoved()
            try {
                val origin = try { findOrigin(data) } catch (error: MacUnavailable) {
                    val journal = RelayJournal(data, { vault.saveSyncConnection(data) })
                    val config = journal.active?.takeUnless { journal.disabled } ?: throw error
                    val relay = timelineRelay(data, journal, config)
                    return@withLock journal.useMailbox(config) { readTimelineOriginals(ids, relay::sendTransient) }
                }
                val client = DeviceClient(data.getString("hubKey"), restoreKeys(data),
                    { deviceHttp(origin, it) }, data.getString("device"))
                readTimelineOriginals(ids, client::send)
            } catch (error: DeviceRemoved) {
                markRemoved(data)
                throw error
            } catch (error: DeviceStatus) {
                if (error.status == 403) timeline.clear()
                throw error
            } catch (error: RelayStatus) {
                if (error.unauthorized) timeline.clear()
                throw error
            }
        }
    }

    private fun timelineOwner(data: JSONObject) = data.getString("hub") + ":" + data.getString("device")

    private fun timelineRelay(data: JSONObject, journal: RelayJournal, config: RelayConfig): RelayExchange {
        val protocol = DeviceMessages(data.getString("hubKey"), restoreKeys(data), data.getString("device"))
        return RelayExchange(protocol, journal, RelayMailbox(config),
            { delivery, reply -> applyRelayReceipt(data, delivery, reply) })
    }

    private fun applyRelayReceipt(data: JSONObject, delivery: RelayJournal.Delivery, reply: JSONObject) {
        when (delivery.op) {
            "ingest" -> vault.applyReceipt(delivery.ids, uploadReceipt(reply, delivery.ids.size))
            "delete" -> confirmDeletes(delivery.ids, reply)
        }
        data.put("lastSync", System.currentTimeMillis())
    }

    private suspend fun findOrigin(data: JSONObject): String =
        MacDiscovery(app).find(data.getString("hub"), data.optionalString("last"),
            data.getJSONArray("addresses").strings(), data.optionalString("manual"))

    private fun restoreKeys(data: JSONObject): AsymmetricCipherKeyPair {
        val public = data.getString("public")
        val secret = Keys(app).unwrapDeviceKey(data.getString("private").decode64(), public)
        return try { DeviceEnvelope.restore(secret, public.decode64(32)) } finally { secret.fill(0) }
    }

    private fun markRemoved(data: JSONObject) {
        timeline.clear()
        data.put("removed", true)
        for (key in listOf("private", "relay", "relayDisabled", "relayRetired", "relayJournal", "relayRoundAt", "audio", "error")) {
            data.remove(key)
        }
        forgetAudioPolicy { vault.saveSyncConnection(data) }
        SyncWorker.cancel(app)
    }

    private fun refreshRelay(client: DeviceClient, journal: RelayJournal) {
        val reply = try { client.send("relay") } catch (error: DeviceStatus) {
            if (error.status in setOf(400, 404)) return // Older Mac.
            throw error
        }
        timeline.role(reply.optionalString("role"))
        journal.config(if (reply.isNull("relay")) null else RelayConfig.parse(reply.getJSONObject("relay")))
    }

    private suspend fun pullFromMac(data: JSONObject, send: suspend (String, JSONObject) -> JSONObject) {
        val runtime by lazy { AudioRuntime.get(app) }
        pullChanges({ op, body -> send(op, body) }) { page ->
            val audioDeletes = page.filterIsInstance<Change.Delete>().filter { it.source == "android.audio" }
            if (audioDeletes.isEmpty()) vault.applyChanges(page)
            else runtime.applyRecordChanges(page, audioDeletes)
        }
        // Fetch policy before audio backfill.
        val audio = AudioSync.parse(send("audio.sync", JSONObject()))
        if (audio.purgeBefore != null || audio.deleted.isNotEmpty() || data.optJSONObject("audio")?.toString() != audio.policy.toString()) {
            runtime.applyMacAudio(audio) {
                data.put("audio", audio.policy)
                vault.saveSyncConnection(data)
            }
        }
        check(send("audio.sync.ack", audio.ack()).get("acknowledged") == true)
    }

    private fun sendDirect(device: String, client: DeviceClient, journal: RelayJournal) {
        while (true) {
            val ids = vault.pendingDeletes(journal.inFlight("delete") + journal.inFlight("ingest"))
            if (ids.isEmpty()) break
            confirmDeletes(ids, client.send("delete", deleteBody(ids)))
        }
        while (true) {
            val batch = vault.uploadBatch(device, journal.inFlight("ingest"))
            if (batch.isEmpty()) break
            val receipt = uploadReceipt(client.send("ingest", JSONObject().put("records", JSONArray(batch.map { it.second }))), batch.size)
            vault.applyReceipt(batch.map { it.first }, receipt)
        }
    }

    private suspend fun sendThroughRelay(
        device: String, protocol: DeviceMessages, journal: RelayJournal, mailbox: RelayMailbox, relay: RelayExchange,
    ) {
        while (true) {
            val ids = vault.pendingDeletes(journal.inFlight("delete") + journal.inFlight("ingest"))
            if (ids.isEmpty()) break
            var count = ids.size
            while (true) {
                val request = protocol.request("delete", deleteBody(ids.take(count)))
                try {
                    relay.sendWrite("delete", request, ids.take(count))
                    break
                } catch (error: EnvelopeTooLarge) {
                    if (count == 1) throw error
                    count /= 2
                }
            }
        }
        val oversized = mutableSetOf<String>()
        var limit = mailbox.messageBytes
        while (true) {
            val batch = vault.uploadBatch(device, journal.inFlight("ingest") + oversized)
            if (batch.isEmpty()) break
            val upload = relayUpload(protocol, batch, limit)
            if (upload == null) {
                // A record too large for this mailbox can still go directly to the Mac.
                oversized += batch.first().first
                continue
            }
            try {
                relay.sendWrite("ingest", upload.request, batch.take(upload.count).map { it.first })
            } catch (error: EnvelopeTooLarge) {
                // A self-hosted limit can change between hello and PUT.
                limit = minOf(limit, upload.request.json.size - 1)
            }
        }
    }

    private fun deleteBody(ids: List<String>) = JSONObject().put("ids", JSONArray(ids))

    private fun confirmDeletes(ids: List<String>, reply: JSONObject) {
        require(reply.integer("deleted") in 0..ids.size.toLong())
        vault.confirmDeletes(ids)
    }

    private suspend fun syncSummaries(
        now: Long, send: suspend (String, JSONObject) -> JSONObject, relay: Boolean = false,
    ) {
        // Older Macs do not have these operations. A mailbox transport failure still ends the round.
        try {
            val summarizing = vault.summaryModel()?.optBoolean("enabled") == true
            val unsent = vault.unsentSummaries()
            val reply = send("conversations.put", JSONObject().put("summarizing", summarizing).put("summaries", JSONArray(unsent.map { s ->
                JSONObject().put("id", s.id).put("record_ids", JSONArray(s.recordIds)).put("title", s.title)
                    .put("summary", s.summary).put("points", JSONArray(s.points))
            })))
            vault.markSummariesSent(reply.getJSONArray("saved").strings(), reply.getJSONArray("stale").strings())
        } catch (error: Exception) {
            if (!ignoreSummaryError(error, relay)) throw error
        }
        try {
            val from = now - SUMMARY_WINDOW
            val got = send("conversations", JSONObject().put("from", from).put("to", now))
            vault.saveMacSummaries(from, now, got.getJSONArray("conversations"))
        } catch (error: Exception) {
            if (!ignoreSummaryError(error, relay)) throw error
        }
    }

    private fun ignoreSummaryError(error: Exception, relay: Boolean): Boolean {
        if (error is CancellationException || error is DeviceRemoved) return false
        return !relay || (error is DeviceStatus && error.status in setOf(400, 404))
    }

    private fun forgetAudioPolicy(persist: () -> Unit) {
        val runtime = AudioRuntime.get(app)
        synchronized(runtime.lock) {
            runtime.invalidatePolicy()
            persist()
        }
        runtime.schedule()
    }

    private fun parseAddress(value: String): String? = value.trim().takeIf(String::isNotEmpty)?.let {
        try { macOrigin(it) } catch (_: Exception) { throw InvalidMacAddress() }
    }

    private companion object {
        const val MAX_RETRY = 3_600_000L
        /** The Mac accepts at most 32 days per request. */
        const val SUMMARY_WINDOW = 31 * 86_400_000L
    }
}

internal class InvalidMacAddress : Exception()

internal fun syncError(error: Throwable, pairing: Boolean = false): String = when {
    error is InviteExpired || (error is DeviceStatus && error.operation == "pair" && error.status == 403) ->
        "配对邀请已过期或已使用，请在 Mac 上生成新邀请"
    error is EnvelopeTooLarge -> "这批同步内容太大，手机暂时无法接收"
    error is InvalidMacAddress -> "请输入有效的 Mac 地址"
    error is MacUnavailable && error.networkMismatch -> "手机和 Mac 可能不在同一网络"
    error is MacUnavailable || (error is IOException && error !is DeviceStatus) -> "连不上 Mac，请检查 Mac 上的 Tacit 和网络"
    error is DeviceStatus && error.status in setOf(500, 503) -> "Mac 暂时无法处理同步，请稍后重试"
    error is DeviceStatus && error.status == 400 -> "Mac 未能完成请求，请检查两台设备的日期与时间"
    pairing && (error is IllegalArgumentException || error is java.net.URISyntaxException || error is org.json.JSONException) ->
        "配对邀请无效，请重新扫描或粘贴"
    pairing -> "无法完成配对，请在 Mac 上生成新邀请"
    else -> "同步未完成，将重试"
}
