package top.jinso.tacit.sync

import android.net.ConnectivityManager
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.bouncycastle.crypto.AsymmetricCipherKeyPair
import org.json.JSONArray
import org.json.JSONObject
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioRuntime
import top.jinso.tacit.data.Keys
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

internal data class MacStatus(
    val name: String?, val manual: String, val removed: Boolean, val lastSync: Long,
    val pending: Int, val rejected: Map<String, Int>, val error: String?, val relayDisabled: Boolean = false,
)

internal class SyncCoordinator(private val app: TacitApp) {
    private val mutex = Mutex()
    private val vault get() = app.vault
    private val timelineCache = TimelineCache(EncryptedTimelineDisk(app), isDeleted = { vault.isRecordDeleted(it) })
    private val timeline = TimelineSync(timelineCache)
    private val relayBackoff = RelayRateLimit(SystemClock::elapsedRealtime)
    private val directDiscovery = DirectDiscoveryBackoff(SystemClock::elapsedRealtime)
    private val originalReads = Mutex()
    private val originalRequests = ConcurrentHashMap.newKeySet<String>()
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
            val customName = runCatching { Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
            val phoneName = pairingDeviceName(customName, Build.MODEL, Build.BRAND)
            pairWithAvailableTransport(invite, keys, phoneName, findMac = {
                MacDiscovery(app).find(invite.hubId, last, invite.addresses, manual)
            }, rateLimit = relayBackoff) { paired, origin ->
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

    suspend fun run(retry: Boolean, periodic: Boolean = false, fromForeground: Boolean = false) = mutex.withLock {
        val data = try {
            vault.syncConnection()
        } catch (error: Exception) {
            if (error is CancellationException || !fromForeground) throw error
            timeline.clear()
            return@withLock
        }
        if (data == null || data.optBoolean("removed")) {
            if (fromForeground) timeline.clear()
            return@withLock
        }
        if (fromForeground && !timelineWorkerScheduled) {
            SyncWorker.schedulePeriodic(app)
            timelineWorkerScheduled = true
        }
        val wait = data.optLong("retryAt") - System.currentTimeMillis()
        val foregroundRecovery = wait > 0 && !periodic && fromForeground
        val repeatRound = fromForeground && !periodic &&
            foregroundRoundIsRepeat(data.optLong("lastSync"), System.currentTimeMillis(), wait)
        if (wait > 0 && !periodic && !fromForeground) {
            if (retry) SyncWorker.retry(app, wait.coerceAtMost(MAX_RETRY))
            return@withLock
        }
        timelineCache.bind(timelineOwner(data))
        val ctx = currentCoroutineContext()
        var recovered = false
        try {
            val journal = RelayJournal(data, { vault.saveSyncConnection(data) })
            var unavailable: MacUnavailable? = null
            val origin = try { findOrigin(data, budget = if (fromForeground) networkBudget() else null, forceProbe = fromForeground) } catch (error: MacUnavailable) {
                unavailable = error
                null
            }
            // A foreground resume may refresh the local timeline during audio/relay backoff.
            if (fromForeground && origin == null && !repeatRound) timelineCache.refreshFailed()
            if (repeatRound) {
                // A full round just finished; only the direct timeline is worth refreshing, no mailbox traffic.
                if (origin != null) {
                    val client = deviceClient(data, origin, networkBudget())
                    refreshDirectTimeline(client, refreshRelay(data, client, journal))
                }
                return@withLock
            }
            val device = data.getString("device")
            val keys = restoreKeys(data)
            val hubKey = data.getString("hubKey")
            val protocol = DeviceMessages(hubKey, keys, device)
            fun exchange(mailbox: RelayMailbox) = RelayExchange(protocol, journal, mailbox,
                { delivery, reply -> applyRelayReceipt(data, delivery, reply) },
                canResubmit = { it.op != "ingest" || it.ids.all { id -> vault.wire(id) != null } })
            val startingRelay = journal.active
            if (!foregroundRecovery) {
                for (retired in journal.retired().filter { it != startingRelay }) {
                    drainRetired(data, journal, retired, protocol)
                }
            }
            if (startingRelay != null && !journal.disabled &&
                (origin == null || !foregroundRecovery && journal.deliveries().any { it.box == startingRelay.down && it.ids.isNotEmpty() })) {
                ctx.ensureActive()
                if (origin == null) {
                    pollRelayTimeline(data, journal, startingRelay, protocol, postDue = true,
                        budget = if (wait > 0) networkBudget() else null)
                } else {
                    try {
                        pollRelayTimeline(data, journal, startingRelay, protocol, postDue = false, budget = networkBudget())
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: DeviceRemoved) {
                        throw error
                    } catch (_: Exception) {
                        // A mailbox outage cannot block direct sync.
                    }
                }
            }
            journal.prune()

            if (origin != null) {
                val client = DeviceClient(hubKey, keys, { request ->
                    ctx.ensureActive()
                    deviceHttp(origin, request)
                }, device)
                journal.finishRound()
                val role = refreshRelay(data, client, journal)
                if (foregroundRecovery) {
                    directSyncRecovered(data, origin, vault::saveSyncConnection)
                    recovered = true
                }
                if ((periodic || fromForeground) && role == "view") {
                    refreshDirectTimeline(deviceClient(data, origin, networkBudget()), role)
                }
                if (wait > 0 && !recovered) return@withLock
                data.put("last", origin)
                pullFromMac(data, client::send)
                sendDirect(device, client, journal)
                syncSummaries(System.currentTimeMillis(), client::send)
            } else {
                if (journal.disabled) timeline.clear()
                if (wait > 0) return@withLock
                val config = journal.active?.takeUnless { journal.disabled } ?: throw requireNotNull(unavailable)
                val mailbox = RelayMailbox(config, rateLimit = relayBackoff)
                val relay = exchange(mailbox)
                journal.useMailbox(config) {
                    if (config != startingRelay) pollRelayTimeline(data, journal, config, protocol, postDue = true)
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
            data.clearSyncFailure()
            vault.saveSyncConnection(data)
        } catch (error: CancellationException) {
            throw error
        } catch (_: DeviceRemoved) {
            markRemoved(data)
        } catch (error: Exception) {
            if (error is RelayStatus && error.unauthorized && data.optBoolean("relayDisabled")) timeline.clear()
            if (foregroundRecovery && !recovered) {
                timelineCache.refreshFailed()
                return@withLock
            }
            val failures = (data.optInt("failures") + 1).coerceAtMost(8)
            val delay = (30_000L shl (failures - 1)).coerceAtMost(MAX_RETRY)
            data.put("error", if (data.optBoolean("relayDisabled")) null else syncError(error)).put("failures", failures).put("retryAt", System.currentTimeMillis() + delay)
            vault.saveSyncConnection(data)
            SyncWorker.retry(app, delay)
        }
    }

    suspend fun refreshTimeline(foreground: Boolean = false) = withContext(Dispatchers.IO) {
        if (foreground) {
            // Show the cached timeline at once, even offline; the network round waits for a connection.
            val data = try {
                vault.syncConnection()
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                timeline.clear()
                return@withContext
            }
            if (data == null || data.optBoolean("removed")) {
                timeline.clear()
                return@withContext
            }
            timelineCache.bind(timelineOwner(data))
            // WorkManager runs the round so leaving the app does not cancel it midway. Its own lane keeps
            // the foreground flag from being swallowed by a queued network trigger; a round that follows a
            // just-finished one skips the mailbox (foregroundRoundIsRepeat).
            SyncWorker.enqueue(app, fromForeground = true)
            return@withContext
        }
        if (!mutex.tryLock()) return@withContext
        try {
            val data = try {
                vault.syncConnection()
            } catch (_: Exception) {
                // The app already shows the locked-vault state.
                timeline.clear()
                return@withContext
            }
            timelineCache.bind(data?.takeUnless { it.optBoolean("removed") }?.let(::timelineOwner))
            if (data == null || data.optBoolean("removed")) return@withContext
            try {
                val journal = RelayJournal(data, { vault.saveSyncConnection(data) })
                val config = journal.active?.takeUnless { journal.disabled }
                val origin = try { findOrigin(data, networkBudget()) } catch (_: MacUnavailable) { null }
                val budget = networkBudget()
                if (origin != null) {
                    val client = deviceClient(data, origin, budget)
                    refreshDirectTimeline(client, refreshRelay(data, client, journal))
                } else if (journal.disabled) {
                    timeline.clear()
                } else {
                    timelineCache.refreshFailed()
                    if (config != null) {
                        val protocol = DeviceMessages(data.getString("hubKey"), restoreKeys(data), data.getString("device"))
                        pollRelayTimeline(data, journal, config, protocol, postDue = true, budget = budget)
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: DeviceRemoved) {
                markRemoved(data)
            } catch (error: RelayStatus) {
                if (error.unauthorized) timeline.clear() else timelineCache.refreshFailed()
            } catch (_: Exception) {
                // Keep the last confirmed view while the hub is unreachable.
                timelineCache.refreshFailed()
            }
        } finally {
            mutex.unlock()
        }
    }

    private suspend fun refreshDirectTimeline(client: DeviceClient, role: String?) {
        try {
            timeline.pull(role, client::send)
        } catch (error: CancellationException) {
            throw error
        } catch (error: DeviceRemoved) {
            throw error
        } catch (_: Exception) {
            // A projection failure should not prevent audio sync.
            timelineCache.refreshFailed()
        }
    }

    suspend fun timelineOriginals(ids: Set<String>): List<TimelineOriginal> = withContext(Dispatchers.IO) {
        originalReads.withLock {
            val data = vault.syncConnection()?.takeUnless { it.optBoolean("removed") } ?: throw DeviceRemoved()
            val lastInvalidation = timelineSnapshots.value.invalidation
            val config = RelayJournal(data, {}).let { it.active?.takeUnless { _ -> it.disabled } }
            try {
                val origin = withTimeoutOrNull(NETWORK_BUDGET) {
                    try { findOrigin(data, networkBudget()) }
                    catch (error: MacUnavailable) { if (config == null) throw error else null }
                }
                val originals = if (origin != null) {
                    readTimelineOriginals(ids, deviceClient(data, origin)::send)
                } else {
                    val journal = RelayJournal(data, {})
                    val protocol = DeviceMessages(data.getString("hubKey"), restoreKeys(data), data.getString("device"))
                    val relay = RelayExchange(protocol, journal, RelayMailbox(config ?: throw RelayWaiting(), rateLimit = relayBackoff), { _, _ -> })
                    readTimelineOriginals(ids) { op, body -> relay.sendTransient(op, body, originalRequests) }
                }
                val current = vault.syncConnection()
                if (current == null || current.optBoolean("removed") || timelineOwner(current) != timelineOwner(data) ||
                    timelineSnapshots.value.invalidation != lastInvalidation) throw RelayWaiting()
                originals
            } catch (error: DeviceRemoved) {
                updateAfterOriginalFailure(data) { markRemoved(it) }
                throw error
            } catch (error: DeviceStatus) {
                if (error.status == 403) updateAfterOriginalFailure(data) { timeline.clear() }
                throw error
            } catch (error: RelayStatus) {
                if (error.unauthorized) updateAfterOriginalFailure(data) {
                    val journal = RelayJournal(it, { vault.saveSyncConnection(it) })
                    if (config != null && journal.active == config) {
                        journal.disable(config)
                        timeline.clear()
                    }
                }
                throw error
            }
        }
    }

    private suspend fun updateAfterOriginalFailure(previous: JSONObject, update: (JSONObject) -> Unit) {
        // A detail read only takes the sync lock if it needs to update the paired connection.
        mutex.withLock {
            val latest = vault.syncConnection() ?: return@withLock
            if (timelineOwner(latest) == timelineOwner(previous)) update(latest)
        }
    }

    private fun timelineOwner(data: JSONObject) = data.getString("hub") + ":" + data.getString("device")

    fun withdrawTimelineRecords(ids: Set<String>) = timelineCache.withdrawRecords(ids)

    private fun relayTimeline(data: JSONObject, config: RelayConfig) =
        RelayTimeline(data, config.down, timelineCache, timeline, { vault.saveSyncConnection(data) })

    private fun pollRelayTimeline(
        data: JSONObject, journal: RelayJournal, config: RelayConfig, protocol: DeviceMessages,
        postDue: Boolean, budget: (() -> Int)? = null,
    ) {
        val state = relayTimeline(data, config)
        val mailbox = RelayMailbox(config, remainingMillis = budget, rateLimit = relayBackoff)
        val relay = RelayExchange(protocol, journal, mailbox, { delivery, reply -> applyRelayReceipt(data, delivery, reply) })
        journal.useMailbox(config) {
            relay.drain(timelineRequestIds = state.replyIds, originalRequests = originalRequests,
                onTimelineReply = { nonce, message ->
                    if (journal.active == config) state.reply(nonce, message, protocol)
                }, projection = state::push)
            if (postDue && journal.active == config) state.postDue(protocol, mailbox::put)
        }
    }

    private fun drainRetired(data: JSONObject, journal: RelayJournal, config: RelayConfig, protocol: DeviceMessages) {
        try {
            journal.useMailbox(config) {
                val relay = RelayExchange(protocol, journal, RelayMailbox(config, rateLimit = relayBackoff),
                    { delivery, reply -> applyRelayReceipt(data, delivery, reply) })
                relay.drain(allowMove = false, originalRequests = originalRequests) { message ->
                    val active = journal.active
                    if (active == null) timeline.push(message, view = false)
                    else relayTimeline(data, active).push(message)
                }
            }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // Retired mail is best effort. Continue syncing over the active route.
        }
    }

    private fun deviceClient(data: JSONObject, origin: String, budget: (() -> Int)? = null) =
        DeviceClient(data.getString("hubKey"), restoreKeys(data), { request ->
            if (budget == null) deviceHttp(origin, request)
            else {
                val timeout = budget()
                if (timeout <= 0) throw RelayWaiting()
                deviceHttp(origin, request, timeout)
            }
        }, data.getString("device"))

    private fun applyRelayReceipt(data: JSONObject, delivery: RelayJournal.Delivery, reply: JSONObject) {
        when (delivery.op) {
            "ingest" -> vault.applyReceipt(delivery.ids, uploadReceipt(reply, delivery.ids.size))
            "delete" -> confirmDeletes(delivery.ids, reply)
        }
        data.put("lastSync", System.currentTimeMillis())
    }

    private data class DirectRoute(val owner: String, val network: Long?, val addresses: String?, val manual: String?)

    private suspend fun findOrigin(
        data: JSONObject, budget: (() -> Int)? = null, forceProbe: Boolean = false,
    ): String {
        val connectivity = app.getSystemService(ConnectivityManager::class.java)
        val active = connectivity.activeNetwork
        val route = DirectRoute(timelineOwner(data), active?.networkHandle,
            connectivity.getLinkProperties(active)?.linkAddresses?.toString(), data.optionalString("manual"))
        val canRelay = !data.isNull("relay") && !data.optBoolean("relayDisabled")
        return directDiscovery.find(route, canRelay, forceProbe) {
            MacDiscovery(app).find(data.getString("hub"), data.optionalString("last"),
                data.getJSONArray("addresses").strings(), route.manual, budget ?: { Int.MAX_VALUE })
        }
    }

    private fun networkBudget(): () -> Int {
        val deadline = SystemClock.elapsedRealtime() + NETWORK_BUDGET
        return { (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0).toInt() }
    }

    private fun restoreKeys(data: JSONObject): AsymmetricCipherKeyPair {
        val public = data.getString("public")
        val secret = Keys(app).unwrapDeviceKey(data.getString("private").decode64(), public)
        return try { DeviceEnvelope.restore(secret, public.decode64(32)) } finally { secret.fill(0) }
    }

    private fun markRemoved(data: JSONObject) {
        timeline.clear()
        data.put("removed", true)
        for (key in listOf("private", "relay", "relayDisabled", "relayRetired", "relayJournal", "relayRoundAt", "relayTimeline", "audio", "error")) {
            data.remove(key)
        }
        forgetAudioPolicy { vault.saveSyncConnection(data) }
        SyncWorker.cancel(app)
    }

    private fun refreshRelay(data: JSONObject, client: DeviceClient, journal: RelayJournal): String? {
        val reply = try { client.send("relay") } catch (error: DeviceStatus) {
            if (error.status in setOf(400, 404)) {
                timeline.role(null)
                return null // Older Mac.
            }
            throw error
        }
        val role = reply.optionalString("role")
        journal.config(if (reply.isNull("relay")) null else RelayConfig.parse(reply.getJSONObject("relay")))
        val active = journal.active
        if (active == null) timeline.role(role)
        else relayTimeline(data, active).role(role)
        return role
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
        var messageLimit: Int? = null
        while (true) {
            val batch = vault.uploadBatch(device, journal.inFlight("ingest") + oversized)
            if (batch.isEmpty()) break
            val limit = messageLimit ?: mailbox.messageBytes.also { messageLimit = it }
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
                messageLimit = minOf(limit, upload.request.json.size - 1)
            }
        }
    }

    private fun deleteBody(ids: List<String>) = JSONObject().put("ids", JSONArray(ids))

    private fun confirmDeletes(ids: List<String>, reply: JSONObject) {
        require(reply.integer("deleted") in 0..ids.size.toLong())
        withdrawTimelineRecords(ids.toSet())
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
        // Enough for one full pass: known addresses in parallel (2 s), then Bonjour (5 s).
        const val NETWORK_BUDGET = 7_500L
        /** The Mac accepts at most 32 days per request. */
        const val SUMMARY_WINDOW = 31 * 86_400_000L
    }
}

internal class InvalidMacAddress : Exception()

private fun JSONObject.clearSyncFailure() {
    remove("error")
    remove("retryAt")
    remove("failures")
}

/** Remember the authenticated direct route before resuming uploads, which can fail independently. */
internal fun directSyncRecovered(data: JSONObject, origin: String, save: (JSONObject) -> Unit) {
    data.put("last", origin)
    data.clearSyncFailure()
    save(data)
}

private const val SYNC_QUEUED = "暂时连不上 Mac，记录已排队等待同步"
private const val RELAY_RATE_LIMITED = "中转信箱今日请求已达上限，稍后会自动重试"
private const val RELAY_FULL = "中转信箱空间已满，等 Mac 取走后会自动继续"
private const val RELAY_WAITING = "正在等待 Mac 响应，稍后会自动同步"

internal fun isSyncWaiting(message: String, pairing: Boolean = false): Boolean = when (message) {
    SYNC_QUEUED, RELAY_RATE_LIMITED, RELAY_FULL, RELAY_WAITING -> true
    // Previously persisted messages, until the next sync refreshes them.
    "手机和 Mac 可能不在同一网络", "连不上 Mac，请检查 Mac 上的 Tacit 和网络" -> !pairing
    else -> false
}

internal fun syncError(error: Throwable, pairing: Boolean = false): String = when {
    error is InviteExpired || (error is DeviceStatus && error.operation == "pair" && error.status == 403) ->
        "邀请链接已过期或已使用，请在 Mac 上重新生成"
    error is EnvelopeTooLarge -> "这批同步内容太大，暂时无法同步"
    error is RelayStatus && error.status == 429 -> RELAY_RATE_LIMITED
    error is RelayStatus && error.status == 507 -> RELAY_FULL
    error is RelayWaiting -> RELAY_WAITING
    error is InvalidMacAddress -> "请输入有效的 Mac 地址"
    pairing && error is MacUnavailable && error.networkMismatch -> "手机和 Mac 可能不在同一网络"
    error is MacUnavailable || (error is IOException && error !is DeviceStatus) ->
        if (pairing) "连不上 Mac，请检查 Mac 上的 Tacit 和网络" else SYNC_QUEUED
    error is DeviceStatus && error.status in setOf(500, 503) -> "Mac 暂时无法处理同步，请稍后重试"
    error is DeviceStatus && error.status == 400 -> "Mac 未能完成请求，请检查两台设备的日期与时间"
    pairing && (error is IllegalArgumentException || error is java.net.URISyntaxException || error is org.json.JSONException) ->
        "邀请链接无效，请重新扫描或粘贴"
    pairing -> "无法完成连接，请在 Mac 上重新生成邀请"
    else -> "同步未完成，将重试"
}
