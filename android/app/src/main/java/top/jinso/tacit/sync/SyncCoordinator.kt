package top.jinso.tacit.sync

import android.os.Build
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioRuntime
import top.jinso.tacit.data.Keys
import java.io.IOException

internal data class MacStatus(
    val name: String?, val manual: String, val removed: Boolean, val lastSync: Long,
    val pending: Int, val rejected: Map<String, Int>, val error: String?,
)

internal class SyncCoordinator(private val app: TacitApp) {
    private val mutex = Mutex()
    private val vault get() = app.vault

    suspend fun status(includeReasons: Boolean): MacStatus = withContext(Dispatchers.IO) {
        val data = vault.syncConnection()
        MacStatus(data?.optionalString("name"), data?.optString("manual").orEmpty(),
            data?.optBoolean("removed") == true, data?.optLong("lastSync") ?: 0L,
            if (data == null) 0 else vault.pendingCount(),
            if (data == null) emptyMap() else vault.rejectedReasons(includeReasons),
            data?.optionalString("error"))
    }

    suspend fun pair(uri: String, address: String) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val previous = vault.syncConnection()
            check(previous?.optBoolean("removed") != false)
            val invite = Invitation.parse(uri)
            val manual = parseAddress(address)
            val last = previous?.takeIf { it.optString("hub") == invite.hubId }?.optionalString("last")
            val origin = MacDiscovery(app).find(invite.hubId, last, invite.addresses, manual)
            val keys = DeviceEnvelope.generate()
            val public = DeviceEnvelope.public(keys).base64url()
            val secret = DeviceEnvelope.secret(keys)
            val wrapped = try { Keys(app).wrapDeviceKey(secret, public).base64url() } finally { secret.fill(0) }
            val device = DeviceClient(invite.publicKey, keys, { deviceHttp(origin, it) })
                .pair(invite, Build.MODEL.take(200).ifBlank { "Android" })
            vault.saveSyncConnection(JSONObject().put("device", device).put("hub", invite.hubId)
                .put("name", invite.macName).put("hubKey", invite.publicKey).put("private", wrapped)
                .put("public", public)
                .put("addresses", JSONArray(invite.addresses)).put("last", origin).put("manual", manual))
            SyncWorker.schedulePeriodic(app)
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
            forgetAudioPolicy { vault.saveSyncConnection(null) }
            SyncWorker.cancel(app)
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
            val origin = MacDiscovery(app).find(data.getString("hub"), data.optionalString("last"),
                data.getJSONArray("addresses").strings(), data.optionalString("manual"))
            val device = data.getString("device")
            val public = data.getString("public")
            val secret = Keys(app).unwrapDeviceKey(data.getString("private").decode64(), public)
            val keys = try { DeviceEnvelope.restore(secret, public.decode64(32)) } finally { secret.fill(0) }
            val client = DeviceClient(data.getString("hubKey"), keys, { request ->
                ctx.ensureActive()
                deviceHttp(origin, request)
            }, device)
            val runtime by lazy { AudioRuntime.get(app) }
            pullChanges({ op, body -> client.send(op, body).also { data.put("last", origin) } }) { page ->
                val audioDeletes = page.filterIsInstance<Change.Delete>().filter { it.source == "android.audio" }
                if (audioDeletes.isEmpty()) vault.applyChanges(page)
                else runtime.applyRecordChanges(page, audioDeletes)
            }
            // Fetch policy before sending queued records or doing any audio backfill.
            val audio = AudioSync.parse(client.send("audio.sync"))
            if (audio.purgeBefore != null || audio.deleted.isNotEmpty() || data.optJSONObject("audio")?.toString() != audio.policy.toString()) {
                runtime.applyMacAudio(audio) {
                    data.put("audio", audio.policy)
                    vault.saveSyncConnection(data)
                }
            }
            check(client.send("audio.sync.ack", audio.ack()).get("acknowledged") == true)
            while (true) {
                val ids = vault.pendingDeletes()
                if (ids.isEmpty()) break
                val count = client.send("delete", JSONObject().put("ids", JSONArray(ids))).integer("deleted")
                require(count in 0..ids.size.toLong())
                vault.confirmDeletes(ids)
            }
            while (true) {
                val batch = vault.uploadBatch(device)
                if (batch.isEmpty()) break
                val records = JSONArray(batch.map { it.second })
                val receipt = uploadReceipt(client.send("ingest", JSONObject().put("records", records)), batch.size)
                vault.applyReceipt(batch.map { it.first }, receipt)
            }
            // Summaries are a read-only extra: an older Mac without the op must not fail the whole sync.
            try {
                val now = System.currentTimeMillis(); val from = now - SUMMARY_WINDOW
                val got = client.send("conversations", JSONObject().put("from", from).put("to", now))
                vault.saveMacSummaries(from, now, got.getJSONArray("conversations"))
            } catch (error: CancellationException) { throw error } catch (error: DeviceRemoved) { throw error } catch (_: Exception) { }
            data.put("lastSync", System.currentTimeMillis()).put("last", origin)
            data.remove("error")
            data.remove("retryAt")
            data.remove("failures")
            vault.saveSyncConnection(data)
        } catch (error: CancellationException) {
            throw error
        } catch (_: DeviceRemoved) {
            data.put("removed", true)
            data.remove("private")
            data.remove("audio")
            data.remove("error")
            forgetAudioPolicy { vault.saveSyncConnection(data) }
            SyncWorker.cancel(app)
        } catch (error: Exception) {
            val failures = (data.optInt("failures") + 1).coerceAtMost(8)
            val delay = (30_000L shl (failures - 1)).coerceAtMost(MAX_RETRY)
            data.put("error", syncError(error)).put("failures", failures).put("retryAt", System.currentTimeMillis() + delay)
            vault.saveSyncConnection(data)
            SyncWorker.retry(app, delay)
        }
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
