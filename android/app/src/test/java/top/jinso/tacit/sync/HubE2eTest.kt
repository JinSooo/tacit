package top.jinso.tacit.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeNotNull
import org.junit.Test
import top.jinso.tacit.core.Ids
import java.net.URI
import java.time.Instant

class HubE2eTest {
    @Test fun pairUploadReceiveEditsAndAcknowledge() {
        val invitation = System.getenv("TACIT_E2E_INVITE")
        assumeNotNull(invitation)
        val invite = Invitation.parse(requireNotNull(invitation))
        val origin = invite.addresses.single()
        val admin = requireNotNull(System.getenv("TACIT_E2E_ADMIN"))
        val token = requireNotNull(System.getenv("TACIT_E2E_TOKEN"))
        fun request(path: String, method: String, json: JSONObject? = null): JSONObject {
            val connection = URI(admin + path).toURL().openConnection() as java.net.HttpURLConnection
            try {
                connection.requestMethod = method
                connection.connectTimeout = 5_000
                connection.readTimeout = 5_000
                connection.setRequestProperty("Authorization", "Bearer $token")
                if (json != null) {
                    connection.setRequestProperty("Content-Type", "application/json")
                    connection.doOutput = true
                    connection.outputStream.use { it.write(json.toString().toByteArray()) }
                }
                assertEquals(path, 200, connection.responseCode)
                return JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
            } finally { connection.disconnect() }
        }
        fun note(source: String = "manual.note", parent: String? = null) = JSONObject()
            .put("schema", 1).put("id", Ids.next()).put("device", "local-device")
            .put("source", source).put("kind", "event").put("t_start", Instant.now().toString())
            .put("sensitivity", "normal").put("capture", JSONObject().put("method", "manual"))
            .put("title", "合成记录").put("body", "用于离线互通验证").put("corrects", parent)

        assertTrue(matchesHub(origin, invite.hubId))
        val keys = DeviceEnvelope.generate()
        val post = { payload: ByteArray -> deviceHttp(origin, payload) }
        val device = DeviceClient(invite.publicKey, keys, post).pair(invite, "测试手机")
        val phone = DeviceClient(invite.publicKey, keys, post, device)
        val original = note()
        val deleted = note()
        val phoneDeleted = note()
        val badSource = note("mac.screen")
        val originals = listOf(original, deleted, phoneDeleted, badSource)
        val records = JSONArray(originals.map { sendingCopy(it.toString(), device) })
        val body = JSONObject().put("records", records)
        val first = phone.send("ingest", body)
        assertEquals(3, first.getInt("accepted"))
        assertEquals(setOf(3), uploadReceipt(first, records.length()).keys)
        val duplicate = phone.send("ingest", body)
        assertEquals(3, duplicate.getInt("duplicates"))
        assertEquals(setOf(3), uploadReceipt(duplicate, records.length()).keys)
        assertEquals("local-device", original.getString("device"))

        val correction = note("manual.correction", original.getString("id")).put("device", "mac")
        assertEquals(1, request("/v1/records", "POST", correction)
            .getInt("accepted"))
        request("/v1/records/${deleted.getString("id")}", "DELETE")
        assertEquals(1, phone.send("delete", JSONObject().put("ids", JSONArray(listOf(phoneDeleted.getString("id")))))
            .getInt("deleted"))

        val changes = mutableListOf<Change>()
        pullChanges({ op, payload ->
            if (op == "sync.ack") assertEquals(3, changes.size)
            phone.send(op, payload)
        }) { page -> changes += page }
        assertEquals(correction.getString("id"), (changes.first() as Change.Correction).record.getString("id"))
        assertEquals(listOf(deleted, phoneDeleted).map { it.getString("id") },
            changes.filterIsInstance<Change.Delete>().map { it.id })
        assertEquals(0, phone.send("sync", JSONObject().put("cursor", 0)).getJSONArray("changes").length())
        request("/v1/audio/settings", "PUT", JSONObject().put("retention_days", 0))
        val purge = request("/v1/audio/purge", "POST").getString("purge_before")
        val audio = AudioSync.parse(phone.send("audio.sync"))
        assertEquals(0, audio.retention)
        assertEquals(purge, audio.purgeBefore)
        assertTrue(phone.send("audio.sync.ack", audio.ack()).getBoolean("acknowledged"))
        assertNull(AudioSync.parse(phone.send("audio.sync")).purgeBefore)

        // Keep the LAN listener active after removal so the authenticated client sees plain 401.
        request("/v1/settings/devices/pairing", "POST")
        request("/v1/settings/devices/$device", "DELETE")
        assertThrows(DeviceRemoved::class.java) { phone.send("sync", JSONObject().put("cursor", 0)) }
    }
}
