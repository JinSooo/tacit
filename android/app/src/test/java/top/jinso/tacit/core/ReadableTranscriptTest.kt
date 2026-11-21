package top.jinso.tacit.core
import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.ui.firstSentence
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
    }
}
