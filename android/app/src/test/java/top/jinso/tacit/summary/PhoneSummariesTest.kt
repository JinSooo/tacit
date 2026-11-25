package top.jinso.tacit.summary

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import top.jinso.tacit.core.HistoryRecord
import java.io.IOException
import java.net.SocketTimeoutException

class PhoneSummariesTest {
    private val minute = 60_000L
    private fun record(id: String, start: Long, end: Long?, sensitivity: String = "normal") =
        HistoryRecord(id, "android.audio", "对话记录", "", start * minute, end?.let { it * minute }, null, sensitivity, null, 0)

    @Test fun groupsLikeTheHub() {
        // Joined while the next starts within 10 minutes of the latest end; one private record makes the whole one private.
        val groups = groupConversations(listOf(record("C", 25, 26, "private"), record("A", 0, 5), record("B", 15, 20), record("D", 40, null)))
        assertEquals(listOf(listOf("A", "B", "C"), listOf("D")), groups.map { it.recordIds })
        assertEquals(listOf(true, false), groups.map { it.private })
        assertEquals(26 * minute, groups[0].end)
        assertEquals(40 * minute, groups[1].end)
    }

    @Test fun longTranscriptsKeepHeadAndTail() {
        val turns = (0 until 400).map { SummaryTurn(0, "我", "第${it}句话说得很长很长") }
        val text = summaryTranscript(turns, budget = 300)
        assertTrue(text.contains("（中间省略）"))
        assertTrue(text.contains("第0句") && text.contains("第399句"))
    }

    @Test fun repliesAreCheckedWithTheMacsLimits() {
        val (ok, _) = parseSummary("<think>先想一想</think>```json\n{\"title\":\"新办公室装修预算\",\"summary\":\"约好周五看预算表。\",\"points\":[\"带上预算表\",\"\"]}\n```")
        assertEquals(WrittenSummary("新办公室装修预算", "约好周五看预算表。", listOf("带上预算表")), ok)
        assertNull(parseSummary("{\"title\":\"${"长".repeat(41)}\",\"summary\":\"x\",\"points\":[]}").first)
        assertNull(parseSummary("{\"title\":\"t\",\"summary\":\"x\",\"points\":[\"1\",\"2\",\"3\",\"4\",\"5\",\"6\"]}").first)
        assertNull(parseSummary("不是 JSON").first)
    }

    @Test fun retriesOnceWithTheReason() {
        val sent = mutableListOf<String>()
        val replies = ArrayDeque(listOf("随便说点什么", "{\"title\":\"预算讨论\",\"summary\":\"定了预算。\",\"points\":[]}"))
        val client = SummaryClient(SummaryModel("https://api.example.com/v1/chat/completions", "m", "k")) { url, headers, body ->
            assertEquals("https://api.example.com/v1/chat/completions", url)
            assertEquals("Bearer k", headers["Authorization"])
            sent += body
            200 to """{"choices":[{"finish_reason":"stop","message":{"content":${org.json.JSONObject.quote(replies.removeFirst())}}}]}"""
        }
        assertEquals("预算讨论", client.summarize(0, minute, "10:00 我：定预算").title)
        assertTrue(sent[1].contains("上一次的输出不符合要求"))
    }

    @Test fun plainHttpOnlyForThisPhoneOrTheHomeNetwork() {
        assertEquals("http://127.0.0.1:8080/v1/chat/completions", SummaryClient.endpointOf("http://127.0.0.1:8080/v1/"))
        assertEquals("http://192.168.1.20:11434/v1/chat/completions", SummaryClient.endpointOf("http://192.168.1.20:11434/v1"))
        assertThrows(SummaryFailure::class.java) { SummaryClient.endpointOf("http://api.example.com/v1") }
        assertThrows(SummaryFailure::class.java) { SummaryClient.endpointOf("ftp://example.com") }
    }

    @Test fun serviceFailuresUseTheMacWordingWithoutStatusCodes() {
        val expectations = mapOf(
            401 to "API key 没设置或无效。",
            403 to "API key 没设置或无效。",
            402 to "模型服务的额度用完了，充值或额度恢复后会自动继续。",
            404 to "模型服务拒绝了请求，请检查模型名和地址。",
            408 to "模型服务一直没有回应，请检查网络或稍后再试。",
            422 to "模型服务拒绝了请求，请检查模型名和地址。",
            429 to "请求太频繁，模型服务暂时限流，稍后会自动重试。",
            503 to "模型服务暂时出错，稍后会自动重试。",
            200 to "模型返回的内容不合格式，可以换个模型试试。",
        )
        for ((status, expected) in expectations) {
            val client = SummaryClient(SummaryModel("https://api.example.com/v1", "m", "k")) { _, _, _ -> status to "{}" }
            assertEquals(expected, assertThrows(SummaryFailure::class.java) { client.test() }.reason)
        }
        val quota = SummaryClient(SummaryModel("https://api.example.com/v1", "m", "k")) { _, _, _ ->
            429 to """{"error":{"code":"insufficient_quota"}}"""
        }
        assertEquals(SummaryError.QUOTA, assertThrows(SummaryFailure::class.java) { quota.test() }.error)
    }

    @Test fun networkAndTimeoutAreDistinct() {
        for ((exception, expected) in listOf(
            IOException() to "连不上模型服务，请检查网络和地址。",
            SocketTimeoutException() to "模型服务一直没有回应，请检查网络或稍后再试。",
        )) {
            val client = SummaryClient(SummaryModel("https://api.example.com/v1", "m", "")) { _, _, _ -> throw exception }
            assertEquals(expected, assertThrows(SummaryFailure::class.java) { client.test() }.reason)
        }
    }

    @Test fun retryableFailuresSurfaceOnlyAfterAnHourEvenWhenTheCauseChanges() {
        val start = 100 * minute
        val state = JSONObject().put("error", "服务拒绝了请求（400）")
        assertNull(state.summaryProblem())
        state.recordSummaryFailure(SummaryFailure(SummaryError.NETWORK), start)
        assertNull(state.summaryProblem()?.messageAt(start))
        state.recordSummaryFailure(SummaryFailure(SummaryError.SERVER), start + 45 * minute)
        val problem = requireNotNull(state.summaryProblem())
        assertNull(problem.messageAt(start + 60 * minute - 1))
        assertEquals(SummaryError.SERVER.reason, problem.messageAt(start + 60 * minute))
    }

    @Test fun actionableFailuresSurfaceImmediatelyAndRecoveryResetsTheFailureClock() {
        val start = 100 * minute
        val state = JSONObject()
        for (error in listOf(SummaryError.AUTH, SummaryError.QUOTA, SummaryError.CONFIG, SummaryError.REJECTED)) {
            state.recordSummaryFailure(SummaryFailure(error), start)
            assertEquals(error.reason, state.summaryProblem()?.messageAt(start))
        }
        state.recordSummaryFailure(SummaryFailure(SummaryError.RATE_LIMIT, 30 * minute), start + minute)
        assertEquals(start + 31 * minute, state.optLong("pausedUntil"))
        assertTrue(state.clearSummaryFailure())
        assertNull(state.summaryProblem())
        assertEquals(0L, state.optLong("pausedUntil"))
        state.recordSummaryFailure(SummaryFailure(SummaryError.FORMAT), start + 70 * minute)
        assertNull(state.summaryProblem()?.messageAt(start + 129 * minute))
        assertEquals(SummaryError.FORMAT.reason, state.summaryProblem()?.messageAt(start + 130 * minute))
    }
}
