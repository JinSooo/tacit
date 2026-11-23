package top.jinso.tacit.sync

import kotlinx.coroutines.runBlocking
import org.bouncycastle.crypto.hpke.HPKE
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.time.Instant
import java.time.LocalDate

class RelaySyncTest {
    private val hub = DeviceEnvelope.generate()
    private val phone = DeviceEnvelope.generate()
    private val hubKey = DeviceEnvelope.public(hub).base64url()
    private val protocol = DeviceMessages(hubKey, phone, "android-aebagbaf")
    private val config = RelayConfig("https://relay.example.test", id(1), id(2), id(3), "fixture_token_0123456789")
    private val fake = FakeMailbox()
    private val state = JSONObject().put("relay", config.json())
    private var now = 1_000_000L
    private var saved = state.toString()
    private fun journal(data: JSONObject = JSONObject(saved)) = RelayJournal(data, { saved = data.toString() }, { now })

    @Test fun depositsReadsAndDeletesAuthenticatedReply() = runBlocking {
        val journal = journal()
        val request = protocol.request("ingest", JSONObject())
        val applied = mutableListOf<String>()
        fake.onPut = { nonce, wire ->
            val plaintext = DeviceEnvelope.open(JSONObject(wire.toString(Charsets.UTF_8)),
                DeviceEnvelope.REQUEST_INFO, "android-aebagbaf", hub, DeviceEnvelope.public(phone).base64url())
            assertEquals(nonce, JSONObject(plaintext).getString("nonce"))
            fake.down[nonce] = seal(nonce, receipt())
        }
        val exchange = RelayExchange(protocol, journal, fake.client(), { delivery, body ->
            assertTrue(uploadReceipt(body, delivery.ids.size).isEmpty())
            applied += delivery.ids
        })
        exchange.sendWrite("ingest", request, listOf("record-1"))
        assertEquals(listOf("record-1"), applied)
        assertEquals(listOf(request.nonce), fake.deleted)
        assertTrue(journal.deliveries().isEmpty())
    }

    @Test fun originalPagesStayOutOfPersistentJournalEvenIfTheNextPageIsOffline() = runBlocking {
        val journal = journal()
        val exchange = RelayExchange(protocol, journal, fake.client(), { _, _ -> fail() })
        val before = saved
        var pages = 0
        fake.onPut = { nonce, wire ->
            val request = JSONObject(DeviceEnvelope.open(JSONObject(wire.toString(Charsets.UTF_8)),
                DeviceEnvelope.REQUEST_INFO, "android-aebagbaf", hub, DeviceEnvelope.public(phone).base64url()))
            assertEquals("records.get", request.getString("op"))
            assertFalse(request.getJSONObject("body").has("include_private"))
            if (++pages == 2) throw IOException("合成离线")
            val record = JSONObject().put("id", "raw").put("source", "mac.wechat").put("body", "仅限内存的合成原文")
            val body = JSONObject().put("records", JSONArray(listOf(record))).put("next_cursor", "page-two")
            fake.down[nonce] = seal(nonce, JSONObject().put("status", 200).put("body", body))
        }
        try {
            val active = mutableSetOf<String>()
            readTimelineOriginals(setOf("raw")) { op, body -> exchange.sendTransient(op, body, active) }
            fail("Expected offline read to fail")
        } catch (_: IOException) { }
        assertEquals(2, pages)
        assertEquals(before, saved)
        assertTrue(journal.deliveries().isEmpty())
        assertTrue(fake.down.isEmpty())
    }

    @Test fun ordinarySyncLeavesAuthenticatedProjectionPushForTimelinePoll() {
        val nonce = id(5)
        fake.down[nonce] = seal(nonce, JSONObject().put("kind", "projection.reset").put("epoch", 3))
        val exchange = RelayExchange(protocol, journal(), fake.client(), { _, _ -> fail() })
        exchange.drain()
        assertTrue(fake.down.containsKey(nonce))
        exchange.drain { assertEquals(3, it.getInt("epoch")); true }
        assertEquals(listOf(nonce), fake.deleted)
    }

    // 回归（2026-11-24 审查第 3 条）
    @Test fun emptyPollDoesNotWaitOrSendAgainAndPullsOnlyWhenDueForView() {
        val cache = testCache()
        val timeline = TimelineSync(cache)
        val sent = mutableListOf<String>()
        fake.onPut = { _, wire ->
            val request = JSONObject(DeviceEnvelope.open(JSONObject(wire.toString(Charsets.UTF_8)),
                DeviceEnvelope.REQUEST_INFO, "android-aebagbaf", hub, DeviceEnvelope.public(phone).base64url()))
            sent += request.getString("op")
        }
        fun round() {
            val data = JSONObject(saved)
            val journal = journal(data)
            val state = RelayTimeline(data, config.down, cache, timeline, { saved = data.toString() }, { now })
            val mailbox = fake.client()
            val exchange = RelayExchange(protocol, journal, mailbox, { _, _ -> fail() })
            exchange.drain(timelineRequestIds = state.replyIds,
                onTimelineReply = { nonce, message -> state.reply(nonce, message, protocol) }, projection = state::push)
            state.postDue(protocol, mailbox::put)
        }
        fun reply(body: JSONObject) {
            val nonce = fake.puts.last()
            fake.down[nonce] = seal(nonce, JSONObject().put("status", 200).put("body", body))
        }
        round()
        now += 30_000
        val before = fake.calls.size
        round()
        assertEquals(listOf("list"), fake.calls.drop(before))
        assertEquals(listOf("relay"), sent)
        reply(JSONObject().put("role", "collect"))
        round()
        now += TIMELINE_RECHECK - 1
        round()
        assertEquals(listOf("relay"), sent)
        now++
        round()
        reply(JSONObject().put("role", "view"))
        round()
        repeat(3) { now += 30_000; round() }
        assertEquals(listOf("relay", "relay", "projection.pull"), sent)
        reply(JSONObject("""{"epoch":1,"cursor":0,"more":false,"reset":false,"changes":[]}"""))
        round()
        val idle = fake.calls.size
        now += TIMELINE_RECHECK - 1
        round()
        assertEquals(listOf("list"), fake.calls.drop(idle))
        val hint = id(5)
        fake.down[hint] = seal(hint, JSONObject().put("kind", "projection.hint").put("epoch", 1))
        round()
        assertEquals(listOf("relay", "relay", "projection.pull", "projection.pull"), sent)
    }

    // 回归（2026-11-24 审查第 3 条）
    @Test fun directDiscoveryFailureIsSharedUntilTheNetworkChangesOrBackoffExpires() = runBlocking {
        val backoff = DirectDiscoveryBackoff { now }
        var probes = 0
        suspend fun failed(route: String) {
            try {
                backoff.find(route, canRelay = true) { probes++; throw MacUnavailable(false) }
                fail("Expected relay fallback")
            } catch (_: MacUnavailable) { }
        }
        failed("wifi-a")
        failed("wifi-a")
        assertEquals(1, probes)
        failed("wifi-b")
        assertEquals(2, probes)
        now += TIMELINE_RECHECK
        failed("wifi-b")
        assertEquals(3, probes)
    }

    // 回归（2026-11-24 审查第 6 条）
    @Test fun retiredMailboxAppliesInvalidationAndResetBeforeDeletingEitherNotice() {
        val date = LocalDate.parse("2026-11-24")
        val cache = testCache(date)
        val timeline = TimelineSync(cache)
        val change = JSONObject().put("kind", "day").put("id", date.toString())
            .put("op", "upsert").put("data", JSONObject().put("brief", "虚构日程"))
        for ((kind, expected) in listOf("projection.invalidate" to ProjectionCursor(1, 1),
            "projection.reset" to ProjectionCursor(2, 0))) {
            val seq = expected.epoch
            cache.apply(1, seq, JSONArray(listOf(change.put("seq", seq))))
            assertTrue(date in cache.snapshots.value.days)
            val journal = journal(JSONObject().put("relay", config.json()))
            val write = protocol.request("delete", JSONObject())
            journal.track(config.down, write, "delete", listOf("fixture-record"), null)
            journal.config(null)
            fake.down[write.nonce] = seal(write.nonce, JSONObject().put("status", 200).put("body", JSONObject()))
            val nonce = id(expected.epoch.toInt() + 4)
            fake.down[nonce] = seal(nonce, JSONObject().put("kind", kind).put("epoch", expected.epoch)
                .put("to_seq", 2).put("items", JSONArray(listOf(JSONObject().put("kind", "day").put("id", date.toString())))))
            val exchange = RelayExchange(protocol, journal, fake.client(), { _, _ ->
                assertFalse(date in cache.snapshots.value.days)
            })
            exchange.drain(allowMove = false) {
                assertTrue(nonce in fake.down)
                assertEquals(listOf(config), journal.retired())
                timeline.push(it, view = false)
            }
            assertEquals(expected, cache.cursor)
            assertFalse(date in cache.snapshots.value.days)
            assertEquals(listOf(nonce, write.nonce), fake.deleted.takeLast(2))
            assertTrue(journal.retired().isEmpty())
        }
    }

    private fun testCache(today: LocalDate = LocalDate.parse("2026-11-24")) = TimelineCache(object : TimelineDisk {
        override fun read(owner: String): JSONObject? = null
        override fun write(owner: String, state: JSONObject) = Unit
        override fun clear() = Unit
    }) { today }.apply { bind("test-hub:test-phone") }

    @Test fun pendingBatchesSurviveRestartWithoutRepackingAndExpireWithNewNonce() = runBlocking {
        val batch = listOf("record-1" to JSONObject().put("body", "虚构录音"))
        suspend fun depositUnconfirmed(journal: RelayJournal) {
            val eligible = batch.filterNot { it.first in journal.inFlight("ingest") }
            if (eligible.isEmpty()) return
            val upload = requireNotNull(relayUpload(protocol, eligible, DEFAULT_MESSAGE_BYTES))
            try {
                RelayExchange(protocol, journal, fake.client(), { _, _ -> fail() }, waitMillis = 0)
                    .sendWrite("ingest", upload.request, eligible.map { it.first })
                fail("Expected outstanding delivery")
            } catch (_: RelayWaiting) { }
        }
        depositUnconfirmed(journal())
        assertEquals(1, fake.puts.size)
        now += 86_399_999
        val resumed = journal()
        resumed.prune()
        depositUnconfirmed(resumed)
        assertEquals(setOf("record-1"), resumed.inFlight("ingest"))
        assertEquals(1, fake.puts.size)

        now++
        val expired = journal()
        expired.prune()
        depositUnconfirmed(expired)
        assertEquals(2, fake.puts.size)
        assertNotEquals(fake.puts[0], fake.puts[1])
    }

    @Test fun delayedReceiptsFinishDeleteAndReleaseFailedIngestForRetry() = runBlocking {
        val journal = journal()
        val ingest = protocol.request("ingest", JSONObject())
        val delete = protocol.request("delete", JSONObject())
        val applied = mutableListOf<String>()
        val exchange = RelayExchange(protocol, journal, fake.client(), { delivery, body ->
            assertEquals("delete", delivery.op)
            assertEquals(1, body.getInt("deleted"))
            applied += delivery.ids
        }, waitMillis = 0)
        for ((op, request, record) in listOf(Triple("ingest", ingest, "put-id"), Triple("delete", delete, "delete-id"))) {
            try { exchange.sendWrite(op, request, listOf(record)); fail() } catch (_: RelayWaiting) { }
        }
        fake.down[ingest.nonce] = seal(ingest.nonce, JSONObject().put("status", 503).put("body", JSONObject()))
        fake.down[delete.nonce] = seal(delete.nonce, JSONObject().put("status", 200).put("body", JSONObject().put("deleted", 1)))
        exchange.drain()
        assertEquals(listOf("delete-id"), applied)
        assertTrue(journal.deliveries().isEmpty())
        assertEquals(setOf(ingest.nonce, delete.nonce), fake.deleted.toSet())
        val redo = protocol.request("ingest", JSONObject())
        try { exchange.sendWrite("ingest", redo, listOf("put-id")); fail() } catch (_: RelayWaiting) { }
        assertNotEquals(ingest.nonce, redo.nonce)
    }

    @Test fun retainsAnUnansweredPullAndReusesItsReplyAcrossRounds() = runBlocking {
        val journal = journal()
        val first = RelayExchange(protocol, journal, fake.client(), { _, _ -> fail() }, waitMillis = 0)
        repeat(2) {
            try { first.send("sync", JSONObject().put("cursor", 0)); fail() } catch (_: RelayWaiting) { }
        }
        val nonce = fake.puts.single()
        fake.down[nonce] = seal(nonce, JSONObject().put("status", 200).put("body", JSONObject().put("cursor", 0)))
        val resumed = RelayExchange(protocol, journal(), fake.client(), { _, _ -> fail() }, waitMillis = 0)
        resumed.drain()
        assertEquals(0, resumed.send("sync", JSONObject().put("cursor", 0)).getInt("cursor"))
        assertEquals(listOf(nonce), fake.puts)
    }

    @Test fun authenticatedMoveReplacesConfigAndUnknownMailIsDeleted() {
        val moved = config.copy(url = "https://second.example.test", down = id(4))
        fake.down[id(5)] = seal(id(5), JSONObject().put("kind", "relay.moved").put("relay", moved.json()))
        fake.down[id(6)] = seal(id(6), JSONObject().put("status", 200).put("body", JSONObject()))
        val journal = journal()
        RelayExchange(protocol, journal, fake.client(), { _, _ -> fail() }).drain()
        assertEquals(moved, journal().active)
        assertEquals(setOf(id(5), id(6)), fake.deleted.toSet())
    }

    @Test fun bothAuthFailuresDisableMailboxUntilDirectRefresh() {
        for (status in listOf(401, 403)) {
            val journal = journal(state)
            fake.denied = status
            val error = assertThrows(RelayStatus::class.java) {
                journal.useMailbox(config) { RelayExchange(protocol, journal, fake.client(), { _, _ -> fail() }).drain() }
            }
            assertEquals(status, error.status)
            assertTrue(journal().disabled)
            assertEquals(config, journal().active)
            journal.config(config)
            assertFalse(journal().disabled)
        }
    }

    @Test fun splitsTheSealedEnvelopeUsingTheActualMailboxLimit() {
        val records = (1..4).map { "record-$it" to JSONObject().put("body", "字".repeat(100_000)) }
        val client = fake.client()
        val upload = requireNotNull(relayUpload(protocol, records, client.messageBytes))
        assertEquals(2, upload.count)
        assertTrue(upload.request.json.size <= DEFAULT_MESSAGE_BYTES)
        assertNull(relayUpload(protocol, records.take(1), 300_000))
        assertTrue(requireNotNull(relayUpload(protocol, records.drop(upload.count), client.messageBytes))
            .request.json.size <= DEFAULT_MESSAGE_BYTES)
    }

    @Test fun rejectsCleartextAndCredentialBearingUrls() {
        for (url in listOf("http://relay.example.test", "https://person@relay.example.test", "https://relay.example.test?token=1")) {
            assertThrows(IllegalArgumentException::class.java) { RelayConfig.parse(config.json().put("url", url)) }
        }
        for (url in listOf("http://127.0.0.1:8080", "http://localhost:8080", "https://relay.example.test/prefix")) {
            assertEquals(url, RelayConfig.parse(config.json().put("url", "$url/")).url)
        }
    }

    @Test fun pairingUsesTemporaryCredentialsAndSavesThePermanentConfigBeforeDelete() = runBlocking {
        val permanent = config.copy(down = id(7))
        val invite = Invitation("fixture-hub", "测试 Mac", hubKey, id(8), emptyList(), Instant.now().plusSeconds(30), config)
        fake.onPut = { nonce, wire ->
            val request = JSONObject(DeviceEnvelope.open(JSONObject(wire.toString(Charsets.UTF_8)),
                DeviceEnvelope.REQUEST_INFO, "", hub, null))
            assertEquals("pair", request.getString("op"))
            assertEquals(nonce, request.getString("nonce"))
            val body = JSONObject().put("device_id", "android-aebagbaf").put("hub_id", invite.hubId).put("relay", permanent.json())
            fake.down[nonce] = seal(nonce, JSONObject().put("status", 200).put("body", body))
        }
        pairThroughRelay(invite, phone, "测试手机", fake.client()) { result ->
            assertTrue(fake.deleted.isEmpty())
            assertEquals(permanent, result.relay)
        }
        assertEquals(fake.puts, fake.deleted)
    }

    @Test fun ambiguousPutResumesWithSameNonceAfterRestart() = runBlocking {
        val request = protocol.request("ingest", JSONObject())
        fake.onPut = { _, _ -> throw IOException("合成断线") }
        try {
            RelayExchange(protocol, journal(), fake.client(), { _, _ -> fail() })
                .sendWrite("ingest", request, listOf("record-1"))
            fail()
        } catch (_: IOException) { }
        fake.onPut = { nonce, _ -> fake.down[nonce] = seal(nonce, receipt()) }
        val resumed = journal()
        val exchange = RelayExchange(protocol, resumed, fake.client(), { delivery, _ ->
            assertEquals(listOf("record-1"), delivery.ids)
        })
        exchange.drain()
        exchange.resumeWrites()
        assertEquals(listOf(request.nonce, request.nonce), fake.puts)
        assertTrue(resumed.deliveries().isEmpty())
    }

    private fun id(value: Int) = ByteArray(16) { value.toByte() }.base64url()

    private fun receipt() = JSONObject("""{"status":200,"body":{"accepted":1,"duplicates":0,"rejected":[]}}""")

    private fun seal(nonce: String, message: JSONObject): ByteArray {
        val hpke = HPKE(HPKE.mode_auth, HPKE.kem_X25519_SHA256, HPKE.kdf_HKDF_SHA256, HPKE.aead_AES_GCM128)
        val publicKey = hpke.deserializePublicKey(DeviceEnvelope.public(phone))
        val (ct, enc) = hpke.seal(publicKey, DeviceEnvelope.RESPONSE_INFO.toByteArray(), nonce.toByteArray(),
            message.toString().toByteArray(), null, null, hub)
        return JSONObject().put("v", 1).put("enc", enc.base64url()).put("ct", ct.base64url()).toString().toByteArray()
    }

    private inner class FakeMailbox {
        val down = linkedMapOf<String, ByteArray>()
        val puts = mutableListOf<String>()
        val deleted = mutableListOf<String>()
        val calls = mutableListOf<String>()
        var denied: Int? = null
        var onPut: (String, ByteArray) -> Unit = { _, _ -> }

        fun client() = RelayMailbox(config) { method, url, token, payload, _, _ ->
            assertTrue(url.startsWith(config.url))
            val path = url.removePrefix(config.url)
            calls += if (method == "GET" && "?" in path) "list" else method
            if (path == "/v1/hello") {
                assertNull(token)
                DeviceHttpReply(200, """{"tacit_relay":1,"limits":{"message_bytes":1048576}}""".toByteArray())
            } else {
                assertEquals(config.token, token)
                val prefix = "/v1/spaces/${config.space}/boxes"
                val nonce = path.substringAfterLast('/')
                when {
                    denied != null -> DeviceHttpReply(requireNotNull(denied))
                    method == "PUT" -> {
                        assertEquals("$prefix/${config.up}/messages/$nonce", path)
                        puts += nonce
                        onPut(nonce, requireNotNull(payload))
                        DeviceHttpReply(201)
                    }
                    method == "GET" && "?" in path -> {
                        assertEquals("$prefix/${config.down}/messages?after=0&limit=100", path)
                        val list = JSONArray(down.keys.map { JSONObject().put("id", it) })
                        DeviceHttpReply(200, JSONObject().put("messages", list).toString().toByteArray())
                    }
                    method == "GET" -> {
                        assertEquals("$prefix/${config.down}/messages/$nonce", path)
                        down[nonce]?.let { DeviceHttpReply(200, it) } ?: DeviceHttpReply(404)
                    }
                    else -> {
                        assertEquals("DELETE", method)
                        assertEquals("$prefix/${config.down}/messages/$nonce", path)
                        down.remove(nonce)
                        deleted += nonce
                        DeviceHttpReply(200)
                    }
                }
            }
        }
    }
}
