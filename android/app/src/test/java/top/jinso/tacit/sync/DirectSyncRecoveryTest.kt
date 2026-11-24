package top.jinso.tacit.sync

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DirectSyncRecoveryTest {
    @Test fun authenticatedLanContactAllowsImmediateRetryWithoutClaimingAnUploadSucceeded() {
        val data = JSONObject("""{"lastSync":1000,"retryAt":9000,"failures":4,"error":"连不上 Mac","relayTimeline":{"cursor":50}}""")
        var saved = JSONObject()
        directSyncRecovered(data, "http://192.0.2.10:3080") { saved = JSONObject(it.toString()) }

        // The next worker can proceed immediately, even if the resume was interrupted before uploading.
        assertTrue(saved.optLong("retryAt") < 2_000)
        assertFalse(saved.has("error"))
        assertEquals(1, saved.optInt("failures") + 1)
        assertEquals("http://192.0.2.10:3080", saved.getString("last"))
        assertEquals(1000L, saved.getLong("lastSync"))
        assertEquals(50, saved.getJSONObject("relayTimeline").getInt("cursor"))
    }
}
