package top.jinso.tacit.sync

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URI
import java.security.MessageDigest
import java.time.Instant
import org.bouncycastle.crypto.AsymmetricCipherKeyPair

internal fun JSONObject.integer(key: String): Long = when (val value = get(key)) {
    is Int -> value.toLong()
    is Long -> value
    else -> error("Expected integer: $key")
}

internal fun JSONObject.optionalString(key: String): String? = if (isNull(key)) null else get(key) as String
internal fun JSONArray.strings(): List<String> = (0 until length()).map { get(it) as String }

internal class InviteExpired : Exception()
/** [incomplete]: the time budget ran out before every way to reach the Mac was tried, so it is not a real miss. */
internal class MacUnavailable(val networkMismatch: Boolean, val incomplete: Boolean = false) : IOException()
internal class DeviceRemoved : Exception()
internal class DeviceStatus(val status: Int, val operation: String) : IOException()
internal class EnvelopeTooLarge : Exception()

internal data class Invitation(
    val hubId: String, val macName: String, val publicKey: String, val code: String,
    val addresses: List<String>, val expiresAt: Instant, val relay: RelayConfig? = null,
) {
    companion object {
        fun parse(input: String, now: Instant = Instant.now()): Invitation {
            val uri = URI(input.trim())
            require(uri.scheme == "tacit" && uri.rawAuthority == "pair" && uri.rawPath.isEmpty() && uri.rawFragment == null)
            val query = requireNotNull(uri.rawQuery)
            require(query.startsWith("d=") && query.length <= 16_384)
            val json = JSONObject(query.drop(2).decode64().toString(Charsets.UTF_8))
            require(json.integer("v") == 1L)
            val hubId = json.getString("hub_id")
            val pk = json.getString("pk")
            require(hubIdPattern.matches(hubId) && hubId == hubIdForKey(pk.decode64(32)))
            val code = json.getString("code").also { it.decode64(16) }
            val expires = Instant.parse(json.getString("expires_at"))
            if (!expires.isAfter(now)) throw InviteExpired()
            return Invitation(hubId, json.getString("name").also { require(it.isNotBlank()) }, pk, code,
                json.getJSONArray("addrs").strings().mapNotNull { runCatching { macOrigin(it) }.getOrNull() }.distinct(), expires,
                json.optJSONObject("relay")?.let(RelayConfig::parse))
        }
    }
}

private fun hubIdForKey(pk: ByteArray): String = buildString {
    val alphabet = "abcdefghijklmnopqrstuvwxyz234567"
    var bits = 0
    var remaining = 0
    for (byte in MessageDigest.getInstance("SHA-256").digest(pk).take(16)) {
        bits = (bits shl 8) or (byte.toInt() and 255)
        remaining += 8
        while (remaining >= 5) {
            remaining -= 5
            append(alphabet[(bits shr remaining) and 31])
        }
    }
    if (remaining > 0) append(alphabet[(bits shl (5 - remaining)) and 31])
}

internal fun macOrigin(input: String): String {
    val value = input.trim()
    val uri = URI(if ("://" in value) value else "http://$value")
    require(uri.scheme in setOf("http", "https") && uri.host != null && uri.rawUserInfo == null &&
        uri.rawPath in setOf("", "/") && uri.rawQuery == null && uri.rawFragment == null &&
        (uri.port == -1 || uri.port in 1..65535))
    return "${uri.scheme}://${uri.rawAuthority}"
}

internal data class DeviceHttpReply(val status: Int, val body: ByteArray = byteArrayOf())
internal fun deviceHttp(origin: String, payload: ByteArray?, timeout: Int = if (payload == null) 2_500 else 20_000): DeviceHttpReply {
    val path = if (payload == null) "/v1/device/hello" else "/v1/device"
    val connection = URI(macOrigin(origin) + path).toURL().openConnection(Proxy.NO_PROXY) as HttpURLConnection
    try {
        connection.instanceFollowRedirects = false
        connection.useCaches = false
        connection.connectTimeout = minOf(2_500, timeout)
        connection.readTimeout = timeout
        if (payload != null) {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setFixedLengthStreamingMode(payload.size)
            connection.outputStream.use { it.write(payload) }
        }
        val status = connection.responseCode
        if (status != 200) return DeviceHttpReply(status)
        val limit = if (payload == null) 4096 else 24 * 1024 * 1024
        val bytes = connection.inputStream.use { stream ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                if (output.size() + count > limit) throw EnvelopeTooLarge()
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
        return DeviceHttpReply(status, bytes)
    } finally { connection.disconnect() }
}

internal fun matchesHub(origin: String, hubId: String, timeout: Int = 2_500): Boolean = runCatching {
    val reply = deviceHttp(origin, null, timeout)
    if (reply.status != 200) return false
    val json = JSONObject(reply.body.toString(Charsets.UTF_8))
    json.integer("v") == 1L && json.getString("hub_id") == hubId
}.getOrDefault(false)

internal class DeviceClient(
    private val hub: String,
    private val keys: AsymmetricCipherKeyPair,
    private val post: (ByteArray) -> DeviceHttpReply,
    private val device: String? = null,
) {
    private var removed = false
    private val protocol = DeviceMessages(hub, keys, device)
    fun send(op: String, body: JSONObject = JSONObject()): JSONObject {
        if (removed) throw DeviceRemoved()
        val request = protocol.request(op, body)
        if (request.json.size > MAX_ENVELOPE) throw EnvelopeTooLarge()
        val reply = post(request.json)
        if (reply.status == 401 && device != null) {
            removed = true
            throw DeviceRemoved()
        }
        if (reply.status != 200) throw DeviceStatus(reply.status, op)
        return protocol.response(op, protocol.open(reply.body, request.nonce))
    }

    fun pair(invite: Invitation, phoneName: String): String = pairDevice(invite, keys, phoneName, ::send).id
}

internal class DeviceMessages(
    private val hub: String,
    private val keys: AsymmetricCipherKeyPair,
    private val device: String? = null,
) {
    fun request(op: String, body: JSONObject) = DeviceEnvelope.request(device, hub, keys, op, body)

    fun open(wire: ByteArray, nonce: String) = JSONObject(DeviceEnvelope.open(
        JSONObject(wire.toString(Charsets.UTF_8)), DeviceEnvelope.RESPONSE_INFO, nonce, keys, hub))

    fun response(op: String, message: JSONObject): JSONObject {
        val status = message.integer("status")
        require(status in 100..599)
        if (status == 401L && device != null) throw DeviceRemoved()
        if (status != 200L) throw DeviceStatus(status.toInt(), op)
        return message.getJSONObject("body")
    }
}

internal data class PairedDevice(val id: String, val relay: RelayConfig?)

internal fun pairDevice(
    invite: Invitation,
    keys: AsymmetricCipherKeyPair,
    phoneName: String,
    send: (String, JSONObject) -> JSONObject,
): PairedDevice {
    if (!invite.expiresAt.isAfter(Instant.now())) throw InviteExpired()
    return pairedDevice(invite, send("pair", pairBody(invite, keys, phoneName)))
}

internal fun pairBody(invite: Invitation, keys: AsymmetricCipherKeyPair, phoneName: String): JSONObject =
    JSONObject().put("code", invite.code).put("device_pk", DeviceEnvelope.public(keys).base64url())
        .put("name", phoneName).put("platform", "android")

internal fun pairedDevice(invite: Invitation, response: JSONObject): PairedDevice {
    require(response.getString("hub_id") == invite.hubId)
    val id = response.getString("device_id").also { require(deviceIdPattern.matches(it)) }
    return PairedDevice(id, response.optJSONObject("relay")?.let(RelayConfig::parse))
}

internal fun sendingCopy(wire: String, deviceId: String): JSONObject = JSONObject(wire).put("device", deviceId)

internal fun uploadReceipt(json: JSONObject, count: Int): Map<Int, String> {
    val rejected = json.getJSONArray("rejected")
    val accepted = json.integer("accepted")
    val duplicates = json.integer("duplicates")
    require(accepted in 0L..count.toLong() && duplicates in 0L..count.toLong() &&
        accepted + duplicates + rejected.length() == count.toLong())
    return buildMap {
        for (index in 0 until rejected.length()) {
            val entry = rejected.getJSONObject(index)
            val position = entry.integer("index")
            val reasons = entry.getJSONArray("errors").strings()
            require(position in 0L until count.toLong() && position.toInt() !in this && reasons.isNotEmpty())
            put(position.toInt(), reasons.joinToString("；"))
        }
    }
}

internal sealed interface Change {
    data class Delete(val id: String, val source: String?, val ref: String?) : Change
    data class Correction(val record: JSONObject) : Change
}

internal inline fun pullChanges(send: (String, JSONObject) -> JSONObject, apply: (List<Change>) -> Unit) {
    var cursor = 0L
    do {
        val page = send("sync", JSONObject().put("cursor", cursor))
        val next = page.integer("cursor")
        val more = page.get("more") as Boolean
        val rows = page.getJSONArray("changes")
        require(next >= cursor && (next > cursor || (!more && rows.length() == 0)))
        var last = cursor
        val changes = (0 until rows.length()).map {
            val row = rows.getJSONObject(it)
            val seq = row.integer("seq")
            require(seq > last && seq <= next)
            last = seq
            when (row.getString("kind")) {
                "delete" -> Change.Delete(row.getString("id"), row.optionalString("source"), row.optionalString("source_ref"))
                "correction" -> Change.Correction(row.getJSONObject("record"))
                else -> error("Unknown sync change")
            }
        }
        if (next > cursor) {
            apply(changes)
            check(send("sync.ack", JSONObject().put("cursor", next)).get("ok") == true)
        }
        cursor = next
    } while (more)
}
