package top.jinso.tacit.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.Instant

class RelayRateLimitTest {
    private var elapsed = 0L
    private val wallTime = Instant.parse("2026-11-24T00:00:00Z").toEpochMilli()
    private val rateLimit = RelayRateLimit({ elapsed }, { wallTime })
    private var calls = 0
    private var status = 200
    private var retryAfter: String? = null
    private val first = RelayConfig("https://relay.example", "space-1", "up", "down", "token")
    private fun mailbox(config: RelayConfig = first) = RelayMailbox(config, rateLimit = rateLimit) { _, _, _, _, _, _ ->
        calls++
        DeviceHttpReply(status, """{"messages":[]}""".toByteArray(), retryAfter)
    }

    @Test fun cooldownStopsForegroundPollsAndOtherClientsInTheSameSpace() {
        status = 429
        assertStatus(429) { mailbox().scan {} }
        for (seconds in listOf(0L, 30L, 59L)) {
            elapsed = seconds * 1_000
            assertStatus(429) { mailbox(first.copy(down = "older")).get("original") }
            assertStatus(429) { mailbox().scan {} }
        }
        assertEquals(1, calls)
        status = 200
        mailbox(first.copy(space = "space-2")).scan {}
        assertEquals(2, calls)

        elapsed = 60_000
        status = 429
        assertStatus(429) { mailbox().scan {} }
        elapsed += 119_999
        assertStatus(429) { mailbox().scan {} }
        assertEquals(3, calls)

        elapsed++
        status = 200
        mailbox().scan {}
        status = 429
        assertStatus(429) { mailbox().scan {} }
        elapsed += 60_000
        status = 200
        mailbox().scan {}
        assertEquals(6, calls)
    }

    @Test fun retryAfterIsCappedAndFullMailboxCanStillBeDrained() {
        retryAfter = "86400"
        status = 429
        assertStatus(429) { mailbox().scan {} }
        elapsed = 6 * 3_600_000L - 1
        assertStatus(429) { mailbox().scan {} }
        assertEquals(1, calls)

        elapsed++
        status = 507
        assertStatus(507) { mailbox().scan {} }
        status = 200
        mailbox().delete("read-message")
        assertEquals(3, calls)
    }

    @Test fun exponentialDelayCapsAtOneHourAndUnderstandsHttpDate() {
        status = 429
        for (seconds in listOf(60L, 120L, 240L, 480L, 960L, 1920L, 3600L, 3600L)) {
            assertStatus(429) { mailbox().scan {} }
            elapsed += seconds * 1_000 - 1
            assertStatus(429) { mailbox().scan {} }
            elapsed++
        }
        assertEquals(8, calls)

        retryAfter = "Tue, 24 Nov 2026 02:00:00 GMT"
        assertStatus(429) { mailbox().scan {} }
        elapsed += 7_199_999
        assertStatus(429) { mailbox().scan {} }
        assertEquals(9, calls)
        elapsed++
        status = 200
        mailbox().scan {}
        assertEquals(10, calls)
    }

    @Test fun publicHelloCannotResetTheSpaceBackoffBeforeAnotherRejectedWrite() {
        var writes = 0
        fun writer() = RelayMailbox(first, rateLimit = rateLimit) { method, _, _, _, _, _ ->
            if (method == "PUT") {
                writes++
                DeviceHttpReply(429)
            } else DeviceHttpReply(200, """{"tacit_relay":1,"limits":{"message_bytes":1024}}""".toByteArray())
        }
        val mail = DeviceEnvelope.Request(byteArrayOf(1), "pending")
        assertStatus(429) { writer().put(mail) }

        elapsed = 60_000
        assertStatus(429) { writer().put(mail) }
        elapsed = 179_999
        assertStatus(429) { writer().put(mail) }
        assertEquals(2, writes)

        elapsed++
        assertStatus(429) { writer().put(mail) }
        assertEquals(3, writes)
    }

    private fun assertStatus(expected: Int, request: () -> Unit) {
        assertEquals(expected, assertThrows(RelayStatus::class.java, request).status)
    }
}
