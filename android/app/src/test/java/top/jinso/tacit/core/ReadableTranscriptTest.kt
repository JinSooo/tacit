package top.jinso.tacit.core
import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.ui.firstSentence
import top.jinso.tacit.ui.telltaleSentence
import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.TestStrings
class ReadableTranscriptTest {
    @Test fun removesStandaloneFillersAndJoinsConsecutiveTurns() {
        assertEquals("我：今天开始，明天继续。\n\n对方 1：知道了。",readableTranscript("我：嗯。\n我：今天开始\n我：明天继续。\n对方 1：知道了。"))
    }
    @Test fun englishTurnsHaveSpacesAndKeepSentenceEndings() {
        val raw = "[10:00:00] 我：We can ship.\n[10:00:02] 我：Run the checks\n[10:00:04] 我：before lunch."
        assertEquals("我：We can ship. Run the checks before lunch.", readableTranscript(raw))
        assertEquals("We can ship.", firstSentence(raw))
        assertEquals("我：先检查。再交付。", readableTranscript("我：先检查。\n我：再交付。"))
    }

    @Test fun speakerLabelsAreLocalizedOnlyForDisplay() {
        val raw = "[10:00:00] 我：We can ship.\n对方 12：Yes.\n其他人：Yes.\n小林：Ready.\n[我] Draft text\n[AI] Good\nInside the text: [我]"
        val english = TestStrings(AppLang.EN)
        assertEquals("Me", speakerDisplayName(SPEAKER_ME, AppLang.EN, english))
        assertEquals("Speaker 12", speakerDisplayName(speakerNumber(12), AppLang.EN, english))
        assertEquals("Others", speakerDisplayName("其他人", AppLang.EN, english))
        assertEquals("[10:00:00] Me：We can ship.\nSpeaker 12：Yes.\nOthers：Yes.\n小林：Ready.\n[Me] Draft text\n[AI] Good\nInside the text: [我]",
            localizeTranscriptLines(raw, AppLang.EN, english))
        assertEquals(raw, localizeTranscriptLines(raw, AppLang.ZH, TestStrings(AppLang.ZH)))
        assertEquals(SPEAKER_ME, transcriptLine(raw.lineSequence().first()).speaker)
    }

    @Test fun englishPreviewRequiresAtLeastThreeSpokenWords() {
        fun record(body: String) = HistoryRecord("r", "android.audio", "Conversation", body, 0, null, null, "normal", null, 0)
        assertEquals("Check all shipments.", telltaleSentence(listOf(record("我：Absolutely.\n对方 1：Check all shipments."))))
        assertEquals("Ship the build.", telltaleSentence(listOf(record("我：Ship the build.\n对方 1：Check all of the shipments."))))
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
