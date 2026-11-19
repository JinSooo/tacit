package top.jinso.tacit.sync

import org.bouncycastle.crypto.AsymmetricCipherKeyPair
import org.bouncycastle.crypto.AsymmetricCipherKeyPairGenerator
import org.bouncycastle.crypto.KeyGenerationParameters
import org.bouncycastle.crypto.hpke.HPKE
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.time.Instant

class DeviceProtocolTest {
    private val vectors by lazy { JSONObject(File("../../schema/fixtures/device-envelope.json").readText()) }
    private val expiry = Instant.parse("2030-01-01T00:00:00Z")

    @Test fun opensAndReproducesAllHubVectors() {
        val hub = vectors.getJSONObject("hub")
        val device = vectors.getJSONObject("device")
        for (sample in listOf("pairing", "sync")) {
            val pair = vectors.getJSONObject(sample)
            for (direction in listOf("request", "response")) {
                val vector = pair.getJSONObject(direction)
                val sender = if (direction == "request") device else hub
                val recipient = if (direction == "request") hub else device
                val isAuth = vector.getString("mode") == "auth"
                val wire = vector.getJSONObject("envelope")
                val expectedInfo = if (direction == "request") DeviceEnvelope.REQUEST_INFO else DeviceEnvelope.RESPONSE_INFO
                val requestPlain = JSONObject(pair.getJSONObject("request").getString("plaintext_json_utf8"))
                val aad = when {
                    direction == "response" -> requestPlain.getString("nonce")
                    sample == "sync" -> device.getString("device_id")
                    else -> ""
                }
                if (direction == "request") assertEquals(aad, wire.optionalString("device").orEmpty())
                assertEquals(expectedInfo, vector.getString("info_utf8"))
                assertEquals(aad, vector.getString("aad_utf8"))
                val plaintext = vector.getString("plaintext_json_utf8")
                val senderKey = sender.getString("public_key_base64url")
                assertEquals(plaintext, DeviceEnvelope.open(wire, expectedInfo, aad, keys(recipient),
                    senderKey.takeIf { isAuth }))

                val ikm = hex(vector.getString("ephemeral_ikm_hex"))
                val recipientKey = recipient.getString("public_key_base64url")
                val reproduced = deterministicSeal(plaintext, expectedInfo, aad, recipientKey, keys(sender).takeIf { isAuth }, ikm)
                if (direction == "request") reproduced.put("device", aad.ifEmpty { null } ?: JSONObject.NULL)
                val fields = wire.keys().asSequence().toSet()
                assertEquals(fields, reproduced.keys().asSequence().toSet())
                fields.forEach { field ->
                    assertEquals("$sample $direction $field", wire.get(field), reproduced.get(field))
                }
            }
        }
    }

    @Test fun parsesInviteAndNormalizesOrigins() {
        val invite = Invitation.parse(inviteUri(), expiry.minusSeconds(1))
        assertEquals("测试 Mac", invite.macName)
        assertEquals(listOf("http://192.0.2.1:47824", "https://mac.example.net"), invite.addresses)
        assertEquals("http://[fd00::1]:47824", macOrigin("[fd00::1]:47824"))
        assertThrows(IllegalArgumentException::class.java) { macOrigin("http://user@mac.example.net") }
        assertThrows(IllegalArgumentException::class.java) { macOrigin("https://mac.example.net/other") }
    }

    @Test fun rejectsExpiredAndMismatchedInvite() {
        assertThrows(InviteExpired::class.java) { Invitation.parse(inviteUri(), expiry) }
        assertThrows(IllegalArgumentException::class.java) {
            Invitation.parse(inviteUri("aaaaaaaaaaaaaaaaaaaaaaaaaa"), expiry.minusSeconds(1))
        }
    }

    @Test fun acceptsReceiptAndRetainsRejectionReason() {
        val receipt = JSONObject("""{"accepted":1,"duplicates":1,"rejected":[{"index":1,"errors":["原因 A","原因 B"]}]}""")
        assertEquals(mapOf(1 to "原因 A；原因 B"), uploadReceipt(receipt, 3))
    }

    @Test fun rejectsInvalidReceiptCountsAndPositions() {
        for (receipt in listOf(
            """{"accepted":1,"duplicates":0,"rejected":[]}""",
            """{"accepted":-1,"duplicates":3,"rejected":[]}""",
            """{"accepted":0,"duplicates":0,"rejected":[{"index":1,"errors":["A"]},{"index":1,"errors":["B"]}]}""",
            """{"accepted":1,"duplicates":0,"rejected":[{"index":2,"errors":["A"]}]}""",
            """{"accepted":1,"duplicates":0,"rejected":[{"index":-1,"errors":["A"]}]}""",
        )) {
            assertThrows(IllegalArgumentException::class.java) { uploadReceipt(JSONObject(receipt), 2) }
        }
    }

    @Test fun appliesOrderedPagesBeforeConfirmingIncludingAnEmptyPage() {
        val correction = JSONObject("""{"id":"changed","corrects":"original","body":"修正"}""")
        val pages = listOf(
            JSONObject("""{"changes":[],"cursor":100,"more":true}"""),
            JSONObject().put("changes", JSONArray(listOf(
                JSONObject().put("seq", 101).put("kind", "correction").put("record", correction),
                JSONObject("""{"seq":102,"kind":"delete","id":"original","source":"manual.note","source_ref":null}"""),
            ))).put("cursor", 102).put("more", false),
        )
        val events = mutableListOf<String>()
        val state = linkedMapOf("original" to "补写")
        pullChanges({ op, body ->
            val cursor = body.getInt("cursor")
            events += "$op $cursor"
            if (op == "sync") pages[if (cursor == 0) 0 else 1] else {
                if (cursor == 102) assertTrue(state.isEmpty())
                JSONObject().put("ok", true)
            }
        }) { changes ->
            events += "apply ${changes.size}"
            for (change in changes) when (change) {
                is Change.Correction -> state[change.record.getString("id")] = change.record.getString("body")
                is Change.Delete -> { assertEquals("修正", state.remove("changed")); state.remove(change.id) }
            }
        }
        assertEquals(listOf("sync 0", "apply 0", "sync.ack 100", "sync 100", "apply 2", "sync.ack 102"), events)
    }

    @Test fun doesNotAcknowledgeAnUncommittedPage() {
        assertThrows(IllegalStateException::class.java) {
            pullChanges({ op, _ ->
                assertEquals("sync", op)
                JSONObject("""{"changes":[{"seq":1,"kind":"delete","id":"original"}],"cursor":1,"more":false}""")
            }) { error("模拟存储提交失败") }
        }
    }

    @Test fun plain401DisablesFurtherRequests() {
        var posts = 0
        val hub = DeviceEnvelope.generate()
        val phone = DeviceEnvelope.generate()
        val client = DeviceClient(DeviceEnvelope.public(hub).base64url(), phone,
            { posts++; DeviceHttpReply(401) }, "android-aebagbaf")
        assertThrows(DeviceRemoved::class.java) { client.send("sync") }
        assertThrows(DeviceRemoved::class.java) { client.send("ingest") }
        assertEquals(1, posts)
    }

    @Test fun rewritesOnlySendingCopy() {
        val original = JSONObject("""{"device":"local-install","source":"manual.note","body":"合成内容"}""")
        val wire = original.toString()
        val copy = sendingCopy(wire, "android-aebagbaf")
        assertEquals("android-aebagbaf", copy.getString("device"))
        assertEquals("合成内容", copy.getString("body"))
        assertEquals("local-install", original.getString("device"))
        assertEquals("local-install", JSONObject(wire).getString("device"))
    }

    @Test fun honorsMacAudioRetentionAndBuildsExactAck() {
        val raw = JSONObject().put("retention_days", 0).put("purge_before", expiry.toString())
            .put("delete_conversations", JSONArray(listOf("conversation")))
            .put("voiceprint", JSONObject().put("threshold", 0.49)
                .put("vector", JSONArray(List(512) { if (it == 0) 1 else 0 })))
        val parsed = AudioSync.parse(raw)
        assertEquals(0, parsed.retention)
        assertEquals(0.49, parsed.policy.getJSONObject("voiceprint").voiceprint().threshold, 0.0)
        assertEquals(expiry.toString(), parsed.ack().getString("purged_at"))
        assertEquals(listOf("conversation"), parsed.ack().getJSONArray("deleted").strings())
    }

    private fun inviteUri(hubId: String = vectors.getJSONObject("hub").getString("hub_id")): String {
        val json = JSONObject().put("v", 1).put("hub_id", hubId).put("name", "测试 Mac")
            .put("pk", vectors.getJSONObject("hub").getString("public_key_base64url"))
            .put("code", ByteArray(16).base64url()).put("expires_at", expiry.toString())
            .put("addrs", JSONArray(listOf("192.0.2.1:47824", "https://mac.example.net/")))
        return "tacit://pair?d=${json.toString().toByteArray().base64url()}"
    }

    private fun keys(json: JSONObject) = DeviceEnvelope.restore(hex(json.getString("private_key_hex")),
        json.getString("public_key_base64url").decode64(32))

    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // BC 1.79 exposes a deterministic base sender, but auth mode only accepts the KEM's random
    // key generator. Replace that generator on this test instance to reproduce the auth vector.
    private fun deterministicSeal(plain: String, info: String, aad: String, recipient: String,
                                  sender: AsymmetricCipherKeyPair?, ikm: ByteArray): JSONObject {
        val mode = if (sender == null) HPKE.mode_base else HPKE.mode_auth
        val hpke = HPKE(mode, HPKE.kem_X25519_SHA256, HPKE.kdf_HKDF_SHA256, HPKE.aead_AES_GCM128)
        val key = hpke.deriveKeyPair(ikm)
        val pk = hpke.deserializePublicKey(recipient.decode64(32))
        val (ct, enc) = if (sender == null) {
            val context = hpke.setupBaseS(pk, info.toByteArray(), key)
            arrayOf(context.seal(aad.toByteArray(), plain.toByteArray()), context.encapsulation)
        } else {
            val kem = HPKE::class.java.getDeclaredField("kem").apply { isAccessible = true }.get(hpke)
            kem.javaClass.getDeclaredField("kpGen").apply { isAccessible = true }.set(kem,
                object : AsymmetricCipherKeyPairGenerator {
                    override fun init(parameters: KeyGenerationParameters) {}
                    override fun generateKeyPair() = key
                })
            hpke.seal(pk, info.toByteArray(), aad.toByteArray(), plain.toByteArray(), null, null, sender)
        }
        return JSONObject().put("v", 1).put("enc", enc.base64url()).put("ct", ct.base64url())
    }
}
