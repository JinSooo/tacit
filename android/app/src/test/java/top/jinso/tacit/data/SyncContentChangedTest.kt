package top.jinso.tacit.data

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncContentChangedTest {
    private fun connection(audio: String? = """{"retention_days":7}""") = JSONObject()
        .put("device", "phone-a").put("lastSync", 1L).put("relayJournal", JSONObject().put("cursor", "c1"))
        .apply { if (audio != null) put("audio", JSONObject(audio)) }

    // 实测：一场 88 段的录音开着 7 分钟，同步记账让它重载了 70 次，排版线程八成时间在做白工。
    @Test fun bookkeepingDoesNotReloadRecordPages() {
        val before = connection()
        val after = connection().put("lastSync", 2L).put("relayJournal", JSONObject().put("cursor", "c2"))
            .put("relayRoundAt", 3L).put("error", "offline")
        assertFalse(syncContentChanged(before, after))
    }

    @Test fun whatRecordPagesShowStillReloads() {
        val before = connection()
        assertTrue(syncContentChanged(null, before))
        assertTrue(syncContentChanged(before, null))
        assertTrue(syncContentChanged(before, connection().put("device", "phone-b")))
        assertTrue(syncContentChanged(before, connection().put("removed", true)))
        assertTrue(syncContentChanged(before, connection("""{"retention_days":30}""")))
        assertTrue(syncContentChanged(before, connection("""{"retention_days":7,"voiceprint":{"vector":[1]}}""")))
        assertTrue(syncContentChanged(before, connection(null)))
    }
}
