package top.jinso.tacit.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import org.bouncycastle.crypto.AsymmetricCipherKeyPair
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI

internal data class RelayConfig(val url: String, val space: String, val up: String, val down: String, val token: String) {
    fun json() = JSONObject().put("url", url).put("space", space).put("up", up).put("down", down).put("token", token)

    companion object {
        fun parse(json: JSONObject): RelayConfig {
            val uri = URI(json.getString("url"))
            require(uri.host != null && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
                (uri.port == -1 || uri.port in 1..65535) &&
                (uri.scheme == "https" || uri.scheme == "http" && uri.host in setOf("127.0.0.1", "localhost")))
            val url = uri.toASCIIString().trimEnd('/')
            val space = json.getString("space").also { it.decode64(16) }
            val up = json.getString("up").also { it.decode64(16) }
            val down = json.getString("down").also { it.decode64(16) }
            val token = json.getString("token").also { require(it.matches(Regex("[A-Za-z0-9_-]{20,200}"))) }
            return RelayConfig(url, space, up, down, token)
        }
    }
}

internal const val DEFAULT_MESSAGE_BYTES = 1024 * 1024
internal class RelayStatus(val status: Int) : IOException() {
    val unauthorized get() = status == 401 || status == 403
}

internal class RelayWaiting : IOException()
internal typealias RelayHttp = (String, String, String?, ByteArray?, Int, Int) -> DeviceHttpReply

internal class RelayMailbox(val config: RelayConfig, private val http: RelayHttp = ::relayHttp) {
    private val prefix = "/v1/spaces/${config.space}/boxes"
    private val down = "$prefix/${config.down}/messages"
    val messageBytes: Int by lazy {
        try {
            val result = call("GET", "/v1/hello", token = null).json()
            require(result.integer("tacit_relay") == 1L)
            result.getJSONObject("limits").integer("message_bytes").coerceAtMost(MAX_ENVELOPE.toLong()).toInt()
                .also { require(it > 0) }
        } catch (error: CancellationException) {
            throw error
        } catch (error: RelayStatus) {
            if (error.unauthorized || error.status in setOf(429, 507)) throw error
            DEFAULT_MESSAGE_BYTES
        } catch (_: Exception) {
            DEFAULT_MESSAGE_BYTES
        }
    }

    fun put(request: DeviceEnvelope.Request) {
        if (request.json.size > messageBytes) throw EnvelopeTooLarge()
        call("PUT", "$prefix/${config.up}/messages/${request.nonce}", payload = request.json, statuses = setOf(200, 201))
    }

    fun get(id: String, timeout: Int = 5_000): ByteArray? {
        val response = call("GET", "$down/$id", limit = MAX_ENVELOPE, statuses = setOf(200, 404), timeout = timeout)
        return response.body.takeIf { response.status == 200 }
    }

    fun delete(id: String) { call("DELETE", "$down/$id") }

    fun scan(visit: (String) -> Unit) {
        var after = "0"
        while (true) {
            val page = call("GET", "$down?after=$after&limit=100").json()
            val messages = page.getJSONArray("messages")
            for (i in 0 until messages.length()) {
                visit(messages.getJSONObject(i).getString("id").also { it.decode64(16) })
            }
            val next = page.optionalString("next") ?: return
            require(next.matches(Regex("[0-9]{1,15}")) && next.toLong() > after.toLong())
            after = next
        }
    }

    suspend fun await(id: String, until: Long, now: () -> Long = System::currentTimeMillis): ByteArray? {
        var interval = 250L
        while (true) {
            val remaining = until - now()
            if (remaining <= 0) return null
            get(id, remaining.coerceAtMost(5_000).toInt())?.let { return it }
            delay(minOf(interval, (until - now()).coerceAtLeast(0)))
            interval = (interval * 2).coerceAtMost(2_000)
        }
    }

    private fun call(
        method: String, path: String, token: String? = config.token, payload: ByteArray? = null,
        limit: Int = 32 * 1024, statuses: Set<Int> = setOf(200), timeout: Int = 5_000,
    ): DeviceHttpReply {
        // The injected transport uses the same validation and HTTP status rules as production.
        val reply = http(method, config.url + path, token, payload, limit, timeout)
        if (reply.status !in statuses) throw RelayStatus(reply.status)
        return reply
    }
}

private fun DeviceHttpReply.json() = JSONObject(body.toString(Charsets.UTF_8))

private fun relayHttp(
    method: String, url: String, token: String?, payload: ByteArray?, limit: Int, timeout: Int = 5_000,
): DeviceHttpReply {
    val connection = URI(url).toURL().openConnection() as HttpURLConnection
    try {
        connection.instanceFollowRedirects = false
        connection.useCaches = false
        connection.connectTimeout = minOf(timeout, 2_500)
        connection.readTimeout = timeout
        connection.requestMethod = method
        if (token != null) connection.setRequestProperty("Authorization", "Bearer $token")
        if (payload != null) {
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setFixedLengthStreamingMode(payload.size)
            connection.outputStream.use { it.write(payload) }
        }
        val status = connection.responseCode
        if (status !in 200..299) return DeviceHttpReply(status)
        val output = ByteArrayOutputStream()
        connection.inputStream.use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (output.size() + count > limit) throw EnvelopeTooLarge()
                output.write(buffer, 0, count)
            }
        }
        return DeviceHttpReply(status, output.toByteArray())
    } finally {
        connection.disconnect()
    }
}

internal suspend fun pairWithAvailableTransport(
    invite: Invitation, keys: AsymmetricCipherKeyPair, phoneName: String,
    findMac: suspend () -> String,
    persist: (PairedDevice, String?) -> Unit,
) {
    val origin = try { findMac() } catch (error: MacUnavailable) {
        if (invite.relay == null) throw error
        null
    }
    if (origin == null) pairThroughRelay(invite, keys, phoneName) { persist(it, null) }
    else {
        val client = DeviceClient(invite.publicKey, keys, { deviceHttp(origin, it) })
        persist(pairDevice(invite, keys, phoneName, client::send), origin)
    }
}

internal suspend fun pairThroughRelay(
    invite: Invitation, keys: AsymmetricCipherKeyPair, phoneName: String,
    mailbox: RelayMailbox = RelayMailbox(requireNotNull(invite.relay)),
    persist: (PairedDevice) -> Unit,
) {
    val protocol = DeviceMessages(invite.publicKey, keys)
    if (!invite.expiresAt.isAfter(java.time.Instant.now())) throw InviteExpired()
    val request = protocol.request("pair", pairBody(invite, keys, phoneName))
    mailbox.put(request)
    val wire = mailbox.await(request.nonce, invite.expiresAt.toEpochMilli()) ?: throw InviteExpired()
    val message = protocol.open(wire, request.nonce)
    val body = protocol.response("pair", message)
    persist(pairedDevice(invite, body))
    try { mailbox.delete(request.nonce) } catch (_: IOException) { /* Temporary mail expires with the invitation. */ }
}
