package top.jinso.tacit.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncFeedbackTest {
    @Test fun rejectedRecordsAreGroupedWithoutExposingValidationText() {
        val reasons = mapOf(
            "/body must NOT have more than 200000 characters" to 2,
            "/title must NOT have more than 500 characters" to 1,
            "/t_start 无法转换为可排序的时间" to 1,
            "/t_end must match format date-time" to 2,
            "/source 不支持此设备来源" to 1,
            "/device 必须与配对设备一致" to 1,
            "/source_ref 重读外部存储的来源必须提供稳定键" to 1,
            "/body must be string" to 1,
            "/ must have required property 'source'；/device 必须与配对设备一致；/source 不支持此设备来源" to 1,
        )

        val categories = rejectedRecordCategories(reasons)
        assertEquals(mapOf(
            "单条内容过长" to 3,
            "时间格式异常" to 3,
            "设备身份不匹配" to 2,
            "其他格式问题" to 2,
            "来源不支持" to 1,
        ), categories)
        assertEquals(reasons.values.sum(), categories.values.sum())
    }

    @Test fun relayLimitsAndOfflineSyncExplainWhatWillHappen() {
        val cases = mapOf(
            RelayStatus(429) to "中转信箱今日请求已达上限，稍后会自动重试",
            RelayStatus(507) to "中转信箱空间已满，等 Mac 取走后会自动继续",
            RelayWaiting() to "正在等待 Mac 响应，稍后会自动同步",
            MacUnavailable(false) to "暂时连不上 Mac，记录已排队等待同步",
        )
        for ((error, text) in cases) {
            assertEquals(text, syncError(error))
            assertTrue(isSyncWaiting(text))
        }
        val connectError = syncError(MacUnavailable(true), pairing = true)
        assertFalse(isSyncWaiting(connectError, pairing = true))
        assertEquals("这批同步内容太大，暂时无法同步", syncError(EnvelopeTooLarge()))
    }
}
