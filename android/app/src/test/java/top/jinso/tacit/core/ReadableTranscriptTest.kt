package top.jinso.tacit.core
import org.junit.Assert.*
import org.junit.Test
class ReadableTranscriptTest {
    @Test fun removesStandaloneFillersAndJoinsConsecutiveTurns() {
        assertEquals("我：今天开始，明天继续。\n\n对方 1：知道了。",readableTranscript("我：嗯。\n我：今天开始\n我：明天继续。\n对方 1：知道了。"))
    }
    @Test fun preservesShortDecisionsAndOtherLanguages() {
        val output=readableTranscript("我：不行\n对方 1：Yes\n对方 2：こんにちは。")
        assertTrue(output.contains("不行"));assertTrue(output.contains("Yes"));assertTrue(output.contains("こんにちは"))
    }
}
