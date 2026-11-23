package top.jinso.tacit.core
import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.ui.firstSentence
import top.jinso.tacit.ui.telltaleSentence
import top.jinso.tacit.core.HistoryRecord
class ReadableTranscriptTest {
    @Test fun removesStandaloneFillersAndJoinsConsecutiveTurns() {
        assertEquals("我：今天开始，明天继续。\n\n对方 1：知道了。",readableTranscript("我：嗯。\n我：今天开始\n我：明天继续。\n对方 1：知道了。"))
    }
    @Test fun preservesShortDecisionsAndOtherLanguages() {
        val output=readableTranscript("我：不行\n对方 1：Yes\n对方 2：こんにちは。")
        assertTrue(output.contains("不行"));assertTrue(output.contains("Yes"));assertTrue(output.contains("こんにちは"))
    }

    @Test fun timestampedAndLegacyTurnsReadTheSameWay() {
        val legacy = "我：嗯。\n小周：先看清单\n小周：周五定稿。\n对方 3：我来核对。"
        val timestamped = legacy.lines().mapIndexed { index, line -> "[10:04:0$index] $line" }.joinToString("\n")
        val expected = "小周：先看清单，周五定稿。\n\n对方 3：我来核对。"
        assertEquals(expected, readableTranscript(legacy))
        assertEquals(expected, readableTranscript(timestamped))
        assertEquals("先看清单，周五定稿。", firstSentence(legacy))
        assertEquals("先看清单，周五定稿。", firstSentence(timestamped))
        assertEquals("周五定稿。", firstSentence("对方 1: 周五定稿。"))
        // Reported case: a conversation previewed as a lone "。" from recognized noise.
        assertEquals("周五定稿。", firstSentence("[20:20:01] 对方 1：。\n[20:20:05] 我：周五定稿。"))
        assertEquals("", firstSentence("对方 1：。"))
        // Reported case (2026-11-23): the detail page showed a speaker whose whole line was "。".
        assertEquals("我：周五定稿。", readableTranscript("[20:20:01] 对方 5：。\n[20:20:05] 我：周五定稿。"))
    }

    @Test fun conversationWithoutSummaryShowsTheLineThatSaysTheMost() {
        fun record(minute: Int, body: String) = HistoryRecord("r$minute", "android.audio", "对话记录", body, minute * 60_000L, null, null, "normal", null, 0)
        // Reported case (2026-11-23): the row showed someone else's misrecognized "싫.".
        val game = listOf(record(0, "[20:44:05] 对方 1：싫."), record(3, "[20:46:51] 我：嗯。"),
            record(4, "[20:47:23] 对方 3：刀哇，这能刀吗？"), record(6, "[20:49:45] 对方 6：这跳你好肉啊，我的妈。"))
        assertEquals("这跳你好肉啊，我的妈。", telltaleSentence(game))
        val talk = listOf(record(0, "[10:00:01] 对方 1：东边苗床浇过水了吗？"), record(1, "[10:00:09] 我：好的。\n[10:00:15] 我：明天一早把豆苗移到温室。"))
        assertEquals("明天一早把豆苗移到温室。", telltaleSentence(talk))
        // Only filler: nothing to show, the row falls back to "一场对话".
        assertEquals("", telltaleSentence(listOf(record(0, "[10:00:01] 我：嗯。"))))
    }
}
